<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../assets/maratus-mark-on-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="../../assets/maratus-mark-on-light.svg">
  <img src="../../assets/maratus-mark-on-light.svg" alt="Maratus logo" width="80">
</picture>

# RPC example

A host and two clients run side by side in one Flame game, joined by an
in-memory network with 40 ms of latency each way. The host spawns a pawn for
each client, and each view has buttons that call the pawns' RPCs. A note above
a pawn shows each call that a peer runs, for a few seconds. Some of the calls
are not allowed, and the peer that refuses them shows why in red.

Requires Dart `>=3.11.0 <4.0.0` and Flutter `>=3.41.0`. Use Chrome for the web
runner or install Flutter's Windows build tools for the desktop runner.

## Run

From the repository root:

```sh
flutter pub get
cd examples/rpc
flutter run -d chrome
```

Or run `flutter run -d windows`. On macOS or Linux, generate the corresponding
runner first with `flutter create --platforms=macos .` or
`flutter create --platforms=linux .`.

## Try it

Each pawn shows the ID of the client that owns it, and the pawn that a view
owns has a white ring.

| RPC | Who may call it | Where it runs | Try |
| --- | --- | --- | --- |
| `step` | the pawn's owner | the host | **Step** on a client moves its own pawn. **Step other's** on a client, and **Step** on the host, are refused by the host, because only the owner may step. |
| `say` | anyone | every peer, the caller included | **Say hello** shows in all three views. **Say too much** exceeds the 12-character limit, so the client refuses it before sending. |
| `poke` | anyone | the pawn's owner | **Poke other's pawn** on a client shows only in the other client's view. **Poke every pawn** on the host calls it once per pawn, and each client sees only its own. |
| `whisper` | anyone | the peer that the caller picks with `to:` | **Whisper to other** shows only in the other client's view. The sender is not a recipient, so it shows its own copy itself. |
| `award` | the host | every peer | **Award every pawn** on the host shows in all three views. **Award** on a client is refused by the host. |

`poke` and `whisper` both reach one peer, chosen differently: the pawn decides
who receives a `poke`, its owner, while the caller decides who receives a
`whisper`. `local` only matters when the caller is among the peers that
`target` selects, so neither runs on its caller.

## Explore the code

- [pawn.dart](lib/pawn.dart): the pawn and its RPCs. Each `@RpcMethod`
  declares who may call it (`caller`), where it runs (`target`), and whether
  the caller runs it too (`local`). The parameters' annotations limit their
  values.
- [main.dart](lib/main.dart): the host, the clients, and their buttons. A
  button calls an RPC through the generated `pawn.rpc` sender.

After changing the annotations, regenerate `pawn.g.dart`:

```sh
dart run build_runner build
```

The host checks every call. A call that its policy does not allow, including
the host's own, raises an `RpcRejected` event on the host, with the reason. A
payload that its codec refuses throws an `ArgumentError` on the caller, and
nothing is sent.

RPCs are messages that happen once: a client that joins later does not receive
them. The pawn's column is state, so `step` changes a synchronized field that
the host writes, and the client always has the current column.

See the core [RPC guide](../../packages/maratus/README.md#send-a-typed-rpc) for
the RPC policies.
