import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:maratus_flame/maratus_flame.dart';

part 'player.g.dart';

/// The side of the square arena that each view shows.
const arenaSize = 300.0;

/// The codec of positions within the arena.
const arenaPoint = Vector2Codec(
  x: DoubleCodec(min: 0, max: arenaSize),
  y: DoubleCodec(min: 0, max: arenaSize),
);

/// The codec of the directions that the client steers the player in.
const steering = Vector2Codec(
  x: DoubleCodec(min: -1, max: 1),
  y: DoubleCodec(min: -1, max: 1),
);

/// Creates the schema that the host and the client share, from the handles
/// that the annotations of [Player] generate.
ProtocolSchema createSchema() {
  final builder = ProtocolSchemaBuilder();
  PlayerNet.register(builder);
  return builder.build();
}

/// A square that the client steers with the arrow keys.
///
/// The host is its authority and computes its position from the client's
/// inputs. The client predicts the position from the same inputs, so its
/// square moves at once instead of after the latency, and reconciles with
/// the host's state as it arrives. The annotations declare the prediction,
/// and the generated code runs it every frame.
@Networked(spawnType: 'prediction.player')
class Player extends PositionComponent
    with KeyboardHandler, NetworkedComponent, _$Player {
  /// Creates the player that the host spawned at the position in [context].
  Player(@UseCodec(arenaPoint) SpawnContext<Vector2> context)
    : networkEntity = context.entity,
      spawnPoint = context.data,
      super(
        position: context.data,
        size: Vector2.all(side),
        anchor: Anchor.center,
      );

  /// The length of the square's sides.
  static const side = 24.0;

  /// How far the player moves in one tick.
  static const speed = 4.0;

  static final _fill = Paint()..color = const Color(0xff65c7ad);
  static final _outline = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..color = const Color(0xffffffff);

  @override
  final NetworkEntity networkEntity;

  /// Where the host spawned the player, and where it respawns.
  final Vector2 spawnPoint;

  /// The direction that the client steers in, which the generated code
  /// reads as the input of each frame.
  final direction = Vector2.zero();

  /// The player's position, which the host computes from the client's
  /// inputs.
  ///
  /// Every peer predicts it from the spawn point, and the generated code
  /// writes the position to present every frame.
  @SyncedField(
    'prediction.player.position',
    interpolator: Vector2Interpolator(teleportDistance: 50),
  )
  @UseCodec(arenaPoint)
  Vector2 get syncedPosition => position;
  set syncedPosition(Vector2 value) => position.setFrom(value);

  /// Moves [position] one tick in [direction], within the arena.
  ///
  /// The client runs it to predict, and the host runs it with the same
  /// inputs to compute the position that both show.
  @Prediction(
    'prediction.player.move',
    of: 'syncedPosition',
    input: 'direction',
    tick: Duration(milliseconds: 20),
  )
  static Vector2 move(
    Vector2 position,
    @UseCodec(steering) Vector2 direction,
  ) =>
      (position + direction * speed)
        ..clamp(Vector2.all(side / 2), Vector2.all(arenaSize - side / 2));

  /// Moves the player back to [spawnPoint].
  ///
  /// The client asks with `rpc.respawn()`, and the host runs it: as the
  /// player's authority, it sets the state of the prediction, and the
  /// client's prediction jumps there once that state arrives.
  @RpcMethod('prediction.player.respawn', caller: RpcCaller.owner)
  void respawn() => networkPredictor?.state = spawnPoint;

  @override
  bool onKeyEvent(KeyEvent event, Set<LogicalKeyboardKey> keysPressed) {
    if (!isNetworkOwner) return true;
    double axis(LogicalKeyboardKey back, LogicalKeyboardKey forward) =>
        (keysPressed.contains(forward) ? 1.0 : 0.0) -
        (keysPressed.contains(back) ? 1.0 : 0.0);
    direction.setValues(
      axis(LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight),
      axis(LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown),
    );
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.keyR) {
      rpc.respawn();
    }
    return false;
  }

  @override
  void render(Canvas canvas) {
    canvas.drawRect(size.toRect(), _fill);
    if (!isNetworkOwner) return;
    // On the client, outline where the host last had the player.
    if (networkSynchronizer?.snapshot(PlayerNet.syncedPosition)
        case final host?) {
      final offset = host.value - position;
      canvas.drawRect(offset.toOffset() & size.toSize(), _outline);
    }
  }
}
