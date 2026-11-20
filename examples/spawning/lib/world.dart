import 'dart:math';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flutter/painting.dart' show TextStyle;
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:maratus_flame/maratus_flame.dart';

part 'world.g.dart';

/// The side of the square arena that each view shows.
const arenaSize = 240.0;

/// The codec of positions within the arena.
const arenaPoint = Vector2Codec(
  x: DoubleCodec(min: 0, max: arenaSize),
  y: DoubleCodec(min: 0, max: arenaSize),
);

/// Creates the schema that the host and the clients share, from the handles
/// that the annotations of [Crate], [Player], and [Flag] generate.
ProtocolSchema createSchema() {
  final builder = ProtocolSchemaBuilder();
  CrateNet.register(builder);
  PlayerNet.register(builder);
  FlagNet.register(builder);
  return builder.build();
}

/// A readable name for [peer].
String peerName(PeerId peer) =>
    peer == PeerId.host ? 'Host' : 'Client ${peer.value}';

/// The color of the entities that [peer] owns.
Paint peerPaint(PeerId peer) => _peerPaints[peer.value % _peerPaints.length];

final _peerPaints = [
  Paint()..color = const Color(0xffe0a458),
  Paint()..color = const Color(0xff65c7ad),
  Paint()..color = const Color(0xff8fa8ff),
  Paint()..color = const Color(0xffe57fb0),
];

final _text = TextPaint(
  style: const TextStyle(fontSize: 12, color: Color(0xffffffff)),
);

/// A crate that the host spawns and despawns. The host owns it, so it stays
/// until the host despawns it, and clients that join later receive it.
@Networked(spawnType: 'spawning.crate')
class Crate extends PositionComponent with NetworkedComponent {
  /// Creates the crate that the host spawned at the position in [context].
  Crate(@UseCodec(arenaPoint) SpawnContext<Vector2> context)
    : networkEntity = context.entity,
      super(
        position: context.data,
        size: Vector2.all(side),
        anchor: Anchor.center,
      );

  /// The length of the crate's sides.
  static const side = 16.0;

  @override
  final NetworkEntity networkEntity;

  @override
  void render(Canvas canvas) =>
      canvas.drawRect(size.toRect(), peerPaint(PeerId.host));
}

/// A client's player, which the host spawns when the client joins.
///
/// The host spawns it with `OwnerLeftPolicy.despawn`, so it is despawned on
/// every peer when its client leaves.
@Networked(spawnType: 'spawning.player')
class Player extends PositionComponent with NetworkedComponent, _$Player {
  /// Creates the player that the host spawned at the position in [context].
  Player(@UseCodec(arenaPoint) SpawnContext<Vector2> context)
    : networkEntity = context.entity,
      super(
        position: context.data,
        size: Vector2.all(side),
        anchor: Anchor.center,
      );

  /// The length of the player's sides.
  static const side = 24.0;

  /// The number of flags that each player may drop.
  static const maxFlags = 6;

  /// How far from the player its flags land.
  static const flagReach = 40.0;

  static final _ownRing = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..color = const Color(0xffffffff);

  @override
  final NetworkEntity networkEntity;

  final _random = Random();
  var _flags = 0;

  /// Only the owner may call this, and it runs on the host, which spawns a
  /// flag near the player. Clients cannot spawn entities themselves, so they
  /// ask the host.
  @RpcMethod('spawning.player.drop_flag', caller: RpcCaller.owner)
  void dropFlag() {
    if (_flags >= maxFlags) return;
    _flags++;
    double near(double value) =>
        (value + (_random.nextDouble() * 2 - 1) * flagReach).clamp(
          Flag.side,
          arenaSize - Flag.side,
        );
    // The flag keeps the default policy, so it stays when its owner leaves.
    multiplayerSession.spawn(
      FlagNet.spawnType,
      Vector2(near(x), near(y)),
      owner: networkEntity.owner,
    );
  }

  @override
  void render(Canvas canvas) {
    final paint = peerPaint(networkEntity.owner);
    canvas.drawRect(size.toRect(), paint);
    if (isNetworkOwner) canvas.drawRect(size.toRect().inflate(3), _ownRing);
    _text.render(
      canvas,
      '${networkEntity.owner.value}',
      size / 2,
      anchor: Anchor.center,
    );
  }
}

/// A flag that the host spawns for the client that asked for it.
///
/// The client owns it, but the host spawns it with the default
/// `OwnerLeftPolicy.keep`, so it stays when the client leaves.
@Networked(spawnType: 'spawning.flag')
class Flag extends PositionComponent with NetworkedComponent {
  /// Creates the flag that the host spawned at the position in [context].
  Flag(@UseCodec(arenaPoint) SpawnContext<Vector2> context)
    : networkEntity = context.entity,
      super(
        position: context.data,
        size: Vector2.all(side),
        anchor: Anchor.bottomLeft,
      );

  /// The height of the flag.
  static const side = 14.0;

  static final _pole = Paint()
    ..strokeWidth = 2
    ..color = const Color(0xffffffff);

  @override
  final NetworkEntity networkEntity;

  @override
  void render(Canvas canvas) {
    canvas
      ..drawLine(Offset.zero, Offset(0, side), _pole)
      ..drawPath(
        Path()
          ..moveTo(0, 0)
          ..lineTo(side * 0.8, side * 0.25)
          ..lineTo(0, side * 0.5)
          ..close(),
        peerPaint(networkEntity.owner),
      );
  }
}
