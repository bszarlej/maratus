import 'package:maratus/maratus.dart';
import 'package:maratus_annotations/maratus_annotations.dart';

import 'inputs.dart';

part 'avatar.g.dart';

/// A player's avatar, as each peer represents it, without a game engine.
@Networked(spawnType: 'test.avatar', syncInterval: Duration(milliseconds: 20))
final class Avatar with _$Avatar {
  /// Creates the avatar of a spawned entity, named by its spawn data.
  Avatar(@MaxLength(32) SpawnContext<String> context) : name = context.data;

  /// How far from the origin an avatar may move.
  static const bound = 100.0;

  /// The player's name, sent once when the avatar spawns.
  final String name;

  /// The horizontal position, written by the authority.
  @SyncedField('test.avatar.x', interpolator: DoubleInterpolator())
  @Range(min: -bound, max: bound)
  double x = 0;

  /// The latest input, sent at every interval.
  @SyncedField(
    'test.avatar.input',
    mode: SyncMode.always,
    deliveryMode: DeliveryMode.unreliable,
    channel: 2,
  )
  MoveInput input = const MoveInput(0, 0);

  /// The direction of movement: -1, 0, or 1.
  int direction = 0;

  /// The messages this avatar received, with their senders.
  final messages = <(PeerId, String, int)>[];

  /// The senders of jumps this avatar received.
  final jumps = <PeerId>[];

  /// The label shown above the avatar, read from [name].
  @SyncedField('test.avatar.label')
  @MaxLength(40)
  String get label => 'Avatar of $name';

  /// Steers the avatar in [direction].
  @RpcMethod(
    'test.avatar.steer',
    caller: RpcCaller.owner,
    deliveryMode: DeliveryMode.unreliableOrdered,
    channel: 1,
  )
  void steer(@Range(min: -1, max: 1) int direction) =>
      this.direction = direction;

  /// Shows [text] at [volume] to every peer.
  @RpcMethod(
    'test.avatar.say',
    target: RpcTarget.all,
    local: RpcLocal.include,
    version: 2,
  )
  void say(
    @MaxLength(64) String text,
    RpcContext context, {
    @Range(min: 0, max: 10) required int volume,
  }) => messages.add((context.sender, text, volume));

  /// Makes the avatar jump.
  @RpcMethod('test.avatar.jump')
  Future<void> jump(RpcContext context) async => jumps.add(context.sender);
}
