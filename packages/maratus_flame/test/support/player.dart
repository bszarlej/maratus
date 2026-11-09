import 'package:flame/components.dart';
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:maratus_flame/maratus_flame.dart';

part 'player.g.dart';

/// Positions within the arena of the tests.
const arenaPoint = Vector2Codec(
  x: DoubleCodec(min: 0, max: 1000),
  y: DoubleCodec(min: 0, max: 1000),
);

/// A component whose network members are generated from its annotations.
@Networked(spawnType: 'test.player')
final class Player extends PositionComponent with NetworkedComponent, _$Player {
  /// Creates the component of a spawned player in [lane].
  Player(@Range(min: 0, max: 3) SpawnContext<int> context)
    : networkEntity = context.entity,
      lane = context.data;

  @override
  final NetworkEntity networkEntity;

  /// The lane from the spawn data.
  final int lane;

  /// The damage of each hit this component received.
  final hits = <int>[];

  /// The targets, weapons, and senders of the shots this component received.
  final shots = <(Vector2, int, PeerId)>[];

  /// The texts and senders of the whispers this component received.
  final whispers = <(String, PeerId)>[];

  /// How often a hand-written [onNetworkAttach] ran.
  var attachments = 0;

  /// Written by the player's authority and applied on every other peer.
  @SyncedField('test.player.health')
  @Range(min: 0, max: 100)
  int health = 100;

  /// The inherited position, sent for interpolation only.
  @SyncedField('test.player.position', interpolator: Vector2Interpolator())
  @UseCodec(arenaPoint)
  Vector2 get syncedPosition => position;

  /// Host → everyone, the host included.
  @RpcMethod(
    'test.player.hit',
    caller: RpcCaller.host,
    target: RpcTarget.all,
    local: RpcLocal.include,
  )
  void hit(@Range(min: 1, max: 100) int damage) => hits.add(damage);

  /// Owner → host.
  @RpcMethod('test.player.fire', caller: RpcCaller.owner)
  void fire(
    @UseCodec(arenaPoint) Vector2 at,
    @Range(min: 0, max: 3) int weapon,
    RpcContext context,
  ) => shots.add((at, weapon, context.sender));

  /// Any peer → one peer it selects.
  @RpcMethod('test.player.whisper', target: RpcTarget.peer)
  void whisper(@MaxLength(120) String text, RpcContext context) =>
      whispers.add((text, context.sender));

  // Overriding the attach hook does not need to call super to keep the
  // generated bindings.
  @override
  void onNetworkAttach(EntityAttachment attachment) => attachments++;
}
