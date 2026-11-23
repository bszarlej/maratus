import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maratus_flame/maratus_flame.dart';

final class _Protocol {
  _Protocol() {
    final builder = ProtocolSchemaBuilder();
    body = builder.addSpawnType(
      const SpawnTypeId('test.body'),
      const Vector2Codec(),
    );
    marker = builder.addSpawnType(
      const SpawnTypeId('test.marker'),
      const IntCodec(min: 0, max: 9),
    );
    schema = builder.build();
  }

  late final SpawnType<Vector2> body;
  late final SpawnType<int> marker;
  late final ProtocolSchema schema;
}

/// A positioned entity, such as a player or a crate.
final class _Body extends PositionComponent with NetworkedComponent {
  _Body(SpawnContext<Vector2> context)
    : networkEntity = context.entity,
      super(position: context.data);

  @override
  final NetworkEntity networkEntity;
}

/// An entity without a position, such as the state of a match.
final class _Marker extends Component with NetworkedComponent {
  _Marker(SpawnContext<int> context) : networkEntity = context.entity;

  @override
  final NetworkEntity networkEntity;
}

/// A session driven by a scope with a spawner, in its own game.
final class _Peer {
  _Peer(this.session, this.game, this.scope, this.spawner, this.created);

  final MultiplayerSession session;
  final FlameGame game;
  final MultiplayerScope scope;
  final MultiplayerSpawner spawner;

  /// The IDs of the entities that [spawner] created components of, in order.
  final List<int> created;

  /// The ID of this peer.
  PeerId get id => session.localPeer!;

  /// The host's component of [entity].
  _Body operator [](NetworkEntity entity) =>
      spawner.spawnedComponents[entity]! as _Body;

  /// The IDs of the entities that this peer has components of.
  Set<int> get seen => {
    for (final entity in spawner.spawnedComponents.keys) entity.id.value,
  };
}

final class _World {
  final clock = ManualClock();
  final protocol = _Protocol();
  late final network = InMemoryNetwork(clock: clock);
  final peers = <_Peer>[];

  Future<_Peer> host(List<Component> extra) {
    final session = MultiplayerSession(schema: protocol.schema, clock: clock);
    addTearDown(session.close);
    return attach(session..host(network.host()), extra);
  }

  Future<_Peer> join([List<Component> extra = const []]) {
    final session = MultiplayerSession(schema: protocol.schema, clock: clock);
    addTearDown(session.close);
    return attach(session..join(network.connect()), extra);
  }

  Future<_Peer> attach(
    MultiplayerSession session,
    List<Component> extra,
  ) async {
    final game = await initializeFlameGame();
    addTearDown(game.dispose);
    final created = <int>[];
    final spawner = MultiplayerSpawner()
      ..register(protocol.body, (context) {
        created.add(context.entity.id.value);
        return _Body(context);
      })
      ..register(protocol.marker, _Marker.new);
    final scope = MultiplayerScope(
      session: session,
      children: [spawner, ...extra],
    );
    await game.add(scope);
    game.update(0);
    final peer = _Peer(session, game, scope, spawner, created);
    peers.add(peer);
    return peer;
  }

  /// Advances the network and updates every game, letting loads finish.
  Future<void> pump([int rounds = 6]) async {
    for (var i = 0; i < rounds; i++) {
      clock.advance(Duration.zero);
      for (final peer in peers) {
        peer.game.update(0);
      }
      for (var j = 0; j < 3; j++) {
        await Future<void>.value();
      }
    }
  }

  /// Lets [seconds] of game time pass on every peer, then pumps.
  Future<void> step(double seconds) async {
    for (final peer in peers) {
      peer.game.update(seconds);
    }
    await pump();
  }
}

int _id(NetworkEntity entity) => entity.id.value;

void main() {
  test('shows a client the entities near its own, with hysteresis', () async {
    final world = _World();
    final host = await world.host([
      ProximityVisibility(showRange: 10, hideRange: 15, interval: 1),
    ]);
    final client = await world.join();
    await world.pump();
    final peer = client.id;
    final session = host.session;
    final player = session.spawn(
      world.protocol.body,
      Vector2(0, 0),
      owner: peer,
    );
    final near = session.spawn(world.protocol.body, Vector2(8, 0));
    final far = session.spawn(world.protocol.body, Vector2(40, 0));
    await world.pump();
    // New entities come into view at once, without waiting for the interval.
    expect(client.seen, {_id(player), _id(near)});

    host[player].position.x = 26;
    await world.step(0.5);
    expect(client.seen, {_id(player), _id(near)}, reason: 'Not yet updated.');
    await world.step(0.5);
    expect(client.seen, {_id(player)});
    expect(session.isVisibleTo(far, peer), isFalse);

    host[player].position.x = 31;
    await world.step(1);
    expect(client.seen, {_id(player), _id(far)});

    // Beyond the show range but within the hide range, it stays in view.
    host[player].position.x = 27;
    await world.step(1);
    expect(client.seen, {_id(player), _id(far)});

    host[player].position.x = 24;
    await world.step(1);
    expect(client.seen, {_id(player)});
  });

  test('hides a new entity that spawns out of range from the start', () async {
    final world = _World();
    final host = await world.host([ProximityVisibility(showRange: 10)]);
    final client = await world.join();
    await world.pump();
    final session = host.session;
    final player = session.spawn(
      world.protocol.body,
      Vector2(0, 0),
      owner: client.id,
    );
    session.spawn(world.protocol.body, Vector2(50, 0));
    await world.pump();
    await world.step(1);
    expect(client.created, [_id(player)]);
  });

  test('shows a late-joining client the entities near its player', () async {
    final world = _World();
    final host = await world.host([ProximityVisibility(showRange: 10)]);
    final session = host.session;
    final near = session.spawn(world.protocol.body, Vector2(5, 5));
    session.spawn(world.protocol.body, Vector2(50, 50));
    final client = await world.join();
    await world.pump();
    // Without a player, the client sees from nowhere.
    expect(client.seen, isEmpty);

    final player = session.spawn(
      world.protocol.body,
      Vector2(0, 0),
      owner: client.id,
    );
    await world.pump();
    expect(client.seen, {_id(near), _id(player)});
  });

  test('each client sees from the entities that it owns', () async {
    final world = _World();
    final host = await world.host([ProximityVisibility(showRange: 10)]);
    final first = await world.join();
    final second = await world.join();
    await world.pump();
    final session = host.session;
    final firstPlayer = session.spawn(
      world.protocol.body,
      Vector2(0, 0),
      owner: first.id,
      onOwnerLeft: OwnerLeftPolicy.despawn,
    );
    final secondPlayer = session.spawn(
      world.protocol.body,
      Vector2(100, 0),
      owner: second.id,
    );
    final nearFirst = session.spawn(world.protocol.body, Vector2(0, 5));
    final nearSecond = session.spawn(world.protocol.body, Vector2(100, 5));
    await world.pump();
    expect(first.seen, {_id(firstPlayer), _id(nearFirst)});
    expect(second.seen, {_id(secondPlayer), _id(nearSecond)});

    host[secondPlayer].position.setValues(0, 8);
    await world.step(0.2);
    expect(first.seen, {_id(firstPlayer), _id(nearFirst), _id(secondPlayer)});
    expect(second.seen, {_id(secondPlayer), _id(nearFirst), _id(firstPlayer)});

    first.session.close();
    await world.pump();
    await world.step(0.2);
    expect(second.seen, {_id(secondPlayer), _id(nearFirst)});
  });

  test('sees from the entities whose ownership moved to a client', () async {
    final world = _World();
    final host = await world.host([ProximityVisibility(showRange: 10)]);
    final first = await world.join();
    final second = await world.join();
    await world.pump();
    final session = host.session;
    final player = session.spawn(
      world.protocol.body,
      Vector2(0, 0),
      owner: first.id,
    );
    final near = session.spawn(world.protocol.body, Vector2(0, 5));
    await world.pump();
    expect(first.seen, {_id(player), _id(near)});
    expect(second.seen, isEmpty);

    session.transferOwnership(player, second.id);
    await world.step(0.2);

    expect(second.seen, {_id(player), _id(near)});
    expect(first.seen, isEmpty);
    expect(
      second.spawner
          .componentsOwnedBy(second.id)
          .map((c) => c.networkEntity.id),
      [player.id],
    );
    expect(first.spawner.componentsOwnedBy(first.id), isEmpty);
  });

  test('leaves entities without a position to the other rules', () async {
    final world = _World();
    final host = await world.host([ProximityVisibility(showRange: 10)]);
    final client = await world.join();
    await world.pump();
    final marker = host.session.spawn(world.protocol.marker, 1);
    final body = host.session.spawn(world.protocol.body, Vector2(0, 0));
    await world.pump();
    expect(client.seen, {_id(marker)});

    host.session.setPublicVisibility(marker, false);
    await world.pump();
    expect(client.seen, isEmpty);
    expect(host.session.isVisibleTo(body, client.id), isFalse);
  });

  test('measures distances in the coordinates of the scope', () async {
    final world = _World();
    final host = await world.host([ProximityVisibility(showRange: 10)]);
    final client = await world.join();
    await world.pump();
    final session = host.session;
    final player = session.spawn(
      world.protocol.body,
      Vector2(0, 0),
      owner: client.id,
    );
    final platform = session.spawn(world.protocol.body, Vector2(8, 0));
    // Each 8 from the platform, but 16 and 2 from the player.
    session.spawn(world.protocol.body, Vector2(8, 0), parent: platform);
    final inward = session.spawn(
      world.protocol.body,
      Vector2(-6, 0),
      parent: platform,
    );
    await world.pump();
    expect(client.seen, {_id(player), _id(platform), _id(inward)});
  });

  test('works next to other filters', () async {
    final world = _World();
    final host = await world.host([ProximityVisibility(showRange: 10)]);
    final client = await world.join();
    await world.pump();
    final session = host.session;
    final player = session.spawn(
      world.protocol.body,
      Vector2(0, 0),
      owner: client.id,
    );
    final allowed = session.spawn(world.protocol.body, Vector2(5, 0));
    final rejected = session.spawn(world.protocol.body, Vector2(0, 5));
    session.addVisibilityFilter((entity, _) => entity != rejected);
    await world.step(0.2);
    expect(client.seen, {_id(player), _id(allowed)});
  });

  test('sees from the components that viewersOf returns', () async {
    final world = _World();
    final camera = PositionComponent(position: Vector2(100, 0));
    final host = await world.host([
      camera,
      ProximityVisibility(showRange: 10, viewersOf: (_) => [camera]),
    ]);
    final client = await world.join();
    await world.pump();
    final session = host.session;
    final player = session.spawn(
      world.protocol.body,
      Vector2(0, 0),
      owner: client.id,
    );
    session.spawn(world.protocol.body, Vector2(5, 0));
    final watched = session.spawn(world.protocol.body, Vector2(95, 0));
    await world.pump();
    expect(client.seen, {_id(player), _id(watched)});
  });

  test('removing it shows the entities that it hid', () async {
    final world = _World();
    final proximity = ProximityVisibility(showRange: 10);
    final host = await world.host([proximity]);
    final client = await world.join();
    await world.pump();
    final far = host.session.spawn(world.protocol.body, Vector2(50, 0));
    await world.pump();
    expect(client.seen, isEmpty);

    proximity.removeFromParent();
    await world.pump();
    expect(client.seen, {_id(far)});

    await host.scope.add(proximity);
    await world.pump();
    expect(client.seen, isEmpty);
  });

  test('does nothing on a client', () async {
    final world = _World();
    final host = await world.host(const []);
    final client = await world.join([ProximityVisibility(showRange: 10)]);
    await world.pump();
    final far = host.session.spawn(world.protocol.body, Vector2(50, 0));
    await world.step(1);
    expect(client.seen, {_id(far)});
  });

  test('validates its ranges and interval', () {
    expect(() => ProximityVisibility(showRange: -1), throwsArgumentError);
    expect(
      () => ProximityVisibility(showRange: double.infinity),
      throwsArgumentError,
    );
    expect(
      () => ProximityVisibility(showRange: 10, hideRange: 9),
      throwsArgumentError,
    );
    expect(
      () => ProximityVisibility(showRange: 10, interval: 0),
      throwsArgumentError,
    );
    expect(ProximityVisibility(showRange: 10).hideRange, 10);
  });
}
