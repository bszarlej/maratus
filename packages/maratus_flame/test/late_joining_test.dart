import 'dart:async';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maratus_flame/maratus_flame.dart';

const _interval = Duration(milliseconds: 50);
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
    height = builder.addField(
      const FieldId('test.height'),
      const DoubleCodec(min: 0, max: 100),
    );
    schema = builder.build();
  }

  late final SpawnType<String> avatar;
  late final SyncField<double> height;
  late final ProtocolSchema schema;
}

/// A spawned avatar whose loading waits for [loadGate], with a synchronized
/// height.
final class _Avatar extends Component with NetworkedComponent {
  _Avatar(SpawnContext<String> context, this.heightField, {this.loadGate})
    : networkEntity = context.entity,
      name = context.data;

  @override
  final NetworkEntity networkEntity;
  final String name;
  final SyncField<double> heightField;
  final Future<void>? loadGate;
  var height = 0.0;

  /// Each received height applied, with the session state it was applied in.
  final applied = <(double, SessionState)>[];

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    await loadGate;
  }

  @override
  void onNetworkAttach(EntityAttachment attachment) {
    attachment.synchronize([
      heightField.property(
        get: () => height,
        set: (value) {
          height = value;
          applied.add((value, multiplayerSession.state));
        },
      ),
    ], interval: _interval);
  }
}

/// A session driven by a scope with a spawner, in its own game.
final class _Peer {
  _Peer(this.session, this.game, this.spawner);

  final MultiplayerSession session;
  final FlameGame game;
  final MultiplayerSpawner spawner;

  /// The spawned avatar named [name].
  _Avatar operator [](String name) => spawner.spawnedComponents.values
      .cast<_Avatar>()
      .singleWhere((avatar) => avatar.name == name);

  Iterable<String> get names =>
      spawner.spawnedComponents.values.cast<_Avatar>().map((a) => a.name);
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

  /// Joins with a spawner whose avatars wait for [gate] to load, and whose
  /// factory throws for the names in [failing].
  Future<_Peer> join({Future<void>? gate, Set<String> failing = const {}}) =>
      attach(session()..join(network.connect()), gate: gate, failing: failing);

  Future<_Peer> attach(
    MultiplayerSession session, {
    Future<void>? gate,
    Set<String> failing = const {},
  }) async {
    final game = await initializeFlameGame();
    addTearDown(game.dispose);
    final spawner = MultiplayerSpawner()
      ..register(protocol.avatar, (context) {
        if (failing.contains(context.data)) {
          throw StateError('Cannot create ${context.data}.');
        }
        return _Avatar(context, protocol.height, loadGate: gate);
      });
    await game.add(MultiplayerScope(session: session, children: [spawner]));
    game.update(0);
    final peer = _Peer(session, game, spawner);
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

  /// Lets a synchronizer interval pass, so that every game captures state.
  Future<void> tick() async {
    clock.advance(_interval);
    await pump();
  }
}

void main() {
  test(
    'a joining client is ready once its baseline components mount',
    () async {
      final world = _World();
      final host = await world.host();
      host.session
        ..spawn(world.protocol.avatar, 'Ada')
        ..spawn(world.protocol.avatar, 'Bob');
      await world.pump();
      host['Ada'].height = 12;
      await world.tick();
      final gate = Completer<void>();

      final client = await world.join(gate: gate.future);
      await world.pump();

      expect(client.session.state, SessionState.synchronizing);
      expect(client.session.pendingBaselineCount, 2);
      expect(host.session.isReady(client.session.localPeer!), isFalse);
      expect(client.names, ['Ada', 'Bob']);
      expect(client['Ada'].isLoaded, isFalse);
      expect(client['Ada'].applied, isEmpty);

      gate.complete();
      await world.pump();

      expect(client.session.state, SessionState.ready);
      expect(host.session.isReady(client.session.localPeer!), isTrue);
      expect(client['Ada'].isNetworkReady, isTrue);
      expect(client['Bob'].isNetworkReady, isTrue);
      expect(client['Ada'].applied, [(12.0, SessionState.synchronizing)]);
      expect(client['Bob'].applied, [(0.0, SessionState.synchronizing)]);
    },
  );

  test('changes during installation reach loading components', () async {
    final world = _World();
    final host = await world.host();
    final ada = host.session.spawn(world.protocol.avatar, 'Ada');
    await world.pump();
    final gate = Completer<void>();
    final client = await world.join(gate: gate.future);
    await world.pump();
    final loadingAda = client['Ada'];
    expect(client.session.state, SessionState.synchronizing);

    host.session
      ..despawn(ada)
      ..spawn(world.protocol.avatar, 'Bob');
    await world.pump();

    // Nothing remains of the baseline, so the client is ready while Bob,
    // spawned afterward, loads like any spawn during gameplay.
    expect(client.session.state, SessionState.ready);
    expect(client.names, ['Bob']);
    final bob = client['Bob'];
    expect(bob.isLoaded, isFalse);

    gate.complete();
    await world.pump();

    expect(loadingAda.isMounted, isFalse);
    expect(bob.isNetworkReady, isTrue);
    expect(client.spawner.children, [bob]);
  });

  test(
    'a failing factory ends the bootstrap without a partial world',
    () async {
      final world = _World();
      final host = await world.host();
      host.session.spawn(world.protocol.avatar, 'Ada');
      final bob = host.session.spawn(world.protocol.avatar, 'Bob');
      await world.pump();
      _drain(host.session);
      final gate = Completer<void>();

      final client = await world.join(gate: gate.future, failing: {'Bob'});
      await world.pump();
      final events = _drain(client.session);
      // Ada's component was still loading when the bootstrap failed.
      gate.complete();
      await world.pump();

      expect(client.session.disconnectReason, DisconnectReason.bootstrapFailed);
      expect(
        events.whereType<SpawnHandlerFailed>().map((event) => event.entity),
        [bob.id],
      );
      expect(
        events.last,
        const SessionStateChanged(
          SessionState.disconnected,
          DisconnectReason.bootstrapFailed,
        ),
      );
      expect(client.spawner.spawnedComponents, isEmpty);
      expect(client.spawner.children, isEmpty);
      expect(_drain(host.session), [
        const PeerJoined(_client1),
        const PeerLeft(_client1, DisconnectReason.bootstrapFailed),
      ]);
      expect(host.names, ['Ada', 'Bob']);
    },
  );

  test('a client rejoins through the same scope with a fresh world', () async {
    final world = _World();
    final host = await world.host();
    host.session.spawn(world.protocol.avatar, 'Ada');
    await world.pump();
    final client = await world.join();
    await world.pump();
    expect(client.session.state, SessionState.ready);
    final before = client['Ada'];

    client.session.close();
    expect(client.spawner.spawnedComponents, isEmpty);
    host.session.spawn(world.protocol.avatar, 'Bob');
    client.session.join(world.network.connect());
    await world.pump();

    expect(client.session.state, SessionState.ready);
    expect(client.session.localPeer, const PeerId(3));
    expect(client.names, ['Ada', 'Bob']);
    expect(client['Ada'], isNot(same(before)));
    expect(before.isMounted, isFalse);
    expect(client['Ada'].isNetworkReady, isTrue);
    expect(client['Bob'].isNetworkReady, isTrue);
  });
}
