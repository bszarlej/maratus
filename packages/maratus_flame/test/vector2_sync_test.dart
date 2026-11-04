import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maratus_flame/maratus_flame.dart';

const _ms = Duration(milliseconds: 1);

/// A component that its authority moves, and that other peers show
/// smoothly.
final class _Mover extends PositionComponent with NetworkedComponent {
  _Mover(this.networkEntity, this.field);

  @override
  final NetworkEntity networkEntity;
  final SyncField<Vector2> field;
  late MultiplayerSynchronizer synchronizer;

  @override
  void onNetworkAttach(EntityAttachment attachment) {
    synchronizer = attachment.synchronize([
      field.property(
        get: () => position,
        interpolator: const Vector2Interpolator(),
      ),
    ]);
  }

  @override
  void update(double dt) {
    if (synchronizer.interpolated(field) case final shown?) {
      position.setFrom(shown.value);
    }
  }
}

/// A host and a client that share static entity 1.
final class _Fixture {
  _Fixture() {
    final builder = ProtocolSchemaBuilder();
    field = builder.addField(const FieldId('position'), const Vector2Codec());
    final schema = builder.build();
    final network = InMemoryNetwork(clock: clock);
    host = MultiplayerSession(schema: schema, clock: clock)
      ..host(network.host());
    client = MultiplayerSession(schema: schema, clock: clock)
      ..join(network.connect());
    for (var i = 0; i < 8; i++) {
      clock.advance(Duration.zero);
      host.update();
      client.update();
    }
    expect(client.state, SessionState.ready);
    hostEntity = register(host);
    clientEntity = register(client);
    addTearDown(host.close);
    addTearDown(client.close);
  }

  final clock = ManualClock();
  late final SyncField<Vector2> field;
  late final MultiplayerSession host;
  late final MultiplayerSession client;
  late final NetworkEntity hostEntity;
  late final NetworkEntity clientEntity;

  NetworkEntity register(MultiplayerSession session) => session.registry
      .register(const EntityId(1), owner: PeerId.host, authority: PeerId.host);

  /// Mounts a scope for [session] and [child] inside it.
  Future<FlameGame> game(MultiplayerSession session, Component child) async {
    final game = await initializeFlameGame();
    addTearDown(game.dispose);
    final scope = MultiplayerScope(session: session);
    await game.add(scope);
    await scope.add(child);
    for (var i = 0; i < 2; i++) {
      game.update(0);
      await Future<void>.value();
    }
    expect(child.isMounted, isTrue);
    return game;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Vector2Codec', () {
    const codec = Vector2Codec(
      x: DoubleCodec(min: 0, max: 100),
      y: DoubleCodec(min: -10, max: 10),
    );

    test('round-trips vectors as pairs of coordinates', () {
      final wire = codec.encode(Vector2(12.5, -2.25));
      final decoded = codec.decode(wire);

      expect(wire, [12.5, -2.25]);
      expect(decoded, Vector2(12.5, -2.25));
      expect(codec.decode(wire), isNot(same(decoded)));
    });

    test('describes its coordinate codecs', () {
      expect(
        codec.descriptor,
        'flame.vector2@1(double(min=0,max=100),double(min=-10,max=10))',
      );
      expect(const Vector2Codec().descriptor, 'flame.vector2@1(double,double)');
    });

    test('rejects invalid vectors where they are invalid', () {
      for (final (wire, path) in <(Object?, List<String>)>[
        (null, []),
        ([1.0], []),
        ([1.0, 2.0, 3.0], []),
        (['1', 2.0], ['0']),
        ([1.0, 11.0], ['1']),
      ]) {
        expect(
          () => codec.decode(wire),
          throwsA(isA<ProtocolException>().having((e) => e.path, 'path', path)),
          reason: '$wire',
        );
      }
      expect(() => codec.encode(Vector2(101, 0)), throwsArgumentError);
    });
  });

  group('Vector2Interpolator', () {
    test('blends into a new vector without changing its inputs', () {
      final from = Vector2(0, 10);
      final to = Vector2(10, 30);

      final blended = const Vector2Interpolator().lerp(from, to, 0.25);

      expect(blended, Vector2(2.5, 15));
      expect(from, Vector2(0, 10));
      expect(to, Vector2(10, 30));
    });

    test('shows long moves as teleports', () {
      const interpolator = Vector2Interpolator(teleportDistance: 5);

      expect(interpolator.isTeleport(Vector2.zero(), Vector2(3, 4)), isTrue);
      expect(interpolator.isTeleport(Vector2.zero(), Vector2(3, 3.9)), isFalse);
      expect(
        const Vector2Interpolator().isTeleport(Vector2.zero(), Vector2(1e6, 0)),
        isFalse,
      );
    });
  });

  test('components present interpolated positions', () async {
    final fixture = _Fixture();
    final host = _Mover(fixture.hostEntity, fixture.field);
    final client = _Mover(fixture.clientEntity, fixture.field);
    final hostGame = await fixture.game(fixture.host, host);
    final clientGame = await fixture.game(fixture.client, client);

    void deliver() {
      fixture.clock.advance(Duration.zero);
      clientGame.update(0);
    }

    // The host sampled its position while mounting, at 0 ms.
    deliver();
    for (final x in [10.0, 20.0]) {
      fixture.clock.advance(_ms * 50);
      host.position.setValues(x, 0);
      hostGame.update(0);
      deliver();
    }
    expect(client.position, Vector2.zero());

    fixture.clock.advance(_ms * 25);
    clientGame.update(0);
    expect(client.position, Vector2(5, 0));
    fixture.clock.advance(_ms * 50);
    clientGame.update(0);
    expect(client.position, Vector2(15, 0));
    expect(client.synchronizer.snapshot(fixture.field)!.value, Vector2(20, 0));
    expect(host.position, Vector2(20, 0));
  });
}
