<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg">
    <img src="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg" alt="Maratus logo" width="300">
  </picture>
</p>

<p align="center">
  Godot-inspired multiplayer for Dart-based games.
</p>

<p align="center">
  Documentation (coming soon) ·
  <a href="https://github.com/bszarlej/maratus/tree/master/examples/chat">Chat demo</a> ·
  <a href="https://github.com/bszarlej/maratus/issues">Issues</a>
</p>

Build multiplayer games with a shared world, typed messages, and a host
that controls gameplay. Maratus handles connections and replication so you can
focus on your game.

- Typed RPCs with caller and ownership checks.
- Replicated spawning and selected property synchronization.
- Late joining with the current world state.
- WebSockets for real connections and an in-memory network for testing.

The core is pure Dart, with no Flutter dependency, so it can also run your
dedicated server. Using Flame? Start with
[`maratus_flame`](https://pub.dev/packages/maratus_flame), which adds component
integration and re-exports this package.

## Install

```sh
dart pub add maratus
```

```dart
import 'package:maratus/maratus.dart';
```

## Connect your game

Define the same protocol schema on the host and clients, then bind your game's
entities, RPCs, and synchronized properties. A native host fits into your game
loop like this, using your prepared `session`:

```dart
session.host(await WebSocketHost.bind(port: 8080));

void tick() {
  session.update(); // Apply incoming messages.
  // Run your gameplay here.
  session.captureState(); // Send synchronized property changes.
}
```

Call `tick()` each frame and `session.close()` when the game ends.
Clients join using `session.join(WebSocketClient.connect(uri))`.

The [runnable Dart example](example/main.dart) shows the complete flow: a client
steers an avatar, the host moves it, and its position is synchronized back.
For a playable Flutter app and a dedicated Dart host, see the
[chat example](https://github.com/bszarlej/maratus/tree/master/examples/chat).

## Compatibility and scope

Requires Dart `>=3.11.0 <4.0.0`. Windows, macOS, and Linux can host and join;
browsers can join.

The initial release focuses on small sessions, such as 2–4 players. Connections
use reliable, ordered WebSockets and currently require a directly reachable host.

Planned work:

- Android/iOS support and larger-session tuning: compatibility and performance
  validation are still pending.
- Additional transports, unreliable delivery, relays/NAT traversal,
  built-in client-side prediction and reconciliation, interest management, and state
  compression: **not implemented yet**.

The documentation website is coming soon. Start with the examples above.

## License

MIT. See [LICENSE](LICENSE).
