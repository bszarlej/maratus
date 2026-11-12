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
- Player lists on every peer: who joined, who is ready, and who left.
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

## Choose delivery per RPC and field

RPCs and synchronized fields default to reliable delivery on channel zero.
Set `deliveryMode` and `channel` on their handles, builder registrations, or
annotations to use an ENet connection's other delivery options:

```dart
final position = builder.addField(
  const FieldId('player.position'),
  const DoubleCodec(),
  deliveryMode: DeliveryMode.unreliableOrdered,
  channel: 1,
);
attachment.synchronize([
  position.property(
    get: () => player.x,
    set: (value) => player.x = value,
    mode: SyncMode.always,
  ),
]);
```

`addRpc` accepts the same delivery options. `unreliableOrdered` can lose
messages and discards packets that arrive after a newer packet on that lane;
`unreliable` can also reorder them. RPC requests and host relays use the
method's configuration. Unreliable RPCs are not retried automatically.

Unreliable fields require `SyncMode.always`, so later samples can recover a
lost value even when it stops changing. State sequences prevent older samples
from overwriting newer values of each field. Fields with different modes or
channels travel in separate packets. Use separate channels for independent
streams, especially when combining ordered unreliable fields and RPCs.

Session control, spawning, authority transfers, initial snapshots, and late-join
catch-up remain reliable on channel zero. Packets on other lanes can arrive
before the control changes they need: unreliable packets are discarded, while
reliable packets wait within `pendingDeliveryLimits` and the bootstrap timeout.
There is no global ordering between channels or modes.

Use the optional [`maratus_enet`](../maratus_enet) package and configure both
peers with enough channels (`channelCount: 2` for channel one). `host` and
`join` throw `UnsupportedError` before taking ownership of a peer that cannot
provide the schema's modes and channels. WebSockets support only reliable
channel zero. Delivery settings are part of the schema fingerprint.

ENet limits each unreliable message to 1,000 encoded bytes, including the
session envelope. Oversized state groups are split into individual fields;
an individual field that still cannot fit reports `PropertySyncFailed`.
An oversized outgoing client RPC throws `ArgumentError`; a host delivery
reports `RpcRejected` with `invalidPayload`.

For deterministic tests, configure `InMemoryNetwork` with `deliveryModes`
and `channelCount`, then use `dropNextUnreliable` or `delayNextUnreliable`.
The default in-memory transport mirrors reliable-only WebSockets.

## Follow who is playing

The host and every client report players joining, becoming ready, and
leaving with the same events, so a lobby or player list works the same on
every peer:

```dart
for (var event = session.poll(); event != null; event = session.poll()) {
  switch (event) {
    case PeerJoined(:final peer) || PeerReady(:final peer):
      lobby.show(peer, ready: session.isReady(peer));
    case PeerLeft(:final peer, :final reason):
      lobby.remove(peer, reason);
    default:
  }
}
```

`session.peers` lists the other peers: the clients on the host, and the host
and the other clients on a client. A client doesn't report itself or the
host. `session.isReady(peer)` tells whether a peer has finished joining, for
example before a client sends it an RPC that targets one peer.

Clients learn about other players in order with the rest of the world: a
client hears that a player joined before it receives any entity the player
owns, and that a player left before the host despawns the player's entities.
Clients that join later receive the current players and their readiness with
the world. A client appears only once the host admits it: not while the
host's `onJoinRequest` handler is still deciding, and never if the host
rejects it.

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
use WebSockets or the optional native ENet transport and currently require a
directly reachable host.

Planned work:

- Android/iOS support and larger-session tuning: compatibility and performance
  validation are still pending.
- Relays/NAT traversal,
  built-in client-side prediction and reconciliation, interest management, and state
  compression: **not implemented yet**.

The documentation website is coming soon. Start with the examples above.

## Wire format

Sessions use self-contained binary packets with variable-length integers and
little-endian IEEE-754 numbers. Values that round-trip exactly through a 32-bit
float use four bytes; other fractional values retain all eight bytes of a double.
Exactly integral doubles in the safe integer range use integer encoding consistently on native and JavaScript platforms;
negative zero retains its IEEE-754 representation. Strings remain UTF-8.
Custom value codecs keep their existing null/bool/number/string/list/map model.

Fields, RPCs, and spawn types each get a separate zero-based numeric ID table,
sorted lexicographically by identifier. Registration order does not matter.
The handshake checks the schema fingerprint before accepting application data.
No dictionary updates or previous packets are needed to decode a message, so
packet loss, duplication, and reordering do not affect decoding.

The envelope starts with `0x4d`, binary format version `2`, then varints for the
protocol version, message kind, generation, revision, and body presence mask.
Body entries follow a fixed mask order; state fields carry numeric IDs and tagged
values. Decoding rejects unknown IDs, duplicate keys, invalid tags, overflowing
or noncanonical varints, non-finite doubles, truncation, and trailing bytes.
Message, collection, and nesting limits remain enforced.

All session peers must upgrade together: binary format version 2 replaces both
the original JSON representation and binary format version 1.
The internal protocol codec still supports JSON for diagnostics; sessions do not
negotiate a fallback. A two-position-field regression fixture measures 100 bytes
in JSON and 22 bytes in binary (4.5x smaller). Actual savings depend on payloads.
CPU performance has not been benchmarked.

During `update()` and `captureState()`, consecutive state messages for the same
peer, delivery mode, and channel share a packet. Each message keeps its revision,
sequence, and sample time. Batches share the generation and format headers, flush
before control/RPC messages and before the call returns, and target at most 1200
bytes (or a smaller transport limit). Large standalone reliable messages retain
their existing behavior. Every packet remains independently decodable; no previous
snapshot is needed. Diagnostics count logical messages and actual packet bytes,
including batch framing once.

Use `QuantizedDoubleCodec` when a field may intentionally lose precision:

```dart
final position = builder.addField(
  const FieldId('player.position.x'),
  QuantizedDoubleCodec(min: -1000, max: 1000, step: 0.01),
);
```

This maps values to integer grid indices, rounding to the nearest hundredth.
The range must contain a whole number of steps; invalid configurations and values
outside the range are rejected. The range and step enter the schema fingerprint.
Movements that round to the same value do not trigger `SyncMode.onChange`
updates. Quantization is opt-in: `DoubleCodec` continues to preserve exact values.

## License

MIT. See [LICENSE](LICENSE).
