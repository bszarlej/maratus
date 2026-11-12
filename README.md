<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/maratus-lockup-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/maratus-lockup-on-light.svg">
    <img src="assets/maratus-lockup-on-light.svg" alt="Maratus logo" width="380">
  </picture>
</p>

# Maratus

Godot-inspired multiplayer for Dart and Flame: typed RPCs, replicated spawning,
property synchronization, and late joining. The host manages the session and
entity lifecycle; each entity has an owner and a separate state authority.
Hosts can run inside a game or in a standalone Dart process.

## Installation

For Flame games:

```sh
flutter pub add maratus_flame
```

For Dart applications and dedicated hosts:

```sh
dart pub add maratus
```

Requires Dart `>=3.11.0 <4.0.0`. Flame integration also requires Flutter
`>=3.41.0` and Flame `^1.38.2`.

## Packages

| Package | Purpose |
| ------- | ------- |
| [maratus](packages/maratus) | Sessions, RPCs, replication, WebSockets, and an in-memory transport. No Flutter dependency. |
| [maratus_flame](packages/maratus_flame) | Component lifecycle integration, spawning, and vector interpolation. Re-exports the core API. |
| [maratus_enet](packages/maratus_enet) | Optional native ENet transport over UDP. |
| [maratus_webrtc](packages/maratus_webrtc) | Optional WebRTC transport and WebSocket signaling server. |
| [maratus_annotations](packages/maratus_annotations) | Annotations for networked classes and data codecs. |
| [maratus_generator](packages/maratus_generator) | Generates protocol registrations, bindings, RPC senders, and codecs. Development dependency. |

Start with the [Flame setup guide](packages/maratus_flame/README.md) or the
[core API guide](packages/maratus/README.md). Protocols use explicit identifiers
and typed codecs, registered by hand or through code generation.

## Transports

| Transport | Host / client platforms | Delivery | Connection setup |
| --------- | ----------------------- | -------- | ---------------- |
| WebSocket | Desktop and mobile hosts and clients; browser clients | Reliable, ordered; one channel | Reachable TCP endpoint; `wss:` for HTTPS browser apps. |
| ENet | Desktop and mobile hosts and clients | Reliable and unreliable; independent channels | Reachable UDP endpoint. |
| WebRTC | Desktop, mobile, and browser hosts and clients | Reliable and unreliable; independent channels | Signaling service; STUN/TURN servers for connections across networks. |

RPCs and synchronized fields select their delivery mode and channel. Session
control, spawning, and initial snapshots remain reliable. See the
[delivery guide](packages/maratus/README.md#delivery) and each transport's README
for configuration and platform requirements.

## Examples

- [WebSocket chat](examples/chat): Windows or standalone Dart hosting, browser
  clients, replicated avatars, and simulated connection problems.
- [Flame](packages/maratus_flame/example/main.dart): host and client in one game,
  with input RPCs and interpolated movement.
- [Dart](packages/maratus/example/main.dart): spawning, input, and state
  synchronization over a deterministic in-memory network.
- [Code generation](packages/maratus_generator/example/main.dart): the Dart
  example implemented with annotations.

## Contributing

From the repository root, with Flutter installed:

```sh
flutter pub get
dart run melos run check-format
dart run melos analyze --fatal-infos
dart run melos test
dart run melos run test:browser --no-select
```

Native transport tests require the compiler setups documented for
[ENet](packages/maratus_enet) and [WebRTC](packages/maratus_webrtc).
Browser tests require Chrome; set `CHROME_EXECUTABLE` if it is not found.
Run WebRTC browser interoperability tests with `dart test --platform chrome`
from `packages/maratus_webrtc`.

After changing the generator or annotated code, regenerate committed outputs:

```sh
dart run melos run generate --no-select
```

Report bugs and feature requests in the
[issue tracker](https://github.com/bszarlej/maratus/issues).

## License

[MIT](LICENSE).
