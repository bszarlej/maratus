<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg">
    <img src="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg" alt="Maratus logo" width="300">
  </picture>
</p>

<p align="center">
  <a title="Pub" href="https://pub.dev/packages/maratus_flame" ><img alt="pub version" src="https://img.shields.io/pub/v/maratus_flame.svg"></a>
</p>

# maratus_flame

Flame bindings for [`maratus`](https://pub.dev/packages/maratus). This package connects
network entities, RPC handlers, and synchronized properties to the component
tree. It re-exports the core API.

## Installation

Requires Dart `>=3.11.0 <4.0.0`, Flutter `>=3.41.0`, and Flame `^1.38.2`.

```sh
flutter pub add maratus_flame
```

## Add multiplayer to a game

Create a host or client transport as described in the core
[session lifecycle guide](https://pub.dev/packages/maratus#session-lifecycle), then pass it
to the function below with an existing `FlameGame`. Every peer must register
the same spawn types, fields, and RPC definitions.

The host spawns a player with 100 health. Each peer's spawner creates its local
component, and the component binds its health property when it attaches to the
scope. Rendering and gameplay are left to your game.

```dart
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:maratus_flame/maratus_flame.dart';

Future<MultiplayerScope> addMultiplayer(
  FlameGame game,
  MultiplayerPeer transport, {
  required bool isHost,
}) async {
  final builder = ProtocolSchemaBuilder();
  final playerType = builder.addSpawnType(
    const SpawnTypeId('game.player'),
    const IntCodec(min: 0, max: 100),
  );
  final healthField = builder.addField(
    const FieldId('game.player.health'),
    const IntCodec(min: 0, max: 100),
  );
  final session = MultiplayerSession(schema: builder.build());
  if (isHost) {
    session.host(transport);
  } else {
    session.join(transport);
  }

  final spawner = MultiplayerSpawner()
    ..register(
      playerType,
      (context) => Player(context.entity, healthField, context.data),
    );
  final scope = MultiplayerScope(session: session, children: [spawner]);
  await game.add(scope);
  if (isHost) session.spawn(playerType, 100);
  return scope;
}

class Player extends PositionComponent with NetworkedComponent {
  Player(this.networkEntity, this.healthField, this.health);

  @override
  final NetworkEntity networkEntity;
  final SyncField<int> healthField;
  int health;

  @override
  void onNetworkAttach(EntityAttachment attachment) {
    attachment.synchronize([
      healthField.property(
        get: () => health,
        set: (value) => health = value,
      ),
    ]);
  }
}
```

By default, the host is the entity's authority and publishes its health changes.
Only run authoritative gameplay where
`networkEntity.authority == multiplayerSession.localPeer`. Ownership is
separate: assigning a client as `owner` allows owner-restricted RPCs and lets it
write fields registered with `writer: FieldWriter.owner`, such as its input, but
does not transfer authority over the other synchronized state.

Call `session.spawn` and `session.despawn` on the host to create and remove
replicated entities. A spawner creates components for existing entities too,
including those received while joining. Removing a component locally does not
despawn its entity.

## Component lifecycle

- Use one `MultiplayerScope` per session. It applies incoming network events
  before its children's gameplay updates, calls their `captureNetworkState`
  hooks, then captures outgoing state. Do not also call `session.update()` or
  `session.captureState()` elsewhere.
- Bind RPC handlers and properties in `onNetworkAttach`. Bindings are disposed
  on removal and recreated on remount. Check `isNetworkReady` before using the
  component's session in gameplay code.
- If you override `onLoad`, call `super.onLoad()` before asynchronous work. Call
  super in `onMount` and `onRemove` overrides too. The bindings wait for component
  readiness before dispatching RPCs.
- Removing the scope or its game disposes the scope and closes its session by
  default. Set `ownsSession: false` when another object manages the session.
  Call `scope.dispose()` explicitly if you abandon it before mounting; create
  a new scope for the next game lifecycle.

For a static component, declare a static entity in the shared schema and obtain
it through `session.staticEntity(...)` after calling `host` or `join`. Add the
component beneath the scope and bind it in the same way as a spawned component.

## Transports and delivery

The bindings accept any `MultiplayerPeer`. Use the core WebSocket transport,
[`maratus_enet`](https://pub.dev/packages/maratus_enet), or
[`maratus_webrtc`](https://pub.dev/packages/maratus_webrtc) according to your platform and
delivery requirements. See the core [delivery guide](https://pub.dev/packages/maratus#delivery)
for reliable and unreliable modes and transport requirements.

## Examples

- [Host/client game](example/main.dart): replicated avatars, owner-only input
  RPCs, and position smoothing with `Vector2Codec` and `Vector2Interpolator`.
  It runs two sessions over an in-memory network in one game.
- [WebSocket chat](https://github.com/bszarlej/maratus/tree/master/examples/chat): a runnable desktop and browser
  app with replicated avatars, network simulation, and diagnostics.
- [Code generation](https://pub.dev/packages/maratus_generator): generate schema handles,
  component bindings, and typed RPC senders from annotations.

Report bugs through the [issue tracker](https://github.com/bszarlej/maratus/issues).

## License

MIT. See [LICENSE](LICENSE).
