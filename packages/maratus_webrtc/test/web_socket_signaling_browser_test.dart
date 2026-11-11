@TestOn('browser')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus_webrtc/maratus_webrtc.dart';
import 'package:test/test.dart';

Future<void> _until(
  bool Function() condition,
  List<(MultiplayerPeer, List<PeerEvent>)> peers,
) async {
  final deadline = Stopwatch()..start();
  while (true) {
    for (final (peer, events) in peers) {
      for (var event = peer.poll(); event != null; event = peer.poll()) {
        events.add(event);
      }
    }
    if (condition()) return;
    if (deadline.elapsed > const Duration(seconds: 20)) {
      fail('Browser signaling condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Uri server;

  setUpAll(() async {
    final channel = spawnHybridUri(
      'support/signaling_server_hybrid.dart',
      stayAlive: true,
    );
    final port = await channel.stream.first as int;
    server = Uri.parse('ws://127.0.0.1:$port/signaling');
  });

  test('browser peers connect through a native signaling server', () async {
    final signaling = await WebSocketHostSignaling.connect(server);
    final host = WebRtcHost(signaling: signaling);
    final client = WebRtcClient.connect(
      WebSocketSignalingChannel.join(server, room: signaling.room),
    );
    addTearDown(() async {
      host.close();
      client.close();
      await Future.wait([host.done, client.done]);
    });
    final hostEvents = <PeerEvent>[];
    final clientEvents = <PeerEvent>[];
    final both = [(host, hostEvents), (client, clientEvents)];
    await _until(() => hostEvents.isNotEmpty && clientEvents.isNotEmpty, both);
    expect(hostEvents.single, isA<ConnectionOpened>());
    expect(clientEvents.single, isA<ConnectionOpened>());

    clientEvents.single.connection.send(Uint8List.fromList([1, 2, 3]));
    await _until(() => hostEvents.length == 2, both);
    expect((hostEvents.last as MessageReceived).message, [1, 2, 3]);
  });

  test('an unknown room fails the client', () async {
    final client = WebRtcClient.connect(
      WebSocketSignalingChannel.join(server, room: 'missing'),
    );
    addTearDown(() async {
      client.close();
      await client.done;
    });
    final events = <PeerEvent>[];
    await _until(() => events.isNotEmpty, [(client, events)]);
    expect(
      events.single,
      isA<ConnectionClosed>().having(
        (event) => event.reason,
        'reason',
        CloseReason.connectFailed,
      ),
    );
  });

  test('a taken room name is refused', () async {
    final first = await WebSocketHostSignaling.connect(server, room: 'taken');
    addTearDown(first.close);
    await expectLater(
      WebSocketHostSignaling.connect(server, room: 'taken'),
      throwsA(
        isA<SignalingException>().having(
          (error) => error.message,
          'message',
          'room-unavailable',
        ),
      ),
    );
  });
}
