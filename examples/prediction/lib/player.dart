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

/// The player's position, which the host computes from the client's inputs.
const playerPosition = SyncField(
  id: FieldId('prediction.player.position'),
  codec: arenaPoint,
);

/// The direction that the client steers the player in, one input per tick.
const playerMove = InputStream(
  id: InputId('prediction.player.move'),
  codec: Vector2Codec(
    x: DoubleCodec(min: -1, max: 1),
    y: DoubleCodec(min: -1, max: 1),
  ),
  tick: Duration(milliseconds: 20),
);

/// Creates the schema that the host and the client share.
///
/// The annotations of [Player] generate its spawn type and RPC. They do not
/// declare predictions yet, so its position and input stream are
/// registered here.
ProtocolSchema createSchema() {
  final builder = ProtocolSchemaBuilder();
  PlayerNet.register(builder);
  builder
    ..addFieldDefinition(playerPosition)
    ..addInputDefinition(playerMove);
  return builder.build();
}

/// A square that the client steers with the arrow keys.
///
/// The host is its authority and computes its position from the client's
/// inputs. The client predicts the position from the same inputs, so its
/// square moves at once instead of after the latency, and reconciles with
/// the host's state as it arrives.
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

  final _direction = Vector2.zero();
  late Prediction<Vector2, Vector2> _prediction;
  late MultiplayerSynchronizer _synchronizer;

  /// Whether this peer is the client that steers the player.
  bool get isOwn =>
      isNetworkReady && networkEntity.owner == multiplayerSession.localPeer;

  /// Moves [position] one tick in [direction], within the arena.
  ///
  /// The client runs it to predict, and the host runs it with the same
  /// inputs to compute the position that both show.
  static Vector2 move(Vector2 position, Vector2 direction) =>
      (position + direction * speed)
        ..clamp(Vector2.all(side / 2), Vector2.all(arenaSize - side / 2));

  @override
  void onNetworkAttach(EntityAttachment attachment) {
    // Every peer predicts, before it synchronizes the predicted position.
    _prediction = attachment.predict(
      state: playerPosition,
      input: playerMove,
      initial: position,
      step: move,
      interpolator: const Vector2Interpolator(teleportDistance: 50),
    );
    _synchronizer = attachment.synchronize([_prediction.property()]);
  }

  /// Moves the player back to [spawnPoint].
  ///
  /// The client asks with `rpc.respawn()`, and the host runs it: as the
  /// player's authority, it sets the state, and the client's prediction
  /// jumps there once that state arrives.
  @RpcMethod('prediction.player.respawn', caller: RpcCaller.owner)
  void respawn() => _prediction.state = spawnPoint;

  @override
  bool onKeyEvent(KeyEvent event, Set<LogicalKeyboardKey> keysPressed) {
    if (!isOwn) return true;
    double axis(LogicalKeyboardKey back, LogicalKeyboardKey forward) =>
        (keysPressed.contains(forward) ? 1.0 : 0.0) -
        (keysPressed.contains(back) ? 1.0 : 0.0);
    _direction.setValues(
      axis(LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight),
      axis(LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown),
    );
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.keyR) {
      rpc.respawn();
    }
    return false;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!isNetworkReady) return;
    // The client advances its prediction with its input every frame; the
    // host shows the state that it computes.
    position.setFrom(
      isOwn
          ? _prediction.advance(
              _direction,
              Duration(
                microseconds: (dt * Duration.microsecondsPerSecond).round(),
              ),
            )
          : _prediction.presented,
    );
  }

  @override
  void render(Canvas canvas) {
    canvas.drawRect(size.toRect(), _fill);
    if (!isOwn) return;
    // On the client, outline where the host last had the player.
    if (_synchronizer.snapshot(playerPosition) case final host?) {
      final offset = host.value - position;
      canvas.drawRect(offset.toOffset() & size.toSize(), _outline);
    }
  }
}
