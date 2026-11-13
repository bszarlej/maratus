<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg">
    <img src="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg" alt="Maratus logo" width="300">
  </picture>
</p>

<p align="center">
  <a title="Pub" href="https://pub.dev/packages/maratus" ><img alt="pub version" src="https://img.shields.io/pub/v/maratus.svg"></a>
</p>

# maratus

Multiplayer sessions, typed RPCs, replicated entities, and property synchronization
for Dart. The core has no Flutter dependency and runs in native applications,
browsers, and dedicated hosts. Flame games can use
[`maratus_flame`](https://pub.dev/packages/maratus_flame), which re-exports this API.

## Installation

Requires Dart `>=3.11.0 <4.0.0`.

```sh
dart pub add maratus
```

## Send a typed RPC

Register the same protocol on the host and every client. This example declares
a static chat room and a message that any ready peer can send to everyone,
including itself:

```dart
import 'package:maratus/maratus.dart';

({ProtocolSchema schema, StaticEntity room, Rpc<String> chat}) createProtocol() {
  final builder = ProtocolSchemaBuilder();
  final room = builder.addStaticEntity(const StaticEntityId('chat.room'));
  final chat = builder.addRpc(
    const RpcId('chat.message'),
    const StringCodec(maxLength: 240),
    caller: RpcCaller.anyPeer,
    target: RpcTarget.all,
    local: RpcLocal.include,
  );
  return (schema: builder.build(), room: room, chat: chat);
}
```

Start a native host:

```dart
final protocol = createProtocol();
final session = MultiplayerSession(schema: protocol.schema);
session.host(await WebSocketHost.bind(port: 8080));
```

Or start a client, using the same schema:

```dart
final protocol = createProtocol();
final session = MultiplayerSession(schema: protocol.schema);
session.join(
  WebSocketClient.connect(Uri.parse('ws://localhost:8080/netcode')),
);
```

After `host` or `join`, bind the local room on each peer. This attachment stays
valid for the session's lifetime and is ready on its first update:

```dart
final entity = session.staticEntity(protocol.room);
final messages = <String>[];
session.attachEntity(entity, isReady: () => true, isValid: () => true)
  ..bindRpc(protocol.chat, (context, text) {
    messages.add('${context.sender.value}: $text');
  });
```

Keep updating the session as described below. Once the client reaches
`SessionState.ready`, or while hosting, send a message:

```dart
final accepted = session.callRpc(entity, protocol.chat, 'Hello');
```

The return value reports local acceptance, not remote execution or a gameplay
result. `caller` controls permission; `target` selects recipients; `local`
controls whether a caller that is also a recipient executes the RPC.
The host validates callers using their connections, not an identity in the payload.

For a runnable application, see the
[WebSocket chat example](https://github.com/bszarlej/maratus/tree/master/examples/chat).

## Session lifecycle

Drive a Dart session from the game loop in this order:

```dart
void tick() {
  session.update(); // Apply incoming messages and ready attachments.
  // Run gameplay here.
  session.captureState(); // Sample and send authoritative properties.
}
```

Flame's `MultiplayerScope` handles this ordering. Do not also drive its session
manually. Call `session.close()` when the game ends; the session owns and closes
its transport. Bind local entities again after starting a new session.

A transport connection is not gameplay readiness. Joining clients receive the
current entities and state, apply subsequent changes, and finish loading their
attachments before becoming ready. Transient RPCs are not replayed to late
joiners. Rejoining starts a fresh synchronization with a new peer identity.

Drain `session.poll()` during updates to handle lifecycle events and errors:

| Event | Meaning |
| ----- | ------- |
| `SessionStateChanged` | The local session changed state; includes a disconnect reason when applicable. |
| `PeerJoined`, `PeerReady`, `PeerLeft` | A client was admitted, finished synchronizing, or left. |
| `RpcRejected`, `RpcHandlerFailed` | An RPC was rejected or its handler failed. |
| `InputRejected` | The host ignored inputs from a client that does not own the entity, or that it does not predict. |
| `SpawnHandlerFailed`, `PropertySyncFailed`, `AdmissionFailed` | A local spawn, property, prediction step, or admission callback failed. |

`session.peers` excludes the local peer. On clients it includes the host and
other clients, but membership events describe only other clients. Use
`session.isReady(peer)` to check a remote peer's readiness.

Configure `SessionTimeouts` for handshake, initialization, and optional idle
timeouts. `session.diagnostics` reports traffic, queue depths, latency, and
replication activity.

## Replicated entities and state

The host creates entities with `session.spawn` and removes them with
`session.despawn`. Register a `SpawnType<T>` in the shared schema and install a
`session.bindSpawn` handler on each peer to construct its local representation.
Attach that representation with `session.attachEntity`; its `isReady` and
`isValid` callbacks control when it can receive updates and RPCs.

Each entity has two separate roles:

- **Owner:** the peer that controls the entity's input. It may call RPCs
  declared with `RpcCaller.owner`, writes owner-written fields, and sends the
  inputs of a prediction. The owner never changes.
- **Authority:** the peer that writes the entity's other synchronized
  properties. The host is the default authority, including for client-owned
  entities.

Bind registered `SyncField<T>` handles through `attachment.synchronize`, with
getters for sampling and setters for received values. Fields support initial-only,
changed-value, and periodic updates. Sampling defaults to a 50 ms interval,
independent of render frequency. Interpolation provides presentation values
without replacing authoritative state.

Register a field with `writer: FieldWriter.owner` to let the entity's owner
write it, such as a player's movement input:

```dart
final input = builder.addField(
  const FieldId('arena.player.input'),
  const IntCodec(min: -1, max: 1),
  writer: FieldWriter.owner,
);
```

The host accepts owner-written values only from the owner and relays them to the
other clients, while the authority keeps writing the fields that result from
them, such as the player's position. One synchronizer can bind both kinds of
fields: each peer samples the fields it writes and applies the others. Unlike
RPCs, state is replaceable, so newer input replaces input that a congested
connection has not sent yet. Late joiners receive owner-written values in their
initial state.

Use `QuantizedDoubleCodec(min: -1000, max: 1000, step: 0.01)` when a field can
trade precision for smaller encoded values. `DoubleCodec` preserves values exactly.

The [Dart example](example/main.dart) demonstrates the complete flow: the host
spawns an avatar, its owner sends steering RPCs, and the host synchronizes its
position. The [generator guide](https://pub.dev/packages/maratus_generator) shows
the same bindings declared with annotations.

The host can transfer an entity's authority to a ready client or back to itself
with `session.transferAuthority(entity, peer)`. Transfers report
`AuthorityChanged`; state from the previous authority is rejected after the
transfer. Owner-written fields keep their writer. When an authority
disconnects, the host takes over surviving entities.
Set `onOwnerLeft: OwnerLeftPolicy.despawn` when spawning entities that should be
removed with their owner.

## Client-side prediction

With the host as authority, a player's input otherwise shows its effect only
after a round trip. To let the owner see its movement at once, register an input
stream with a fixed tick next to the field that the inputs advance:

```dart
final move = builder.addInput(
  const InputId('arena.player.move'),
  const IntCodec(min: -1, max: 1),
  tick: const Duration(milliseconds: 20),
);
final x = builder.addField(
  const FieldId('arena.player.x'),
  const DoubleCodec(min: 0, max: 2048),
);
```

On every peer, predict the field before synchronizing the entity, with a step
function that applies one input for one tick, and bind the prediction's
property:

```dart
double step(double x, int move) => (x + move * 4).clamp(0, 2048);

final prediction = attachment.predict(
  state: x,
  input: move,
  initial: spawnX,
  step: step,
  interpolator: const DoubleInterpolator(teleportDistance: 200),
);
attachment.synchronize([prediction.property()]);

// Every frame, after session.update():
final shown = entity.owner == session.localPeer
    ? prediction.advance(readMove(), elapsed)
    : prediction.presented;
```

- The owner calls `advance` every frame, also without input. Each whole tick
  numbers the input, applies `step`, and keeps the input until the host
  acknowledges it. `captureState` sends the inputs.
- The host applies each input once and in order during `update`, and reports
  the latest input it applied with the state it sends. It applies at most one
  tick of inputs per tick of its own clock after a short burst.
- When the host's state arrives, the owner resets to it and applies the inputs
  that the host has not applied yet again. A difference blends out over
  `smoothing` with the interpolator, or shows at once without one.
- Every other peer presents the host's state, interpolated by the prediction's
  interpolator.

`step` must return the same state on the host and the owner for the same state
and input. States and inputs pass through their codecs before each step, so a
quantized codec does not make them drift apart. With unreliable delivery, each
input message repeats the inputs that the host has not acknowledged, so the next
message repairs a lost one.

To change the state outside the step, such as to respawn a player, set it on
the entity's authority:

```dart
prediction.state = spawnX; // On the host.
```

The new state replicates as usual. The owner resets to it when it arrives and
applies its newer inputs again, so a jump that the interpolator treats as a
teleport shows at once.

The [prediction example](https://github.com/bszarlej/maratus/tree/master/examples/prediction)
runs a host and a client side by side over a simulated network with latency.

### Late inputs

By default, the host waits for late inputs: the entity stands still on the host
until they arrive, and the host then applies up to a quarter of a second of them
at once. To keep the entity moving instead, so that gravity or momentum still
act while the owner's connection stalls, pass the input that means no control:

```dart
final prediction = attachment.predict(
  // ...
  idleInput: 0, // As if the player let go of the controls.
);
```

Once the owner's inputs are more than a quarter of a second late, the host
applies `idleInput` for each further tick. When the late inputs then arrive
together, as they do over an unreliable channel, the host applies the newest
quarter of a second of them at once and skips the older ones, which the idle
ticks replaced. Either way, the owner's prediction corrects to the host's state.

### Limitations

- The step sees only the entity's state and one input. Anything else that it
  reads, such as a level captured in its closure, must be the same on the host
  and the owner. The owner does not predict interactions with other entities,
  such as collisions with moving objects: the host's state corrects them when
  it arrives.
- The host does not synchronize its clock with the owner's. Inputs that arrive
  faster than it applies them, from an owner whose clock runs fast or in a
  burst of more than a quarter of a second after a delay, wait on the host and
  delay the entity for the other peers for as long as the owner keeps sending.
  Beyond half a second, the host drops the oldest, and the owner's prediction
  corrects. An idle input avoids this after late inputs that arrive together.
- Prediction applies while the host is the entity's authority. An owner that
  becomes the authority continues from its prediction and applies its inputs
  directly; while another client is the authority, the owner's prediction
  pauses and follows that client's state.
- Prediction covers the entities a player controls; other entities are not
  rolled back.

## Delivery

RPCs and fields default to reliable delivery on channel zero. Optional
[`maratus_enet`](https://pub.dev/packages/maratus_enet) and
[`maratus_webrtc`](https://pub.dev/packages/maratus_webrtc)
transports also support unreliable delivery and independent channels:

| Mode | Behavior within a channel |
| ---- | ------------------------- |
| `DeliveryMode.reliable` | Ordered delivery while connected. |
| `DeliveryMode.unreliableOrdered` | Messages may be lost; messages older than the newest received one are discarded. |
| `DeliveryMode.unreliable` | Messages may be lost or reordered. |

Set `deliveryMode` and `channel` when registering an RPC, field, or input
stream. Configure both transport peers with enough channels, such as
`channelCount: 2` to use channel one. `host` and `join` reject transports that
cannot support the schema. WebSockets support only reliable channel zero.

Unreliable fields require `SyncMode.always`, so later samples can recover a lost
value even after it stops changing. Older state samples never overwrite newer
ones. Unreliable RPCs are not retried. Use separate channels for independent
streams: there is no global ordering across modes or channels.

Session control, spawning, authority transfers, initial state, and late-join
catch-up remain reliable on channel zero. Unreliable messages that arrive before
their required lifecycle changes are discarded; reliable messages wait within
`pendingDeliveryLimits` and the initialization timeout.

ENet and WebRTC limit unreliable messages to 1,000 encoded bytes, including the
session envelope. State groups are split when necessary; an individual field
that still cannot fit reports `PropertySyncFailed`. An oversized client RPC
throws `ArgumentError`; an oversized host delivery reports `RpcRejected`.

For deterministic tests, use `InMemoryNetwork` and `ManualClock`. Its optional
delivery modes, delays, and `dropNextUnreliable`/`delayNextUnreliable` controls
exercise connection behavior without real sockets.

## Admission and deployment

Hosts admit compatible clients by default. Set `session.onJoinRequest` to accept
or reject clients, optionally after checking credentials with your backend.
Register request data with `builder.setJoinRequest(codec)` and pass it to
`session.join(peer, request: data)`. Pending admission receives no replicated
world state. Set `session.admitting = false` to reject new join requests.

WebSocket hosting defaults to `127.0.0.1`. Bind to `0.0.0.0` for IPv4 LAN access,
allow the port through the firewall, and connect clients to the host's reachable
address. For HTTPS browser applications, provide a `wss:` endpoint, for example
through a TLS reverse proxy.

Desktop, Android, and iOS applications can host or join with all three transports.
Browsers can join over WebSockets and host or join over WebRTC. WebSocket and
ENet connections require a reachable host. See the WebRTC package guide for
signaling and STUN/TURN configuration.

## Protocol compatibility

Peers must use compatible protocol versions and identical schema fingerprints.
Explicit identifiers, codec descriptors, and delivery settings define the schema;
registration order does not matter. Generated and manual registrations can be
combined. Version custom codec descriptors when their wire meaning changes.

Sessions use binary encoding and batch state updates. Current binary format
version 2 cannot communicate with the earlier JSON or binary version 1 formats;
all peers must upgrade together. There is no wire-format fallback.

## License

[MIT](LICENSE).
