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

---

Godot-inspired multiplayer for Dart games: host-authoritative sessions, typed
RPCs, replicated spawning, selected property synchronization, and late joining
over WebSockets.

`maratus` has no Flutter dependency. It runs in Flutter apps, dedicated Dart
hosts, command-line tools, and browser tests. For [Flame](https://flame-engine.org)
games, [`maratus_flame`](https://pub.dev/packages/maratus_flame) adds scopes,
networked components, and a spawner on top of this package and re-exports it.

## Installation

```sh
dart pub add maratus
```

```dart
import 'package:maratus/maratus.dart';
```

## Compatibility

| Dependency | Supported versions |
| ---------- | ------------------ |
| Dart       | `>=3.11.0 <4.0.0`  |

## Concepts

| Concept                   | Role                                                                                                        |
| ------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `MultiplayerSession`      | One multiplayer world: hosting or joining, peer lifecycle, connection state, and message dispatch.          |
| `MultiplayerPeer`         | The transport a session runs over (WebSocket or in-memory), delivering byte messages and connection events. |
| `EntityAttachment`        | Connects a networked entity to the local object that represents it, with its RPC handlers and readiness.    |
| `MultiplayerSynchronizer` | Replicates explicitly selected properties from an entity's authority to the other peers.                    |
| `Rpc<T>`                  | A typed call addressed to a registered entity, with caller, destination, and local-execution policies.      |
| `ValueCodec<T>`           | Converts a value to and from its wire representation, validating values received from other peers.          |

Spawn types, RPCs, and synchronized properties are registered explicitly with
stable identifiers and codecs before connecting. Nothing is discovered by
reflection, and `runtimeType` is never used as a protocol identifier. Host and
clients must register the same schema; a mismatch fails the handshake. RPC
caller, destination, and local-execution policies are part of that schema.

### Values and codecs

Every value sent over the network passes through a `ValueCodec<T>`, which
converts it to a wire value and validates it when it is received. Built-in
codecs cover `bool`, `int`, `double`, `String`, lists, and nullable values,
with optional range and length limits. Custom types compose them:

```dart
class MoveInputCodec extends ValueCodec<MoveInput> {
  const MoveInputCodec();

  static const _axis = DoubleCodec(min: -1, max: 1);

  @override
  String get descriptor => 'game.move_input@1';

  @override
  Object? encode(MoveInput value) =>
      {'x': _axis.encode(value.x), 'y': _axis.encode(value.y)};

  @override
  MoveInput decode(Object? wire) {
    final object = WireObject(wire, const {'x', 'y'});
    return MoveInput(object.read('x', _axis), object.read('y', _axis));
  }
}
```

A codec's `descriptor` names its wire representation and is part of the schema
fingerprint, so change its version whenever the representation changes. RPC
payloads cross the codec and wire-validation boundary even for host-local calls.
Integers are limited to ±(2^53 - 1) so that web clients represent them exactly,
and numbers must be finite.

Messages travel as compact UTF-8 JSON. The protocol codec rejects a received
message with a `ProtocolException` before any handler runs if it exceeds
64 KiB, 32 levels of nesting, or 1,024 elements in a list or object, uses
another protocol version, refers to unregistered identifiers, or contains
values that its codecs reject.
A session converts that rejection into a disconnect reason.

### Topology

A session has exactly one **host** and any number of **clients**, connected in
a star:

```text
client A ──┐
client B ──┼── host (native app or dedicated Dart process)
client C ──┘
```

- The host is a peer in the game: it runs the authoritative simulation and can
  have its own local player.
- Clients connect only to the host. Client-to-client messages, including RPCs
  between clients, are routed through and validated by the host.
- The host assigns each connection a peer ID. The host's own ID is fixed;
  client IDs are unique within a session and are never reused for a different
  connection.
- Clients are untrusted. The host derives a message's sender from the
  connection it arrived on, never from a claimed ID in the payload, and
  validates every payload before dispatch.

### Authority and ownership

Every networked entity has two independent properties:

- **Authority** is the peer whose copy of the entity is the source of truth. It
  writes synchronized properties and decides the entity's lifecycle. Other
  peers apply its updates and reject state from anyone else.
- **Ownership** is the peer that controls the entity's input. It is the peer
  permitted to call owner-only RPCs, such as movement input on its avatar.

A typical avatar has the host as authority and its player as owner: the client
sends input, the host simulates and replicates the result. Spawning and
replicated state are host-controlled, and an entity's authority is set when it
is spawned and fixed for its lifetime.

### Connection states

A transport connection is not the same as being ready to play.
`SessionState` describes the local host or client's lifecycle:

| State           | Meaning                                                                                                 |
| --------------- | ------------------------------------------------------------------------------------------------------- |
| `disconnected`  | No connection. Initial and final state.                                                                 |
| `connecting`    | Opening the transport to the host.                                                                      |
| `handshaking`   | Transport open. Protocol version and schema fingerprint are being checked; awaiting a host-assigned ID. |
| `synchronizing` | Accepted. Installing the host's baseline of entities and state while later changes keep arriving.      |
| `ready`         | The baseline is installed and acknowledged. Gameplay messages can be exchanged.                        |
| `hosting`       | Accepting clients and tracking each client's readiness.                                                |

Calling `close()` moves the local session directly to `disconnected` and
closes its transport. Remote peers observe that close during `update()`.
Every return to `disconnected` carries a reason, such as a local close,
host shutdown, version or schema mismatch, timeout, failed bootstrap,
transport error, or protocol violation. A host moves from `disconnected` to `hosting` and tracks
each client through the handshake, synchronization, and ready stages.

Disconnecting clears the entity registry and marks its existing entries
removed. Rejoining starts a fresh connection with a new peer ID and
connection generation, even when it rejoins the same hosting session.
Messages carrying an old generation are discarded.

### Sessions

Create a schema, then give each `MultiplayerSession` its own transport peer.
The session owns that peer and closes it when the session disconnects. This
example drives an in-memory host and client without real-time delays. It
registers matching static entities and sends owner-only input to the host:

```dart
import 'package:maratus/maratus.dart';

void main() {
  final builder = ProtocolSchemaBuilder();
  final move = builder.addRpc(
    const RpcId('player.move'),
    const IntCodec(min: -1, max: 1),
    caller: RpcCaller.owner,
    target: RpcTarget.host,
    local: RpcLocal.include,
  );
  final schema = builder.build();
  final clock = ManualClock();
  final network = InMemoryNetwork(clock: clock);
  final host = MultiplayerSession(schema: schema, clock: clock)
    ..host(network.host());
  final client = MultiplayerSession(schema: schema, clock: clock)
    ..join(network.connect());

  void pump() {
    // Each update consumes arrivals; the next advance delivers replies.
    for (var i = 0; i < 6; i++) {
      clock.advance(Duration.zero);
      host.update();
      client.update();
    }
  }

  try {
    pump();
    assert(client.state == SessionState.ready);
    assert(host.isReady(client.localPeer!));

    // Static setup: each peer registers the same ID and ownership metadata.
    final hostEntity = host.registry.create(
      owner: client.localPeer!,
      authority: PeerId.host,
    );
    final clientEntity = client.registry.register(
      hostEntity.id,
      owner: hostEntity.owner,
      authority: hostEntity.authority,
    );
    var position = 0;
    host.bindRpc(hostEntity, move, (context, direction) {
      assert(context.sender == hostEntity.owner);
      assert(context.target == PeerId.host);
      position += direction;
    });
    host.registry.markReady(hostEntity.id);
    client.registry.markReady(clientEntity.id);

    final queued = client.callRpc(clientEntity, move, 1);
    assert(queued);
    assert(position == 0);
    pump();
    assert(position == 1);
  } finally {
    client.close();
    host.close();
  }
}
```

Call `update()` regularly to consume transport events, advance the handshake,
and enforce `SessionTimeouts`. The defaults allow 10 seconds for connecting
and handshaking, and 30 seconds for the bootstrap, which includes loading the
components of the baseline; both durations must be positive. Queued events
and a joining client's completed installation are processed before timeouts
are checked, so they take precedence even after a deadline. In tests, advance
the same `ManualClock` used by the network and sessions; in an application,
call `update()` in the game loop. Starting, closing, and kicking a peer take
effect when those methods are called.

Read lifecycle events with `poll()` until it returns `null`. Clients report
`SessionStateChanged`; hosts also report `PeerJoined`, `PeerReady`, and
`PeerLeft`. A joined peer may still be synchronizing: use `isReady(peer)` or
wait for `PeerReady` before sending gameplay messages.

The session's `onMessage` callback observes accepted state messages during
`update()`, after entity and authority validation. The session retains their
values and applies them through bound synchronizers; the callback can inspect
traffic without applying state itself. Its sender is derived from the
connection, so clients observe the host as the sender of relayed state.
Calling `update()` or `captureState()` recursively, from each other, or from
an RPC or spawn handler throws a `StateError`. Handshake messages are managed
by the session. Spawning and despawning use `spawn()` and `despawn()`, RPCs use
`callRpc()`, and properties use `EntityAttachment.synchronize()`.

Three values distinguish session identity and message ordering:

- **Epoch:** a new hosting run chooses a new epoch; connected clients learn
  it from the host. Peer and entity IDs are scoped to that run.
- **Generation:** the host assigns a generation to each accepted connection.
  A message with another generation is discarded before game dispatch.
- **Revision:** the host advances it automatically for each replicated spawn,
  despawn, or state message, including accepted state relayed from a client
  authority. After the baseline, clients accept those messages only when
  their revision exceeds the last applied revision. RPC messages do not
  advance that counter. Applications do not allocate revisions or send raw
  state messages.

The session bootstrap establishes a revision barrier. Its baseline holds the
replicated entities and retained property values that exist when the host
welcomes the client; see [Late joining](#late-joining). Static entity
identities registered directly in `registry` must be registered on each peer
separately. Registering an entity records its ID, owner, and fixed authority
locally.
It starts `pending`, becomes `ready` through `markReady()`, and can be
`removed` without allowing its ID to be reused in that session. A pending
entity that was removed cannot become ready after asynchronous loading
finishes.

### Typed RPCs

`ProtocolSchemaBuilder.addRpc<T>()` returns the `Rpc<T>` handle used with
`bindRpc()` and `callRpc()`. Retain that handle: a separately constructed
handle with the same ID cannot replace the registered codec or permissions.
Each peer registers its definitions before connecting. Matching identifiers,
codec descriptors, and policies produce the same fingerprint regardless of
registration order.

Permission to call and destination are separate choices:

| Setting | Choices |
| ------- | ------- |
| `RpcCaller` | `anyPeer` (default), `owner`, `authority`, or `host` |
| `RpcTarget` | `host` (default), `owner`, `authority`, `all`, or `peer` |
| `RpcLocal` | `exclude` (default) or `include` |

Caller policies are evaluated against the host's authenticated sender and
the addressed entity's metadata. `RpcTarget.all` selects the host and ready
clients; joining clients receive no calls until they are ready, as described
in [Late joining](#late-joining). `RpcTarget.peer` requires
`callRpc(..., peer: peerId)`; other target modes reject an explicit peer. A
specific destination must exist and be ready. For example, owner-only input
can target the host, while a host-only effect can target all peers.

`RpcLocal.include` allows the caller to execute only when it is among the
selected destinations; `exclude` removes it from those destinations. Host-local
calls use the same permission and payload validation as remote calls. Clients
always send through the host and wait for its routed delivery before executing
their own call. There is no optimistic local invocation or duplicate echo.
Unattached host-local handlers run inside `callRpc()`; received handlers run
during `update()`. Attached component handlers always wait for `update()`,
including host-local calls.

Handlers receive an immutable `RpcContext` containing the entity and method
IDs, original sender, executing target, owner, authority, and session epoch.
Client-to-client delivery preserves the original sender authenticated by the
host. Context metadata remains a snapshot if the entity is later removed or
the session ends.

`callRpc()` returns a `bool`, describing local queue or dispatch acceptance.
A client's `true` means its request was queued; the host or recipient may
still reject it. On the host, every selected delivery must be accepted for
`true`, but a broadcast can partially enqueue before returning `false`.
Selecting no destinations also returns `false`. There is no remote
acknowledgement or returned gameplay result.

Bind handlers to matching static entities as above, or to replicated entities
from their spawn handlers and components. A pending entity may have a binding,
but calls execute only when it is ready. Disposing the returned `RpcBinding` removes its handler;
entity removal and session shutdown invalidate bindings. Unknown, removed, or
unattached pending entities, missing handlers, denied callers, and invalid destinations
are rejected. Well-formed rejected calls produce local `RpcRejected` events;
malformed protocol messages or unregistered method IDs disconnect the sender.
Neither diagnostic is a remote acknowledgement. Foreign RPC handles and
payloads that fail local codec or wire validation throw `ArgumentError`.

A handler may return `void` or `Future<void>`. Synchronous exceptions and
asynchronous failures produce `RpcHandlerFailed` events without stopping later
calls. The dispatcher does not await asynchronous handlers, so their completion
order is not guaranteed. Closing a session does not cancel application work
already started by a handler; its asynchronous side effects remain the
application's responsibility. Failures completing after the session ends are
consumed without adding events to a later session. Session control and spawning
messages do not depend on public RPCs.

### Replicated spawning

The host creates replicated entities, and every peer creates their local
representation. Register each spawn type with a codec for its construction
data. The data is sent once, when the entity spawns, and is independent of
synchronized fields:

```dart
final builder = ProtocolSchemaBuilder();
final avatarType = builder.addSpawnType(
  const SpawnTypeId('game.avatar'),
  const IntCodec(min: 0, max: 5), // The color the host chose.
);
```

Every peer binds handlers that create and release the local representation of
a spawn type's entities:

```dart
final avatars = <NetworkEntity, Avatar>{};
session.bindSpawn(
  avatarType,
  onSpawn: (context) {
    avatars[context.entity] = Avatar(color: context.data);
    // A joining client waits until the entities of its baseline are ready.
    session.registry.markReady(context.entity.id);
  },
  onDespawn: avatars.remove,
);
```

In Flame, `MultiplayerSpawner` from
[`maratus_flame`](https://pub.dev/packages/maratus_flame) creates and removes
components this way.

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

`spawn()` allocates the entity ID and a replication revision, sends a spawn
record with the owner, authority, optional parent, and construction data to
every joined client, and returns the host's entity. Only the host spawns: a
client that calls `spawn()` or `despawn()` gets a `StateError`, and a client
that sends spawn or despawn records is disconnected for a protocol violation.
The owner must be the host or a joined client. The authority, fixed for the
entity's lifetime, must be the host or the owner. Invalid metadata, foreign
handles, and construction data that fails its codec throw `ArgumentError`
without spawning anything.

A `parent` must be another replicated entity. Despawning an entity also
despawns its descendants on every peer, with a single record; despawn handlers
run for children before their parents. `despawn()` returns `false` and sends
nothing for an entity that was already removed, so reacting to a despawn by
despawning again cannot echo it. Releasing a local representation, such as a
component, never despawns its entity.

`OwnerLeftPolicy` configures what happens when a client owner leaves, whether it
closes, is kicked, times out, or loses its connection. `keep`, the default,
leaves the entity with its original metadata; peer IDs are never reused within
a session, so its owner-only RPCs can no longer be called. `despawn` removes
it and its descendants for the remaining peers. A host that closes ends the
session for everyone without sending despawn records.

Clients apply spawn and despawn records in revision order and validate them.
A record that reuses a registered entity ID, names an unknown or unreplicated
parent, gives authority to a peer other than the host or the owner, or
despawns an entity that was not spawned is a protocol violation. A replayed
record with an obsolete revision is ignored. A joining client receives every
live entity, parents first, between the welcome and the end of
synchronization. It then receives every later spawn and despawn, including
those made while it is still synchronizing. Static and spawned entities share
the session's ID space, so register static entities with the same IDs on every
peer before spawning.

`onSpawn` and `onDespawn` handlers each receive their own copy of the
construction data. A binding is told about the entities that exist when it is
created, then about every spawn and despawn, including the end of the session.
Bindings survive session restarts until they are disposed. Handler exceptions
produce `SpawnHandlerFailed` events. A joining client becomes ready only once
the entities of its baseline are ready, so handlers must attach those entities
or mark them ready; see [Late joining](#late-joining).

### Property synchronization

Register fields before building the shared schema, retaining their typed
`SyncField<T>` handles:

```dart
final healthField = builder.addField(
  const FieldId('game.avatar.health'),
  const IntCodec(min: 0, max: 100),
);
```

Each peer attaches the entity to its local object and binds the same selected
properties:

```dart
var health = 100;
final attachment = session.attachEntity(
  entity,
  // Whether the local object can take part in gameplay, such as after loading.
  isReady: () => true,
  // Whether the attachment still belongs to the local object's lifetime.
  isValid: () => true,
);
final synchronizer = attachment.synchronize([
  healthField.property(get: () => health, set: (value) => health = value),
], interval: const Duration(milliseconds: 50));
```

`field.property()` creates a typed `SyncProperty<T>` with its field ID,
codec, getter, optional setter, and update mode. Only the entity's authority
samples its getters; other peers apply incoming values through their setters.
Prefer this helper inside heterogeneous property lists, or provide an
explicit type argument to `SyncProperty<T>()`. A live entity has one
synchronizer, with no repeated field IDs. Foreign field handles, empty
property lists, and nonpositive intervals are rejected.

Every field sends an initial value on its authority's first eligible capture.
`SyncMode.onChange`, the default, then sends only values whose encoding has
changed. `SyncMode.always` sends at every interval, even if unchanged. The
default interval is 50 milliseconds. Cadence uses the session's monotonic
clock, independently of render frequency; repeated captures before a deadline
do nothing, and resuming after a pause does not produce a burst of missed
samples. The first capture and later samples require a ready attachment and
a hosting or ready session.

The codec's encoded bytes define both the saved sample and equality. Custom
codecs should produce a consistent representation and decode into fresh
values. Mutable values, including vectors encoded by a custom codec, are
copied through serialization: changing a live vector cannot rewrite an earlier
sample. Each changed field sends its complete value. Fields due together are
combined when the message fits the wire limits, otherwise sent separately;
cross-field atomicity is not guaranteed. A field too large for its own message
produces a `PropertySyncFailed` event.

`synchronizer.snapshot(field)` returns a `SyncSnapshot<T>?` with a fresh value
copy and its local send or receive time on the session clock. The authority's
snapshot is its last sampled value sent; a receiver's is its latest accepted
value. Setters receive separate copies, so presentation changes do not alter
the retained authoritative state. Omit a property's setter when presentation
code will read snapshots itself. Interpolation remains application code;
built-in visual smoothing is planned for a later milestone.

The host validates every client write against the entity's fixed authority
and relays accepted state to the other clients. Clients apply state only from
their host connection and never overwrite entities they themselves author.
Unknown entities and unauthorized writers produce `StateRejected` events;
obsolete revisions and late updates for removed entities are ignored.
Malformed payloads still disconnect the sender. Applying received values
never samples or sends properties, preventing replication feedback loops.
Getter, codec, and setter failures produce `PropertySyncFailed` events without
preventing unrelated fields from synchronizing. A setter is attempted once per
distinct received value, including when it throws; it runs again when the value
changes or a replacement synchronizer binds. Repeated unchanged periodic
updates refresh snapshots without invoking the setter again.

Received state is retained even while the local object loads. Once its attachment
is ready, the next `update()` applies the latest values before queued component
RPCs run. Disposing an attachment also disposes its synchronizer; a replacement
attachment can bind again and receive the retained state. Despawning forgets
that entity's snapshots, and closing clears all session state.

A joining client receives live spawn records followed by the host's retained
property values, and applies those values as each attachment becomes ready,
before the client reports ready. Register matching static entities on each
peer after starting its session and before processing incoming state.

Call `session.update()` before gameplay, then `session.captureState()`
afterward. In Flame, `MultiplayerScope` from `maratus_flame` performs both
steps automatically.

### Late joining

A client can join while the game is running. The host welcomes it with a
baseline at the host's current revision: every live replicated entity, parents
first, followed by the retained values of synchronized properties. Every change
after that revision follows in order, including changes made while the client
is still joining, so nothing is lost between the baseline and gameplay.

The client stays `synchronizing` while it installs the baseline. It applies
later spawn, despawn, and state records as they arrive, and reports ready only
once every live entity of the baseline is ready: when the spawn handler has
attached the entity and its attachment reports ready, or the handler has called
`registry.markReady()`. In Flame, that is when the component created by a
`MultiplayerSpawner` has mounted. Values are applied to an entity's
synchronizer as soon as its attachment is ready, so the baseline state is in
place before the client reports ready. A baseline entity despawned
in the meantime stops delaying readiness, and entities spawned after the
baseline load like any spawn during gameplay. Static entities registered
directly in `registry` are not part of the baseline.

The ready report acknowledges the latest revision the client has applied,
which can be later than its baseline. The host accepts any revision it has
sent since that baseline and then reports `PeerReady`. While joining,
`pendingBaselineCount` counts the baseline entities that are not ready yet,
for example to show progress on a loading screen until `SessionState.ready`.

RPCs are transient: they reach a joining client only after the host has
received its ready report. A broadcast skips clients that are still
synchronizing, a call addressed to one is rejected with `invalidTarget`, and
earlier calls are never replayed. Keep anything a late joiner must know in
construction data or synchronized properties, such as the health that remains
after a hit, and use RPCs for momentary effects, such as the hit's sound. A
synchronizing client cannot call RPCs, and it disconnects a host that delivers
one early.

The bootstrap is bounded in time and memory. `SessionTimeouts.bootstrap`
limits how long a client may take from its welcome to its ready report,
including loading, and the host applies its own bootstrap timeout to each
joining client. The session keeps no backlog of its own: the baseline and later
changes travel through the transport's bounded queues (`QueueLimits`), and the
client applies them as they arrive, retaining only the latest value of each
field while a component loads. A client that stops updating while it joins
eventually overflows a queue, which closes its connection, instead of
accumulating changes.

If the spawn handler of a baseline entity throws before that entity is ready,
for example because a spawner's factory fails, the client cannot install a
complete world. It reports `SpawnHandlerFailed`, then disconnects with
`DisconnectReason.bootstrapFailed` instead of waiting for its timeout, and the
host reports `PeerLeft` with the same reason. Setter failures remain
`PropertySyncFailed` diagnostics. A client that leaves before it is ready,
whether its bootstrap fails, times out, or loses its connection, releases every
entity it installed and their components are removed, so no partial world
remains. The host applies the departed client's `OwnerLeftPolicy` as for any
departure.

To retry, call `join()` again with a new transport. Each attempt starts a fresh
bootstrap with a new peer ID and connection generation and receives a complete
baseline; nothing is resumed from the earlier attempt, and messages addressed
to the old connection cannot reach the new one. In Flame, a
`MultiplayerScope` keeps driving its session across attempts, and its spawners
create components for the new baseline. Retrying is the application's decision: a factory that
always fails will fail again.

### Transports

A `MultiplayerPeer` is the local end of a transport: a host that accepts
connections, or a client with one connection to its host. Each connection is
a `PeerConnection` that carries byte messages. Everything a peer observes (a
connection opening, a message arriving, a connection closing) waits as an
event until it is taken with `poll()`. Network activity is therefore handled
at a fixed point in each update instead of in callbacks.

- **Delivery.** Each message arrives exactly once, in the order it was sent,
  unless its connection closes first. A transport's `TransportCapabilities`
  state whether it can host on the current platform and which delivery modes
  and channels it supports. Sending with any other mode or channel throws an
  `UnsupportedError`.
- **Closing.** When one side closes a connection, the messages it already
  sent are still delivered, and the other side then reports the connection
  closed. Messages that the closing side has not polled yet are discarded.
  Closing again has no effect, and sending on a closed connection returns
  `false`. Closing a peer closes all of its connections and discards its
  pending events.
- **Queue limits.** Each connection limits how many messages, and how many
  bytes, can wait to be polled and wait to be delivered (`QueueLimits`). A
  reliable connection cannot drop a message, so when a message does not fit,
  the connection closes with `CloseReason.overflow`. The current queue sizes
  are available as `incoming` and `outgoing`.

### WebSocket connections

Use the same registered schema on the host and clients. A native host starts
listening before the session begins:

```dart
final transport = await WebSocketHost.bind(
  address: '0.0.0.0',
  port: 8080,
  path: '/netcode',
);
final session = MultiplayerSession(schema: schema)..host(transport);
```

Native and browser clients use the same joining API:

```dart
final transport = WebSocketClient.connect(
  Uri.parse('ws://192.168.1.20:8080/netcode'),
  connectTimeout: const Duration(seconds: 10),
);
final session = MultiplayerSession(schema: schema)..join(transport);
```

Drive `session.update()` from a game loop, or through a `MultiplayerScope` in Flame,
and consume its events with `session.poll()`. Joining returns immediately while
the socket opens;
wait for `SessionState.ready` before sending gameplay RPCs. The
[host/join example](https://github.com/bszarlej/maratus/tree/master/examples/chat) exchanges typed messages using the public
API and includes native and browser run instructions.

The session owns its transport. To stop and await the transport's asynchronous
cleanup, retain that transport reference:

```dart
session.close();
await transport.done;
```

Closing is idempotent. `done` covers listener shutdown, pending connection
cancellation, subscriptions, and bounded native socket cleanup. Native close
waits up to five seconds for the socket to drain. Browser close removes the
adapter's handlers and timers immediately; the browser completes its network
closing handshake independently. Cleanup completion does not acknowledge
remote gameplay execution.

#### Reachability and errors

The default listener address, `127.0.0.1`, accepts clients on the same machine.
For LAN play, bind `0.0.0.0` and connect to the host's LAN address, such as
`192.168.1.20`. A client must never use `0.0.0.0` as its destination;
`localhost` refers to the machine running that client. Allow the chosen TCP
port through the host's firewall. For internet clients, provide a reachable
public endpoint or configure routing and port forwarding yourself. The package
does not provide NAT traversal, relays, or browser hosting.

`WebSocketHost.bind()` fails with an exception if binding is unavailable, for
example when the port is already in use. Check `WebSocketHost.isSupported`
before offering a Host control in a browser app. Invalid addresses, ports, or
client URL arguments fail at setup; network connection failures arrive through
the transport's event queue. After `session.update()`, inspect
`SessionStateChanged.reason` or `session.disconnectReason`:

| Reason | Typical cause |
| ------ | ------------- |
| `transportError` | Refused connection, opening deadline, wrong endpoint path or subprotocol, TLS/browser rejection, lost connection, malformed transport frame, or queue overflow. |
| `timeout` | The session's own connecting, handshake, or bootstrap deadline expired, for example while the baseline's components were still loading. |
| `bootstrapFailed` | A spawn handler, such as a spawner's factory, failed for an entity of the joining client's baseline. |
| `schemaMismatch` / `versionMismatch` | The peers registered different definitions or use incompatible protocol versions. |
| `protocolViolation` | A received session message failed protocol validation. |
| `remoteClosed` | The other participant closed normally, including a host shutting down. |

Hosts receive `PeerLeft.reason` for clients that had joined. Browser errors
deliberately provide little network detail; use the browser console and the
host or proxy logs to distinguish an unreachable host from certificate or
policy rejection. Rejoining requires creating a new `WebSocketClient`.

#### Secure WebSockets

Use `ws://` for local development and `wss://` for encrypted connections.
An HTTPS-served browser app normally requires `wss://` with a trusted certificate
for the endpoint's hostname. Browser content-security and network-access
policies also apply. The native listener accepts plain WebSockets; terminate
TLS at a reverse proxy and keep its backend listener on loopback.

For example, an nginx `server` block inside its `http` configuration can expose
`wss://game.example.com/netcode` while forwarding to a native host bound to
`127.0.0.1:8080`. Replace the hostname and certificate paths with your own:

```nginx
server {
    listen 443 ssl;
    server_name game.example.com;
    ssl_certificate /etc/ssl/game/fullchain.pem;
    ssl_certificate_key /etc/ssl/game/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location = /netcode {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

Forward the WebSocket upgrade headers and preserve the endpoint path. Set the
proxy's idle timeout to suit your application's expected quiet periods; the
adapter does not send periodic keepalive messages. An idle connection can
therefore close when that timeout expires. See nginx's
[WebSocket proxying](https://nginx.org/en/docs/http/websocket.html) and
[HTTPS configuration](https://nginx.org/en/docs/http/configuring_https_servers.html)
documentation.

#### Queues and wire format

Both directions default to 1,024 queued messages and 4 MiB of payload bytes
per connection. Pass `incomingLimits` and `outgoingLimits` to the host or client
to change them. The host's `maxConnections` defaults to 64 and also bounds
closed connections whose lifecycle events have not been polled. These are
resource limits, not player-capacity guarantees.

Incoming payloads remain counted until `poll()` removes them. Outgoing payloads
remain counted until the receiver polls them and its transport acknowledgement
arrives. This prevents a sender from handing an unlimited backlog to the socket
when the receiving game stops updating. `session.update()` polls its transport
automatically; applications should not also poll that transport themselves.
If either queue fills, the connection closes instead of dropping a reliable
message. `PeerConnection.send()` and `session.callRpc()` report only local
acceptance: a transport acknowledgement does not mean a handler ran or returned
a result.

The adapters require the `maratus-v1` WebSocket subprotocol and binary
frames. Each payload has a five-byte transport header; polling sends a separate
five-byte acknowledgement. Queue byte counters cover payloads, excluding these
headers and WebSocket framing. Text frames, invalid frame tags, and unexpected
sequence numbers close the connection. Only reliable delivery on channel zero
is supported; unreliable modes and independent-channel requests throw
`UnsupportedError`.

Queue limits bound the payloads retained by this adapter. They do not bound
every allocation made by the operating system, Dart SDK, or browser: these
layers can buffer socket data, and an oversized WebSocket frame may be assembled
before the adapter can reject it. The session's protocol limits still apply
after transport framing is removed.

## Platform support

| Platform | WebSocket host | WebSocket client |
| -------- | -------------- | ---------------- |
| Windows, macOS, Linux | Native adapter | Native adapter |
| Web browser | Not supported | Browser adapter |
| Android, iOS | Outside the support matrix | Outside the support matrix |

The native adapters use `dart:io`; the browser adapter uses `package:web` through
conditional imports. Browser builds do not import the native implementation.

### Limitations

- Reliable, ordered delivery over WebSockets (`ws://` or `wss://`), plus an
  in-memory transport for tests. Requests for unreliable or unordered delivery
  or independent channels are rejected.
- Clients must be able to reach the host directly. NAT traversal and relays
  are not provided.
- Peer identities are assigned by the host. Player accounts and authentication
  are left to the application.
- Sessions are not resumed. Rejoining starts a fresh bootstrap with a new peer
  ID, so an application that wants a player to keep their entities must
  transfer them itself.
- Authority is fixed. Authority transfer, client-side prediction,
  reconciliation, and rollback are not provided. Interpolation is application
  code; snapshots keep presentation separate from authoritative state.
- No interest management or state compression: every client receives every
  replicated entity.
- Sessions are intended for small player counts, such as 2-4 players. No
  capacity guarantees are made.

## Testing multiplayer code

`InMemoryNetwork` connects peers within one process. Each client reaches the
host over a link with a latency, and deliveries are timers on an injected
`MonotonicClock`. With a `ManualClock`, nothing arrives until the test
advances the clock, so tests are deterministic and never sleep:

```dart
final clock = ManualClock();
final network = InMemoryNetwork(
  clock: clock,
  latency: const Duration(milliseconds: 20),
);
final host = network.host();
final client = network.connect();

clock.advance(const Duration(milliseconds: 40)); // One round trip.
final event = host.poll(); // ConnectionOpened

client.link.latency = const Duration(milliseconds: 200); // A latency spike.
client.link.disconnect(); // A network failure.
```

In-memory links deliver reliably and in order. They do not simulate loss or
reordering.

## License

MIT. See [LICENSE](LICENSE).
