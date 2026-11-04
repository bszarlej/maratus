import 'package:flame/components.dart';
import 'package:maratus/maratus.dart';

/// A codec for [Vector2] values, which travel as `[x, y]`.
///
/// Each coordinate is validated by its own [DoubleCodec], so received
/// positions can be bounded to the game's world. Decoding creates a new
/// vector, so synchronizing a component's position samples a copy of it.
///
/// ```dart
/// final positionField = builder.addField(
///   const FieldId('game.avatar.position'),
///   const Vector2Codec(
///     x: DoubleCodec(min: 0, max: 1920),
///     y: DoubleCodec(min: 0, max: 1080),
///   ),
/// );
/// ```
final class Vector2Codec extends ValueCodec<Vector2> {
  /// Creates a codec whose [x] and [y] coordinates are validated by their
  /// codecs.
  const Vector2Codec({
    this.x = const DoubleCodec(),
    this.y = const DoubleCodec(),
  });

  /// The codec for horizontal coordinates.
  final DoubleCodec x;

  /// The codec for vertical coordinates.
  final DoubleCodec y;

  @override
  String get descriptor => 'flame.vector2@1(${x.descriptor},${y.descriptor})';

  @override
  Object? encode(Vector2 value) => [x.encode(value.x), y.encode(value.y)];

  @override
  Vector2 decode(Object? wire) {
    if (wire is! List<Object?> || wire.length != 2) {
      throw const ProtocolException(
        ProtocolErrorCode.invalidValue,
        'expected a list of two coordinates',
      );
    }
    return Vector2(_coordinate(x, wire, 0), _coordinate(y, wire, 1));
  }

  static double _coordinate(DoubleCodec codec, List<Object?> wire, int index) {
    try {
      return codec.decode(wire[index]);
    } on ProtocolException catch (error) {
      throw error.within('$index');
    }
  }
}

/// Blends [Vector2] values linearly, for example to smooth positions.
///
/// ```dart
/// attachment.synchronize([
///   positionField.property(
///     get: () => position,
///     interpolator: const Vector2Interpolator(teleportDistance: 200),
///   ),
/// ]);
/// ```
final class Vector2Interpolator extends Interpolator<Vector2> {
  /// Creates an interpolator that shows moves of at least
  /// [teleportDistance] as jumps, or blends every move if it is `null`.
  const Vector2Interpolator({this.teleportDistance})
    : assert(teleportDistance == null || teleportDistance > 0);

  /// The shortest move shown as a jump instead of blending, or `null` to
  /// blend every move.
  final double? teleportDistance;

  @override
  Vector2 lerp(Vector2 from, Vector2 to, double t) =>
      Vector2(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);

  @override
  bool isTeleport(Vector2 from, Vector2 to) {
    final distance = teleportDistance;
    return distance != null && from.distanceTo(to) >= distance;
  }
}
