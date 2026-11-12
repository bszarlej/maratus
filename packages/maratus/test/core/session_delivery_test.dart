import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

const _clientId = PeerId(2);
const _otherId = PeerId(3);
const _timeout = Duration(milliseconds: 20);

final class _Schema {
  _Schema() {
    final builder = ProtocolSchemaBuilder();
    board = builder.addStaticEntity(const StaticEntityId('test.board'));
    spawnType = builder.addSpawnType(
      const SpawnTypeId('test.actor'),
      const IntCodec(),
    );
    for (final (name, mode, channel) in [
      ('control', DeliveryMode.reliable, 0),
      ('reliable', DeliveryMode.reliable, 1),
      ('independent', DeliveryMode.reliable, 2),
      ('unreliable', DeliveryMode.unreliable, 1),
      ('ordered', DeliveryMode.unreliableOrdered, 2),
    ]) {
      rpcs[name] = builder.addRpc(
        RpcId('test.$name'),
        const IntCodec(),
        caller: RpcCaller.anyPeer,
        target: RpcTarget.all,
        local: RpcLocal.include,
        deliveryMode: mode,
        channel: channel,
      );
    }
    field = builder.addField(
      const FieldId('test.position'),
      const IntCodec(),
      deliveryMode: DeliveryMode.unreliable,
      channel: 1,
    );
    reliableField = builder.addField(
      const FieldId('test.label'),
      const IntCodec(),
      channel: 2,
    );
    schema = builder.build();
  }

  late final StaticEntity board;
  late final SpawnType<int> spawnType;
  late final SyncField<int> field;
  late final SyncField<int> reliableField;
  late final ProtocolSchema schema;
  final rpcs = <String, Rpc<int>>{};
}

typedef _Received = ({ProtocolMessage message, DeliveryMode mode, int channel});

final class _RecordingPeer implements MultiplayerPeer {
  _RecordingPeer(this.peer, ProtocolSchema schema)
    : codec = ProtocolCodec(schema);

  final MultiplayerPeer peer;
  final ProtocolCodec codec;
  final received = <_Received>[];

  @override
  bool get isHost => peer.isHost;

  @override
  TransportCapabilities get capabilities => peer.capabilities;

  @override
  PeerEvent? poll() {
    final event = peer.poll();
    if (event case MessageReceived(
      :final message,
      :final mode,
      :final channel,
    )) {
      for (final envelope in codec.decodePacket(message)) {
        received.add((message: envelope.message, mode: mode, channel: channel));
      }
    }
    return event;
  }

  @override
  void close() => peer.close();
}

typedef _Call = ({PeerId target, PeerId sender, int value});

final class _Harness {
  _Harness() {
    network = InMemoryNetwork(
      clock: clock,
      deliveryModes: DeliveryMode.values.toSet(),
      channelCount: 3,
    );
    host = _session(network.host());
    first = _session(network.connect());
    second = _session(network.connect());
    run();
    expect(first.state, SessionState.ready);
    expect(second.state, SessionState.ready);
  }

  final clock = ManualClock();
  final schema = _Schema();
  final peers = <_RecordingPeer>[];
  final sessions = <MultiplayerSession>[];
  final calls = <_Call>[];
  late final InMemoryNetwork network;
  late final MultiplayerSession host;
  late final MultiplayerSession first;
  late final MultiplayerSession second;

  MultiplayerSession _session(MultiplayerPeer transport) {
    final peer = _RecordingPeer(transport, schema.schema);
    final session = MultiplayerSession(
      schema: schema.schema,
      clock: clock,
      pingInterval: null,
    );
    if (peer.isHost) {
      session.host(peer);
    } else {
      session.join(peer);
    }
    final entity = session.staticEntity(schema.board);
    session.registry.markReady(entity.id);
    for (final rpc in schema.rpcs.values) {
      session.bindRpc(entity, rpc, (context, value) {
        calls.add((
          target: context.target,
          sender: context.sender,
          value: value,
        ));
      });
    }
    peers.add(peer);
    sessions.add(session);
    addTearDown(session.close);
    return session;
  }

  void run() {
    for (var round = 0; round < 8; round++) {
      clock.advance(Duration.zero);
      for (final session in sessions) {
        session.update();
      }
    }
  }

  bool call(MultiplayerSession sender, Rpc<int> rpc, int value) =>
      sender.callRpc(sender.staticEntity(schema.board), rpc, value);
}

final class _RawHost {
  _RawHost({QueueLimits pendingDeliveryLimits = const QueueLimits()}) {
    network = InMemoryNetwork(
      clock: clock,
      deliveryModes: DeliveryMode.values.toSet(),
      channelCount: 3,
    );
    peer = network.host();
    codec = ProtocolCodec(schema.schema);
    client = MultiplayerSession(
      schema: schema.schema,
      clock: clock,
      pingInterval: null,
      pendingDeliveryLimits: pendingDeliveryLimits,
      timeouts: const SessionTimeouts(bootstrap: _timeout),
      onMessage: (_, envelope) => states.add(envelope.message as StateMessage),
    )..join(network.connect());
    entity = client.staticEntity(schema.board);
    client.registry.markReady(entity.id);
    for (final rpc in schema.rpcs.values) {
      client.bindRpc(entity, rpc, (_, value) => calls.add(value));
    }
    addTearDown(client.close);
    addTearDown(peer.close);
    run();
    send(const WelcomeMessage(peer: _clientId, epoch: 1));
    send(const SyncedMessage());
    run();
    expect(client.state, SessionState.ready);
  }

  final schema = _Schema();
  final clock = ManualClock();
  final calls = <int>[];
  final states = <StateMessage>[];
  late final InMemoryNetwork network;
  late final InMemoryHost peer;
  late final ProtocolCodec codec;
  late final MultiplayerSession client;
  late final NetworkEntity entity;
  late PeerConnection connection;

  void run() {
    for (var round = 0; round < 8; round++) {
      clock.advance(Duration.zero);
      for (var event = peer.poll(); event != null; event = peer.poll()) {
        if (event case ConnectionOpened(:final connection)) {
          this.connection = connection;
        }
      }
      client.update();
    }
  }

  void send(
    ProtocolMessage message, {
    int revision = 0,
    int generation = 5,
    DeliveryMode mode = DeliveryMode.reliable,
    int channel = 0,
  }) {
    connection.send(
      codec.encode(
        MessageEnvelope(message, generation: generation, revision: revision),
      ),
      mode: mode,
      channel: channel,
    );
  }

  void rpc(String name, int value, {int revision = 0}) {
    final rpc = schema.rpcs[name]!;
    send(
      RpcDeliveryMessage(
        entity: entity.id,
        rpc: rpc.id,
        payload: value,
        sender: PeerId.host,
        target: _clientId,
      ),
      revision: revision,
      mode: rpc.deliveryMode,
      channel: rpc.channel,
    );
  }

  void state(int value, int sequence, {int revision = 0}) => send(
    StateMessage(
      entity: entity.id,
      values: {schema.field.id: value},
      sampledAt: Duration(microseconds: sequence),
      sequence: sequence,
    ),
    revision: revision,
    mode: schema.field.deliveryMode,
    channel: schema.field.channel,
  );
}

void main() {
  for (final name in ['control', 'reliable', 'unreliable', 'ordered']) {
    test('$name RPC delivery is preserved through host routing and relays', () {
      final harness = _Harness();
      final rpc = harness.schema.rpcs[name]!;
      for (final peer in harness.peers) {
        for (final record in peer.received) {
          expect(record.mode, DeliveryMode.reliable);
          expect(record.channel, 0);
        }
        peer.received.clear();
      }

      expect(harness.call(harness.first, rpc, 10), isTrue);
      harness.run();
      expect(
        harness.calls,
        unorderedEquals([
          (target: PeerId.host, sender: _clientId, value: 10),
          (target: _clientId, sender: _clientId, value: 10),
          (target: _otherId, sender: _clientId, value: 10),
        ]),
      );
      expect(harness.peers.first.received.single.message, isA<RpcMessage>());
      for (final peer in harness.peers) {
        expect(peer.received, hasLength(1));
        expect(peer.received.single.mode, rpc.deliveryMode);
        expect(peer.received.single.channel, rpc.channel);
        peer.received.clear();
      }
      harness.calls.clear();

      expect(harness.call(harness.host, rpc, 20), isTrue);
      harness.run();
      expect(
        harness.calls,
        unorderedEquals([
          (target: PeerId.host, sender: PeerId.host, value: 20),
          (target: _clientId, sender: PeerId.host, value: 20),
          (target: _otherId, sender: PeerId.host, value: 20),
        ]),
      );
      expect(harness.peers.first.received, isEmpty);
      for (final peer in harness.peers.skip(1)) {
        expect(peer.received.single.message, isA<RpcDeliveryMessage>());
        expect(peer.received.single.mode, rpc.deliveryMode);
        expect(peer.received.single.channel, rpc.channel);
      }
    });
  }

  for (final name in ['unreliable', 'ordered']) {
    test(
      '$name RPC request loss does not execute or disturb reliable control',
      () {
        final harness = _Harness();
        final rpc = harness.schema.rpcs[name]!;
        harness.network.dropNextUnreliable(
          fromHost: false,
          channel: rpc.channel,
        );
        expect(harness.call(harness.first, rpc, 1), isTrue);
        harness.run();
        expect(harness.calls, isEmpty);
        expect(
          harness.call(harness.first, harness.schema.rpcs['control']!, 2),
          isTrue,
        );
        harness.run();
        expect(harness.calls.map((call) => call.value), [2, 2, 2]);
        expect(harness.first.state, SessionState.ready);
        expect(harness.second.state, SessionState.ready);
      },
    );

    test('$name RPC relay loss affects only the selected transmission', () {
      final harness = _Harness();
      final rpc = harness.schema.rpcs[name]!;
      harness.network.dropNextUnreliable(fromHost: true, channel: rpc.channel);
      expect(harness.call(harness.first, rpc, 1), isTrue);
      harness.run();
      expect(
        harness.calls,
        unorderedEquals([
          (target: PeerId.host, sender: _clientId, value: 1),
          (target: _otherId, sender: _clientId, value: 1),
        ]),
      );
      expect(harness.first.state, SessionState.ready);
      expect(harness.second.state, SessionState.ready);
    });
  }

  for (final field in [false, true]) {
    for (final hosting in [false, true]) {
      test(
        'unsupported ${field ? 'field' : 'RPC'} capability rejects ${hosting ? 'host' : 'join'} before taking ownership',
        () {
          final builder = ProtocolSchemaBuilder();
          if (field) {
            builder.addField(
              const FieldId('test.field'),
              const IntCodec(),
              channel: 1,
            );
          } else {
            builder.addRpc(
              const RpcId('test.rpc'),
              const IntCodec(),
              deliveryMode: DeliveryMode.unreliable,
            );
          }
          final clock = ManualClock();
          final network = InMemoryNetwork(clock: clock);
          final peer = hosting ? network.host() : network.connect();
          addTearDown(peer.close);
          final session = MultiplayerSession(
            schema: builder.build(),
            clock: clock,
          );
          addTearDown(session.close);

          expect(
            () => hosting ? session.host(peer) : session.join(peer),
            throwsUnsupportedError,
          );
          expect(session.state, SessionState.disconnected);
          expect(peer.isClosed, isFalse);
          session.close();
          expect(peer.isClosed, isFalse);
        },
      );
    }
  }

  test(
    'reliable client RPC overtaking Ready waits for the host to accept Ready',
    () {
      final harness = _Harness();
      final raw = harness.network.connect();
      addTearDown(raw.close);
      harness.run();
      final connection = (raw.poll()! as ConnectionOpened).connection;
      final codec = ProtocolCodec(harness.schema.schema);
      connection.send(
        codec.encode(
          MessageEnvelope(
            HelloMessage(fingerprint: harness.schema.schema.fingerprint),
          ),
        ),
      );
      harness.run();
      MessageEnvelope? welcome;
      for (var event = raw.poll(); event != null; event = raw.poll()) {
        if (event is MessageReceived) {
          final envelope = codec.decode(event.message);
          if (envelope.message is WelcomeMessage) welcome = envelope;
        }
      }
      expect(welcome, isNotNull);
      final peer = (welcome!.message as WelcomeMessage).peer;
      expect(harness.host.isReady(peer), isFalse);
      final rpc = harness.schema.rpcs['reliable']!;
      connection.send(
        codec.encode(
          MessageEnvelope(
            RpcMessage(
              entity: harness.host.staticEntity(harness.schema.board).id,
              rpc: rpc.id,
              payload: 77,
            ),
            generation: welcome.generation,
            revision: welcome.revision,
          ),
        ),
        mode: rpc.deliveryMode,
        channel: rpc.channel,
      );
      harness.run();
      expect(harness.calls, isEmpty);
      expect(harness.host.isReady(peer), isFalse);

      connection.send(
        codec.encode(
          MessageEnvelope(
            const ReadyMessage(),
            generation: welcome.generation,
            revision: welcome.revision,
          ),
        ),
      );
      harness.run();
      expect(harness.host.isReady(peer), isTrue);
      expect(
        harness.calls,
        unorderedEquals([
          (target: PeerId.host, sender: peer, value: 77),
          (target: _clientId, sender: peer, value: 77),
          (target: _otherId, sender: peer, value: 77),
        ]),
      );
    },
  );

  test(
    'reliable gameplay waits for control and preserves only its own channel order',
    () {
      final harness = _RawHost();
      harness.rpc('reliable', 10, revision: 2);
      harness.rpc('reliable', 20, revision: 1);
      harness.rpc('independent', 30);
      harness.run();
      expect(harness.calls, [30]);
      expect(harness.client.revision, 0);

      harness.send(const PeerJoinedMessage(peer: _otherId), revision: 1);
      harness.run();
      expect(harness.calls, [30]);
      harness.send(const PeerReadyMessage(peer: _otherId), revision: 2);
      harness.run();
      expect(harness.calls, [30, 10, 20]);
      expect(harness.client.revision, 2);
      expect(harness.client.state, SessionState.ready);
    },
  );

  test(
    'independent reliable state waits for lifecycle without advancing its revision',
    () {
      final harness = _RawHost();
      final field = harness.schema.reliableField;
      harness.send(
        StateMessage(
          entity: harness.entity.id,
          values: {field.id: 42},
          sampledAt: const Duration(milliseconds: 1),
          sequence: 50,
        ),
        revision: 1,
        channel: field.channel,
      );
      harness.run();
      expect(harness.states, isEmpty);
      expect(harness.client.revision, 0);
      harness.send(const PeerJoinedMessage(peer: _otherId), revision: 1);
      harness.run();
      expect(harness.states.single.values[field.id], 42);
      expect(harness.client.revision, 1);
      expect(harness.client.state, SessionState.ready);
    },
  );

  test(
    'unreliable gameplay overtaking its lifecycle dependency is discarded',
    () {
      final harness = _RawHost();
      harness.rpc('unreliable', 1, revision: 1);
      harness.state(1, 1, revision: 1);
      harness.run();
      expect(harness.calls, isEmpty);
      expect(harness.states, isEmpty);
      harness.send(const PeerJoinedMessage(peer: _otherId), revision: 1);
      harness.run();
      expect(harness.calls, isEmpty);
      expect(harness.states, isEmpty);

      harness.rpc('unreliable', 2, revision: 1);
      harness.state(2, 2, revision: 1);
      harness.run();
      expect(harness.calls, [2]);
      expect(harness.states.single.values[harness.schema.field.id], 2);
      expect(harness.client.revision, 1);
    },
  );

  test(
    'unreliable state overtaking spawn and despawn cannot discard either control record',
    () {
      final harness = _RawHost();
      const spawnedId = EntityId(7);
      final lifecycle = <String>[];
      harness.client.bindSpawn(
        harness.schema.spawnType,
        onSpawn: (context) {
          lifecycle.add('spawn ${context.data}');
          harness.client.registry.markReady(context.entity.id);
        },
        onDespawn: (_) => lifecycle.add('despawn'),
      );
      void state(int revision) => harness.send(
        StateMessage(
          entity: spawnedId,
          values: {harness.schema.field.id: revision},
          sampledAt: Duration(milliseconds: revision),
          sequence: revision,
        ),
        revision: revision,
        mode: DeliveryMode.unreliable,
        channel: 1,
      );

      state(1);
      harness.run();
      expect(harness.client.revision, 0);
      expect(harness.states, isEmpty);
      harness.send(
        SpawnMessage(
          entity: spawnedId,
          type: harness.schema.spawnType.id,
          data: 42,
          owner: PeerId.host,
          authority: PeerId.host,
        ),
        revision: 1,
      );
      harness.run();
      final entity = harness.client.registry[spawnedId]!;
      expect(entity.state, EntityState.ready);
      expect(lifecycle, ['spawn 42']);
      expect(harness.client.revision, 1);

      state(2);
      harness.run();
      expect(harness.client.revision, 1);
      expect(harness.states, isEmpty);
      harness.send(const DespawnMessage(entity: spawnedId), revision: 2);
      harness.run();
      expect(entity.state, EntityState.removed);
      expect(lifecycle, ['spawn 42', 'despawn']);
      expect(harness.client.revision, 2);
      expect(harness.client.state, SessionState.ready);
    },
  );

  test('pending reliable delivery enforces its message limit', () {
    final harness = _RawHost(
      pendingDeliveryLimits: const QueueLimits(maxMessages: 1),
    );
    harness.rpc('reliable', 1, revision: 1);
    harness.run();
    expect(harness.client.state, SessionState.ready);
    harness.rpc('reliable', 2, revision: 1);
    harness.run();
    expect(harness.calls, isEmpty);
    expect(harness.client.disconnectReason, DisconnectReason.transportError);
  });

  test('pending reliable delivery enforces its byte limit', () {
    final harness = _RawHost(
      pendingDeliveryLimits: const QueueLimits(maxBytes: 1),
    );
    harness.rpc('reliable', 1, revision: 1);
    harness.run();
    expect(harness.calls, isEmpty);
    expect(harness.client.disconnectReason, DisconnectReason.transportError);
  });

  test('pending reliable delivery expires even after the session is ready', () {
    final harness = _RawHost();
    harness.rpc('reliable', 1, revision: 1);
    harness.run();
    harness.clock.advance(_timeout - const Duration(microseconds: 1));
    harness.run();
    expect(harness.client.state, SessionState.ready);
    harness.clock.advance(const Duration(microseconds: 1));
    harness.run();
    expect(harness.calls, isEmpty);
    expect(harness.client.disconnectReason, DisconnectReason.timeout);
  });

  test('closing a session clears gameplay waiting for a dependency', () {
    final harness = _RawHost();
    harness.rpc('reliable', 1, revision: 1);
    harness.run();
    harness.client.close();
    harness.clock.advance(_timeout);
    harness.run();
    expect(harness.calls, isEmpty);
    expect(harness.client.disconnectReason, DisconnectReason.closed);
    expect(harness.network.links, isEmpty);
    expect(harness.clock.pendingTimerCount, 0);
  });

  test('a configured RPC delivered on the wrong channel is rejected', () {
    final harness = _RawHost();
    harness.send(
      RpcDeliveryMessage(
        entity: harness.entity.id,
        rpc: harness.schema.rpcs['reliable']!.id,
        payload: 1,
        sender: PeerId.host,
        target: _clientId,
      ),
    );
    harness.run();
    expect(harness.calls, isEmpty);
    expect(harness.client.disconnectReason, DisconnectReason.protocolViolation);
  });

  test(
    'old generation gameplay does not occupy the pending delivery budget',
    () {
      final harness = _RawHost(
        pendingDeliveryLimits: const QueueLimits(maxMessages: 1),
      );
      for (var i = 0; i < 2; i++) {
        harness.send(
          RpcDeliveryMessage(
            entity: harness.entity.id,
            rpc: harness.schema.rpcs['reliable']!.id,
            payload: i,
            sender: PeerId.host,
            target: _clientId,
          ),
          generation: 4,
          revision: 1,
          channel: 1,
        );
      }
      harness.run();
      harness.rpc('reliable', 3);
      harness.run();
      expect(harness.calls, [3]);
      expect(harness.client.state, SessionState.ready);
    },
  );

  test(
    'state from a previous authority revision cannot replace new authority state',
    () {
      final harness = _RawHost();
      harness.state(10, 10);
      harness.run();
      harness.send(const PeerJoinedMessage(peer: _otherId), revision: 1);
      harness.send(
        AuthorityMessage(entity: harness.entity.id, authority: _otherId),
        revision: 2,
      );
      harness.run();
      harness.state(20, 1, revision: 2);
      harness.run();
      harness.state(99, 99, revision: 1);
      harness.run();

      expect(
        harness.states.map(
          (message) => message.values[harness.schema.field.id],
        ),
        [10, 20],
      );
      expect(harness.client.revision, 2);
      expect(harness.client.state, SessionState.ready);
    },
  );
}
