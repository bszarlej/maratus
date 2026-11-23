import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flutter/painting.dart' show TextStyle;
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:maratus_flame/maratus_flame.dart';

part 'ball.g.dart';

/// The number of columns the ball can stand in.
const columns = 8;

/// The width of each column.
const cell = 40.0;

/// The height of the ball's track, with room for a note above the ball.
const trackHeight = 72.0;

/// Creates the schema that the host and the clients share.
ProtocolSchema createSchema() {
  final builder = ProtocolSchemaBuilder();
  BallNet.register(builder);
  return builder.build();
}

/// A readable name for [peer].
String peerName(PeerId peer) =>
    peer == PeerId.host ? 'Host' : 'Client ${peer.value}';

/// The peer after [owner] in the order the host, then its clients in the
/// order they joined. Only the host calls this.
PeerId nextPeer(MultiplayerSession session, PeerId owner) {
  final order = [PeerId.host, ...session.peers.where(session.isReady)];
  return order[(order.indexOf(owner) + 1) % order.length];
}

/// A ball that one peer at a time owns and moves.
///
/// The host stays the ball's authority throughout; only its owner changes.
@Networked(spawnType: 'ownership.ball')
class Ball extends PositionComponent with NetworkedComponent, _$Ball {
  /// Creates the ball that the host spawned in the column in [context].
  Ball(@Range(min: 0, max: columns - 1) SpawnContext<int> context)
    : networkEntity = context.entity,
      column = context.data,
      super(size: Vector2.all(cell), anchor: Anchor.center);

  @override
  final NetworkEntity networkEntity;

  /// The column the ball stands in. The ball's owner writes it, so it moves
  /// with the ball when the host transfers the ball to another peer.
  @SyncedField('ownership.ball.column', writer: FieldWriter.owner)
  @Range(min: 0, max: columns - 1)
  int column;

  /// Moves the ball one column in [direction], if this peer owns it.
  void move(int direction) {
    if (!isNetworkOwner) {
      note('not yours to move', rejected: true);
      return;
    }
    column = (column + direction).clamp(0, columns - 1);
  }

  /// Anyone may call this, and it runs on the host, which gives the ball to
  /// the caller.
  @RpcMethod('ownership.ball.claim')
  void claim(RpcContext context) =>
      multiplayerSession.transferOwnership(networkEntity, context.sender);

  /// Only the owner may call this, and it runs on the host, which gives the
  /// ball to the next peer. The host refuses a pass from a peer that has just
  /// given the ball away, even if the peer sent it before it learned so.
  @RpcMethod('ownership.ball.pass', caller: RpcCaller.owner)
  void pass() {
    final session = multiplayerSession;
    session.transferOwnership(networkEntity, nextPeer(session, owner));
  }

  /// The ball's current owner.
  PeerId get owner => networkEntity.owner;

  static final _fills = [
    Paint()..color = const Color(0xff8899aa),
    Paint()..color = const Color(0xff65c7ad),
    Paint()..color = const Color(0xffe0a458),
    Paint()..color = const Color(0xffb48ead),
  ];
  static final _ownRing = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..color = const Color(0xffffffff);
  static final _text = TextPaint(
    style: const TextStyle(fontSize: 13, color: Color(0xffffffff)),
  );
  static final _rejectedText = TextPaint(
    style: const TextStyle(fontSize: 13, color: Color(0xffff7a7a)),
  );

  /// How long a note stays above the ball, in seconds.
  static const noteSeconds = 3.0;

  var _note = '';
  var _rejected = false;
  var _noteLeft = 0.0;

  /// Shows [text] above the ball for [noteSeconds], in red if something was
  /// [rejected].
  void note(String text, {bool rejected = false}) {
    _note = text;
    _rejected = rejected;
    _noteLeft = noteSeconds;
  }

  @override
  void update(double dt) {
    super.update(dt);
    position.setValues((column + 0.5) * cell, trackHeight - cell * 0.7);
    if (_noteLeft > 0 && (_noteLeft -= dt) <= 0) _note = '';
  }

  @override
  void render(Canvas canvas) {
    final center = (size / 2).toOffset();
    final fill = _fills[(owner.value - 1) % _fills.length];
    canvas.drawCircle(center, cell * 0.35, fill);
    if (isNetworkOwner) canvas.drawCircle(center, cell * 0.35 + 3, _ownRing);
    _text.render(canvas, '${owner.value}', size / 2, anchor: Anchor.center);
    (_rejected ? _rejectedText : _text).render(
      canvas,
      _note,
      Vector2(size.x / 2, -4),
      anchor: Anchor.bottomCenter,
    );
  }
}
