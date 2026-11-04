import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

const _interval = Duration(milliseconds: 50);
const _client1 = PeerId(2);

/// A connection is congested from two unacknowledged messages.
const _backpressure = QueueLimits(maxMessages: 2);

/// The registrations shared by every session of a test.
final class _Schema {
  _Schema() {
    final builder = ProtocolSchemaBuilder();
    health = builder.addField(
      const FieldId('test.health'),
      const IntCodec(min: 0, max: 1000),
    );
    effect = builder.addRpc(
      const RpcId('test.effect'),
      const BoolCodec(),
      caller: RpcCaller.host,
      target: RpcTarget.all,
    );
    item = builder.addSpawnType(
      const SpawnTypeId('test.item'),
      const BoolCodec(),
    );
    schema = builder.build();
  }

  late final SyncField<int> health;
  late final Rpc<bool> effect;
  late final SpawnType<bool> item;
  late final ProtocolSchema schema;
}

/// One peer's synchronized health of an entity.
final class _Model {
  _Model(MultiplayerSession session, NetworkEntity entity, _Schema schema) {
    attachment = session.attachEntity(
      entity,
      isReady: () => true,
      isValid: () => true,
    );
    attachment
      ..synchronize([
        schema.health.property(
          get: () => health,
          set: (value) {
            health = value;
            applied.add(value);
          },
        ),
      ], interval: _interval)
      ..bindRpc(schema.effect, (_, _) => effects.add(health));
  }

  late final EntityAttachment attachment;
  var health = 0;
  final applied = <int>[];

  /// The health this model had when each effect RPC ran.
  final effects = <int>[];
}

/// A host and the clients that join it over an in-memory network.
final class _Harness {
  _Harness() {
    network = InMemoryNetwork(clock: clock);
    host = _session()..host(network.host());
  }

  final clock = ManualClock();
  final schema = _Schema();
  late final InMemoryNetwork network;
  late final MultiplayerSession host;
  final sessions = <MultiplayerSession>[];

  /// The state messages each session accepted, by entity ID.
  final observed = <MultiplayerSession, List<int>>{};

  MultiplayerSession _session() {
    late final MultiplayerSession session;
    session = MultiplayerSession(
      schema: schema.schema,
      clock: clock,
      stateBackpressure: _backpressure,
      onMessage: (_, envelope) => observed
          .putIfAbsent(session, () => [])
          .add((envelope.message as StateMessage).entity.value),
    );
    addTearDown(session.close);
    sessions.add(session);
    return session;
  }

  MultiplayerSession join() => _session()..join(network.connect());

  /// Registers static entity [id] on every session, in session order.
  List<NetworkEntity> register(
    int id, {
    PeerId owner = PeerId.host,
    PeerId authority = PeerId.host,
  }) => [
    for (final session in sessions)
      session.registry.register(
        EntityId(id),
        owner: owner,
        authority: authority,
      ),
  ];

  /// Delivers everything in transit and updates every session except the
  /// [stalled] ones.
  void settle({Set<MultiplayerSession> stalled = const {}}) {
    for (var i = 0; i < 6; i++) {
      clock.advance(Duration.zero);
      for (final session in sessions) {
        if (!stalled.contains(session)) session.update();
      }
    }
  }

  /// After an interval, sets each model's health and captures it on
  /// [writer], then delivers it to the sessions that are not [stalled].
  void sample(
    MultiplayerSession writer,
    Map<_Model, int> healths, {
    Set<MultiplayerSession> stalled = const {},
  }) {
    clock.advance(_interval);
    for (final MapEntry(key: model, value: health) in healths.entries) {
      model.health = health;
    }
    writer.captureState();
    settle(stalled: stalled);
  }
}

void main() {
  test(
    'a stalled client keeps its queue bounded and gets the latest state',
    () {
      final harness = _Harness();
      final client = harness.join();
      harness.settle();
      final [onHost, onClient] = harness.register(7);
      final writer = _Model(harness.host, onHost, harness.schema);
      final reader = _Model(client, onClient, harness.schema);
      harness.sample(harness.host, {writer: 0});

      for (var health = 1; health <= 10; health++) {
        harness.sample(harness.host, {writer: health}, stalled: {client});
      }

      final atHost = harness.host.diagnostics;
      final peer = atHost.peers.single;
      expect(peer.outgoing.messages, 2);
      expect(peer.heldState.messages, 1);
      expect(peer.heldState.bytes, greaterThan(0));
      // The first held value was replaced seven times.
      expect(peer.coalescedStates, 7);
      expect(atHost.heldState, peer.heldState);
      expect(atHost.coalescedStates, 7);

      harness.settle();
      expect(reader.applied, [0, 2, 10]);
      expect(harness.host.diagnostics.peers.single.heldState.messages, 0);
      expect(client.obsoleteMessageCount, 0);
      expect(client.revision, harness.host.revision);
    },
  );

  test('state below the threshold is sent at once', () {
    final harness = _Harness();
    final client = harness.join();
    harness.settle();
    final [onHost, onClient] = harness.register(7);
    final writer = _Model(harness.host, onHost, harness.schema);
    final reader = _Model(client, onClient, harness.schema);

    for (var health = 1; health <= 10; health++) {
      harness.sample(harness.host, {writer: health});
    }

    expect(reader.applied, [
      for (var health = 1; health <= 10; health++) health,
    ]);
    final peer = harness.host.diagnostics.peers.single;
    expect(peer.heldState, (messages: 0, bytes: 0));
    expect(peer.coalescedStates, 0);
  });

  test('held state reaches a client before a later RPC', () {
    final harness = _Harness();
    final client = harness.join();
    harness.settle();
    final [onHost, onClient] = harness.register(7);
    final writer = _Model(harness.host, onHost, harness.schema);
    final reader = _Model(client, onClient, harness.schema);
    harness.sample(harness.host, {writer: 0});
    for (var health = 1; health <= 3; health++) {
      harness.sample(harness.host, {writer: health}, stalled: {client});
    }
    expect(harness.host.diagnostics.peers.single.heldState.messages, 1);

    expect(harness.host.callRpc(onHost, harness.schema.effect, true), isTrue);
    expect(harness.host.diagnostics.peers.single.heldState.messages, 0);
    harness.settle();

    // The effect ran after the state that preceded it.
    expect(reader.effects, [3]);
    expect(reader.health, 3);
  });

  test('held state precedes spawn records without becoming obsolete', () {
    final harness = _Harness();
    final client = harness.join();
    harness.settle();
    final spawned = <NetworkEntity>[];
    client.bindSpawn(
      harness.schema.item,
      onSpawn: (context) {
        spawned.add(context.entity);
        client.registry.markReady(context.entity.id);
      },
    );
    final [onHost, onClient] = harness.register(7);
    final writer = _Model(harness.host, onHost, harness.schema);
    final reader = _Model(client, onClient, harness.schema);
    harness.sample(harness.host, {writer: 0});
    for (var health = 1; health <= 3; health++) {
      harness.sample(harness.host, {writer: health}, stalled: {client});
    }

    harness.host.spawn(harness.schema.item, true);
    harness.settle();

    expect(spawned, hasLength(1));
    expect(reader.health, 3);
    expect(client.obsoleteMessageCount, 0);
    expect(client.revision, harness.host.revision);
  });

  test('despawning drops the held state of its entities', () {
    final harness = _Harness();
    final client = harness.join();
    harness.settle();
    final models = <MultiplayerSession, _Model>{};
    for (final session in harness.sessions) {
      session.bindSpawn(
        harness.schema.item,
        onSpawn: (context) =>
            models[session] = _Model(session, context.entity, harness.schema),
      );
    }
    final item = harness.host.spawn(harness.schema.item, true);
    harness.sample(harness.host, {models[harness.host]!: 0});
    for (var health = 1; health <= 3; health++) {
      harness.sample(
        harness.host,
        {models[harness.host]!: health},
        stalled: {client},
      );
    }
    final sentToClient = harness.observed[client]!.length;
    expect(harness.host.diagnostics.peers.single.heldState.messages, 1);

    expect(harness.host.despawn(item), isTrue);
    harness.settle();

    expect(client.registry[item.id]!.state, EntityState.removed);
    // Only the two states sent before congestion arrived, and the held one
    // was dropped. They arrived in the update that despawned the entity, so
    // its setter never ran again.
    expect(harness.observed[client], hasLength(sentToClient + 2));
    expect(models[client]!.applied, [0]);
    expect(client.obsoleteMessageCount, 0);
  });

  test('a congested host makes its client hold state it authors', () {
    final harness = _Harness();
    final client = harness.join();
    harness.settle();
    final [onHost, onClient] = harness.register(
      7,
      owner: _client1,
      authority: _client1,
    );
    final relay = _Model(harness.host, onHost, harness.schema);
    final writer = _Model(client, onClient, harness.schema);
    harness.sample(client, {writer: 0});

    for (var health = 1; health <= 10; health++) {
      harness.sample(client, {writer: health}, stalled: {harness.host});
    }

    final peer = client.diagnostics.peers.single;
    expect(peer.outgoing.messages, 2);
    expect(peer.heldState.messages, 1);
    expect(peer.coalescedStates, 7);
    harness.settle();
    expect(relay.applied, [0, 2, 10]);
  });

  test('a goodbye discards held state', () {
    final harness = _Harness();
    final client = harness.join();
    harness.settle();
    final [onHost, onClient] = harness.register(7);
    final writer = _Model(harness.host, onHost, harness.schema);
    final reader = _Model(client, onClient, harness.schema);
    harness.sample(harness.host, {writer: 0});
    for (var health = 1; health <= 3; health++) {
      harness.sample(harness.host, {writer: health}, stalled: {client});
    }

    expect(harness.host.kick(client.localPeer!), isTrue);
    harness.settle();

    expect(client.disconnectReason, DisconnectReason.kicked);
    expect(reader.applied, [0]);
    expect(harness.host.diagnostics.heldState, (messages: 0, bytes: 0));
  });

  test('pings bypass held state', () {
    final harness = _Harness();
    final client = harness.join();
    harness.settle();
    final [onHost, onClient] = harness.register(7);
    final writer = _Model(harness.host, onHost, harness.schema);
    _Model(client, onClient, harness.schema);
    harness.sample(harness.host, {writer: 0});

    for (var health = 1; health <= 30; health++) {
      harness.sample(harness.host, {writer: health}, stalled: {client});
    }

    final atHost = harness.host.diagnostics;
    expect(atHost.sent[MessageKind.ping].messages, 1);
    expect(atHost.peers.single.outgoing.messages, 3);
    expect(atHost.peers.single.heldState.messages, 1);
  });

  test('held state keeps one entry for each entity', () {
    final harness = _Harness();
    final client = harness.join();
    harness.settle();
    final writers = <_Model>[];
    final readers = <_Model>[];
    for (var id = 1; id <= 3; id++) {
      final [onHost, onClient] = harness.register(id);
      writers.add(_Model(harness.host, onHost, harness.schema));
      readers.add(_Model(client, onClient, harness.schema));
    }
    harness.sample(harness.host, {for (final writer in writers) writer: 0});

    for (var health = 1; health <= 10; health++) {
      harness.sample(
        harness.host,
        {for (final writer in writers) writer: health},
        stalled: {client},
      );
    }

    final peer = harness.host.diagnostics.peers.single;
    expect(peer.outgoing.messages, 2);
    expect(peer.heldState.messages, 3);
    harness.settle();
    expect([for (final reader in readers) reader.health], [10, 10, 10]);
    expect(client.obsoleteMessageCount, 0);
  });
}
