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
Only run authoritative gameplay where `isNetworkAuthority` is true; the host can
transfer the authority to another peer. Ownership, which `isNetworkOwner`
reports, is separate: assigning a client as `owner` allows owner-restricted RPCs
and lets it write fields registered with `writer: FieldWriter.owner`, such as its
input, but does not transfer authority over the other synchronized state. The
host can move the ownership later with `session.transferOwnership`, optionally
with the authority, so check `isNetworkOwner` where it matters each frame;
`ProximityVisibility` and `componentsOwnedBy` follow the current owner.

To smooth a position that arrives a few times a second, give its property a
`Vector2Interpolator`. On the peers that do not write the position, the scope
then passes positions blended between the received samples to the setter,
before each frame's gameplay:

```dart
positionField.property(
  get: () => position,
  set: (value) => position.setFrom(value),
  interpolator: const Vector2Interpolator(teleportDistance: 200),
),
```

Call `session.spawn` and `session.despawn` on the host to create and remove
replicated entities. A spawner creates components for existing entities too,
including those received while joining. Removing a component locally does not
despawn its entity.

To react to session events without polling the session yourself, pass `onEvent`
to the scope. It receives each event after the session updates and before
gameplay, for example to spawn a player for each client that joins:

```dart
MultiplayerScope(
  session: session,
  onEvent: (event) {
    if (event case PeerJoined(:final peer)) {
      session.spawn(playerType, 100, owner: peer);
    }
  },
  children: [spawner],
);
```

`spawner.spawnedComponents[entity]` finds the component of an entity, and
`spawner.componentsOwnedBy(peer)` lists the components of the entities that a
peer owns, such as its player.

When the host limits what each client sees, as the core
[visibility guide](https://pub.dev/packages/maratus#visibility) describes, a
client's spawner removes the component of an entity that leaves its view. If the
entity comes into view again, the spawner creates a new component, which starts
from the entity's latest state.

The most common limit is distance. Add a `ProximityVisibility` inside the scope
to show each client the entities whose components are `PositionComponent`s near
the ones it owns, such as its player:

```dart
MultiplayerScope(
  session: session,
  children: [
    spawner,
    // Show within 80, hide beyond 95, and update five times a second.
    ProximityVisibility(showRange: 80, hideRange: 95, interval: 0.2),
  ],
);
```

An entity in a client's view leaves it only beyond `hideRange`, so entities at
the edge do not keep leaving and returning. The host measures distances in the
scope's coordinates and runs `updateVisibility` every `interval` seconds, and at
once when a new entity's component attaches, so an entity that spawns out of
range never reaches the client. Pass `viewersOf` to choose the components that a
client sees from instead, such as a spectator's camera. Entities without a
position are left to the other rules, and filters added with
`session.addVisibilityFilter` keep working next to it: a client sees an entity
only if every filter accepts it.

To show a player's own movement without waiting for the host, predict it from
the player's inputs, as the core
[prediction guide](https://pub.dev/packages/maratus#client-side-prediction)
describes. Predict before synchronizing, and run the prediction in `update` on
every peer. On the owner, `update` advances it with the input; elsewhere, it
returns the state to present:

```dart
@override
void onNetworkAttach(EntityAttachment attachment) {
  _prediction = attachment.predict(
    state: positionField, // A Vector2Codec field.
    input: moveInput, // An input stream of steering directions.
    initial: position.clone(),
    step: (position, direction) => position + Vector2(direction * 4.0, 0),
    interpolator: const Vector2Interpolator(teleportDistance: 200),
  );
  attachment.synchronize([_prediction.property()]);
}

@override
void update(double dt) {
  super.update(dt);
  if (!isNetworkReady) return;
  position.setFrom(
    _prediction.update(
      readDirection(),
      Duration(microseconds: (dt * 1e6).round()),
    ),
  );
}
```

With code generation, a component declares all of this with annotations
instead, as the
[generator guide](https://pub.dev/packages/maratus_generator#predict-the-owners-state)
shows: `@Prediction` on the step names the predicted `@SyncedField` member
and the member that holds the owner's input. The scope then runs the prediction
before each frame's gameplay and writes the state to present to the member, so
the component needs no `onNetworkAttach` or `update` code for it. A component
with `@SyncedField` members cannot predict by hand: their synchronizer binds
before `onNetworkAttach`, and a prediction must come first. The
[prediction example](https://github.com/bszarlej/maratus/tree/master/examples/prediction)
declares its prediction with annotations.

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
- [Prediction](https://github.com/bszarlej/maratus/tree/master/examples/prediction):
  a host and a client side by side, where the client's square moves at once
  despite the latency and converges with the host's state.
- [Code generation](https://pub.dev/packages/maratus_generator): generate schema handles,
  component bindings, and typed RPC senders from annotations.

Report bugs through the [issue tracker](https://github.com/bszarlej/maratus/issues).

## License

MIT. See [LICENSE](LICENSE).
