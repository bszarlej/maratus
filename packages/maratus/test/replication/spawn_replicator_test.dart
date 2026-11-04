import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

const _ms = Duration(milliseconds: 1);
const _client1 = PeerId(2);
const _client2 = PeerId(3);

List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

/// A list codec whose decoded lists can be changed, so tests can check that
/// each consumer gets its own copy of the construction data.
final class _MutableListCodec extends ValueCodec<List<int>> {
  const _MutableListCodec();

  static const _list = ListCodec(IntCodec(min: 0, max: 99), maxLength: 4);

  @override
  String get descriptor => 'test.mutable_list@1';

  @override
  Object? encode(List<int> value) => _list.encode(value);

  @override
  List<int> decode(Object? wire) => _list.decode(wire).toList();
}

/// The registrations shared by every session of a test.
final class _Schema {
  _Schema() {
    final builder = ProtocolSchemaBuilder();
    avatar = builder.addSpawnType(
      const SpawnTypeId('test.avatar'),
      const StringCodec(maxLength: 16),
    );
    item = builder.addSpawnType(
      const SpawnTypeId('test.item'),
      const _MutableListCodec(),
    );
    poke = builder.addRpc(
      const RpcId('test.poke'),
      const IntCodec(min: 0, max: 9),
      target: RpcTarget.all,
      local: RpcLocal.include,
    );
    direct = builder.addRpc(
      const RpcId('test.direct'),
      const IntCodec(min: 0, max: 9),
      target: RpcTarget.peer,
    );
    schema = builder.build();
  }

  late final SpawnType<String> avatar;
  late final SpawnType<List<int>> item;
  late final Rpc<int> poke;
  late final Rpc<int> direct;
  late final ProtocolSchema schema;
}

/// A session and a log of what its spawn bindings were told.
final class _Peer {
  _Peer(this.session, this.schema, {bool bind = true}) {
    if (bind) this.bind();
  }

  final MultiplayerSession session;
  final _Schema schema;
  final log = <String>[];
  final contexts = <EntityId, SpawnContext<Object?>>{};
  final bindings = <SpawnBinding>[];
  void Function(SpawnContext<Object?> context)? onSpawn;
  void Function(NetworkEntity entity)? onDespawn;

  void bind() {
    bindings
      ..add(
        session.bindSpawn(
          schema.avatar,
          onSpawn: (context) => _spawned('avatar', context),
          onDespawn: _despawned,
        ),
      )
      ..add(
        session.bindSpawn(
          schema.item,
          onSpawn: (context) => _spawned('item', context),
          onDespawn: _despawned,
        ),
      );
  }

  void unbind() {
    for (final binding in bindings) {
      binding.dispose();
    }
    bindings.clear();
  }

  /// The live registry entities with their metadata, to compare peers.
  List<String> get world => [
    for (final entity in session.registry.entities)
      '${entity.id.value} o${entity.owner.value} a${entity.authority.value}',
  ];

  void _spawned(String type, SpawnContext<Object?> context) {
    final entity = context.entity;
    final parent = context.parent;
    log.add(
      '+${entity.id.value} $type ${context.data} '
      'o${entity.owner.value} a${entity.authority.value}'
      '${parent == null ? '' : ' p${parent.id.value}'}',
    );
    contexts[entity.id] = context;
    onSpawn?.call(context);
  }

  void _despawned(NetworkEntity entity) {
    log.add('-${entity.id.value}');
    onDespawn?.call(entity);
  }
}

/// A host and the clients that join it over an in-memory network.
final class _Harness {
  _Harness({
    this.timeouts = const SessionTimeouts(),
    QueueLimits hostOutgoingLimits = const QueueLimits(),
  }) {
    network = InMemoryNetwork(clock: clock);
    host = _peer()
      ..session.host(network.host(outgoingLimits: hostOutgoingLimits));
  }

  final clock = ManualClock();
  final schema = _Schema();
  final SessionTimeouts timeouts;
  late final InMemoryNetwork network;
  late final _Peer host;

  /// The messages passed to any session's message handler.
  final messages = <ProtocolMessage>[];
  final _updates = <void Function()>[];

  _Peer _peer({bool bind = true}) {
    final session = MultiplayerSession(
      schema: schema.schema,
      clock: clock,
      timeouts: timeouts,
      onMessage: (_, envelope) => messages.add(envelope.message),
    );
    addTearDown(session.close);
    _updates.add(session.update);
    return _Peer(session, schema, bind: bind);
  }

  _Peer join({bool bind = true}) =>
      _peer(bind: bind)..session.join(network.connect());

  _RawClient rawClient() {
    final client = _RawClient(network.connect(), schema.schema);
    _updates.add(client.update);
    return client;
  }

  void run({Duration step = Duration.zero, int rounds = 6}) {
    for (var i = 0; i < rounds; i++) {
      clock.advance(step);
      for (final update in _updates) {
        update();
      }
    }
  }
}

/// A client that speaks the protocol directly, to observe what a host sends.
final class _RawClient {
  _RawClient(this.peer, this.schema) : codec = ProtocolCodec(schema);

  final InMemoryClient peer;
  final ProtocolSchema schema;
  final ProtocolCodec codec;
  PeerConnection? connection;
  PeerId? id;
  var generation = 0;
  final received = <ProtocolMessage>[];
  CloseReason? closeReason;

  void update() {
    for (var event = peer.poll(); event != null; event = peer.poll()) {
      switch (event) {
        case ConnectionOpened(:final connection):
          this.connection = connection;
        case MessageReceived(:final message):
          final envelope = codec.decode(message);
          if (envelope.message case WelcomeMessage(:final peer)) {
            id = peer;
            generation = envelope.generation;
          }
          received.add(envelope.message);
        case ConnectionClosed(:final reason):
          closeReason = reason;
      }
    }
  }

  void send(ProtocolMessage message) => connection!.send(
    codec.encode(MessageEnvelope(message, generation: generation)),
  );

  void hello() => send(HelloMessage(fingerprint: schema.fingerprint));
}

/// A client session joining a host that speaks the protocol directly, to
/// send records that a host session would not.
final class _RawHostHarness {
  _RawHostHarness() {
    network = InMemoryNetwork(clock: clock);
    final peer = network.host();
    codec = ProtocolCodec(schema.schema);
    client = _Peer(
      MultiplayerSession(schema: schema.schema, clock: clock)
        ..join(network.connect()),
      schema,
    );
    addTearDown(client.session.close);
    _updates = [
      () {
        for (var event = peer.poll(); event != null; event = peer.poll()) {
          if (event case ConnectionOpened(:final connection)) {
            this.connection = connection;
          }
        }
      },
      client.session.update,
    ];
    run();
  }

  final clock = ManualClock();
  final schema = _Schema();
  late final InMemoryNetwork network;
  late final ProtocolCodec codec;
  late final _Peer client;
  late final List<void Function()> _updates;
  PeerConnection? connection;

  void run() {
    for (var i = 0; i < 6; i++) {
      clock.advance(Duration.zero);
      for (final update in _updates) {
        update();
      }
    }
  }

  void send(ProtocolMessage message, {int revision = 0}) => connection!.send(
    codec.encode(MessageEnvelope(message, generation: 5, revision: revision)),
  );

  /// Welcomes the client at [revision], sending [baseline] before the end of
  /// synchronization.
  void welcome({int revision = 0, List<ProtocolMessage> baseline = const []}) {
    send(const WelcomeMessage(peer: _client1, epoch: 9), revision: revision);
    for (final record in baseline) {
      send(record, revision: revision);
    }
    send(const SyncedMessage(), revision: revision);
    run();
  }
}

SpawnMessage _avatar(
  int entity, {
  String data = 'Ada',
  int owner = 1,
  int authority = 1,
  int? parent,
}) => SpawnMessage(
  entity: EntityId(entity),
  type: const SpawnTypeId('test.avatar'),
  data: data,
  owner: PeerId(owner),
  authority: PeerId(authority),
  parent: parent == null ? null : EntityId(parent),
);

void main() {
  group('spawning', () {
    test('replicates entities and their metadata to every joined client', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      harness.run();
      final host = harness.host.session;

      final entity = host.spawn(
        harness.schema.avatar,
        'Ada',
        owner: _client1,
        authority: _client1,
      );

      expect(entity.id, const EntityId(1));
      expect(entity.owner, _client1);
      expect(entity.authority, _client1);
      expect(entity.state, EntityState.pending);
      expect(harness.host.log, ['+1 avatar Ada o2 a2']);
      expect(first.log, isEmpty);
      harness.run();
      for (final client in [first, second]) {
        expect(client.log, ['+1 avatar Ada o2 a2']);
        final replica = client.session.registry[entity.id]!;
        expect(client.contexts[entity.id]!.entity, same(replica));
        expect(replica.state, EntityState.pending);
        expect(client.session.revision, host.revision);
        expect(client.session.state, SessionState.ready);
      }
      expect(harness.messages, isEmpty);
    });

    test('replicates parents, which clients resolve to their own entities', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final host = harness.host.session;
      final parent = host.spawn(harness.schema.avatar, 'Ada');

      host.spawn(harness.schema.item, [7], parent: parent);
      harness.run();

      expect(client.log, ['+1 avatar Ada o1 a1', '+2 item [7] o1 a1 p1']);
      expect(
        client.contexts[const EntityId(2)]!.parent,
        same(client.session.registry[parent.id]),
      );
      expect(harness.host.contexts[const EntityId(2)]!.parent, same(parent));
    });

    test('reaches clients that are still synchronizing after the baseline', () {
      final harness = _Harness();
      final client = harness.join();
      final host = harness.host.session;
      for (var i = 0; i < 3 && host.peers.isEmpty; i++) {
        harness.run(rounds: 1);
      }
      expect(host.peers, [_client1]);
      expect(host.isReady(_client1), isFalse);

      host.spawn(harness.schema.avatar, 'Ada', owner: _client1);
      harness.run();

      expect(client.session.state, SessionState.ready);
      expect(client.log, ['+1 avatar Ada o2 a1']);
      expect(client.session.revision, host.revision);
    });

    test('sends a late joiner the live entities first, parents first', () {
      final harness = _Harness();
      final host = harness.host.session;
      final root = host.spawn(harness.schema.avatar, 'Root');
      host.spawn(harness.schema.item, [1], parent: root);
      final gone = host.spawn(harness.schema.avatar, 'Gone');
      host.spawn(harness.schema.avatar, 'Kept');
      host.despawn(gone);
      final baseline = host.revision;

      final client = harness.join();
      client.onSpawn = (context) =>
          client.session.registry.markReady(context.entity.id);
      harness.run();

      expect(client.session.state, SessionState.ready);
      expect(client.log, [
        '+1 avatar Root o1 a1',
        '+2 item [1] o1 a1 p1',
        '+4 avatar Kept o1 a1',
      ]);
      expect(client.world, harness.host.world);
      expect(client.session.revision, baseline);
      expect(client.session.registry[gone.id], isNull);

      host.spawn(harness.schema.avatar, 'Later', owner: _client1);
      harness.run();
      expect(client.log.last, '+5 avatar Later o2 a1');
      expect(client.session.obsoleteMessageCount, 0);
    });

    test('gives every consumer its own copy of construction data', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final host = harness.host.session;
      harness.host.onSpawn = (context) => (context.data! as List<int>).add(99);
      final data = [1, 2];

      host.spawn(harness.schema.item, data);
      data.add(3);
      harness.run();
      final joiner = harness.join();
      harness.run();

      expect(harness.host.log, ['+1 item [1, 2] o1 a1']);
      expect(harness.host.contexts.values.single.data, [1, 2, 99]);
      expect(client.log, ['+1 item [1, 2] o1 a1']);
      expect(joiner.log, ['+1 item [1, 2] o1 a1']);
      expect(data, [1, 2, 3]);
      harness.host
        ..onSpawn = null
        ..unbind()
        ..bind();
      expect(harness.host.log.last, '+1 item [1, 2] o1 a1');
    });

    test('nested spawns from a handler replicate after their parent', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final host = harness.host.session;
      harness.host.onSpawn = (context) {
        if (context.data == 'Ada') {
          host.spawn(harness.schema.item, [1], parent: context.entity);
        }
      };

      host.spawn(harness.schema.avatar, 'Ada');
      harness.run();

      expect(harness.host.log, ['+1 avatar Ada o1 a1', '+2 item [1] o1 a1 p1']);
      expect(client.log, harness.host.log);
    });

    test('rejects invalid requests without spawning anything', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final host = harness.host.session;
      final schema = harness.schema;
      final unreplicated = host.registry.create(
        owner: PeerId.host,
        authority: PeerId.host,
      );
      final removed = host.spawn(schema.avatar, 'Gone');
      host.despawn(removed);
      final foreign = EntityRegistry().create(
        owner: PeerId.host,
        authority: PeerId.host,
      );
      harness.run();
      final revision = host.revision;
      final world = harness.host.world;
      final log = [...harness.host.log];

      const impostor = SpawnType<String>(
        id: SpawnTypeId('test.avatar'),
        codec: StringCodec(maxLength: 16),
      );
      expect(() => host.spawn(impostor, 'Ada'), throwsArgumentError);
      expect(() => host.spawn(schema.avatar, 'a' * 17), throwsArgumentError);
      expect(() => host.spawn(schema.item, [100]), throwsArgumentError);
      expect(
        () => host.spawn(schema.avatar, 'Ada', owner: const PeerId(9)),
        throwsArgumentError,
      );
      expect(
        () => host.spawn(
          schema.avatar,
          'Ada',
          owner: _client1,
          authority: _client2,
        ),
        throwsArgumentError,
      );
      expect(
        () => host.spawn(schema.avatar, 'Ada', authority: _client1),
        throwsArgumentError,
      );
      for (final parent in [unreplicated, removed, foreign]) {
        expect(
          () => host.spawn(schema.avatar, 'Ada', parent: parent),
          throwsArgumentError,
        );
      }
      expect(
        () => client.session.spawn(schema.avatar, 'Ada'),
        throwsStateError,
      );
      harness.run();

      expect(host.revision, revision);
      expect(harness.host.world, world);
      expect(harness.host.log, log);
      expect(client.world, isEmpty);
      expect(client.session.revision, revision);
      expect(host.spawn(schema.avatar, 'Next').id, const EntityId(3));
      host.close();
      expect(() => host.spawn(schema.avatar, 'Ada'), throwsStateError);
    });

    test('a send failure removes the client once every client was offered', () {
      final harness = _Harness(
        hostOutgoingLimits: const QueueLimits(maxMessages: 2),
      );
      final first = harness.join();
      final second = harness.join();
      harness.run();
      final host = harness.host.session;
      // Fill only the first client's queue, with RPCs addressed to it.
      final target = host.registry.create(
        owner: PeerId.host,
        authority: PeerId.host,
      );
      host.registry.markReady(target.id);
      for (var i = 0; i < 2; i++) {
        expect(
          host.callRpc(target, harness.schema.direct, i, peer: _client1),
          isTrue,
        );
      }
      _drain(host);

      final entity = host.spawn(
        harness.schema.avatar,
        'Ada',
        owner: _client1,
        onOwnerLeft: OwnerLeftPolicy.despawn,
      );

      expect(_drain(host), [
        const PeerLeft(_client1, DisconnectReason.transportError),
      ]);
      expect(entity.state, EntityState.removed);
      expect(harness.host.log, isEmpty);
      harness.run();
      expect(first.session.state, SessionState.disconnected);
      expect(second.log, ['+2 avatar Ada o2 a1', '-2']);
      expect(second.world, isEmpty);
    });
  });

  group('despawning', () {
    test('removes an entity and its descendants, children first', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final host = harness.host.session;
      final schema = harness.schema;
      final root = host.spawn(schema.avatar, 'Root');
      final branch = host.spawn(schema.item, [1], parent: root);
      host
        ..spawn(schema.item, [2], parent: branch)
        ..spawn(schema.item, [3], parent: root)
        ..spawn(schema.avatar, 'Other');
      harness.run();
      final revision = host.revision;
      harness.host.log.clear();
      client.log.clear();

      expect(host.despawn(root), isTrue);
      harness.run();

      expect(harness.host.log, ['-4', '-3', '-2', '-1']);
      expect(client.log, harness.host.log);
      expect(host.revision, revision + 1);
      expect(client.session.revision, host.revision);
      expect(harness.host.world, ['5 o1 a1']);
      expect(client.world, harness.host.world);
      expect(branch.state, EntityState.removed);
      expect(client.session.registry[branch.id]!.state, EntityState.removed);
    });

    test('despawning again sends nothing, so reactions cannot echo', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final host = harness.host.session;
      final root = host.spawn(harness.schema.avatar, 'Root');
      final child = host.spawn(harness.schema.item, [1], parent: root);
      final echoes = <bool>[];
      harness.host.onDespawn = (entity) => echoes.add(host.despawn(entity));
      harness.run();
      final revision = host.revision;

      expect(host.despawn(root), isTrue);
      expect(host.despawn(root), isFalse);
      expect(host.despawn(child), isFalse);
      harness.run();

      expect(echoes, [false, false]);
      expect(host.revision, revision + 1);
      expect(client.log, [
        '+1 avatar Root o1 a1',
        '+2 item [1] o1 a1 p1',
        '-2',
        '-1',
      ]);
    });

    test('accepts only replicated entities of a hosting session', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final host = harness.host.session;
      final unreplicated = host.registry.create(
        owner: PeerId.host,
        authority: PeerId.host,
      );
      final entity = host.spawn(harness.schema.avatar, 'Ada');
      harness.run();

      expect(() => host.despawn(unreplicated), throwsArgumentError);
      expect(
        () => host.despawn(client.session.registry[entity.id]!),
        throwsArgumentError,
      );
      expect(
        () => client.session.despawn(client.session.registry[entity.id]!),
        throwsStateError,
      );
      host.registry.remove(unreplicated.id);
      expect(host.despawn(unreplicated), isFalse);
      expect(entity.state, EntityState.pending);
    });

    test('peers that stay connected agree on the replicated entities', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      harness.run();
      final host = harness.host.session;
      final schema = harness.schema;
      final shared = host.spawn(schema.avatar, 'Host');
      final avatar = host.spawn(
        schema.avatar,
        'First',
        owner: _client1,
        authority: _client1,
        onOwnerLeft: OwnerLeftPolicy.despawn,
      );
      host
        ..spawn(schema.item, [1], owner: _client1, parent: avatar)
        ..spawn(schema.item, [2], owner: _client1, parent: shared);
      final secondAvatar = host.spawn(
        schema.avatar,
        'Second',
        owner: _client2,
        onOwnerLeft: OwnerLeftPolicy.despawn,
      );
      harness.run();
      expect(first.world, harness.host.world);
      expect(second.world, harness.host.world);

      host.despawn(secondAvatar);
      harness.run();
      expect(first.world, harness.host.world);
      expect(second.world, harness.host.world);

      first.session.close();
      harness.run();
      expect(harness.host.world, ['1 o1 a1', '4 o2 a1']);
      expect(second.world, harness.host.world);
      expect(second.session.obsoleteMessageCount, 0);
    });
  });

  group('owner departure', () {
    for (final (departure, reason) in [
      ('closes', DisconnectReason.remoteClosed),
      ('is kicked', DisconnectReason.kicked),
      ('loses its connection', DisconnectReason.transportError),
    ]) {
      test('despawns what an owner that $departure held by policy', () {
        final harness = _Harness();
        final owner = harness.join();
        final observer = harness.join();
        harness.run();
        final host = harness.host.session;
        final schema = harness.schema;
        final avatar = host.spawn(
          schema.avatar,
          'Ada',
          owner: _client1,
          authority: _client1,
          onOwnerLeft: OwnerLeftPolicy.despawn,
        );
        host
          ..spawn(schema.item, [1], parent: avatar)
          ..spawn(schema.item, [2], owner: _client1)
          ..spawn(schema.avatar, 'Bob', owner: _client2);
        harness.run();
        _drain(host);
        harness.host.log.clear();
        observer.log.clear();

        switch (reason) {
          case DisconnectReason.remoteClosed:
            owner.session.close();
          case DisconnectReason.kicked:
            host.kick(_client1);
          default:
            harness.network.links.first.disconnect();
        }
        harness.run();

        expect(_drain(host), [PeerLeft(_client1, reason)]);
        expect(harness.host.log, ['-2', '-1']);
        expect(observer.log, ['-2', '-1']);
        expect(harness.host.world, ['3 o2 a1', '4 o3 a1']);
        expect(observer.world, harness.host.world);
      });
    }

    test('releases what a client that times out while joining owned', () {
      final harness = _Harness(
        timeouts: const SessionTimeouts(
          handshake: Duration(milliseconds: 100),
          bootstrap: Duration(milliseconds: 200),
        ),
      );
      final observer = harness.join();
      harness.run();
      final raw = harness.rawClient();
      harness.run();
      raw.hello();
      harness.run();
      final host = harness.host.session;
      expect(host.isReady(raw.id!), isFalse);
      host.spawn(
        harness.schema.avatar,
        'Ada',
        owner: raw.id!,
        onOwnerLeft: OwnerLeftPolicy.despawn,
      );
      harness.run();
      expect(raw.received.whereType<SpawnMessage>(), hasLength(1));

      harness.run(step: _ms * 200, rounds: 1);
      harness.run();

      expect(
        _drain(host),
        contains(PeerLeft(raw.id!, DisconnectReason.timeout)),
      );
      expect(observer.log, ['+1 avatar Ada o3 a1', '-1']);
      expect(harness.host.world, isEmpty);
    });

    test('a closing host ends its entities without despawning them', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      harness.run();
      raw.hello();
      harness.run();
      raw.send(const ReadyMessage());
      harness.run();
      final host = harness.host.session;
      host.spawn(
        harness.schema.avatar,
        'Ada',
        owner: raw.id!,
        onOwnerLeft: OwnerLeftPolicy.despawn,
      );
      harness.run();

      host.close();
      harness.run();

      expect(raw.received.whereType<DespawnMessage>(), isEmpty);
      expect(raw.closeReason, CloseReason.remote);
      expect(harness.host.log, ['+1 avatar Ada o2 a1', '-1']);
    });
  });

  group('bindings', () {
    test('late bindings see live entities, disposed bindings nothing more', () {
      final harness = _Harness();
      final host = harness.host
        ..unbind()
        ..log.clear();
      final session = host.session;
      final first = session.spawn(harness.schema.avatar, 'A');
      final second = session.spawn(harness.schema.avatar, 'B');
      session
        ..spawn(harness.schema.item, [3])
        ..despawn(second);
      expect(host.log, isEmpty);

      host.bind();
      expect(host.log, ['+1 avatar A o1 a1', '+3 item [3] o1 a1']);
      host.unbind();
      session
        ..spawn(harness.schema.avatar, 'D')
        ..despawn(first);
      expect(host.bindings, isEmpty);
      expect(host.log, hasLength(2));

      host.bind();
      expect(host.log.skip(2), ['+4 avatar D o1 a1', '+3 item [3] o1 a1']);
    });

    test('a type has one live binding, and foreign handles are rejected', () {
      final harness = _Harness();
      final session = harness.host.session;
      expect(
        () => session.bindSpawn(harness.schema.avatar, onSpawn: (_) {}),
        throwsStateError,
      );
      const impostor = SpawnType<String>(
        id: SpawnTypeId('test.other'),
        codec: StringCodec(),
      );
      expect(
        () => session.bindSpawn(impostor, onSpawn: (_) {}),
        throwsArgumentError,
      );

      final binding = harness.host.bindings.first..dispose();
      expect(binding.isDisposed, isTrue);
      expect(binding.type, harness.schema.avatar.id);
      binding.dispose();
      final replacement = session.bindSpawn(
        harness.schema.avatar,
        onSpawn: (_) {},
      );
      expect(replacement.isDisposed, isFalse);
    });

    test('bindings outlive restarts and are told when a session ends', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final host = harness.host.session;
      final root = host.spawn(harness.schema.avatar, 'Root');
      host.spawn(harness.schema.item, [1], parent: root);
      harness.run();

      host.close();
      expect(harness.host.log.skip(2), ['-2', '-1']);
      expect(root.state, EntityState.removed);
      harness.run();
      expect(client.session.state, SessionState.disconnected);
      expect(client.log.skip(2), ['-2', '-1']);

      host.host(InMemoryNetwork(clock: harness.clock).host());
      host.spawn(harness.schema.avatar, 'Again');
      expect(harness.host.log.last, '+1 avatar Again o1 a1');
    });

    test('handler failures are reported while later records still apply', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final host = harness.host.session;
      final error = StateError('factory failed');
      harness.host.onSpawn = (context) {
        if (context.data == 'Host') throw error;
      };
      client.onSpawn = (context) {
        if (context.data == 'Client') throw error;
      };
      client.onDespawn = (_) => throw error;
      _drain(host);
      _drain(client.session);

      final failed = host.spawn(harness.schema.avatar, 'Host');
      final other = host.spawn(harness.schema.avatar, 'Client');
      host.spawn(harness.schema.avatar, 'Fine');
      harness.run();
      host.despawn(other);
      harness.run();

      final hostFailure = _drain(host).whereType<SpawnHandlerFailed>().single;
      expect(hostFailure.entity, failed.id);
      expect(hostFailure.type, harness.schema.avatar.id);
      expect(hostFailure.error, same(error));
      expect(hostFailure.stackTrace, isA<StackTrace>());
      expect(
        _drain(
          client.session,
        ).whereType<SpawnHandlerFailed>().map((event) => event.entity),
        [other.id, other.id],
      );
      expect(client.log.last, '-2');
      expect(client.world, ['1 o1 a1', '3 o1 a1']);
      expect(client.session.state, SessionState.ready);
    });

    test('handlers cannot update the session that calls them', () {
      final harness = _Harness();
      final session = harness.host.session;
      harness.host.onSpawn = (_) => session.update();
      _drain(session);

      session.spawn(harness.schema.avatar, 'Ada');

      expect(
        _drain(session).whereType<SpawnHandlerFailed>().single.error,
        isA<StateError>(),
      );
      session.update();
    });

    test('a handler can attach an entity before same-update RPCs arrive', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final host = harness.host.session;
      final received = <int>[];
      var ready = false;
      client.onSpawn = (context) => client.session
          .attachEntity(
            context.entity,
            isReady: () => ready,
            isValid: () => true,
          )
          .bindRpc(harness.schema.poke, (_, value) => received.add(value));
      final entity = host.spawn(harness.schema.avatar, 'Ada');
      host
        ..bindRpc(entity, harness.schema.poke, (_, _) {})
        ..registry.markReady(entity.id);
      _drain(client.session);

      expect(host.callRpc(entity, harness.schema.poke, 5), isTrue);
      harness.clock.advance(Duration.zero);
      client.session.update();

      expect(client.session.pendingRpcCount, 1);
      expect(received, isEmpty);
      ready = true;
      client.session.update();
      expect(received, [5]);
      expect(_drain(client.session).whereType<RpcRejected>(), isEmpty);
    });
  });

  group('protocol', () {
    test('a client cannot despawn through the protocol', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      harness.run();
      raw.hello();
      harness.run();
      raw.send(const ReadyMessage());
      harness.run();
      final host = harness.host.session;
      host.spawn(harness.schema.avatar, 'Ada', owner: raw.id!);
      _drain(host);

      raw.send(const DespawnMessage(entity: EntityId(1)));
      harness.run();

      expect(_drain(host), [
        PeerLeft(raw.id!, DisconnectReason.protocolViolation),
      ]);
      expect(harness.host.world, ['1 o2 a1']);
    });

    test('a duplicate record with an obsolete revision is ignored', () {
      final harness = _RawHostHarness()..welcome();
      harness
        ..send(_avatar(1), revision: 1)
        ..send(_avatar(1), revision: 1)
        ..run();

      expect(harness.client.log, ['+1 avatar Ada o1 a1']);
      expect(harness.client.session.obsoleteMessageCount, 1);
      expect(harness.client.session.state, SessionState.ready);
    });

    test('a client accepts records from a host baseline', () {
      final harness = _RawHostHarness();
      final client = harness.client;
      client.onSpawn = (context) =>
          client.session.registry.markReady(context.entity.id);
      harness.welcome(
        revision: 4,
        baseline: [_avatar(3), _avatar(5, parent: 3)],
      );

      expect(harness.client.session.state, SessionState.ready);
      expect(harness.client.log, [
        '+3 avatar Ada o1 a1',
        '+5 avatar Ada o1 a1 p3',
      ]);
      expect(harness.client.session.revision, 4);
    });

    const spawned = '+1 avatar Ada o1 a1';
    final violations = <(String, List<ProtocolMessage>, List<String>)>[
      ('a duplicate entity', [_avatar(1), _avatar(1, data: 'Bob')], [spawned]),
      ('an unknown parent', [_avatar(2, parent: 1)], []),
      (
        'a despawned parent',
        [
          _avatar(1),
          const DespawnMessage(entity: EntityId(1)),
          _avatar(2, parent: 1),
        ],
        [spawned],
      ),
      ('a static parent', [_avatar(2, parent: 7)], []),
      ('a third-party authority', [_avatar(1, owner: 2, authority: 3)], []),
      ('a client authority without ownership', [_avatar(1, authority: 2)], []),
      ('an unknown despawn', [const DespawnMessage(entity: EntityId(1))], []),
      ('a static despawn', [const DespawnMessage(entity: EntityId(7))], []),
      (
        'a repeated despawn',
        [
          _avatar(1),
          const DespawnMessage(entity: EntityId(1)),
          const DespawnMessage(entity: EntityId(1)),
        ],
        [spawned],
      ),
      ('a static entity ID', [_avatar(7)], []),
    ];
    for (final (name, records, applied) in violations) {
      test('a client leaves a host that sends $name', () {
        final harness = _RawHostHarness();
        harness.client.session.registry.register(
          const EntityId(7),
          owner: PeerId.host,
          authority: PeerId.host,
        );
        harness.welcome();
        for (var i = 0; i < records.length; i++) {
          harness.send(records[i], revision: i + 1);
        }
        harness.run();

        expect(
          harness.client.session.disconnectReason,
          DisconnectReason.protocolViolation,
        );
        expect(
          harness.client.log.where((entry) => entry.startsWith('+')),
          applied,
        );
      });
    }

    for (final (name, record, revision) in [
      ('a baseline record at another revision', _avatar(1), 3),
      (
        'a despawn while synchronizing',
        const DespawnMessage(entity: EntityId(1)),
        0,
      ),
    ]) {
      test('a client leaves a host that sends $name', () {
        final harness = _RawHostHarness();
        harness
          ..send(const WelcomeMessage(peer: _client1, epoch: 9))
          ..send(_avatar(1))
          ..send(record, revision: revision)
          ..send(const SyncedMessage())
          ..run();

        expect(
          harness.client.session.disconnectReason,
          DisconnectReason.protocolViolation,
        );
        expect(harness.client.log.first, '+1 avatar Ada o1 a1');
      });
    }

    test('a client leaves a host that spawns an unregistered type', () {
      final harness = _RawHostHarness()..welcome();
      final bytes = Uint8List.fromList(
        '{"v":1,"k":"spawn","g":5,"r":1,'
                '"b":{"e":1,"t":"test.ghost","d":0,"o":1,"a":1}}'
            .codeUnits,
      );
      harness.connection!.send(bytes);
      harness.run();

      expect(
        harness.client.session.disconnectReason,
        DisconnectReason.protocolViolation,
      );
      expect(harness.client.log, isEmpty);
    });
  });
}
