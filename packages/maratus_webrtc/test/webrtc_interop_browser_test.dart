@TestOn('browser')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus_webrtc/maratus_webrtc.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

/// A native peer running in a hybrid isolate, and what it reported.
final class _NativePeer {
  _NativePeer(String role) {
    channel = spawnHybridUri('support/native_peer_hybrid.dart', message: role);
    channel.stream.listen(reports.add);
  }

  late final StreamChannel<Object?> channel;
  final reports = <Object?>[];

  Map<Object?, Object?> get setup => reports.first! as Map<Object?, Object?>;

  bool get opened => reports.contains('opened');

  String? get closed => reports
      .whereType<Map<Object?, Object?>>()
      .map((report) => report['closed'] as String?)
      .nonNulls
      .firstOrNull;
}

Future<void> _until(
  bool Function() condition, {
  void Function()? update,
}) async {
  final deadline = Stopwatch()..start();
  while (true) {
    update?.call();
    if (condition()) return;
    if (deadline.elapsed > const Duration(seconds: 20)) {
      fail('Interoperability condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Sends every delivery mode and waits for the native peer's echoes.
Future<void> _exchange(
  MultiplayerPeer peer,
  PeerConnection connection,
  List<PeerEvent> events,
) async {
  void pump() {
    for (var event = peer.poll(); event != null; event = peer.poll()) {
      events.add(event);
    }
  }

  Iterable<MessageReceived> echoes() => events.whereType<MessageReceived>();
  final large = Uint8List.fromList([
    for (var index = 0; index < 50000; index++) index % 241,
  ]);
  connection
    ..send(Uint8List.fromList([1, 2, 3]))
    ..send(large, channel: 1);
  await _until(() => echoes().length == 2, update: pump);
  expect(echoes().first.message, [1, 2, 3]);
  expect(echoes().last.message, large);
  expect(echoes().last.channel, 1);
  // Datagrams can be lost even on loopback, so send until one returns.
  for (final (mode, channel) in [
    (DeliveryMode.unreliableOrdered, 0),
    (DeliveryMode.unreliable, 1),
  ]) {
    bool returned() =>
        echoes().any((event) => event.mode == mode && event.channel == channel);
    await _until(
      returned,
      update: () {
        pump();
        if (!returned()) {
          connection.send(
            Uint8List.fromList([9]),
            mode: mode,
            channel: channel,
          );
        }
      },
    );
  }
  await _until(() => connection.outgoing.messages == 0, update: pump);
}

void main() {
  test('a browser client connects to a native host', () async {
    final native = _NativePeer('host');
    addTearDown(native.channel.sink.close);
    await _until(() => native.reports.isNotEmpty);
    final server = Uri.parse(
      'ws://127.0.0.1:${native.setup['port']}/signaling',
    );
    final client = WebRtcClient.connect(
      WebSocketSignalingChannel.join(
        server,
        room: native.setup['room']! as String,
      ),
      channelCount: 2,
    );
    addTearDown(() async {
      client.close();
      await client.done;
    });
    final events = <PeerEvent>[];
    await _until(
      () => events.isNotEmpty,
      update: () => events.addAll([?client.poll()]),
    );
    expect(events.single, isA<ConnectionOpened>());
    await _exchange(client, events.single.connection, events);
    events.first.connection.close();
    await _until(() => native.closed != null);
    expect(native.closed, 'remote');
  });

  test('a native client connects to a browser host', () async {
    final native = _NativePeer('client');
    addTearDown(native.channel.sink.close);
    await _until(() => native.reports.isNotEmpty);
    final server = Uri.parse(
      'ws://127.0.0.1:${native.setup['port']}/signaling',
    );
    final signaling = await WebSocketHostSignaling.connect(server);
    final host = WebRtcHost(signaling: signaling, channelCount: 2);
    addTearDown(() async {
      host.close();
      await host.done;
    });
    native.channel.sink.add(signaling.room);
    final events = <PeerEvent>[];
    await _until(
      () => events.isNotEmpty,
      update: () => events.addAll([?host.poll()]),
    );
    expect(events.single, isA<ConnectionOpened>());
    await _until(() => native.opened);
    await _exchange(host, events.single.connection, events);
    host.close();
    await _until(() => native.closed != null);
    expect(native.closed, 'remote');
  });
}
