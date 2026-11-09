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

Add multiplayer to your Flame components with typed RPCs, replicated spawning,
and synchronized properties. Built on the pure-Dart
[`maratus`](https://pub.dev/packages/maratus) core, which this package re-exports.

- Drive networking alongside your game's updates with `MultiplayerScope`.
- Bind RPCs and synchronized properties to a component's lifecycle.
- Spawn entities across peers and bring late joiners up to date.
- Smooth remote positions with built-in vector interpolation.

Documentation (coming soon) ·
[Examples](https://github.com/bszarlej/maratus/tree/master/examples/chat) ·
[Issues](https://github.com/bszarlej/maratus/issues)

## Get started

```sh
flutter pub add maratus_flame
```

Mix `NetworkedComponent` into a component and bind the properties you want to
synchronize. This example assumes a shared schema with a registered
`SyncField<int>` for health and an entity from your session:

```dart
import 'package:flame/components.dart';
import 'package:maratus_flame/maratus_flame.dart';

class Player extends PositionComponent with NetworkedComponent {
  Player(this.networkEntity, this.healthField);

  @override
  final NetworkEntity networkEntity;
  final SyncField<int> healthField;
  int health = 100;

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

Add the component beneath a `MultiplayerScope(session: session)` after hosting
or joining. Changes made by the entity's authority are synchronized to other
peers; the scope handles applying incoming state and capturing outgoing changes.

You can also annotate the component instead, with
[`maratus_annotations`](https://pub.dev/packages/maratus_annotations): mark
fields with `@SyncedField` and methods with `@RpcMethod`, and
[`maratus_generator`](https://pub.dev/packages/maratus_generator) generates the
handles, binds them on every attachment, and adds typed senders such as
`player.rpc.hit(25)`.

See the [Flame example](example/main.dart) for a complete host/client game with
spawned avatars, input RPCs, and smooth movement. The
[chat demo](https://github.com/bszarlej/maratus/tree/master/examples/chat)
includes WebSocket hosting and joining.

## Compatibility

Requires Dart `>=3.11.0 <4.0.0`, Flutter `>=3.41.0`, and Flame `^1.38.2`.

WebSocket hosting and joining are supported on Windows, macOS, and Linux.
Browsers can join native hosts. The initial release focuses on small sessions,
such as 2–4 players, with reliable, ordered delivery and a directly reachable host.

Planned work:

- Android/iOS support and larger-session tuning: compatibility and performance
  validation are still pending.
- Additional transports, unreliable delivery, relays/NAT traversal,
  built-in client-side prediction and reconciliation, interest management, and state
  compression: **not implemented yet**.

## License

MIT. See [LICENSE](LICENSE).
