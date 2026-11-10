<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg">
    <img src="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg" alt="Maratus logo" width="300">
  </picture>
</p>

<p align="center">
  Generates <a href="https://pub.dev/packages/maratus">maratus</a> multiplayer code from annotations.
</p>

---

# maratus_generator

Declare RPC handlers, synchronized fields, spawn types, and data codecs with
[`maratus_annotations`](https://pub.dev/packages/maratus_annotations), much like
Godot's `@rpc`, and let `build_runner` write the rest:

- Const protocol handles and a function that registers them, with the same
  codecs and schema fingerprint as hand-written registration.
- A mixin that binds each annotated method and field to its entity.
- Typed senders for Flame components: `player.rpc.hit(25)`.
- `ValueCodec`s for data classes.

Generated and hand-written registrations mix freely in one schema.

## Install

```sh
dart pub add maratus maratus_annotations dev:maratus_generator dev:build_runner
```

In a Flame game, add `maratus_flame` instead of `maratus`, with `flutter pub add`.

## Annotate a component

```dart
import 'package:flame/components.dart';
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:maratus_flame/maratus_flame.dart';

part 'player.g.dart';

const arenaPoint = Vector2Codec(
  x: DoubleCodec(min: 0, max: 1920),
  y: DoubleCodec(min: 0, max: 1080),
);

@Networked(spawnType: 'arena.player')
final class Player extends PositionComponent
    with NetworkedComponent, _$Player {
  Player(@Range(min: 0, max: 3) SpawnContext<int> context)
    : networkEntity = context.entity,
      lane = context.data;

  @override
  final NetworkEntity networkEntity;

  final int lane;

  /// Written by the player's authority, the host, and sent to every peer.
  @SyncedField('arena.player.health')
  @Range(min: 0, max: 100)
  int health = 100;

  /// Host → everyone, the host included: a momentary effect.
  @RpcMethod(
    'arena.player.hit',
    caller: RpcCaller.host,
    target: RpcTarget.all,
    local: RpcLocal.include,
  )
  void hit(@Range(min: 1, max: 100) int damage) => add(HitFlash(damage));

  /// Owner → host: a request the host checks.
  @RpcMethod('arena.player.fire', caller: RpcCaller.owner)
  void fire(
    @UseCodec(arenaPoint) Vector2 at,
    @Range(min: 0, max: 3) int weapon,
    RpcContext context, // optional; filled in on delivery, never sent
  ) {
    // Fire from the player's position toward `at`.
  }
}
```

Then generate `player.g.dart`:

```sh
dart run build_runner build
```

## Use the generated code

Register the handles on every peer, next to any hand-written registrations:

```dart
final builder = ProtocolSchemaBuilder();
PlayerNet.register(builder);
builder.addRpc(
  const RpcId('arena.chat'),
  const StringCodec(maxLength: 240),
  target: RpcTarget.all,
);
final schema = builder.build();
```

Spawn players through their spawn type:

```dart
MultiplayerSpawner()..register(PlayerNet.spawnType, Player.new);
session.spawn(PlayerNet.spawnType, 2, owner: peer);
```

Each attachment binds the annotated members before `onNetworkAttach` runs, so
calls arrive at the methods and `health` follows the host. Call RPCs through
the typed senders, which return whether the session accepted the call:

```dart
player.rpc.hit(25); // On the host: everyone sees the hit.
player.rpc.fire(target, 2); // On the owner: ask the host to fire.
player.hit(25); // A plain call runs locally, without the network.
```

The handles also work without components:
`session.callRpc(entity, PlayerNet.hit, 25)`.

## Configure delivery

Annotations accept the same `deliveryMode` and `channel` settings as
hand-written RPC and field handles. Both default to reliable channel zero:

```dart
@RpcMethod(
  'player.input',
  deliveryMode: DeliveryMode.unreliableOrdered,
  channel: 1,
)
void input(int direction) => this.direction = direction;

@SyncedField(
  'player.x',
  mode: SyncMode.always,
  deliveryMode: DeliveryMode.unreliableOrdered,
  channel: 2,
)
double x = 0;
```

Unreliable fields require `SyncMode.always`; generation rejects `onChange`
because a lost final change would never be sent again. Initial snapshots
remain reliable. Configure an ENet peer with enough channels (`channelCount: 3`
here) on both ends. WebSockets support reliable channel zero only. The generated
schema fingerprint includes delivery settings.

## Rules

- **Identifiers are explicit.** Renaming a method or field never changes the
  protocol. Identifiers follow the rules of `ProtocolSchemaBuilder`, such as
  `arena.player.hit`.
- **Every value needs a codec.** `bool`, `int`, `double`, `String`, lists, and
  nullable types take one from their type, limited by `@Range` and
  `@MaxLength`. A class with `@NetworkCodec` uses its generated codec. Any
  other type needs `@UseCodec`, which takes a const codec. A missing codec is
  a build error that names the value.
- **A single parameter is the payload itself,** so its codec matches
  hand-written code exactly. Several parameters, or none, travel as a
  positional list with a generated codec. Its descriptor carries the RPC's
  identifier, a `version:` (default 1), and the parameters' codecs. Bump the
  version when the meaning of the parameters changes but their codecs don't,
  such as when two `int` parameters swap places.
- **Handlers return `void` or `Future<void>`.** Nothing comes back over the
  network, as with `callRpc`. An `RpcContext` parameter is optional: at most
  one, filled in on delivery and never sent. Other parameters are required.
- **`RpcTarget.peer`** gives the sender a required `to:` parameter.
- **A class's synchronized fields share one synchronizer.** Don't call
  `synchronize` in `onNetworkAttach` for a class with `@SyncedField` members.
  A field's setter, or a getter's setter of the same name, applies received
  values. Annotate a getter to synchronize an inherited value, such as
  `position`, and read interpolated values from `networkSynchronizer`.
- **Mix in `_$ClassName`** in any class with `@RpcMethod` or `@SyncedField`
  members, and import `maratus` or `maratus_flame` in its library, with or
  without a prefix but without a `show` or `hide` combinator.

## Generate codecs for data classes

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

This generates `MoveInputCodec`, identical to a hand-written codec that composes
the same codecs with `WireObject`. Fields travel under their explicit wire keys,
so renaming or reordering them never changes the wire format. The descriptor is
exactly the given one: change its version whenever the fields change.

## Without Flame

Any class can be `@Networked`. Bind its members through the attachment of its
entity yourself:

```dart
session.bindSpawn(
  AvatarNet.spawnType,
  onSpawn: (context) {
    final avatar = avatars[context.entity] = Avatar(context);
    avatar.bindNetworkMembers(
      session.attachEntity(
        context.entity,
        isReady: () => true,
        isValid: () => avatars[context.entity] == avatar,
      ),
    );
  },
  onDespawn: avatars.remove,
);
```

The [example](example/main.dart) runs a host and a client this way.

## License

MIT. See [LICENSE](LICENSE).
