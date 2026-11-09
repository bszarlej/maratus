import 'package:maratus/maratus.dart';
import 'package:maratus_annotations/maratus_annotations.dart';

part 'inputs.g.dart';

/// A movement input, the example of the ValueCodec documentation.
@NetworkCodec('test.move_input@1')
final class MoveInput {
  /// Creates an input that moves by [x] and [y].
  const MoveInput(this.x, this.y);

  static const _axis = DoubleCodec(min: -1, max: 1);

  /// The horizontal axis, from -1 to 1.
  @WireKey('x')
  @Range(min: -1, max: 1)
  final double x;

  /// The vertical axis, from -1 to 1.
  @WireKey('y')
  @UseCodec(_axis)
  final double y;
}

/// A player's profile, with optional and nested values.
@NetworkCodec('test.profile@1')
final class Profile {
  /// Creates a profile.
  const Profile({
    required this.name,
    required this.input,
    this.level = 1,
    this.tags = const [],
    this.nickname,
  });

  /// The player's name.
  @WireKey('name')
  @MaxLength(16)
  final String name;

  /// The player's level.
  @WireKey('level')
  @Range(min: 1, max: 99)
  final int level;

  /// Up to four tags.
  @WireKey('tags')
  @MaxLength(4)
  final List<String> tags;

  /// An optional nickname.
  @WireKey('nickname')
  final String? nickname;

  /// The player's latest input.
  @WireKey('input')
  final MoveInput input;
}
