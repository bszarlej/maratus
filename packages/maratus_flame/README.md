<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg">
    <img src="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg" alt="Maratus logo" width="300">
  </picture>
</p>

<p align="center">
  Godot-inspired multiplayer for <a href="https://flame-engine.org">Flame</a> games.
</p>

---

# maratus_flame

[Flame](https://flame-engine.org) bindings for
[`maratus`](https://pub.dev/packages/maratus), Godot-inspired multiplayer for Dart: a scope that drives a
multiplayer session for a component subtree, networked components with typed
RPCs and synchronized properties, and a spawner for replicated entities.

This package re-exports `maratus`, so its networking APIs need a single import. The
[`maratus` documentation](https://pub.dev/packages/maratus) covers sessions, schemas and codecs, RPC
policies, spawning, property synchronization, late joining, and transports;
this page covers what is specific to Flame.

## Installation

```sh
flutter pub add maratus_flame
```

```dart
import 'package:maratus_flame/maratus_flame.dart';
```

## Compatibility

| Dependency | Supported versions |
| ---------- | ------------------ |
| Dart       | `>=3.11.0 <4.0.0`  |
| Flutter    | `>=3.41.0`         |
| Flame      | `^1.38.2`          |

WebSocket hosting is supported on Windows, macOS, and Linux; browsers can join
native hosts. See the core package's
[platform support](https://pub.dev/packages/maratus#platform-support) for the
transport support matrix and limitations.

## Concepts

| Concept              | Role                                                                                                   |
| -------------------- | ------------------------------------------------------------------------------------------------------ |
| `MultiplayerScope`   | A component that drives one session for its subtree, at a fixed point in each update.                  |
| `NetworkedComponent` | A component mixin that attaches a networked entity, with its RPC handlers and synchronized properties. |
| `MultiplayerSpawner` | Creates and removes the components of entities the host spawns and despawns, by registered spawn type. |

## Component lifecycles

A `MultiplayerScope` drives a session for its subtree; static components mix in
`NetworkedComponent` and expose an entity already registered in that session.
Each peer must register matching IDs and ownership metadata. For example:

```dart
import 'package:flame/components.dart';
import 'package:maratus_flame/maratus_flame.dart';

class Player extends PositionComponent with NetworkedComponent {
  Player(this.networkEntity, this.move);

  @override
  final NetworkEntity networkEntity;
  final Rpc<int> move;

  @override
  void onNetworkAttach(EntityAttachment attachment) {
    attachment.bindRpc(move, (context, direction) {
      position.x += direction;
    });
  }

  @override
  Future<void> onLoad() async {
    // Register before waiting for assets. Mount readiness is checked later.
    await super.onLoad();
    // Load assets here; never await a child's mounted future here.
  }
}

// After session.host(...) or session.join(...):
final entity = session.registry.register(
  const EntityId(1),
  owner: PeerId.host,
  authority: PeerId.host,
);
final scope = MultiplayerScope(
  session: session,
  children: [Player(entity, move)],
);
await game.add(scope);
```

The mixin exposes `multiplayerScope`, `multiplayerSession`, `networkEntity`,
and `isNetworkReady`. Call super when overriding `onLoad`, `onMount`, and
`onRemove`; call `super.onLoad()` before asynchronous loading starts. Bind
handlers in `onNetworkAttach`, which runs again for each remount. The session
marks a pending entity ready once its component and scope are mounted.

The scope's `updateTree()` runs this sequence:

1. Invalidate detached attachments, then call `session.update()`. This consumes
   socket events, applies spawn and despawn records, validates calls, applies
   synchronized properties to ready components, and dispatches eligible queued
   component RPCs.
2. Run the scope and its children's gameplay updates in Flame order.
3. Call `captureNetworkState(dt)` on each ready networked component.
4. Call `session.captureState()` to sample and send due synchronized fields.

Do not also call `session.update()` from another timer or game callback. Only
one live scope can drive a session. Nested scopes use different sessions and
capture their own descendants. The capture callback is an application hook
that runs before automatic property sampling. Asynchronous RPC handlers are
not awaited, so their later side effects must check that the component still
belongs to the intended lifetime.

`EntityAttachment` keeps RPC handlers and pending work in the session, separate
from the entity's network identity. Fully validated calls for an attached
entity can wait while its component loads. All its local invocations, including
host-local calls, run at an update boundary. Handler-enqueued calls wait until
the following update. Each invocation checks the exact attachment, binding,
entity, and current readiness, so removing a component or one of its ancestors
inside a handler prevents further calls from reaching that instance.

`PendingRpcLimits` defaults to 256 invocations, 1 MiB of encoded delivery
envelopes, and a maximum age of 10 seconds across the session. Limits must be
positive. A full queue rejects the newest call with `pendingQueueFull`; an
expired call produces `readinessTimeout`. Age is measured by the session's
monotonic clock and checked during updates. These local diagnostics do not
acknowledge remote execution. Inspect `pendingRpcCount` and `pendingRpcBytes`
for the current backlog. Disposing a binding or attachment discards its work;
replacement instances never inherit it. Framework-free integrations can use
`session.attachEntity()` with their own validity and readiness predicates.

Local removal or reparenting disposes the component's attachment and bindings,
without removing its registry entity or sending a network despawn. A remount
creates a new attachment; an already-ready entity remains ready in the registry
while attachment readiness controls local dispatch. Removing the registry
entity is terminal and invalidates the attachment. Reusing a component after
session restart requires an entity from the new registry lifetime.

Use `component.removeFromParent()`, its `parent` setter, or the scope's removal
methods to discard queued calls immediately, including before the next update.
When custom parent logic removes and re-adds a never-mounted component between
updates, call `component.detachNetwork()` first, or
`scope.detachSubtree(parent)` for a larger subtree. Flame provides no callback
for that intermediate removal, so polling alone cannot detect it.

Removing a scope permanently disposes it and closes its session by default.
Use `ownsSession: false` when another owner manages the session, and explicitly
close that session later. Call `scope.dispose()` if abandoning it before it
mounts: Flame does not call `onRemove` for never-mounted components. A new scope
is needed for a new game lifecycle. The scope also observes the game's removal
future, so removing a `GameWidget` disposes its scopes even though Flame does
not propagate that removal to child components. Cleanup then runs in a
microtask; call `scope.dispose()` explicitly when immediate closure is needed.
Disposal is idempotent and releases all bindings and pending calls; it creates
no timers or stream subscriptions.

Pausing the Flame engine stops polling, gameplay, and capture together. Socket
queues remain bounded and may close an overflowing connection. A client that
keeps updating while a host is paused can time out while joining. Established
sessions currently have **no heartbeat or idle timeout**; a ready client stays
connected until its transport closes. On resume, queued replies take precedence
over joining deadlines, while expired pending component RPCs are rejected.

A component that finishes loading after its scope was disposed mounts without
an attachment.

The [running example](https://github.com/bszarlej/maratus/tree/master/examples/chat) uses a mounted chat component inside a
scope, with its own Flame update and capture steps, and a spawner that gives
every participant a replicated avatar.

## Spawning components

The host spawns replicated entities with `session.spawn()`, and every peer
creates their components; see [replicated spawning](https://pub.dev/packages/maratus#replicated-spawning)
for spawn types, metadata, and despawning. Register the spawn type's codec in
the shared schema:

```dart
final builder = ProtocolSchemaBuilder();
final avatarType = builder.addSpawnType(
  const SpawnTypeId('game.avatar'),
  const IntCodec(min: 0, max: 5), // The color the host chose.
);
```

Add a `MultiplayerSpawner` to the scope on every peer, with a factory that
builds the component from the spawned entity and its data:

```dart
class Avatar extends PositionComponent with NetworkedComponent {
  Avatar(SpawnContext<int> context)
    : networkEntity = context.entity,
      color = context.data;

  @override
  final NetworkEntity networkEntity;
  final int color;
}

final spawner = MultiplayerSpawner()..register(avatarType, Avatar.new);
final scope = MultiplayerScope(session: session, children: [spawner]);
```

The host then spawns entities, for example an avatar for each client that
joins:

```dart
// On PeerJoined(peer):
session.spawn(
  avatarType,
  color,
  owner: peer,
  onOwnerLeft: OwnerLeftPolicy.despawn,
);
```

The spawner creates each component while its spawn record is applied: on the
host inside `spawn()`, and on clients during the scope's session update. The
component's attachment therefore exists before RPCs that arrive in the same
update are dispatched, so a call sent right after a spawn waits for the
component to mount. A component is added under the component of its parent
entity when that component is attached in the same scope, and under the
spawner otherwise. Despawning removes the component, even while it is still
loading, so no ghost mounts afterward. A spawner added later, or added back
after removal, creates components for the live entities it lacks and drops
those whose entities were despawned meanwhile. A spawn type belongs to one
spawner per session.

A joining client reports ready once the components of the entities in its
baseline have mounted. A factory that throws for one of those entities ends
the join with `DisconnectReason.bootstrapFailed` and removes the components
created so far.

## Synchronizing component properties

Register fields in the shared schema, retaining their typed `SyncField<T>`
handles, then bind the same selected properties on each peer when the component
attaches:

```dart
final healthField = builder.addField(
  const FieldId('game.avatar.health'),
  const IntCodec(min: 0, max: 100),
);
```

Bind the same selected properties on each peer when its component attaches:

```dart
class HealthComponent extends Component with NetworkedComponent {
  HealthComponent(this.networkEntity, this.healthField);

  @override
  final NetworkEntity networkEntity;
  final SyncField<int> healthField;
  int health = 100;
  late MultiplayerSynchronizer synchronizer;

  @override
  void onNetworkAttach(EntityAttachment attachment) {
    synchronizer = attachment.synchronize([
      healthField.property(
        get: () => health,
        set: (value) => health = value,
      ),
    ], interval: const Duration(milliseconds: 50));
  }
}
```

The scope applies received values before gameplay while the component is
ready, and samples the authority's values after gameplay and every
`captureNetworkState()` hook. Values received while a component loads are kept
and applied once it mounts, and a remounted component receives them again. See
[property synchronization](https://pub.dev/packages/maratus#property-synchronization) for update modes,
snapshots, and authority validation.

## License

MIT. See [LICENSE](LICENSE).
