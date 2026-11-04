import 'dart:async';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maratus_flame/maratus_flame.dart';

const _client1 = PeerId(2);

List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

final class _Protocol {
  _Protocol() {
    final builder = ProtocolSchemaBuilder();
    avatar = builder.addSpawnType(
      const SpawnTypeId('test.avatar'),
      const StringCodec(maxLength: 16),
    );
    item = builder.addSpawnType(
      const SpawnTypeId('test.item'),
      const IntCodec(min: 0, max: 9),
    );
    poke = builder.addRpc(
      const RpcId('test.poke'),
      const IntCodec(min: 0, max: 9),
      target: RpcTarget.all,
      local: RpcLocal.include,
    );
    schema = builder.build();
  }

  late final SpawnType<String> avatar;
  late final SpawnType<int> item;
  late final Rpc<int> poke;
  late final ProtocolSchema schema;
}

final class _Avatar extends Component with NetworkedComponent {
  _Avatar(SpawnContext<String> context, this.poke, {this.loadGate})
    : networkEntity = context.entity,
      name = context.data;

  @override
  final NetworkEntity networkEntity;
  final String name;
  final Rpc<int> poke;
  final Future<void>? loadGate;
  final received = <int>[];

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    await loadGate;
  }

  @override
  void onNetworkAttach(EntityAttachment attachment) {
    attachment.bindRpc(poke, (_, value) => received.add(value));
  }
}

final class _Item extends Component with NetworkedComponent {
  _Item(SpawnContext<int> context)
    : networkEntity = context.entity,
      value = context.data;

  _Item.of(this.networkEntity) : value = 0;

  @override
  final NetworkEntity networkEntity;
  final int value;
}

/// A session driven by a scope with a spawner, in its own game.
final class _Peer {
  _Peer(this.session, this.game, this.scope, this.spawner);

  final MultiplayerSession session;
  final FlameGame game;
  final MultiplayerScope scope;
  final MultiplayerSpawner spawner;

  /// The spawned component of the entity with [id], if any.
  NetworkedComponent? operator [](int id) {
    for (final MapEntry(key: entity, value: component)
        in spawner.spawnedComponents.entries) {
      if (entity.id.value == id) return component;
    }
    return null;
  }

  Iterable<int> get spawnedIds =>
      spawner.spawnedComponents.keys.map((entity) => entity.id.value);
}

final class _World {
  final clock = ManualClock();
  final protocol = _Protocol();
  late final network = InMemoryNetwork(clock: clock);
  final peers = <_Peer>[];

  MultiplayerSession session() {
    final session = MultiplayerSession(schema: protocol.schema, clock: clock);
    addTearDown(session.close);
    return session;
  }

  Future<_Peer> host() => attach(session()..host(network.host()));

  Future<_Peer> join({Future<void>? avatarGate}) => attach(
    session()..join(network.connect()),
    spawner: spawnerFor(avatarGate: avatarGate),
  );

  MultiplayerSpawner spawnerFor({Future<void>? avatarGate}) =>
      MultiplayerSpawner()
        ..register(
          protocol.avatar,
          (context) => _Avatar(context, protocol.poke, loadGate: avatarGate),
        )
        ..register(protocol.item, _Item.new);

  Future<_Peer> attach(
    MultiplayerSession session, {
    MultiplayerSpawner? spawner,
    bool ownsSession = true,
  }) async {
    final game = await initializeFlameGame();
    addTearDown(game.dispose);
    final scopeSpawner = spawner ?? spawnerFor();
    final scope = MultiplayerScope(
      session: session,
      ownsSession: ownsSession,
      children: [scopeSpawner],
    );
    await game.add(scope);
    game.update(0);
    final peer = _Peer(session, game, scope, scopeSpawner);
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
}

void main() {
  test('every peer creates matching components for spawned entities', () async {
    final world = _World();
    final host = await world.host();
    final first = await world.join();
    await world.join();
    await world.pump();
    expect(first.session.state, SessionState.ready);

    final avatar = host.session.spawn(
      world.protocol.avatar,
      'Ada',
      owner: _client1,
      authority: _client1,
    );
    host.session.spawn(world.protocol.item, 7, parent: avatar);
    expect(host[1], isA<_Avatar>());
    expect(host[2]!.parent, same(host[1]));
    await world.pump();

    for (final peer in world.peers) {
      final component = peer[1]! as _Avatar;
      final item = peer[2]! as _Item;
      expect(component.name, 'Ada');
      expect(component.networkEntity.owner, _client1);
      expect(component.networkEntity.authority, _client1);
      expect(component.networkEntity.state, EntityState.ready);
      expect(component.parent, same(peer.spawner));
      expect(component.isNetworkReady, isTrue);
      expect(item.value, 7);
      expect(item.parent, same(component));
      expect(item.isNetworkReady, isTrue);
    }
  });

  test('a joining client creates components for existing entities', () async {
    final world = _World();
    final host = await world.host();
    final avatar = host.session.spawn(world.protocol.avatar, 'Ada');
    host.session.spawn(world.protocol.item, 3, parent: avatar);

    final client = await world.join();
    await world.pump();

    expect((client[1]! as _Avatar).name, 'Ada');
    expect(client[2]!.parent, same(client[1]));
    expect(client[2]!.isNetworkReady, isTrue);
  });

  test('a spawner added later creates components for live entities', () async {
    final world = _World();
    final session = world.session()..host(world.network.host());
    final early = session.spawn(world.protocol.avatar, 'Early');
    session.despawn(session.spawn(world.protocol.avatar, 'Gone'));

    final host = await world.attach(session);
    await world.pump();

    expect(host.spawner.spawnedComponents.keys, [early]);
    expect(host[1]!.isNetworkReady, isTrue);
  });

  test('RPCs sent with a spawn reach its components once they mount', () async {
    final world = _World();
    final host = await world.host();
    final client = await world.join();
    await world.pump();

    final avatar = host.session.spawn(world.protocol.avatar, 'Ada');
    expect(host.session.callRpc(avatar, world.protocol.poke, 5), isTrue);
    await world.pump();

    expect((host[1]! as _Avatar).received, [5]);
    expect((client[1]! as _Avatar).received, [5]);
    for (final peer in world.peers) {
      expect(_drain(peer.session).whereType<RpcRejected>(), isEmpty);
    }
  });

  test('despawning removes components and descendants everywhere', () async {
    final world = _World();
    final host = await world.host();
    await world.join();
    await world.pump();
    final avatar = host.session.spawn(world.protocol.avatar, 'Ada');
    host.session.spawn(world.protocol.item, 1, parent: avatar);
    await world.pump();
    final components = [
      for (final peer in world.peers) ...[peer[1]!, peer[2]!],
    ];

    expect(host.session.despawn(avatar), isTrue);
    expect(host.spawner.spawnedComponents, isEmpty);
    await world.pump();

    for (final peer in world.peers) {
      expect(peer.spawner.spawnedComponents, isEmpty);
      expect(peer.spawner.children, isEmpty);
    }
    for (final component in components) {
      expect(component.isMounted, isFalse);
      expect(component.isNetworkReady, isFalse);
    }
  });

  test('despawning a loading component leaves no ghost behind', () async {
    final world = _World();
    final host = await world.host();
    final gate = Completer<void>();
    final client = await world.join(avatarGate: gate.future);
    await world.pump();
    final avatar = host.session.spawn(world.protocol.avatar, 'Ada');
    await world.pump();
    final loading = client[1]! as _Avatar;
    expect(loading.isLoaded, isFalse);

    host.session.despawn(avatar);
    await world.pump();
    gate.complete();
    await world.pump();

    expect(client.spawner.spawnedComponents, isEmpty);
    expect(client.spawner.children, isEmpty);
    expect(loading.isLoaded, isTrue);
    expect(loading.isMounted, isFalse);
    expect(loading.isNetworkReady, isFalse);
  });

  test('departures and session ends remove the affected components', () async {
    final world = _World();
    final host = await world.host();
    final owner = await world.join();
    final observer = await world.join();
    await world.pump();
    host.session
      ..spawn(
        world.protocol.avatar,
        'Ada',
        owner: _client1,
        onOwnerLeft: OwnerLeftPolicy.despawn,
      )
      ..spawn(world.protocol.avatar, 'Kept', owner: _client1);
    await world.pump();
    final ownerComponents = owner.spawner.spawnedComponents.values.toList();
    final removed = observer[1]!;

    owner.session.close();
    expect(owner.spawner.spawnedComponents, isEmpty);
    await world.pump();

    expect(host.spawnedIds, [2]);
    expect(observer.spawnedIds, [2]);
    expect(removed.isMounted, isFalse);
    for (final component in ownerComponents) {
      expect(component.isMounted, isFalse);
    }
    host.session.close();
    await world.pump();
    expect(observer.session.state, SessionState.disconnected);
    expect(observer.spawner.spawnedComponents, isEmpty);
    expect(observer.spawner.children, isEmpty);
  });

  test('local removal neither despawns nor recreates a component', () async {
    final world = _World();
    final host = await world.host();
    final client = await world.join();
    await world.pump();
    final avatar = host.session.spawn(world.protocol.avatar, 'Ada');
    await world.pump();
    final component = client[1]!;

    component.removeFromParent();
    await world.pump();
    expect(component.isMounted, isFalse);
    expect(client.session.registry[avatar.id]!.state, EntityState.ready);
    expect(client.spawner.spawnedComponents.values, [component]);
    host.session.spawn(world.protocol.item, 1, parent: avatar);
    await world.pump();

    expect(client[2]!.parent, same(client.spawner));
    expect(host[2]!.parent, same(host[1]));
    expect(host.session.despawn(avatar), isTrue);
    await world.pump();
    expect(client.spawner.spawnedComponents, isEmpty);
    expect(client.session.state, SessionState.ready);
    expect(host.session.isReady(client.session.localPeer!), isTrue);
  });

  test('a removed spawner reconciles its components when re-added', () async {
    final world = _World();
    final host = await world.host();
    final gone = host.session.spawn(world.protocol.avatar, 'Gone');
    final kept = host.session.spawn(world.protocol.avatar, 'Kept');
    await world.pump();
    final goneComponent = host[1]!;
    final keptComponent = host[2]!;

    host.spawner.removeFromParent();
    await world.pump();
    final added = host.session.spawn(world.protocol.avatar, 'Added');
    host.session.despawn(gone);
    expect(host.spawner.spawnedComponents.keys, [gone, kept]);
    await host.scope.add(host.spawner);
    await world.pump();

    expect(host.spawner.spawnedComponents.keys, [kept, added]);
    expect(host[2], same(keptComponent));
    expect(host.spawner.children, [keptComponent, host[3]]);
    expect(keptComponent.isNetworkReady, isTrue);
    expect(host[3]!.isNetworkReady, isTrue);
    expect(goneComponent.isMounted, isFalse);
  });

  test('a spawner being removed with its subtree creates nothing', () async {
    final world = _World();
    final session = world.session()..host(world.network.host());
    final outer = Component();
    final container = Component();
    final spawner = world.spawnerFor();
    final host = await world.attach(session, spawner: MultiplayerSpawner());
    await host.scope.add(outer);
    await outer.add(container);
    await container.add(spawner);
    await world.pump();

    // An ordinary parent removes the subtree without telling the scope.
    container.removeFromParent();
    session.spawn(world.protocol.avatar, 'Ada');
    expect(spawner.spawnedComponents, isEmpty);
    await world.pump();
    await outer.add(container);
    await world.pump();

    expect((spawner.spawnedComponents.values.single as _Avatar).name, 'Ada');
    expect(spawner.spawnedComponents.values.single.isNetworkReady, isTrue);
  });

  test('a spawn type belongs to one spawner and one factory', () async {
    final world = _World();
    final host = await world.host();
    final rival = MultiplayerSpawner();
    await host.scope.add(rival);
    host.game.update(0);

    expect(
      () => host.spawner.register(world.protocol.item, _Item.new),
      throwsStateError,
    );
    expect(
      () => rival.register(world.protocol.item, _Item.new),
      throwsStateError,
    );
    const impostor = SpawnType<int>(
      id: SpawnTypeId('test.ghost'),
      codec: IntCodec(),
    );
    expect(() => rival.register(impostor, _Item.new), throwsArgumentError);
    host.session.spawn(world.protocol.item, 1);

    expect(host[1], isA<_Item>());
    expect(rival.spawnedComponents, isEmpty);
  });

  test('a factory must create the component of the spawned entity', () async {
    final world = _World();
    final session = world.session()..host(world.network.host());
    final stray = session.registry.create(
      owner: PeerId.host,
      authority: PeerId.host,
    );
    final spawner = MultiplayerSpawner()
      ..register(world.protocol.item, (_) => _Item.of(stray));
    await world.attach(session, spawner: spawner);
    _drain(session);

    session.spawn(world.protocol.item, 1);

    expect(
      _drain(session).whereType<SpawnHandlerFailed>().single.error,
      isA<StateError>(),
    );
    expect(spawner.spawnedComponents, isEmpty);
    expect(spawner.children, isEmpty);
  });

  test('a disposed scope stops its spawners', () async {
    final world = _World();
    final session = world.session()..host(world.network.host());
    final host = await world.attach(session, ownsSession: false);
    session.spawn(world.protocol.avatar, 'Ada');

    host.scope.dispose();
    session.spawn(world.protocol.avatar, 'Bob');
    await world.pump();

    expect(host.spawnedIds, [1]);
    expect(session.state, SessionState.hosting);
  });

  test('a mounted spawner keeps working across session restarts', () async {
    final world = _World();
    final session = world.session()..host(world.network.host());
    final host = await world.attach(session, ownsSession: false);
    session.spawn(world.protocol.avatar, 'Before');
    await world.pump();
    final before = host[1]!;

    session.close();
    expect(host.spawner.spawnedComponents, isEmpty);
    await world.pump();
    expect(before.isMounted, isFalse);
    session.host(InMemoryNetwork(clock: world.clock).host());
    final after = session.spawn(world.protocol.avatar, 'After');
    await world.pump();

    expect(after.id, const EntityId(1));
    expect((host[1]! as _Avatar).name, 'After');
    expect(host[1]!.isNetworkReady, isTrue);
  });
}
