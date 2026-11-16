import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:maratus_flame/maratus_flame.dart';

part 'arena.g.dart';

/// The side of the square arena that each view shows.
const arenaSize = 300.0;

/// How close a crate must be to a client's player to come into its view.
const showRange = 80.0;

/// How far a crate in a client's view must be from its player to leave the
/// view again. It is larger than [showRange], so crates at the edge do not
/// keep leaving and returning.
const hideRange = 95.0;

/// The codec of positions within the arena.
const arenaPoint = Vector2Codec(
  x: DoubleCodec(min: 0, max: arenaSize),
  y: DoubleCodec(min: 0, max: arenaSize),
);

/// Creates the schema that the host and the client share, from the handles
/// that the annotations of [Player] and [Crate] generate.
ProtocolSchema createSchema() {
  final builder = ProtocolSchemaBuilder();
  PlayerNet.register(builder);
  CrateNet.register(builder);
  return builder.build();
}

/// A square that the client that owns it steers with the arrow keys, inside
/// the circle within which crates come into that client's view.
@Networked(spawnType: 'visibility.player')
class Player extends PositionComponent
    with KeyboardHandler, NetworkedComponent, _$Player {
  /// Creates the player that the host spawned at the position in [context].
  Player(@UseCodec(arenaPoint) SpawnContext<Vector2> context)
    : networkEntity = context.entity,
      super(
        position: context.data,
        size: Vector2.all(side),
        anchor: Anchor.center,
      );

  /// The length of the square's sides.
  static const side = 20.0;

  /// How far the player moves per second.
  static const speed = 120.0;

  static final _fill = Paint()..color = const Color(0xff65c7ad);
  static final _range = Paint()
    ..style = PaintingStyle.stroke
    ..color = const Color(0x8865c7ad);

  @override
  final NetworkEntity networkEntity;

  final _direction = Vector2.zero();

  /// Whether this peer is the client that steers the player.
  bool get isOwn =>
      isNetworkReady && networkEntity.owner == multiplayerSession.localPeer;

  /// The inherited position, which the client that owns the player writes,
  /// and the host applies.
  @SyncedField('visibility.player.position', writer: FieldWriter.owner)
  @UseCodec(arenaPoint)
  Vector2 get syncedPosition => position;
  set syncedPosition(Vector2 value) => position.setFrom(value);

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
    return false;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!isOwn) return;
    position
      ..add(_direction * (speed * dt))
      ..clamp(Vector2.all(side / 2), Vector2.all(arenaSize - side / 2));
  }

  @override
  void render(Canvas canvas) {
    canvas
      ..drawRect(size.toRect(), _fill)
      ..drawCircle((size / 2).toOffset(), showRange, _range);
  }
}

/// A crate. On the host, a crate that a client sees is drawn brighter.
@Networked(spawnType: 'visibility.crate')
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
  static const side = 12.0;

  static final _fill = Paint()..color = const Color(0xffe0a458);
  static final _hidden = Paint()..color = const Color(0x55e0a458);

  @override
  final NetworkEntity networkEntity;

  /// Whether this crate is on the host, but in no client's view.
  bool get _hiddenFromClients {
    if (!isNetworkReady) return false;
    final session = multiplayerSession;
    return session.state == SessionState.hosting &&
        !session.peers.any((peer) => session.isVisibleTo(networkEntity, peer));
  }

  @override
  void render(Canvas canvas) =>
      canvas.drawRect(size.toRect(), _hiddenFromClients ? _hidden : _fill);
}
