import 'dart:async';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maratus_flame/maratus_flame.dart';

const _entityId = EntityId(1);

final class _Harness {
  _Harness() {
    final builder = ProtocolSchemaBuilder();
    rpc = builder.addRpc(
      const RpcId('fixture.set'),
      const IntCodec(),
      target: RpcTarget.host,
      local: RpcLocal.include,
    );
    schema = builder.build();
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
    entity = register(host);
    clientEntity = register(client);
    client.registry.markReady(clientEntity.id);
    addTearDown(host.close);
    addTearDown(client.close);
  }

  final clock = ManualClock();
  late final InMemoryNetwork network;
  late final ProtocolSchema schema;
  late final Rpc<int> rpc;
  late final MultiplayerSession host;
  late final MultiplayerSession client;
  late final NetworkEntity entity;
  late final NetworkEntity clientEntity;

  NetworkEntity register(MultiplayerSession session) => session.registry
      .register(_entityId, owner: PeerId.host, authority: PeerId.host);

  void send(int value) {
    expect(client.callRpc(clientEntity, rpc, value), isTrue);
    clock.advance(Duration.zero);
  }
}

final class _Probe extends Component with NetworkedComponent {
  _Probe(this.networkEntity, this.rpc, {this.loadGate, this.trace});

  @override
  NetworkEntity networkEntity;

  Rpc<int> rpc;
  final Future<void>? loadGate;
  final List<String>? trace;
  final received = <int>[];
  final attachments = <EntityAttachment>[];
  void Function(int)? onReceive;
  var value = 0;
  var removals = 0;
  var captures = 0;

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    await loadGate;
  }

  @override
  void onNetworkAttach(EntityAttachment attachment) {
    attachments.add(attachment);
    attachment.bindRpc(rpc, (context, payload) {
      received.add(payload);
      value = payload;
      trace?.add('rpc:$payload');
      onReceive?.call(payload);
    });
  }

  @override
  void update(double dt) {
    trace?.add('update:$value');
  }

  @override
  void captureNetworkState(double dt) {
    captures++;
    trace?.add('capture:$value');
  }

  @override
  void onRemove() {
    removals++;
    super.onRemove();
  }
}

final class _LoadingParent extends Component {
  _LoadingParent(this.child, this.gate);

  final Component child;
  final Future<void> gate;

  @override
  Future<void> onLoad() async {
    await add(child);
    await gate;
  }
}

final class _GameplayComponent extends Component {
  _GameplayComponent(this.callback);

  final void Function() callback;

  @override
  void update(double dt) => callback();
}

final class _LoadingScope extends MultiplayerScope {
  _LoadingScope({required super.session, required this.gate});

  final Future<void> gate;

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    await gate;
  }
}

Future<FlameGame> _game() async {
  final game = await initializeFlameGame();
  addTearDown(game.dispose);
  return game;
}

Future<void> _mount(
  FlameGame game,
  Component parent,
  Component component,
) async {
  await parent.add(component);
  game.update(0);
  await Future<void>.value();
  game.update(0);
  expect(component.isMounted, isTrue);
}

void main() {
  for (final ownsSession in [true, false]) {
    testWidgets('GameWidget removal disposes its scope (owned: $ownsSession)', (
      tester,
    ) async {
      final harness = _Harness();
      final component = _Probe(harness.entity, harness.rpc);
      final scope = MultiplayerScope(
        session: harness.host,
        ownsSession: ownsSession,
        children: [component],
      );
      final game = FlameGame(children: [scope]);
      addTearDown(game.dispose);
      await tester.pumpWidget(GameWidget(game: game));
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(component.isNetworkReady, isTrue);
      game.pauseEngine();
      expect(harness.host.callRpc(harness.entity, harness.rpc, 1), isTrue);

      await tester.pumpWidget(const SizedBox());
      expect(scope.isDisposed, isTrue);
      expect(component.received, isEmpty);
      expect(component.attachments.single.isDisposed, isTrue);
      expect(harness.host.pendingRpcCount, 0);
      expect(
        harness.host.state,
        ownsSession ? SessionState.disconnected : SessionState.hosting,
      );
    });
  }

  test('one live scope owns the update boundary even before mounting', () {
    final harness = _Harness();
    final scope = MultiplayerScope(session: harness.host, ownsSession: false);
    expect(() => MultiplayerScope(session: harness.host), throwsStateError);
    scope.dispose();
    final replacement = MultiplayerScope(
      session: harness.host,
      ownsSession: false,
    );
    expect(replacement.isDisposed, isFalse);
    expect(harness.host.state, SessionState.hosting);
    replacement.dispose();
  });

  test('disposal before mounting closes an owned session', () {
    final harness = _Harness();
    final scope = MultiplayerScope(session: harness.host);
    scope.dispose();
    scope.dispose();
    expect(scope.isDisposed, isTrue);
    expect(harness.host.state, SessionState.disconnected);
  });

  test('game removal also disposes a scope that is still loading', () async {
    final harness = _Harness();
    final game = await _game();
    final gate = Completer<void>();
    final scope = _LoadingScope(session: harness.host, gate: gate.future);
    final loading = game.add(scope);
    expect(scope.isMounted, isFalse);
    // This is the lifecycle boundary invoked by GameWidget disposal.
    // ignore: invalid_use_of_internal_member
    game.finalizeRemoval();
    await Future<void>.value();

    expect(scope.isDisposed, isTrue);
    expect(harness.host.state, SessionState.disconnected);
    scope.removeFromParent();
    gate.complete();
    await loading;
  });

  test(
    'exposes the nearest scope and entity identity after mounting',
    () async {
      final harness = _Harness();
      final game = await _game();
      final scope = MultiplayerScope(session: harness.host);
      final component = _Probe(harness.entity, harness.rpc);
      expect(component.isNetworkReady, isFalse);
      expect(() => component.multiplayerSession, throwsStateError);
      await _mount(game, game, scope);
      await _mount(game, scope, component);

      expect(component.multiplayerScope, same(scope));
      expect(component.multiplayerSession, same(harness.host));
      expect(component.networkEntity, same(harness.entity));
      expect(component.isNetworkReady, isTrue);
      expect(harness.entity.state, EntityState.ready);
      expect(component.attachments, hasLength(1));
    },
  );

  test('applies queued RPCs before gameplay and captures afterward', () async {
    final harness = _Harness();
    final game = await _game();
    final trace = <String>[];
    final component = _Probe(harness.entity, harness.rpc, trace: trace);
    final scope = MultiplayerScope(session: harness.host);
    await _mount(game, game, scope);
    await _mount(game, scope, component);
    trace.clear();

    harness.send(7);
    expect(trace, isEmpty);
    expect(component.value, 0);
    game.update(0.25);

    expect(trace, ['rpc:7', 'update:7', 'capture:7']);
    expect(harness.host.pendingRpcCount, 0);
  });

  test('local RPCs also wait for the scope update boundary', () async {
    final harness = _Harness();
    final game = await _game();
    final component = _Probe(harness.entity, harness.rpc);
    final scope = MultiplayerScope(session: harness.host);
    await _mount(game, game, scope);
    await _mount(game, scope, component);

    expect(harness.host.callRpc(harness.entity, harness.rpc, 11), isTrue);
    expect(component.received, isEmpty);
    expect(harness.host.pendingRpcCount, 1);
    game.update(0);
    expect(component.received, [11]);
  });

  test('capture observes gameplay changes made by later siblings', () async {
    final harness = _Harness();
    final game = await _game();
    final trace = <String>[];
    final scope = MultiplayerScope(session: harness.host);
    final component = _Probe(harness.entity, harness.rpc, trace: trace);
    await _mount(game, game, scope);
    await _mount(game, scope, component);
    await _mount(
      game,
      scope,
      _GameplayComponent(() {
        component.value++;
        trace.add('sibling:${component.value}');
      }),
    );
    trace.clear();
    harness.send(7);
    game.update(0);
    expect(trace, ['rpc:7', 'update:7', 'sibling:8', 'capture:8']);
  });

  test(
    'a child can load before its ancestor mounts without deadlocking',
    () async {
      final harness = _Harness();
      final game = await _game();
      final scope = MultiplayerScope(session: harness.host);
      await _mount(game, game, scope);
      final gate = Completer<void>();
      final component = _Probe(harness.entity, harness.rpc);
      final parent = _LoadingParent(component, gate.future);
      final loading = scope.add(parent);
      await component.loaded;
      game.update(0);
      expect(component.isLoaded, isTrue);
      expect(component.isMounted, isFalse);
      expect(parent.isMounted, isFalse);
      harness.send(3);
      game.update(0);
      expect(component.received, isEmpty);
      expect(harness.host.pendingRpcCount, 1);

      gate.complete();
      await loading;
      game.update(0);
      expect(parent.isMounted, isTrue);
      expect(component.isMounted, isTrue);
      expect(component.received, [3]);
      expect(component.attachments, hasLength(1));
    },
  );

  test('stages RPCs while loading and delivers once after mounting', () async {
    final harness = _Harness();
    final game = await _game();
    final scope = MultiplayerScope(session: harness.host);
    await _mount(game, game, scope);
    final gate = Completer<void>();
    final component = _Probe(
      harness.entity,
      harness.rpc,
      loadGate: gate.future,
    );
    final loading = scope.add(component);
    game.update(0);
    expect(component.isMounted, isFalse);
    expect(component.attachments, hasLength(1));

    harness.send(3);
    game.update(0);
    expect(component.received, isEmpty);
    expect(harness.host.pendingRpcCount, 1);
    expect(component.isNetworkReady, isFalse);

    gate.complete();
    await loading;
    game.update(0);
    expect(component.isMounted, isTrue);
    expect(component.received, [3]);
    expect(component.attachments, hasLength(1));
    game.update(0);
    expect(component.received, [3]);
  });

  test(
    'cancels a removed loading component without an onRemove call',
    () async {
      final harness = _Harness();
      final game = await _game();
      final scope = MultiplayerScope(session: harness.host);
      await _mount(game, game, scope);
      final gate = Completer<void>();
      final component = _Probe(
        harness.entity,
        harness.rpc,
        loadGate: gate.future,
      );
      final loading = scope.add(component);
      harness.send(4);
      game.update(0);
      expect(harness.host.pendingRpcCount, 1);

      component.removeFromParent();
      game.update(0);
      expect(component.removals, 0);
      expect(component.attachments.single.isDisposed, isTrue);
      expect(harness.host.pendingRpcCount, 0);
      expect(harness.host.pendingRpcBytes, 0);
      gate.complete();
      await loading;
      game.update(0);
      expect(component.isMounted, isFalse);
      expect(component.received, isEmpty);
      expect(harness.entity.state, EntityState.pending);

      await _mount(game, scope, component);
      harness.send(5);
      game.update(0);
      expect(component.received, [5]);
      expect(component.attachments, hasLength(2));
    },
  );

  test(
    'a component loading when its scope is disposed mounts detached',
    () async {
      final harness = _Harness();
      final game = await _game();
      final scope = MultiplayerScope(session: harness.host, ownsSession: false);
      await _mount(game, game, scope);
      final gate = Completer<void>();
      final component = _Probe(
        harness.entity,
        harness.rpc,
        loadGate: gate.future,
      );
      final loading = scope.add(component);
      expect(component.attachments, hasLength(1));

      scope.dispose();
      gate.complete();
      await loading;
      game.update(0);

      expect(component.isMounted, isTrue);
      expect(component.isNetworkReady, isFalse);
      expect(component.attachments.single.isDisposed, isTrue);
      expect(harness.host.state, SessionState.hosting);
    },
  );

  test('local removal preserves identity and remount binds once', () async {
    final harness = _Harness();
    final game = await _game();
    final scope = MultiplayerScope(session: harness.host);
    final component = _Probe(harness.entity, harness.rpc);
    await _mount(game, game, scope);
    await _mount(game, scope, component);
    expect(harness.host.callRpc(harness.entity, harness.rpc, 1), isTrue);

    component.removeFromParent();
    game.update(0);
    expect(component.received, isEmpty);
    expect(component.attachments.single.isDisposed, isTrue);
    expect(harness.entity.state, EntityState.ready);
    expect(harness.host.registry[_entityId], same(harness.entity));
    expect(harness.host.pendingRpcCount, 0);

    await _mount(game, scope, component);
    harness.send(2);
    game.update(0);
    expect(component.received, [2]);
    expect(component.attachments, hasLength(2));
    expect(component.removals, 1);
  });

  for (final removal in ['component', 'scope', 'all', 'custom']) {
    test(
      'loading cancellation through $removal survives same-frame reuse',
      () async {
        final harness = _Harness();
        final game = await _game();
        final scope = MultiplayerScope(session: harness.host);
        await _mount(game, game, scope);
        final Component parent;
        if (removal == 'custom') {
          parent = Component();
          await _mount(game, scope, parent);
        } else {
          parent = scope;
        }
        final gate = Completer<void>();
        final component = _Probe(
          harness.entity,
          harness.rpc,
          loadGate: gate.future,
        );
        final loading = parent.add(component);
        expect(harness.host.callRpc(harness.entity, harness.rpc, 1), isTrue);
        switch (removal) {
          case 'component':
            component.removeFromParent();
          case 'scope':
            scope.remove(component);
          case 'all':
            scope.removeAll([component]);
          case 'custom':
            component.detachNetwork();
            parent.remove(component);
        }
        expect(harness.host.pendingRpcCount, 0);
        gate.complete();
        await loading;
        await parent.add(component);
        game.update(0);

        expect(component.isMounted, isTrue);
        expect(component.received, isEmpty);
        expect(component.attachments, hasLength(2));
        expect(harness.host.callRpc(harness.entity, harness.rpc, 2), isTrue);
        game.update(0);
        expect(component.received, [2]);
      },
    );
  }

  test(
    'custom subtree cancellation discards descendant calls before reuse',
    () async {
      final harness = _Harness();
      final game = await _game();
      final scope = MultiplayerScope(session: harness.host);
      final customParent = Component();
      await _mount(game, game, scope);
      await _mount(game, scope, customParent);
      final gate = Completer<void>();
      final component = _Probe(harness.entity, harness.rpc);
      final subtree = _LoadingParent(component, gate.future);
      final loading = customParent.add(subtree);
      await component.loaded;
      expect(harness.host.callRpc(harness.entity, harness.rpc, 1), isTrue);

      scope.detachSubtree(subtree);
      customParent.remove(subtree);
      expect(harness.host.pendingRpcCount, 0);
      gate.complete();
      await loading;
      await customParent.add(subtree);
      game.update(0);
      expect(component.isMounted, isTrue);
      expect(component.received, isEmpty);
      expect(component.attachments, hasLength(2));
      expect(harness.host.callRpc(harness.entity, harness.rpc, 2), isTrue);
      game.update(0);
      expect(component.received, [2]);
    },
  );

  test(
    'scope removeWhere discards selected components calls immediately',
    () async {
      final harness = _Harness();
      final game = await _game();
      final scope = MultiplayerScope(session: harness.host);
      final component = _Probe(harness.entity, harness.rpc);
      await _mount(game, game, scope);
      await _mount(game, scope, component);
      expect(harness.host.callRpc(harness.entity, harness.rpc, 1), isTrue);
      scope.removeWhere((child) => identical(child, component));
      expect(harness.host.pendingRpcCount, 0);
      game.update(0);
      expect(component.received, isEmpty);
      expect(component.isNetworkReady, isFalse);
    },
  );

  test('a replacement instance never receives its predecessor calls', () async {
    final harness = _Harness();
    final game = await _game();
    final scope = MultiplayerScope(session: harness.host);
    final first = _Probe(harness.entity, harness.rpc);
    await _mount(game, game, scope);
    await _mount(game, scope, first);
    expect(harness.host.callRpc(harness.entity, harness.rpc, 1), isTrue);
    first.removeFromParent();
    game.update(0);

    final replacement = _Probe(harness.entity, harness.rpc);
    await _mount(game, scope, replacement);
    harness.send(2);
    game.update(0);
    expect(first.received, isEmpty);
    expect(replacement.received, [2]);
    expect(replacement.attachments, hasLength(1));
  });

  test(
    'reparenting within a scope recreates bindings without despawn',
    () async {
      final harness = _Harness();
      final game = await _game();
      final scope = MultiplayerScope(session: harness.host);
      final firstParent = Component();
      final nextParent = Component();
      final component = _Probe(harness.entity, harness.rpc);
      await _mount(game, game, scope);
      await _mount(game, scope, firstParent);
      await _mount(game, scope, nextParent);
      await _mount(game, firstParent, component);
      expect(harness.host.callRpc(harness.entity, harness.rpc, 1), isTrue);

      component.parent = nextParent;
      game.update(0);
      expect(component.parent, same(nextParent));
      expect(component.received, isEmpty);
      expect(component.attachments, hasLength(2));
      expect(harness.entity.state, EntityState.ready);
      harness.send(2);
      game.update(0);
      expect(component.received, [2]);
    },
  );

  test('ancestor removal in one handler blocks the next queued call', () async {
    final harness = _Harness();
    final game = await _game();
    final scope = MultiplayerScope(session: harness.host);
    final parent = Component();
    final component = _Probe(harness.entity, harness.rpc);
    await _mount(game, game, scope);
    await _mount(game, scope, parent);
    await _mount(game, parent, component);
    component.onReceive = (_) => parent.removeFromParent();
    harness.send(1);
    harness.send(2);
    game.update(0);

    expect(component.received, [1]);
    expect(component.isNetworkReady, isFalse);
    expect(harness.host.pendingRpcCount, 0);
    game.update(0);
    expect(component.received, [1]);
    expect(component.isMounted, isFalse);
  });

  test(
    'nested scopes keep their sessions and capture passes separate',
    () async {
      final first = _Harness();
      final second = _Harness();
      final game = await _game();
      final outer = MultiplayerScope(session: first.host);
      final inner = MultiplayerScope(session: second.host);
      final outerComponent = _Probe(first.entity, first.rpc);
      final innerComponent = _Probe(second.entity, second.rpc);
      await _mount(game, game, outer);
      await _mount(game, outer, outerComponent);
      await _mount(game, outer, inner);
      await _mount(game, inner, innerComponent);
      final outerCaptures = outerComponent.captures;
      final innerCaptures = innerComponent.captures;

      first.send(1);
      second.send(2);
      game.update(0);
      expect(outerComponent.received, [1]);
      expect(innerComponent.received, [2]);
      expect(innerComponent.multiplayerScope, same(inner));
      expect(innerComponent.multiplayerSession, same(second.host));
      expect(outerComponent.captures, outerCaptures + 1);
      expect(innerComponent.captures, innerCaptures + 1);
    },
  );

  test('different games never dispatch into one another', () async {
    final first = _Harness();
    final second = _Harness();
    final firstGame = await _game();
    final secondGame = await _game();
    final firstScope = MultiplayerScope(session: first.host);
    final secondScope = MultiplayerScope(session: second.host);
    final firstComponent = _Probe(first.entity, first.rpc);
    final secondComponent = _Probe(second.entity, second.rpc);
    await _mount(firstGame, firstGame, firstScope);
    await _mount(secondGame, secondGame, secondScope);
    await _mount(firstGame, firstScope, firstComponent);
    await _mount(secondGame, secondScope, secondComponent);

    first.send(1);
    second.send(2);
    firstGame.update(0);
    expect(firstComponent.received, [1]);
    expect(secondComponent.received, isEmpty);
    secondGame.update(0);
    expect(secondComponent.received, [2]);
  });

  test(
    'a removed component can be reused with another session identity',
    () async {
      final first = _Harness();
      final second = _Harness();
      final game = await _game();
      final firstScope = MultiplayerScope(session: first.host);
      final secondScope = MultiplayerScope(session: second.host);
      final component = _Probe(first.entity, first.rpc);
      await _mount(game, game, firstScope);
      await _mount(game, game, secondScope);
      await _mount(game, firstScope, component);
      expect(first.host.callRpc(first.entity, first.rpc, 1), isTrue);
      component.removeFromParent();
      game.update(0);

      component
        ..networkEntity = second.entity
        ..rpc = second.rpc;
      await _mount(game, secondScope, component);
      second.send(2);
      game.update(0);
      expect(component.received, [2]);
      expect(component.attachments, hasLength(2));
      expect(component.multiplayerSession, same(second.host));
      expect(first.entity.state, EntityState.ready);
    },
  );

  test(
    'repeated game disposal releases session and transport resources',
    () async {
      for (var cycle = 0; cycle < 3; cycle++) {
        final harness = _Harness();
        final game = await _game();
        final scope = MultiplayerScope(session: harness.host);
        final component = _Probe(harness.entity, harness.rpc);
        await _mount(game, game, scope);
        await _mount(game, scope, component);
        expect(
          harness.host.callRpc(harness.entity, harness.rpc, cycle),
          isTrue,
        );
        game.dispose();
        harness.clock.advance(Duration.zero);
        harness.client.update();

        expect(component.received, isEmpty);
        expect(component.attachments.single.isDisposed, isTrue);
        expect(scope.isDisposed, isTrue);
        expect(harness.host.pendingRpcCount, 0);
        expect(harness.host.state, SessionState.disconnected);
        expect(harness.client.state, SessionState.disconnected);
        expect(harness.clock.pendingTimerCount, 0);
        expect(harness.network.links, isEmpty);
      }
    },
  );

  test(
    'session restart invalidates old entities and pending invocations',
    () async {
      final harness = _Harness();
      final game = await _game();
      final scope = MultiplayerScope(session: harness.host, ownsSession: false);
      final component = _Probe(harness.entity, harness.rpc);
      await _mount(game, game, scope);
      await _mount(game, scope, component);
      expect(harness.host.callRpc(harness.entity, harness.rpc, 1), isTrue);
      harness.host.close();
      harness.host.host(harness.network.host());
      final freshEntity = harness.register(harness.host);
      game.update(0);

      expect(component.received, isEmpty);
      expect(component.isNetworkReady, isFalse);
      expect(component.attachments.single.isDisposed, isTrue);
      expect(harness.host.pendingRpcCount, 0);
      component.removeFromParent();
      game.update(0);
      component.networkEntity = freshEntity;
      await _mount(game, scope, component);
      expect(harness.host.callRpc(freshEntity, harness.rpc, 2), isTrue);
      game.update(0);
      expect(component.received, [2]);
    },
  );

  test(
    'owned scope disposal closes the session and releases pending work',
    () async {
      final harness = _Harness();
      final game = await _game();
      final scope = MultiplayerScope(session: harness.host);
      final component = _Probe(harness.entity, harness.rpc);
      await _mount(game, game, scope);
      await _mount(game, scope, component);
      expect(harness.host.callRpc(harness.entity, harness.rpc, 1), isTrue);

      scope.dispose();
      scope.dispose();
      game.update(0);
      expect(harness.host.state, SessionState.disconnected);
      expect(harness.host.pendingRpcCount, 0);
      expect(component.received, isEmpty);
      expect(component.isNetworkReady, isFalse);
      harness.clock.advance(Duration.zero);
      harness.client.update();
      expect(harness.client.state, SessionState.disconnected);
      expect(harness.network.links, isEmpty);
      expect(harness.clock.pendingTimerCount, 0);
    },
  );

  test('unowned scope removal detaches while preserving its session', () async {
    final harness = _Harness();
    final game = await _game();
    final scope = MultiplayerScope(session: harness.host, ownsSession: false);
    final component = _Probe(harness.entity, harness.rpc);
    await _mount(game, game, scope);
    await _mount(game, scope, component);
    expect(harness.host.callRpc(harness.entity, harness.rpc, 1), isTrue);

    scope.removeFromParent();
    game.update(0);
    expect(harness.host.state, SessionState.hosting);
    expect(component.attachments.single.isDisposed, isTrue);
    expect(harness.entity.state, EntityState.ready);
    expect(harness.host.pendingRpcCount, 0);

    final replacement = MultiplayerScope(
      session: harness.host,
      ownsSession: false,
    );
    await _mount(game, game, replacement);
    final freshComponent = _Probe(harness.entity, harness.rpc);
    await _mount(game, replacement, freshComponent);
    harness.send(2);
    game.update(0);
    expect(component.received, isEmpty);
    expect(freshComponent.received, [2]);
  });

  test('pausing leaves ready peers connected and defers gameplay', () async {
    final harness = _Harness();
    final game = await _game();
    final scope = MultiplayerScope(session: harness.host);
    final component = _Probe(harness.entity, harness.rpc);
    await _mount(game, game, scope);
    await _mount(game, scope, component);
    final captures = component.captures;
    game.pauseEngine();
    harness.send(9);
    harness.clock.advance(const Duration(minutes: 1));
    harness.client.update();

    expect(component.received, isEmpty);
    expect(component.captures, captures);
    expect(harness.client.state, SessionState.ready);
    game.resumeEngine();
    game.update(0);
    expect(component.received, [9]);
    expect(component.captures, captures + 1);
  });

  test('a joining client times out while the host game is paused', () async {
    final harness = _Harness();
    final game = await _game();
    final scope = MultiplayerScope(session: harness.host);
    await _mount(game, game, scope);
    game.pauseEngine();
    final joining = MultiplayerSession(
      schema: harness.schema,
      clock: harness.clock,
    )..join(harness.network.connect());
    addTearDown(joining.close);
    harness.clock.advance(Duration.zero);
    joining.update();
    harness.clock.advance(const Duration(seconds: 11));
    joining.update();

    expect(joining.state, SessionState.disconnected);
    expect(joining.disconnectReason, DisconnectReason.timeout);
    expect(harness.host.state, SessionState.hosting);
  });
}
