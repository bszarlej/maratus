import 'dart:async';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maratus_flame/maratus_flame.dart';

final class _VectorCodec extends ValueCodec<Vector2> {
  const _VectorCodec();

  static const _coordinate = DoubleCodec();

  @override
  String get descriptor => 'test.vector2@1';

  @override
  Object? encode(Vector2 value) => {
    'x': _coordinate.encode(value.x),
    'y': _coordinate.encode(value.y),
  };

  @override
  Vector2 decode(Object? wire) {
    final object = WireObject(wire, const {'x', 'y'});
    return Vector2(
      object.read('x', _coordinate),
      object.read('y', _coordinate),
    );
  }
}

final class _Probe extends PositionComponent with NetworkedComponent {
  _Probe(this.networkEntity, this.field, {this.loadGate});

  @override
  final NetworkEntity networkEntity;
  final SyncField<Vector2> field;
  final Future<void>? loadGate;
  final attached = Completer<void>();
  final synchronizers = <MultiplayerSynchronizer>[];
  void Function()? onUpdate;
  void Function()? onCapture;
  var samples = 0;
  var applications = 0;

  MultiplayerSynchronizer get synchronizer => synchronizers.last;

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    await loadGate;
  }

  @override
  void onNetworkAttach(EntityAttachment attachment) {
    synchronizers.add(
      attachment.synchronize([
        field.property(
          get: () {
            samples++;
            return position;
          },
          set: (value) {
            applications++;
            position.setFrom(value);
          },
        ),
      ]),
    );
    if (!attached.isCompleted) attached.complete();
  }

  @override
  void update(double dt) => onUpdate?.call();

  @override
  void captureNetworkState(double dt) => onCapture?.call();
}

final class _Fixture {
  _Fixture() {
    final builder = ProtocolSchemaBuilder();
    field = builder.addField(const FieldId('position'), const _VectorCodec());
    final schema = builder.build();
    network = InMemoryNetwork(clock: clock);
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
  late final InMemoryNetwork network;
  late final SyncField<Vector2> field;
  late final MultiplayerSession host;
  late final MultiplayerSession client;
  late final NetworkEntity hostEntity;
  late final NetworkEntity clientEntity;

  NetworkEntity register(MultiplayerSession session) => session.registry
      .register(const EntityId(1), owner: PeerId.host, authority: PeerId.host);

  Future<FlameGame> game(MultiplayerSession session) async {
    final game = await initializeFlameGame();
    addTearDown(game.dispose);
    await mount(game, game, MultiplayerScope(session: session));
    return game;
  }

  MultiplayerScope scope(FlameGame game) =>
      game.children.whereType<MultiplayerScope>().single;

  Future<void> mount(FlameGame game, Component parent, Component child) async {
    await parent.add(child);
    game.update(0);
    await Future<void>.value();
    game.update(0);
    expect(child.isMounted, isTrue);
  }

  void deliver(FlameGame clientGame) {
    clock.advance(Duration.zero);
    clientGame.update(0);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scope captures gameplay and hooks before remote gameplay', () async {
    final fixture = _Fixture();
    final hostGame = await fixture.game(fixture.host);
    final clientGame = await fixture.game(fixture.client);
    final host = _Probe(fixture.hostEntity, fixture.field);
    final client = _Probe(fixture.clientEntity, fixture.field);
    await fixture.mount(hostGame, fixture.scope(hostGame), host);
    await fixture.mount(clientGame, fixture.scope(clientGame), client);
    fixture.deliver(clientGame);
    final before = host.samples;
    host.onUpdate = () => host.position.x = 10;
    host.onCapture = () => host.position.y = 20;
    Vector2? receivedBeforeGameplay;
    client.onUpdate = () {
      receivedBeforeGameplay = client.position.clone();
    };

    fixture.clock.advance(const Duration(milliseconds: 50));
    hostGame.update(1 / 60);
    fixture.deliver(clientGame);

    expect(receivedBeforeGameplay, Vector2(10, 20));
    expect(host.samples, before + 1);
    expect(client.samples, 0);
    final snapshot = client.synchronizer.snapshot(fixture.field)!;
    expect(snapshot.value, Vector2(10, 20));
    host.position.setValues(30, 40);
    client.position.setValues(500, 600);
    expect(snapshot.value, Vector2(10, 20));
    expect(host.synchronizer.snapshot(fixture.field)!.value, Vector2(10, 20));
    snapshot.value.setZero();
    expect(client.synchronizer.snapshot(fixture.field)!.value, Vector2(10, 20));

    // Extra render frames neither resample before the clock deadline nor echo
    // a client's local display changes back to the authority.
    host.onUpdate = null;
    host.onCapture = null;
    for (var i = 0; i < 5; i++) {
      clientGame.update(1 / 120);
      fixture.clock.advance(Duration.zero);
      hostGame.update(1 / 120);
    }
    expect(host.samples, before + 1);
    expect(host.position, Vector2(30, 40));
    expect(client.samples, 0);
  });

  test('loading components apply the latest state after mounting', () async {
    final fixture = _Fixture();
    final hostGame = await fixture.game(fixture.host);
    final clientGame = await fixture.game(fixture.client);
    final host = _Probe(fixture.hostEntity, fixture.field);
    await fixture.mount(hostGame, fixture.scope(hostGame), host);
    final gate = Completer<void>();
    final client = _Probe(
      fixture.clientEntity,
      fixture.field,
      loadGate: gate.future,
    );
    final loading = fixture.scope(clientGame).add(client);
    await client.attached.future;

    host.position.setValues(7, 8);
    fixture.clock.advance(const Duration(milliseconds: 50));
    hostGame.update(0);
    fixture.deliver(clientGame);
    expect(client.isMounted, isFalse);
    expect(client.applications, 0);
    expect(client.position, Vector2.zero());
    expect(client.synchronizer.snapshot(fixture.field)!.value, Vector2(7, 8));

    gate.complete();
    await loading;
    clientGame.update(0);
    clientGame.update(0);
    expect(client.isNetworkReady, isTrue);
    expect(client.position, Vector2(7, 8));
    expect(client.applications, 1);
  });

  test(
    'remount disposes old synchronizers and applies retained state',
    () async {
      final fixture = _Fixture();
      final hostGame = await fixture.game(fixture.host);
      final clientGame = await fixture.game(fixture.client);
      final host = _Probe(fixture.hostEntity, fixture.field);
      final client = _Probe(fixture.clientEntity, fixture.field);
      await fixture.mount(hostGame, fixture.scope(hostGame), host);
      await fixture.mount(clientGame, fixture.scope(clientGame), client);
      fixture.deliver(clientGame);
      final previous = client.synchronizer;
      final applications = client.applications;

      client.removeFromParent();
      clientGame.update(0);
      host.position.setValues(21, 22);
      fixture.clock.advance(const Duration(milliseconds: 50));
      hostGame.update(0);
      fixture.deliver(clientGame);
      expect(previous.isDisposed, isTrue);
      expect(client.applications, applications);

      await fixture.mount(clientGame, fixture.scope(clientGame), client);
      expect(client.synchronizer, isNot(same(previous)));
      expect(client.position, Vector2(21, 22));
      expect(client.applications, applications + 1);
      expect(fixture.clientEntity.state, EntityState.ready);
    },
  );

  test('removal during gameplay stops that frame capture', () async {
    final fixture = _Fixture();
    final game = await fixture.game(fixture.host);
    final probe = _Probe(fixture.hostEntity, fixture.field);
    await fixture.mount(game, fixture.scope(game), probe);
    final samples = probe.samples;
    probe.onUpdate = probe.removeFromParent;

    fixture.clock.advance(const Duration(milliseconds: 50));
    game.update(0);
    expect(probe.samples, samples);
    expect(probe.synchronizer.isDisposed, isTrue);
  });

  test('scope disposal in a capture hook stops sampling', () async {
    final fixture = _Fixture();
    final game = await fixture.game(fixture.host);
    final scope = fixture.scope(game);
    final probe = _Probe(fixture.hostEntity, fixture.field);
    await fixture.mount(game, scope, probe);
    final samples = probe.samples;
    probe.onCapture = scope.dispose;

    fixture.clock.advance(const Duration(milliseconds: 50));
    game.update(0);
    expect(probe.samples, samples);
    expect(probe.synchronizer.isDisposed, isTrue);
    expect(scope.isDisposed, isTrue);
  });
}
