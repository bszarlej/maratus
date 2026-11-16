import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

const _interval = Duration(milliseconds: 50);
const _client1 = PeerId(2);
const _client2 = PeerId(3);
const _stranger = PeerId(9);

List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

/// The registrations shared by every session of a test.
final class _Schema {
  _Schema() {
    final builder = ProtocolSchemaBuilder();
    avatar = builder.addSpawnType(
      const SpawnTypeId('test.avatar'),
      const StringCodec(maxLength: 16),
    );
    board = builder.addStaticEntity(const StaticEntityId('test.board'));
    health = builder.addField(
      const FieldId('test.health'),
      const IntCodec(min: 0, max: 100),
    );
    x = builder.addField(
      const FieldId('test.x'),
      const IntCodec(),
      deliveryMode: DeliveryMode.unreliable,
      channel: 1,
    );
    poke = builder.addRpc(
      const RpcId('test.poke'),
      const IntCodec(min: 0, max: 9),
      caller: RpcCaller.host,
      target: RpcTarget.all,
    );
    direct = builder.addRpc(
      const RpcId('test.direct'),
      const IntCodec(min: 0, max: 9),
      caller: RpcCaller.host,
      target: RpcTarget.peer,
    );
    ask = builder.addRpc(
      const RpcId('test.ask'),
      const IntCodec(min: 0, max: 9),
    );
    schema = builder.build();
  }

  late final SpawnType<String> avatar;
  late final StaticEntity board;
  late final SyncField<int> health;
  late final SyncField<int> x;
  late final Rpc<int> poke;
  late final Rpc<int> direct;
  late final Rpc<int> ask;
  late final ProtocolSchema schema;
}

/// A session whose spawn handler attaches each entity it is told about,
/// synchronizes the entity's fields with [values], and logs its spawns,
/// despawns, and RPCs by the entity's construction data.
final class _Peer {
  _Peer(this.session, this.schema) {
    session.bindSpawn(
      schema.avatar,
      onSpawn: (context) {
        final entity = context.entity;
        final name = names[entity.id] = context.data;
        log.add('+$name');
        // Each stay of an entity on this peer starts without values.
        final fields = values[entity.id] = {};
        session.attachEntity(entity, isReady: () => true, isValid: () => true)
          ..bindRpc(schema.poke, (_, value) => calls.add('poke $name $value'))
          ..bindRpc(
            schema.direct,
            (_, value) => calls.add('direct $name $value'),
          )
          ..bindRpc(schema.ask, (_, value) => calls.add('ask $name $value'))
          ..synchronize([
            schema.health.property(
              get: () => fields['health'] ?? 100,
              set: (value) => fields['health'] = value,
            ),
            schema.x.property(
              get: () => fields['x'] ?? 0,
              set: (value) => fields['x'] = value,
              mode: SyncMode.always,
            ),
          ], interval: _interval);
      },
      onDespawn: (entity) => log.add('-${names[entity.id]}'),
    );
  }

  final MultiplayerSession session;
  final _Schema schema;
  final log = <String>[];
  final names = <EntityId, String>{};
  final values = <EntityId, Map<String, int>>{};
  final calls = <String>[];
}

/// A host and the clients that join it over an in-memory network with an
/// unreliable channel.
final class _Harness {
  _Harness() {
    network = InMemoryNetwork(
      clock: clock,
      deliveryModes: DeliveryMode.values.toSet(),
      channelCount: 2,
    );
    host = _peer()..session.host(network.host());
  }

  final clock = ManualClock();
  final schema = _Schema();
  final _peers = <_Peer>[];
  late final InMemoryNetwork network;
  late final _Peer host;

  _Peer _peer() {
    final session = MultiplayerSession(schema: schema.schema, clock: clock);
    addTearDown(session.close);
    final peer = _Peer(session, schema);
    _peers.add(peer);
    return peer;
  }

  /// A client that joined the host and is ready.
  _Peer join() {
    final client = _peer()..session.join(network.connect());
    run();
    return client;
  }

  void run() {
    for (var i = 0; i < 6; i++) {
      clock.advance(Duration.zero);
      for (final peer in _peers) {
        peer.session.update();
      }
    }
  }

  /// Samples the fields that each peer writes once, and delivers them.
  void capture() {
    clock.advance(_interval);
    for (final peer in _peers) {
      peer.session.captureState();
    }
    run();
  }
}

void main() {
  test('every client sees the entities when nothing hides them', () {
    final harness = _Harness();
    final first = harness.join();
    final second = harness.join();
    final host = harness.host.session;
    final entity = host.spawn(harness.schema.avatar, 'Ada');
    harness.run();

    expect(first.log, ['+Ada']);
    expect(second.log, ['+Ada']);
    for (final peer in [PeerId.host, _client1, _client2]) {
      expect(host.isVisibleTo(entity, peer), isTrue);
      expect(
        host.isVisibleTo(host.staticEntity(harness.schema.board), peer),
        isTrue,
      );
    }
    expect(host.isVisibleTo(entity, _stranger), isFalse);
  });

  test('an entity without public visibility reaches only its owner', () {
    final harness = _Harness();
    final first = harness.join();
    final second = harness.join();
    final host = harness.host.session;
    final entity = host.spawn(
      harness.schema.avatar,
      'Ada',
      owner: _client1,
      publicVisibility: false,
    );
    harness.run();

    expect(first.log, ['+Ada']);
    expect(second.log, isEmpty);
    expect(second.session.registry[entity.id], isNull);
    expect(host.isVisibleTo(entity, _client1), isTrue);
    expect(host.isVisibleTo(entity, _client2), isFalse);
  });

  test('an entity comes into view with its latest values, and returns as a '
      'new entity', () {
    final harness = _Harness();
    final client = harness.join();
    final host = harness.host.session;
    final entity = host.spawn(
      harness.schema.avatar,
      'Ada',
      publicVisibility: false,
    );
    harness.host.values[entity.id]!['health'] = 42;
    harness.capture();
    expect(client.log, isEmpty);

    host.setVisibilityFor(entity, _client1, true);
    harness.run();
    final shown = client.session.registry[entity.id]!;
    expect(client.log, ['+Ada']);
    expect(shown.state, EntityState.ready);
    expect(client.values[entity.id], {'health': 42, 'x': 0});
    expect(host.isVisibleTo(entity, _client1), isTrue);

    host.setVisibilityFor(entity, _client1, false);
    harness.run();
    expect(client.log, ['+Ada', '-Ada']);
    expect(shown.state, EntityState.removed);
    expect(host.isVisibleTo(entity, _client1), isFalse);

    harness.host.values[entity.id]!['health'] = 7;
    harness.capture();
    host.setVisibilityFor(entity, _client1, true);
    harness.run();
    final returned = client.session.registry[entity.id]!;
    expect(client.log, ['+Ada', '-Ada', '+Ada']);
    expect(returned, isNot(same(shown)));
    expect(returned.state, EntityState.ready);
    expect(client.values[entity.id], {'health': 7, 'x': 0});
    expect(_drain(client.session).whereType<StateRejected>(), isEmpty);
  });

  test("a client's own visibility overrides public visibility and filters", () {
    final harness = _Harness();
    final first = harness.join();
    final second = harness.join();
    final host = harness.host.session;
    host.addVisibilityFilter((_, peer) => peer != _client2);
    final entity = host.spawn(harness.schema.avatar, 'Ada');
    harness.run();
    expect(
      [first.log, second.log],
      [
        ['+Ada'],
        <String>[],
      ],
    );

    host
      ..setVisibilityFor(entity, _client1, false)
      ..setVisibilityFor(entity, _client2, true);
    harness.run();
    expect(
      [first.log, second.log],
      [
        ['+Ada', '-Ada'],
        ['+Ada'],
      ],
    );

    // Without their own visibility, the clients follow the entity's public
    // visibility and the filter's latest decisions again.
    host
      ..setVisibilityFor(entity, _client1, null)
      ..setVisibilityFor(entity, _client2, null);
    harness.run();
    expect(
      [first.log, second.log],
      [
        ['+Ada', '-Ada', '+Ada'],
        ['+Ada', '-Ada'],
      ],
    );

    host.setPublicVisibility(entity, false);
    harness.run();
    expect(first.log, ['+Ada', '-Ada', '+Ada', '-Ada']);

    host.setVisibilityFor(entity, _client2, true);
    harness.run();
    expect(second.log, ['+Ada', '-Ada', '+Ada']);
    expect(host.isVisibleTo(entity, _client1), isFalse);
  });

  test('filters decide when an entity spawns, when a client joins, and '
      'when visibility updates', () {
    final harness = _Harness();
    final host = harness.host.session;
    final near = {_client1};
    host.addVisibilityFilter((_, peer) => near.contains(peer));
    final first = harness.join();
    host.spawn(harness.schema.avatar, 'Ada');
    harness.run();
    final second = harness.join();
    expect(
      [first.log, second.log],
      [
        ['+Ada'],
        <String>[],
      ],
    );

    near
      ..clear()
      ..add(_client2);
    host.updateVisibility(peer: _client2);
    harness.run();
    expect(
      [first.log, second.log],
      [
        ['+Ada'],
        ['+Ada'],
      ],
    );

    host.updateVisibility();
    harness.run();
    expect(
      [first.log, second.log],
      [
        ['+Ada', '-Ada'],
        ['+Ada'],
      ],
    );
  });

  test('filters stay until removed, across session restarts', () {
    final harness = _Harness();
    final host = harness.host.session;
    bool hideAll(NetworkEntity _, PeerId _) => false;
    host
      ..addVisibilityFilter(hideAll)
      ..addVisibilityFilter(hideAll)
      ..close()
      ..host(harness.network.host());
    final client = harness.join();
    host.spawn(harness.schema.avatar, 'Ada');
    harness.run();
    expect(client.log, isEmpty);

    expect(host.removeVisibilityFilter(hideAll), isTrue);
    expect(host.removeVisibilityFilter(hideAll), isFalse);
    harness.run();
    expect(client.log, isEmpty);

    host.updateVisibility();
    harness.run();
    expect(client.log, ['+Ada']);
  });

  test('a filter that throws rejects the entity and is reported', () {
    final harness = _Harness();
    final client = harness.join();
    final host = harness.host.session;
    final error = StateError('broken');
    var calls = 0;
    host
      ..addVisibilityFilter((_, _) => throw error)
      ..addVisibilityFilter((_, _) {
        calls++;
        return true;
      });
    _drain(host);
    final entity = host.spawn(harness.schema.avatar, 'Ada');
    harness.run();

    expect(client.log, isEmpty);
    expect(calls, 0);
    final failure = _drain(host).whereType<VisibilityFilterFailed>().single;
    expect(failure.entity, entity.id);
    expect(failure.peer, _client1);
    expect(failure.error, same(error));
  });

  test('filters cannot change the session', () {
    final harness = _Harness();
    final client = harness.join();
    final host = harness.host.session;
    final entity = host.spawn(harness.schema.avatar, 'Ada');
    harness.run();
    final attempts = <void Function()>[
      () => host.spawn(harness.schema.avatar, 'Bob'),
      () => host.despawn(entity),
      () => host.transferAuthority(entity, _client1),
      () => host.setPublicVisibility(entity, false),
      () => host.setVisibilityFor(entity, _client1, false),
      host.updateVisibility,
      () => host.addVisibilityFilter((_, _) => false),
      () => host.removeVisibilityFilter((_, _) => false),
      host.update,
      host.captureState,
    ];
    final errors = <Object>[];
    host.addVisibilityFilter((_, _) {
      for (final attempt in attempts) {
        try {
          attempt();
        } on StateError catch (error) {
          errors.add(error);
        }
      }
      return true;
    });
    _drain(host);

    host.updateVisibility();
    harness.run();

    expect(errors, hasLength(attempts.length));
    expect(_drain(host).whereType<VisibilityFilterFailed>(), isEmpty);
    expect(harness.host.log, ['+Ada']);
    expect(client.log, ['+Ada']);
  });

  test('an entity leaves view with its descendants in one despawn record, and '
      'returns with those that are visible', () {
    final harness = _Harness();
    final client = harness.join();
    final host = harness.host.session;
    final parent = host.spawn(harness.schema.avatar, 'Ada');
    host.spawn(harness.schema.avatar, 'Bob', parent: parent);
    final hidden = host.spawn(
      harness.schema.avatar,
      'Cid',
      parent: parent,
      publicVisibility: false,
    );
    harness.run();
    expect(client.log, ['+Ada', '+Bob']);
    int despawns() =>
        client.session.diagnostics.received[MessageKind.despawn].messages;
    final before = despawns();

    host.setVisibilityFor(parent, _client1, false);
    harness.run();
    expect(client.log, ['+Ada', '+Bob', '-Bob', '-Ada']);
    expect(despawns(), before + 1);

    host.setVisibilityFor(parent, _client1, null);
    harness.run();
    expect(client.log.skip(4), ['+Ada', '+Bob']);
    expect(host.isVisibleTo(hidden, _client1), isFalse);

    // A child that is hidden from a client stays hidden with its parent.
    host.setVisibilityFor(hidden, _client1, true);
    harness.run();
    expect(client.log.last, '+Cid');
    host.setPublicVisibility(parent, false);
    harness.run();
    expect(client.log.skip(7), ['-Cid', '-Bob', '-Ada']);
    expect(host.isVisibleTo(hidden, _client1), isFalse);
  });

  test('a client sees the entities it owns, and their ancestors', () {
    final harness = _Harness();
    final first = harness.join();
    final second = harness.join();
    final host = harness.host.session;
    final parent = host.spawn(
      harness.schema.avatar,
      'Ada',
      publicVisibility: false,
    );
    harness.run();
    final child = host.spawn(
      harness.schema.avatar,
      'Bob',
      owner: _client1,
      parent: parent,
      publicVisibility: false,
    );
    harness.run();
    expect(
      [first.log, second.log],
      [
        ['+Ada', '+Bob'],
        <String>[],
      ],
    );
    expect(first.session.registry[child.id]!.owner, _client1);
    expect(first.session.state, SessionState.ready);

    host
      ..setVisibilityFor(parent, _client1, false)
      ..setVisibilityFor(child, _client1, false)
      ..updateVisibility();
    harness.run();
    expect(first.log, ['+Ada', '+Bob']);
    expect(host.isVisibleTo(parent, _client1), isTrue);
  });

  test('a joining client receives the entities it sees, with their values', () {
    final harness = _Harness();
    final host = harness.host.session;
    final shown = host.spawn(harness.schema.avatar, 'Ada');
    final hidden = host.spawn(
      harness.schema.avatar,
      'Bob',
      publicVisibility: false,
    );
    harness.host.values[shown.id]!['health'] = 42;
    harness.host.values[hidden.id]!['health'] = 7;
    harness.capture();

    final client = harness.join();

    expect(client.session.state, SessionState.ready);
    expect(client.log, ['+Ada']);
    expect(client.values, {
      shown.id: {'health': 42, 'x': 0},
    });
    expect(_drain(client.session).whereType<StateRejected>(), isEmpty);
    expect(host.isVisibleTo(hidden, _client1), isFalse);
  });

  test('state and RPCs reach only the clients that see the entity', () {
    final harness = _Harness();
    final first = harness.join();
    final second = harness.join();
    final host = harness.host.session;
    final entity = host.spawn(
      harness.schema.avatar,
      'Ada',
      publicVisibility: false,
    );
    host.setVisibilityFor(entity, _client1, true);
    harness.run();
    harness.host.values[entity.id]!['health'] = 42;
    harness.capture();
    _drain(host);

    expect(host.callRpc(entity, harness.schema.poke, 1), isTrue);
    expect(
      host.callRpc(entity, harness.schema.direct, 2, peer: _client2),
      isFalse,
    );
    harness.run();

    expect(first.values[entity.id], {'health': 42, 'x': 0});
    expect(first.calls, ['poke Ada 1']);
    expect(second.calls, isEmpty);
    expect(second.session.registry[entity.id], isNull);
    expect(_drain(second.session).whereType<StateRejected>(), isEmpty);
    expect(
      _drain(host).whereType<RpcRejected>().map(
        (rejected) => (rejected.reason, rejected.target),
      ),
      [(RpcRejection.invalidTarget, _client2)],
    );
  });

  test('the host rejects RPCs for an entity that it hides from the caller', () {
    final harness = _Harness();
    final client = harness.join();
    final host = harness.host.session;
    final entity = host.spawn(harness.schema.avatar, 'Ada');
    harness.run();
    final copy = client.session.registry[entity.id]!;
    _drain(host);

    expect(client.session.callRpc(copy, harness.schema.ask, 3), isTrue);
    host.setVisibilityFor(entity, _client1, false);
    harness.run();

    expect(harness.host.calls, isEmpty);
    final rejected = _drain(host).whereType<RpcRejected>().single;
    expect(rejected.reason, RpcRejection.unknownEntity);
    expect(rejected.sender, _client1);
  });

  test('a new authority sees the entity before the transfer, and a previous '
      'one only as its visibility decides', () {
    final harness = _Harness();
    final first = harness.join();
    final second = harness.join();
    final host = harness.host.session;
    final entity = host.spawn(
      harness.schema.avatar,
      'Ada',
      publicVisibility: false,
    );
    harness.run();
    _drain(second.session);

    expect(host.transferAuthority(entity, _client2), isTrue);
    harness.run();
    expect(first.log, isEmpty);
    expect(second.log, ['+Ada']);
    expect(second.session.registry[entity.id]!.authority, _client2);
    expect(_drain(second.session).whereType<AuthorityChanged>(), [
      AuthorityChanged(
        entity: entity.id,
        previous: PeerId.host,
        authority: _client2,
      ),
    ]);

    second.values[entity.id]!['health'] = 33;
    harness.capture();
    expect(harness.host.values[entity.id]!['health'], 33);

    host.transferAuthority(entity, PeerId.host);
    harness.run();
    expect(second.log, ['+Ada', '-Ada']);
    expect(host.isVisibleTo(entity, _client2), isFalse);
    expect(second.session.state, SessionState.ready);
  });

  test('state sent before an entity left view never reaches it after it '
      'returns', () {
    final harness = _Harness();
    final client = harness.join();
    final host = harness.host.session;
    final entity = host.spawn(harness.schema.avatar, 'Ada');
    harness.run();
    final values = harness.host.values[entity.id]!;
    values['x'] = 1;
    harness.capture();
    expect(client.values[entity.id]!['x'], 1);

    harness.network.delayNextUnreliable(
      const Duration(seconds: 1),
      fromHost: true,
    );
    values['x'] = 2;
    harness.capture();
    host.setVisibilityFor(entity, _client1, false);
    values['x'] = 3;
    harness.capture();
    host.setVisibilityFor(entity, _client1, null);
    harness.run();
    expect(client.log, ['+Ada', '-Ada', '+Ada']);
    expect(client.values[entity.id]!['x'], 3);

    harness.clock.advance(const Duration(seconds: 1));
    harness.run();
    expect(client.values[entity.id]!['x'], 3);
  });

  test('the visibility of a client that left is forgotten', () {
    final harness = _Harness();
    final client = harness.join();
    final host = harness.host.session;
    final entity = host.spawn(
      harness.schema.avatar,
      'Ada',
      publicVisibility: false,
    );
    host.setVisibilityFor(entity, _client1, true);
    harness.run();
    client.session.close();
    harness.run();

    expect(host.isVisibleTo(entity, _client1), isFalse);
    expect(
      () => host.setVisibilityFor(entity, _client1, true),
      throwsArgumentError,
    );
  });

  test('only a host decides visibility, for its replicated entities and '
      'clients', () {
    final harness = _Harness();
    final client = harness.join();
    final host = harness.host.session;
    final entity = host.spawn(harness.schema.avatar, 'Ada');
    final board = host.staticEntity(harness.schema.board);
    harness.run();
    final copy = client.session.registry[entity.id]!;

    for (final call in <void Function()>[
      () => host.setPublicVisibility(board, false),
      () => host.setVisibilityFor(board, _client1, false),
      () => host.setVisibilityFor(entity, _stranger, false),
      () => host.setVisibilityFor(entity, PeerId.host, false),
      () => host.updateVisibility(peer: _stranger),
      () => host.isVisibleTo(copy, _client1),
    ]) {
      expect(call, throwsArgumentError);
    }
    for (final call in <void Function()>[
      () => client.session.isVisibleTo(copy, _client1),
      () => client.session.setPublicVisibility(copy, false),
      () => client.session.setVisibilityFor(copy, PeerId.host, false),
      client.session.updateVisibility,
    ]) {
      expect(call, throwsStateError);
    }

    host.despawn(entity);
    expect(() => host.isVisibleTo(entity, _client1), throwsArgumentError);
    expect(() => host.setPublicVisibility(entity, true), throwsArgumentError);
  });
}
