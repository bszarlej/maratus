import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flutter/painting.dart' show TextStyle;
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:maratus_flame/maratus_flame.dart';

part 'pawn.g.dart';

/// The number of columns the pawn can stand in.
const columns = 8;

/// The number of rows, one for each client's pawn.
const rows = 2;

/// The width of each column.
const cell = 40.0;

/// The height of each row, with room for a note above the pawn.
const rowHeight = 56.0;

/// Creates the schema that the host and the clients share.
ProtocolSchema createSchema() {
  final builder = ProtocolSchemaBuilder();
  PawnNet.register(builder);
  return builder.build();
}

/// A readable name for [peer].
String peerName(PeerId peer) =>
    peer == PeerId.host ? 'Host' : 'Client ${peer.value}';

/// A client's pawn, in a row of its own. Its four RPCs differ only in who
/// may call them and where they run.
@Networked(spawnType: 'rpc.pawn')
class Pawn extends PositionComponent with NetworkedComponent, _$Pawn {
  /// Creates the pawn that the host spawned in the row in [context].
  Pawn(@Range(min: 0, max: rows - 1) SpawnContext<int> context)
    : networkEntity = context.entity,
      row = context.data,
      super(size: Vector2.all(cell), anchor: Anchor.center);

  @override
  final NetworkEntity networkEntity;

  /// The row of this pawn, sent once when it spawns.
  final int row;

  /// The column the pawn stands in. The host, the pawn's authority, writes
  /// it, and the clients receive it.
  @SyncedField('rpc.pawn.column')
  @Range(min: 0, max: columns - 1)
  int column = 0;

  /// Only the owner may call this, and it runs on the host: the owner asks,
  /// and the host moves the pawn.
  @RpcMethod('rpc.pawn.step', caller: RpcCaller.owner)
  void step(@Range(min: -1, max: 1) int direction) =>
      column = (column + direction).clamp(0, columns - 1);

  /// Anyone may call this, and it runs on every peer, the caller included.
  /// A text longer than 12 characters fails on the caller, unsent.
  @RpcMethod('rpc.pawn.say', target: RpcTarget.all, local: RpcLocal.include)
  void say(@MaxLength(12) String text, RpcContext context) =>
      note('${peerName(context.sender)}: $text');

  /// Anyone may call this, and it runs only on the pawn's owner.
  @RpcMethod('rpc.pawn.poke', target: RpcTarget.owner)
  void poke(RpcContext context) => note('poked by ${peerName(context.sender)}');

  /// Anyone may call this, and it runs only on the peer that the caller
  /// picks with `to:`. The caller is not a recipient, so it has to show its own
  /// copy itself.
  @RpcMethod('rpc.pawn.whisper', target: RpcTarget.peer)
  void whisper(@MaxLength(12) String text, RpcContext context) =>
      note('${peerName(context.sender)} whispers: $text');

  /// Only the host may call this, and it runs on every peer.
  @RpcMethod(
    'rpc.pawn.award',
    caller: RpcCaller.host,
    target: RpcTarget.all,
    local: RpcLocal.include,
  )
  void award(@Range(min: 1, max: 3) int stars) => note('★' * stars);

  static final _fills = [
    Paint()..color = const Color(0xff65c7ad),
    Paint()..color = const Color(0xffe0a458),
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

  /// How long a note stays above the pawn, in seconds.
  static const noteSeconds = 3.0;

  var _note = '';
  var _rejected = false;
  var _noteLeft = 0.0;

  /// Shows [text] above the pawn for [noteSeconds], in red if a call was
  /// [rejected].
  void note(String text, {bool rejected = false}) {
    _note = text;
    _rejected = rejected;
    _noteLeft = noteSeconds;
  }

  @override
  void update(double dt) {
    super.update(dt);
    position.setValues((column + 0.5) * cell, (row + 0.7) * rowHeight);
    if (_noteLeft > 0 && (_noteLeft -= dt) <= 0) _note = '';
  }

  @override
  void render(Canvas canvas) {
    final center = (size / 2).toOffset();
    canvas.drawCircle(center, cell * 0.35, _fills[row]);
    if (isNetworkOwner) canvas.drawCircle(center, cell * 0.35 + 3, _ownRing);
    _text.render(
      canvas,
      '${networkEntity.owner.value}',
      size / 2,
      anchor: Anchor.center,
    );
    (_rejected ? _rejectedText : _text).render(
      canvas,
      _note,
      Vector2(size.x / 2, -4),
      anchor: Anchor.bottomCenter,
    );
  }
}
