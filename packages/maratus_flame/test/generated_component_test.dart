import 'package:flame/game.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maratus_flame/maratus_flame.dart';

import 'support/player.dart';

/// A session driven by a scope with a spawner of generated players.
final class _Peer {
  _Peer(this.session, this.game, this.spawner);

  final MultiplayerSession session;
  final FlameGame game;
  final MultiplayerSpawner spawner;

  Player get player => spawner.spawnedComponents.values.single as Player;
}

final class _World {
  final clock = ManualClock();
  late final network = InMemoryNetwork(clock: clock);
  final peers = <_Peer>[];

  late final schema = () {
    final builder = ProtocolSchemaBuilder();
    PlayerNet.register(builder);
    return builder.build();
  }();

  MultiplayerSession session() {
    final session = MultiplayerSession(schema: schema, clock: clock);
    addTearDown(session.close);
    return session;
  }

  Future<_Peer> attach(MultiplayerSession session) async {
    final game = await initializeFlameGame();
    addTearDown(game.dispose);
    final spawner = MultiplayerSpawner()
      ..register(PlayerNet.spawnType, Player.new);
    await game.add(MultiplayerScope(session: session, children: [spawner]));
    game.update(0);
    final peer = _Peer(session, game, spawner);
    peers.add(peer);
    return peer;
  }

  /// Advances the network by [rounds] synchronizer intervals and updates
  /// every game, letting loads finish.
  Future<void> pump([int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      clock.advance(const Duration(milliseconds: 50));
      for (final peer in peers) {
        peer.game.update(0.05);
      }
      for (var j = 0; j < 3; j++) {
        await Future<void>.value();
      }
    }
  }
}

void main() {
  late _World world;
  late _Peer host;
  late _Peer client;

  setUp(() async {
    world = _World();
    host = await world.attach(world.session()..host(world.network.host()));
    client = await world.attach(world.session()..join(world.network.connect()));
    await world.pump();
    expect(client.session.state, SessionState.ready);
    host.session.spawn(
      PlayerNet.spawnType,
      2,
      owner: client.session.localPeer!,
    );
    await world.pump();
  });

  test('spawns components through their generated spawn type', () {
    expect(host.player.lane, 2);
    expect(client.player.lane, 2);
    expect(client.player.networkEntity.owner, client.session.localPeer);
    expect(client.player.isNetworkReady, isTrue);
  });

  test('binds handlers although onNetworkAttach does not call super', () async {
    expect(host.player.attachments, 1);
    expect(client.player.attachments, 1);

    expect(host.player.rpc.hit(25), isTrue);
    await world.pump();

    expect(host.player.hits, [25]);
    expect(client.player.hits, [25]);
  });

  test('typed senders send several parameters and select peers', () async {
    final clientPeer = client.session.localPeer!;

    expect(client.player.rpc.fire(Vector2(10, 20), 2), isTrue);
    expect(client.player.rpc.whisper('psst', to: PeerId.host), isTrue);
    await world.pump();

    final (at, weapon, sender) = host.player.shots.single;
    expect(at, Vector2(10, 20));
    expect(weapon, 2);
    expect(sender, clientPeer);
    expect(host.player.whispers, [('psst', clientPeer)]);
    expect(client.player.shots, isEmpty);
    expect(client.player.whispers, isEmpty);
  });

  test('the host enforces the caller policies of the annotations', () async {
    host.player.rpc.fire(Vector2(1, 1), 0);
    client.player.rpc.hit(5);
    await world.pump();

    expect(host.player.shots, isEmpty);
    expect(host.player.hits, isEmpty);
    expect(client.player.hits, isEmpty);
  });

  test('synchronizes annotated fields and inherited getters', () async {
    host.player
      ..health = 40
      ..position.setValues(100, 200);
    await world.pump(12);

    expect(client.player.health, 40);
    expect(client.player.position, Vector2.zero());
    final shown = client.player.networkSynchronizer?.interpolated(
      PlayerNet.syncedPosition,
    );
    expect(shown?.value, Vector2(100, 200));
  });

  test('releases the synchronizer when the component is removed', () async {
    final player = client.player;
    expect(player.networkSynchronizer, isNotNull);

    player.removeFromParent();
    await world.pump(1);

    expect(player.networkSynchronizer, isNull);
  });
}
