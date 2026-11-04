<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/maratus-lockup-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/maratus-lockup-on-light.svg">
    <img src="assets/maratus-lockup-on-light.svg" alt="Maratus logo" width="380">
  </picture>
</p>

<p align="center">
  Godot-inspired multiplayer for Dart-based games.
</p>

## Packages

| Package | Use it for |
| ------- | ---------- |
| [`maratus`](packages/maratus) | The multiplayer core in pure Dart: sessions, schemas and codecs, RPCs, spawning, property synchronization and interpolation, late joining, diagnostics, and the WebSocket and in-memory transports. Runs without Flutter, for example in a dedicated host. |
| [`maratus_flame`](packages/maratus_flame) | Flame games: `MultiplayerScope`, `NetworkedComponent`, `MultiplayerSpawner`, and synchronized, smoothed `Vector2` values. Re-exports `maratus`, so a game needs only this package. |

A Flame game depends on `maratus_flame`. Shared protocol definitions,
dedicated hosts, and other Dart code that must run without Flutter depend on
`maratus`.

## How it works

- **One host, many clients.** Clients connect to a host that runs the
  authoritative simulation. The host assigns peer identities, validates every
  message, and routes calls between clients.
- **Explicit schemas.** Spawn types, RPCs, and synchronized fields are
  registered with stable identifiers and codecs that validate everything
  received. Host and clients must register the same schema to connect.
- **Authority and ownership.** Each entity's authority writes its state, and
  its owner may send it input, such as movement RPCs for a player's avatar.
- **Late joining.** A joining client installs the host's current world before
  it takes part in gameplay, and fails clearly if it cannot.

See the [`maratus` README](packages/maratus/README.md) for the full contract
and the [`maratus_flame` README](packages/maratus_flame/README.md) for the Flame
integration.

## Examples

[`examples/chat`](examples/chat) is a Flutter app that hosts or joins a session
over WebSockets, exchanges typed chat RPCs, and gives every participant a
replicated avatar with host-simulated movement that clients smooth. Windows
can host or join, and browsers join a native host. A simulated network inside
the app reproduces latency spikes, stalls, and dropped connections, with a
diagnostics overlay to inspect them.

## Compatibility

| Dependency | Supported versions |
| ---------- | ------------------ |
| Dart       | `>=3.11.0 <4.0.0`  |
| Flutter    | `>=3.41.0` (`maratus_flame` only) |
| Flame      | `^1.38.2` (`maratus_flame` only)  |

## Development

The repository is a [pub workspace](https://dart.dev/tools/pub/workspaces)
managed with [Melos](https://melos.invertase.dev). With a Flutter SDK in the
supported range, run from the repository root:

```sh
flutter pub get
dart run melos run check-format
dart run melos analyze --fatal-infos
dart run melos test
dart run melos run test:browser --no-select
```

`melos test` runs `dart test` for `maratus` and `flutter test` for the Flutter
packages. The browser tests start a native loopback host and run Chrome clients
against it; Chrome must be installed, and `CHROME_EXECUTABLE` must point to it
when it is outside its default location. See
[`examples/chat`](examples/chat/README.md) for running and building the example.

CI runs these checks on the minimum supported SDK with the lowest allowed
direct dependency versions and compatible transitive dependencies, and on the
current stable SDK with the newest. It also resolves and tests `maratus` alone
with the plain Dart SDK, so the core cannot gain a Flutter dependency, and builds
the example for web and Windows; see
[.github/workflows/ci.yaml](.github/workflows/ci.yaml).

### Repository layout

| Path | Contents |
| ---- | -------- |
| `packages/maratus/lib/src/core/` | Sessions, peer identity, entities, RPCs, clocks |
| `packages/maratus/lib/src/protocol/` | Message envelopes, codecs, schema, validation |
| `packages/maratus/lib/src/transport/` | Transport contract, in-memory and WebSocket adapters |
| `packages/maratus/lib/src/replication/` | Spawning, property synchronization, bootstrap |
| `packages/maratus_flame/lib/src/` | Flame component bindings |
| `examples/` | Runnable examples |

`packages/maratus/test/package_layout_test.dart` keeps the core within these
areas and free of Flutter and Flame.

## License

MIT. See [LICENSE](LICENSE).
