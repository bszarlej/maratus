@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus_enet/maratus_enet.dart';
import 'package:test/test.dart';

Future<void> _until(
  bool Function() condition, {
  void Function()? update,
}) async {
  final deadline = Stopwatch()..start();
  while (true) {
    update?.call();
    if (condition()) return;
    if (deadline.elapsed > const Duration(seconds: 10)) {
      fail('ENet loopback condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

List<PeerEvent> _drain(MultiplayerPeer peer) => [
  for (var event = peer.poll(); event != null; event = peer.poll()) event,
];

void main() {
  Future<EnetHost> host({
    int channelCount = 1,
    QueueLimits outgoingLimits = const QueueLimits(),
    int maxConnections = 64,
  }) async {
    final peer = await EnetHost.bind(
      port: 0,
      channelCount: channelCount,
      outgoingLimits: outgoingLimits,
      maxConnections: maxConnections,
    );
    addTearDown(() async {
      peer.close();
      await peer.done;
    });
    return peer;
  }

  EnetClient client(EnetHost server, {int? channelCount}) {
    final peer = EnetClient.connect(
      '127.0.0.1',
      port: server.port,
      channelCount: channelCount ?? server.capabilities.channelCount,
    );
    addTearDown(() async {
      peer.close();
      await peer.done;
    });
    return peer;
  }

  Future<(PeerConnection, PeerConnection)> connect(
    EnetHost server,
    EnetClient joiner,
  ) async {
    PeerEvent? accepted;
    PeerEvent? connected;
    await _until(
      () => accepted != null && connected != null,
      update: () {
        accepted ??= server.poll();
        connected ??= joiner.poll();
      },
    );
    expect(accepted, isA<ConnectionOpened>());
    expect(connected, isA<ConnectionOpened>());
    return (accepted!.connection, connected!.connection);
  }

  test(
    'native peers expose all modes and independent channel metadata',
    () async {
      final server = await host(channelCount: 2);
      final joiner = client(server);
      final (sending, receiving) = await connect(server, joiner);
      expect(server.port, greaterThan(0));
      expect(joiner.capabilities.canHost, isTrue);
      for (final mode in DeliveryMode.values) {
        for (var channel = 0; channel < 2; channel++) {
          final bytes = Uint8List.fromList([mode.index, channel, 42]);
          expect(sending.send(bytes, mode: mode, channel: channel), isTrue);
          bytes[2] = 99;
          // An unreliable packet may be lost even on loopback. Retry it
          // periodically and tolerate copies of earlier retries still arriving.
          PeerEvent? event;
          final retry = Stopwatch()..start();
          await _until(
            () => event != null,
            update: () {
              final received = joiner.poll();
              if (received case MessageReceived(:final message)) {
                expect(received.mode.index, message[0]);
                expect(received.channel, message[1]);
                expect(message[2], 42);
                if (message[0] == mode.index && message[1] == channel) {
                  event = received;
                }
              } else if (received != null) {
                fail('Unexpected event while exchanging messages: $received');
              }
              if (event == null &&
                  mode != DeliveryMode.reliable &&
                  retry.elapsed >= const Duration(milliseconds: 100)) {
                expect(
                  sending.send(
                    Uint8List.fromList([mode.index, channel, 42]),
                    mode: mode,
                    channel: channel,
                  ),
                  isTrue,
                );
                retry.reset();
              }
            },
          );
          expect(event, isA<MessageReceived>());
          final message = event! as MessageReceived;
          expect(message.message, [mode.index, channel, 42]);
          expect(message.mode, mode);
          expect(message.channel, channel);
        }
      }
      await _until(() => sending.outgoing.messages == 0);
      _drain(joiner);
      expect(receiving.incoming, (messages: 0, bytes: 0));
    },
  );

  test(
    'reliable credit waits for application poll, then overflow closes',
    () async {
      final server = await host(
        outgoingLimits: const QueueLimits(maxMessages: 1),
      );
      final joiner = client(server);
      final (sending, receiving) = await connect(server, joiner);
      expect(sending.send(Uint8List.fromList([1, 2])), isTrue);
      await _until(() => receiving.incoming.messages == 1);
      expect(sending.outgoing, (messages: 1, bytes: 2));
      expect(joiner.poll(), isA<MessageReceived>());
      await _until(() => sending.outgoing.messages == 0);
      expect(sending.send(Uint8List.fromList([3])), isTrue);
      expect(sending.send(Uint8List.fromList([4])), isFalse);
      expect(sending.closeReason, CloseReason.overflow);
      expect((server.poll()! as ConnectionClosed).reason, CloseReason.overflow);
    },
  );

  test(
    'peer close drains copied reliable messages before remote close',
    () async {
      final server = await host();
      final joiner = client(server);
      final (sending, _) = await connect(server, joiner);
      final payload = Uint8List.fromList([7, 8]);
      expect(sending.send(payload), isTrue);
      payload[0] = 0;
      expect(sending.send(Uint8List(0)), isTrue);
      expect(sending.send(Uint8List(64 * 1024)..[65535] = 9), isTrue);
      server.close();
      server.close();
      expect(server.poll(), isNull);
      final events = <PeerEvent>[];
      await _until(
        () => events.any((event) => event is ConnectionClosed),
        update: () => events.addAll(_drain(joiner)),
      );
      final messages = events.whereType<MessageReceived>().toList();
      expect(messages, hasLength(3));
      expect(messages[0].message, [7, 8]);
      expect(messages[1].message, isEmpty);
      expect(messages[2].message, hasLength(64 * 1024));
      expect(messages[2].message.last, 9);
      expect((events.last as ConnectionClosed).reason, CloseReason.remote);
      expect(sending.send(payload), isFalse);
      await server.done;
      final rebound = await EnetHost.bind(port: server.port);
      rebound.close();
      await rebound.done;
    },
  );

  test(
    'sessions assign two identities and route typed RPCs over ENet',
    () async {
      final builder = ProtocolSchemaBuilder();
      final chat = builder.addRpc(
        const RpcId('chat'),
        const StringCodec(maxLength: 100),
        target: RpcTarget.all,
        local: RpcLocal.include,
      );
      final schema = builder.build();
      final server = await host();
      final sessions = [
        MultiplayerSession(schema: schema)..host(server),
        MultiplayerSession(schema: schema)..join(client(server)),
        MultiplayerSession(schema: schema)..join(client(server)),
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

      await _until(
        () =>
            sessions.skip(1).every((s) => s.state == SessionState.ready) &&
            sessions.first.peers.every(sessions.first.isReady),
        update: update,
      );
      expect(sessions[1].localPeer, isNot(sessions[2].localPeer));
      expect(sessions[1].callRpc(entities[1], chat, 'hello over UDP'), isTrue);
      await _until(
        () => received.every((messages) => messages.isNotEmpty),
        update: update,
      );
      for (final messages in received) {
        expect(messages, [(sessions[1].localPeer!, 'hello over UDP')]);
      }
      sessions.first.close();
      await _until(
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
      final server = await host(channelCount: 2);
      final clock = ManualClock();
      final sessions = [
        MultiplayerSession(schema: schema, clock: clock)..host(server),
        MultiplayerSession(schema: schema, clock: clock)..join(client(server)),
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

      await _until(
        () =>
            sessions[1].state == SessionState.ready &&
            sessions[0].isReady(sessions[1].localPeer!),
        update: update,
      );
      // Retransmission here belongs to the test's application, since an
      // unreliable RPC is allowed to disappear even on loopback.
      await _until(
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
      expect(server.capabilities.maxUnreliableMessageBytes, 1000);
    });
  }

  test(
    'failed connection reports one event and cancelled dial stays silent',
    () async {
      final server = await host();
      final unusedPort = server.port;
      server.close();
      await server.done;
      final joiner = EnetClient.connect(
        '127.0.0.1',
        port: unusedPort,
        connectTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(joiner.close);
      PeerEvent? event;
      await _until(() => event != null, update: () => event = joiner.poll());
      expect((event! as ConnectionClosed).reason, CloseReason.connectFailed);
      expect(joiner.poll(), isNull);
      await joiner.done;

      final cancelled = EnetClient.connect('localhost', port: unusedPort);
      cancelled.close();
      await cancelled.done;
      expect(cancelled.poll(), isNull);
    },
  );

  test(
    'mismatched channel counts cannot establish a usable connection',
    () async {
      final server = await host();
      final joiner = client(server, channelCount: 2);
      PeerEvent? event;
      await _until(() => event != null, update: () => event = joiner.poll());
      expect((event! as ConnectionClosed).reason, CloseReason.connectFailed);
      await joiner.done;
    },
  );

  test('invalid arguments fail before native allocation', () async {
    for (final address in ['', '::1', 'host\u0000suffix']) {
      expect(() => EnetClient.connect(address), throwsArgumentError);
      await expectLater(EnetHost.bind(address: address), throwsArgumentError);
    }
    for (final channels in [0, 86]) {
      expect(
        () => EnetClient.connect('127.0.0.1', channelCount: channels),
        throwsArgumentError,
      );
    }
    expect(() => EnetClient.connect('127.0.0.1', port: 0), throwsArgumentError);
    expect(
      () => EnetClient.connect('127.0.0.1', connectTimeout: Duration.zero),
      throwsArgumentError,
    );
    await expectLater(EnetHost.bind(maxConnections: 0), throwsArgumentError);
  });
}
