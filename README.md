<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/maratus-lockup-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/maratus-lockup-on-light.svg">
    <img src="assets/maratus-lockup-on-light.svg" alt="Maratus logo" width="380">
  </picture>
</p>

<p align="center">
  Godot-inspired multiplayer for Dart and Flame.
</p>

Add multiplayer to your game with typed RPCs, replicated spawning, synchronized
properties, and late joining. Use Flame components on the client and run a host
in your game or in a separate Dart process.

Documentation (coming soon) ·
[Try the demo](examples/chat) ·
[Report an issue](https://github.com/bszarlej/maratus/issues)

## Get started

For a Flame game:

```sh
flutter pub add maratus_flame
```

```dart
import 'package:maratus_flame/maratus_flame.dart';
```

| Package | Use it for |
| ------- | ---------- |
| [maratus_flame](packages/maratus_flame) | Networked Flame components, spawning, and position smoothing. Includes the core APIs. |
| [maratus](packages/maratus) | Shared game protocols and standalone Dart hosts, without Flutter. Install with `dart pub add maratus`. |
| [maratus_annotations](packages/maratus_annotations) | Annotations that declare RPC handlers, synchronized fields, spawn types, and data codecs. |
| [maratus_generator](packages/maratus_generator) | Generates handles, bindings, typed RPC senders, and codecs from those annotations, as a dev dependency. |

Declare your protocol by registering it with `ProtocolSchemaBuilder`, or with
annotations: both produce the same schema.

## Examples

- [Chat demo](examples/chat): host or join over WebSockets, see replicated
  avatars, and try simulated latency and disconnects.
- [Flame example](packages/maratus_flame/example/main.dart): steer replicated
  avatars with a host and client running side by side.
- [Dart example](packages/maratus/example/main.dart): run a session, send input,
  and synchronize movement without Flutter.
- [Generator example](packages/maratus_generator/example/main.dart): the same
  session, with the avatar declared through annotations.

## Current scope

The initial release focuses on small sessions, such as 2–4 players, over
reliable, ordered WebSockets. Desktop apps can host or join; browsers can join.
Clients currently need a directly reachable host.

Requires Dart `>=3.11.0 <4.0.0`; Flame integration also requires Flutter
`>=3.41.0` and Flame `^1.38.2`.

Planned work:

- Android/iOS support and larger-session tuning: compatibility and performance
  validation are still pending.
- Additional transports, unreliable delivery, relays/NAT traversal,
  built-in client-side prediction and reconciliation, interest management, and state
  compression: **not implemented yet**.

## Contributing

From the repository root, with Flutter installed:

```sh
flutter pub get
dart run melos run check-format
dart run melos analyze --fatal-infos
dart run melos test
dart run melos run test:browser --no-select
```

Browser tests require Chrome. Set `CHROME_EXECUTABLE` if it is not found.
After changing `maratus_generator` or annotated code, regenerate the committed
`.g.dart` files with `dart run melos run generate --no-select`.

## License

[MIT](LICENSE).
