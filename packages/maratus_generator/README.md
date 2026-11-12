<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg">
    <img src="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg" alt="Maratus logo" width="300">
  </picture>
</p>

# maratus_generator

Generates [maratus](https://pub.dev/packages/maratus) protocol handles, entity
bindings, and value codecs from
[`maratus_annotations`](https://pub.dev/packages/maratus_annotations). Works
with pure Dart and Flame; Flame components also receive typed RPC senders.
Generated and hand-written handles can share a protocol schema.

## Installation

```sh
dart pub add maratus maratus_annotations dev:maratus_generator dev:build_runner
```

For the Flame example below:

```sh
flutter pub add maratus_flame maratus_annotations dev:maratus_generator dev:build_runner
```

## Generate and use bindings

Create `player.dart`. The host is the default authority for the player's score;
the owner can send an emote to every peer.

```dart
import 'package:flame/components.dart';
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:maratus_flame/maratus_flame.dart';

part 'player.g.dart';

@Networked(spawnType: 'arena.player')
final class Player extends Component with NetworkedComponent, _$Player {
  Player(@MaxLength(32) SpawnContext<String> context)
    : networkEntity = context.entity,
      name = context.data;

  @override
  final NetworkEntity networkEntity;

  final String name;
  String? lastEmote;

  @SyncedField('arena.player.score')
  @Range(min: 0, max: 10000)
  int score = 0;

  @RpcMethod(
    'arena.player.emote',
    caller: RpcCaller.owner,
    target: RpcTarget.all,
    local: RpcLocal.include,
  )
  void emote(@MaxLength(80) String text) => lastEmote = text;
}
```

Then generate `player.g.dart`:

```sh
dart run build_runner build
```

The generated part contains `PlayerNet` (handles and registration), `_$Player`
(bindings), and the `player.rpc` senders. Register the handles on every peer
before creating its session:

```dart
final builder = ProtocolSchemaBuilder();
PlayerNet.register(builder);
final session = MultiplayerSession(schema: builder.build());
```

Host or join with that session, then add a scope and spawner from your game's
`onLoad` on each peer:

```dart
await add(
  MultiplayerScope(
    session: session,
    children: [
      MultiplayerSpawner()..register(PlayerNet.spawnType, Player.new),
    ],
  ),
);
```

The scope drives the session and closes it when disposed. The spawner creates a
`Player` for each matching entity, and its generated members bind before
`onNetworkAttach` runs. On the host, spawn a player for a connected `peer`:

```dart
session.spawn(
  PlayerNet.spawnType,
  'Alex',
  owner: peer,
  onOwnerLeft: OwnerLeftPolicy.despawn,
);
```

On the owning peer, call `player.rpc.emote('Hello')` once the component is
attached and the session is ready. The return value reports whether the local
session accepted the call, not remote receipt or execution. Calling
`player.emote('Hello')` directly only invokes the local method.

See [maratus_flame](https://pub.dev/packages/maratus_flame) for session and
component lifecycle setup.

## Configure delivery

RPCs and fields default to reliable delivery on channel zero. For a field sent
over an unreliable channel:

```dart
@SyncedField(
  'arena.player.x',
  mode: SyncMode.always,
  deliveryMode: DeliveryMode.unreliableOrdered,
  channel: 1,
)
double x = 0;
```

Unreliable fields require `SyncMode.always` so later samples can repair packet
loss; initial snapshots remain reliable. `@RpcMethod` accepts the same
`deliveryMode` and `channel` arguments. ENet and WebRTC support unreliable
delivery with transport-specific channel configuration; WebSockets support
reliable channel zero only. See the core [delivery guide](https://pub.dev/packages/maratus#delivery).

## Declaration rules

- Use stable, explicit identifiers such as `arena.player.emote`. Renaming the
  Dart member does not change its identifier.
- `@Networked` and `@NetworkCodec` do not support generic classes. A spawn type
  needs exactly one constructor parameter of type `SpawnContext<T>`; its
  annotations select the spawn-data codec.
- Classes with annotated members must mix in `_$ClassName`. Import `maratus`
  or `maratus_flame` in the same library, without `show` or `hide`; import
  prefixes are supported.
- Built-in codecs cover `bool`, `int`, `double`, `String`, lists, and nullable
  types. Use `@Range` and `@MaxLength` for limits. Other types require
  `@NetworkCodec` or a const `@UseCodec`; custom codecs cannot be combined with
  those limit annotations.
- RPC handlers return `void`, `Future<void>`, or `FutureOr<void>`; they do not
  return a network response. At most one `RpcContext` parameter may receive
  delivery context. All payload parameters must be required.
- One payload parameter uses its codec directly. Zero or multiple parameters
  use a generated positional-list codec. Bump `@RpcMethod(version: ...)`
  (default 1) when their meaning or order changes without changing their codecs.
- `RpcTarget.peer` adds a required `to:` argument to the Flame sender.
- All annotated fields on a class share one synchronizer. Do not also call
  `synchronize` in `onNetworkAttach`. Received values use the field's setter,
  when available. Annotate a getter to synchronize an inherited property;
  provide a matching setter to apply incoming values. Read interpolated values
  through `networkSynchronizer`.

## Data codecs

In a library with a generated part, annotate each field that belongs on the wire:

```dart
@NetworkCodec('arena.move_input@1')
final class MoveInput {
  const MoveInput(this.x, this.y);

  @WireKey('x')
  @Range(min: -1, max: 1)
  final double x;

  @WireKey('y')
  @Range(min: -1, max: 1)
  final double y;
}
```

This generates `MoveInputCodec`. Decoding calls the unnamed constructor with
parameters matching the annotated field names; every required parameter must
have a matching `@WireKey` field. Wire keys stay stable when Dart fields are
renamed or reordered. The descriptor is used exactly as given: update its
version whenever the keys, field codecs, or their meaning change.

## Without Flame

Import `maratus`, annotate a plain Dart class, and mix in `_$ClassName`.
Register the generated handles in the same way. In your `session.bindSpawn`
callback, create the object, attach its entity with `session.attachEntity`, and
pass that attachment to the generated `bindNetworkMembers` method. Call it once
per attachment, with readiness and validity callbacks appropriate to the object.

Use `session.callRpc(entity, PlayerNet.emote, 'Hello')` to send calls; the
`player.rpc` extension is generated only for Flame components. Your game loop
must call `session.update()` before gameplay and `session.captureState()` after
gameplay, and close the session when finished. The [pure-Dart example](example/main.dart)
includes the complete host/client loop, spawn bindings, and cleanup.

## License

MIT. See [LICENSE](LICENSE).
