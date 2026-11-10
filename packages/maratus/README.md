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
- Authority transfer, so players can take control of shared objects.
- Late joining with the current world state.
- WebSockets for real connections and an in-memory network for testing.
- Optional code generation from annotations.

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

## Define the protocol

The host and every client register the same schema: your game's spawn types,
RPCs, and synchronized fields, each with an explicit identifier and a codec
that validates its values. Peers whose schemas differ cannot connect.

Register them by hand:

```dart
final builder = ProtocolSchemaBuilder();
final avatar = builder.addSpawnType(
  const SpawnTypeId('example.avatar'),
  const StringCodec(maxLength: 32), // The player's name.
);
final x = builder.addField(
  const FieldId('example.avatar.x'),
  const DoubleCodec(min: -100, max: 100),
);
final steer = builder.addRpc(
  const RpcId('example.avatar.steer'),
  const IntCodec(min: -1, max: 1),
  caller: RpcCaller.owner,
);
final schema = builder.build();
```

Or declare them with
[`maratus_annotations`](https://pub.dev/packages/maratus_annotations), and let
[`maratus_generator`](https://pub.dev/packages/maratus_generator) write the
handles, the code that binds them, and codecs for your data classes:

```dart
@Networked(spawnType: 'example.avatar')
final class Avatar with _$Avatar {
  Avatar(@MaxLength(32) SpawnContext<String> context) : name = context.data;

  final String name;

  @SyncedField('example.avatar.x')
  @Range(min: -100, max: 100)
  double x = 0;

  int direction = 0;

  @RpcMethod('example.avatar.steer', caller: RpcCaller.owner)
  void steer(@Range(min: -1, max: 1) int direction) =>
      this.direction = direction;
}

final builder = ProtocolSchemaBuilder();
AvatarNet.register(builder); // Generated.
final schema = builder.build();
```

Both declare the same schema, with the same fingerprint, and they mix freely
in one schema.

## Connect your game

Bind your game's entities, RPCs, and synchronized properties to the session. A
native host fits into your game loop like this, using your prepared `session`:

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
steers an avatar, the host moves it, and its position is synchronized back. The
[generator example](https://github.com/bszarlej/maratus/tree/master/packages/maratus_generator/example/main.dart)
does the same with annotations.
For a playable Flutter app and a dedicated Dart host, see the
[chat example](https://github.com/bszarlej/maratus/tree/master/examples/chat).

## Transfer authority

Each entity has an authority: the peer that writes its synchronized
properties. The host chooses it when spawning an entity and can move it later,
for example to the player who picks up a ball, so that player sees it move
without waiting for the host:

```dart
// On the host. `player` is the PeerId of a ready client, or PeerId.host.
session.transferAuthority(ball, player);
```

Every peer applies the transfer in order with spawning and state changes, and
reports it as an `AuthorityChanged` event. Clients that join later receive the
current authority. Check `entity.authority == session.localPeer` to decide
whether this peer simulates the entity.

Transfers guarantee that:

- **Only one peer writes at a time.** The previous authority stops sending
  state as soon as it receives the transfer, and the host drops anything it
  sent before then. The new authority's state counts once it has acknowledged
  the transfer.
- **Every peer ends up with the same state.** The new authority continues from
  the latest values it received. The previous authority takes back the values
  the host accepted, replacing any it sent that the host dropped.
- **Interpolation stays smooth.** Samples from two authorities are never
  blended: the latest value holds until the new authority's first sample
  arrives.
- **RPCs follow the new authority.** RPCs that only the authority may call,
  or that go to the authority, use the new authority from the transfer on.
- **Entities are never left without a writer.** When a client that is an
  entity's authority leaves, even during a transfer, the host takes the
  authority back, unless the client's departure despawns the entity.

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
