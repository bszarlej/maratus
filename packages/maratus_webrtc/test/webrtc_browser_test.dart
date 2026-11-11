@TestOn('browser')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus_webrtc/maratus_webrtc.dart';
import 'package:test/test.dart';

import 'support/in_memory_signaling.dart';

/// Polls both peers into their event lists until [condition] holds.
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
      fail('Browser WebRTC condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Calls [update] until [condition] holds.
Future<void> _sessionsUntil(
  bool Function() condition, {
  required void Function() update,
}) async {
  final deadline = Stopwatch()..start();
  while (true) {
    update();
    if (condition()) return;
    if (deadline.elapsed > const Duration(seconds: 20)) {
      fail('Browser WebRTC session condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Iterable<MessageReceived> _messages(List<PeerEvent> events) =>
    events.whereType<MessageReceived>();

void main() {
  late InMemorySignaling signaling;

  WebRtcHost host({int channelCount = 1, int maxConnections = 64}) {
    final peer = WebRtcHost(
      signaling: signaling,
      channelCount: channelCount,
      maxConnections: maxConnections,
    );
    addTearDown(() async {
      peer.close();
      await peer.done;
    });
    return peer;
  }

  WebRtcClient client({int channelCount = 1}) {
    final peer = WebRtcClient.connect(
      signaling.join(),
      channelCount: channelCount,
    );
    addTearDown(() async {
      peer.close();
      await peer.done;
    });
    return peer;
  }

  setUp(() => signaling = InMemorySignaling());

  test('browsers support WebRTC hosting', () {
    expect(WebRtcHost.isSupported, isTrue);
    expect(host().capabilities.canHost, isTrue);
  });

  test('peers in one page exchange every delivery mode and close', () async {
    final server = host(channelCount: 2);
    final peer = client(channelCount: 2);
    final hostEvents = <PeerEvent>[];
    final clientEvents = <PeerEvent>[];
    final both = [(server, hostEvents), (peer, clientEvents)];
    await _until(
      () =>
          hostEvents.whereType<ConnectionOpened>().isNotEmpty &&
          clientEvents.whereType<ConnectionOpened>().isNotEmpty,
      both,
    );
    final hostConnection = hostEvents.single.connection;
    final clientConnection = clientEvents.single.connection;

    final large = Uint8List.fromList([
      for (var index = 0; index < 100000; index++) index % 253,
    ]);
    expect(clientConnection.send(Uint8List.fromList([1])), isTrue);
    expect(clientConnection.send(large, channel: 1), isTrue);
    await _until(() => _messages(hostEvents).length == 2, both);
    expect(_messages(hostEvents).first.message, [1]);
    expect(_messages(hostEvents).last.message, large);
    expect(_messages(hostEvents).last.channel, 1);
    await _until(() => clientConnection.outgoing.messages == 0, both);

    // Datagrams can be lost even in one page, so send until one arrives.
    for (final (mode, channel) in [
      (DeliveryMode.unreliableOrdered, 0),
      (DeliveryMode.unreliable, 1),
    ]) {
      bool arrived() => _messages(
        hostEvents,
      ).any((event) => event.mode == mode && event.channel == channel);
      await _until(() {
        if (!arrived()) {
          clientConnection.send(
            Uint8List.fromList([mode.index]),
            mode: mode,
            channel: channel,
          );
        }
        return arrived();
      }, both);
    }
    await _until(() => clientConnection.outgoing.messages == 0, both);

    hostConnection.send(Uint8List.fromList([9]), channel: 1);
    await _until(() => _messages(clientEvents).isNotEmpty, both);
    expect(_messages(clientEvents).single.message, [9]);

    clientConnection.close();
    await _until(
      () => hostEvents.whereType<ConnectionClosed>().isNotEmpty,
      both,
    );
    expect(
      hostEvents.whereType<ConnectionClosed>().single.reason,
      CloseReason.remote,
    );
    await peer.done;
  });

  test('a client with other channels is refused', () async {
    final server = host();
    final peer = client(channelCount: 2);
    final hostEvents = <PeerEvent>[];
    final clientEvents = <PeerEvent>[];
    await _until(() => clientEvents.isNotEmpty, [
      (server, hostEvents),
      (peer, clientEvents),
    ]);
    expect(
      clientEvents.single,
      isA<ConnectionClosed>().having(
        (event) => event.reason,
        'reason',
        CloseReason.connectFailed,
      ),
    );
    expect(hostEvents, isEmpty);
    await peer.done;
  });

  test('closing the host closes its clients', () async {
    final server = host();
    final peers = [client(), client()];
    final hostEvents = <PeerEvent>[];
    final clientEvents = [<PeerEvent>[], <PeerEvent>[]];
    final all = [
      (server, hostEvents),
      for (final (index, peer) in peers.indexed) (peer, clientEvents[index]),
    ];
    await _until(
      () => hostEvents.whereType<ConnectionOpened>().length == 2,
      all,
    );
    await _until(() => clientEvents.every((events) => events.isNotEmpty), all);
    server.close();
    await _until(
      () => clientEvents.every(
        (events) => events.whereType<ConnectionClosed>().isNotEmpty,
      ),
      all,
    );
    for (final events in clientEvents) {
      expect(
        events.whereType<ConnectionClosed>().single.reason,
        CloseReason.remote,
      );
    }
    await server.done;
  });

  test(
    'sessions assign two identities and route typed RPCs over WebRTC',
    () async {
      final builder = ProtocolSchemaBuilder();
      final chat = builder.addRpc(
        const RpcId('chat'),
        const StringCodec(maxLength: 100),
        target: RpcTarget.all,
        local: RpcLocal.include,
      );
      final schema = builder.build();
      final sessions = [
        MultiplayerSession(schema: schema)..host(host()),
        MultiplayerSession(schema: schema)..join(client()),
        MultiplayerSession(schema: schema)..join(client()),
      ];
      addTearDown(() {
        for (final session in sessions) {
          session.close();
        }
      });
      final received = List.generate(3, (_) => <(PeerId, String)>[]);
      final entities = <NetworkEntity>[];
      for (var i = 0; i < sessions.length; i++) {
        final session = sessions[i];
        final entity = session.registry.register(
          const EntityId(1),
          owner: PeerId.host,
          authority: PeerId.host,
        );
        entities.add(entity);
        session.registry.markReady(entity.id);
        session.bindRpc(
          entity,
          chat,
          (context, value) => received[i].add((context.sender, value)),
        );
      }
      void update() {
        for (final session in sessions) {
          session.update();
        }
      }

      await _sessionsUntil(
        () =>
            sessions.skip(1).every((s) => s.state == SessionState.ready) &&
            sessions.first.peers.every(sessions.first.isReady),
        update: update,
      );
      expect(sessions[1].localPeer, isNot(sessions[2].localPeer));
      expect(
        sessions[1].callRpc(entities[1], chat, 'hello over WebRTC'),
        isTrue,
      );
      await _sessionsUntil(
        () => received.every((messages) => messages.isNotEmpty),
        update: update,
      );
      for (final messages in received) {
        expect(messages, [(sessions[1].localPeer!, 'hello over WebRTC')]);
      }
      sessions.first.close();
      await _sessionsUntil(
        () =>
            sessions.skip(1).every((s) => s.state == SessionState.disconnected),
        update: update,
      );
      expect(sessions[1].disconnectReason, DisconnectReason.remoteClosed);
      expect(sessions[2].disconnectReason, DisconnectReason.remoteClosed);
    },
  );

  for (final mode in DeliveryMode.values) {
    test('sessions exchange $mode RPCs and fields on channel one', () async {
      final builder = ProtocolSchemaBuilder();
      final rpc = builder.addRpc(
        const RpcId('input'),
        const IntCodec(),
        target: RpcTarget.all,
        deliveryMode: mode,
        channel: 1,
      );
      final field = builder.addField(
        const FieldId('position'),
        const IntCodec(),
        deliveryMode: mode,
        channel: 1,
      );
      final schema = builder.build();
      final clock = ManualClock();
      final sessions = [
        MultiplayerSession(schema: schema, clock: clock)
          ..host(host(channelCount: 2)),
        MultiplayerSession(schema: schema, clock: clock)
          ..join(client(channelCount: 2)),
      ];
      addTearDown(() {
        for (final session in sessions) {
          session.close();
        }
      });
      final values = [42, 0];
      final received = [<int>[], <int>[]];
      final entities = <NetworkEntity>[];
      for (var i = 0; i < sessions.length; i++) {
        final session = sessions[i];
        final entity = session.registry.register(
          const EntityId(1),
          owner: PeerId.host,
          authority: PeerId.host,
        );
        entities.add(entity);
        final attachment = session.attachEntity(
          entity,
          isReady: () => true,
          isValid: () => true,
        );
        attachment.bindRpc(rpc, (_, value) => received[i].add(value));
        attachment.synchronize([
          field.property(
            get: () => values[i],
            set: (value) => values[i] = value,
            mode: SyncMode.always,
          ),
        ], interval: const Duration(milliseconds: 10));
      }
      void update() {
        clock.advance(const Duration(milliseconds: 10));
        for (final session in sessions) {
          session.update();
        }
      }

      await _sessionsUntil(
        () =>
            sessions[1].state == SessionState.ready &&
            sessions[0].isReady(sessions[1].localPeer!),
        update: update,
      );
      // Retransmission here belongs to the test's application, since an
      // unreliable RPC is allowed to disappear even within one page.
      await _sessionsUntil(
        () => received.every((calls) => calls.isNotEmpty) && values[1] == 42,
        update: () {
          update();
          if (received[0].isEmpty) sessions[1].callRpc(entities[1], rpc, 7);
          if (received[1].isEmpty) sessions[0].callRpc(entities[0], rpc, 9);
          sessions[0].captureState();
        },
      );
      expect(received[0], everyElement(7));
      expect(received[1], everyElement(9));
    });
  }
}
