import 'package:maratus/maratus.dart';
import 'package:meta/meta_meta.dart';

/// Generates a [ValueCodec] for the annotated class, named after the class
/// with a `Codec` suffix, such as `MoveInputCodec` for `MoveInput`.
///
/// Every field annotated with [WireKey] travels in a wire object under its
/// key, encoded with the codec that the field selects; see [UseCodec]. The
/// codec constructs decoded values with the class's unnamed constructor,
/// passing each field to the parameter of the same name, so every required
/// parameter needs a field with a [WireKey].
///
/// ```dart
/// part 'move_input.g.dart';
///
/// @NetworkCodec('arena.move_input@1')
/// final class MoveInput {
///   const MoveInput(this.x, this.y);
///
///   @WireKey('x')
///   @Range(min: -1, max: 1)
///   final double x;
///
///   @WireKey('y')
///   @Range(min: -1, max: 1)
///   final double y;
/// }
/// ```
///
/// The generated codec is identical to a hand-written one that composes the
/// same codecs with [WireObject], and other annotated declarations use it
/// for values of the class.
@Target({TargetKind.classType})
final class NetworkCodec {
  /// Generates a codec whose [ValueCodec.descriptor] is [descriptor].
  const NetworkCodec(this.descriptor);

  /// The descriptor of the generated codec, exactly as given.
  ///
  /// It is part of the schema fingerprint of every handle that uses the
  /// codec. Give it an explicit name and version, such as
  /// `arena.move_input@1`, and change the version whenever the keys, the
  /// fields' codecs, or their meaning change.
  final String descriptor;
}

/// Sends the annotated field of a [NetworkCodec] class under the wire [key].
///
/// Keys are explicit, so renaming or reordering fields never changes the
/// wire format.
@Target({TargetKind.field})
final class WireKey {
  /// Sends the field under [key].
  const WireKey(this.key);

  /// The key of the field in the encoded wire object.
  final String key;
}

/// Limits an `int` or `double` value to the range from [min] to [max],
/// inclusive.
///
/// Values of `int` take integer bounds, which [IntCodec] limits to the
/// integers that every platform represents exactly. A missing bound leaves
/// that side unlimited, as in [IntCodec] and [DoubleCodec].
@Target({TargetKind.parameter, TargetKind.field, TargetKind.getter})
final class Range {
  /// Limits values to the range from [min] to [max].
  const Range({this.min, this.max});

  /// The smallest accepted value, or `null` for no lower bound.
  final num? min;

  /// The largest accepted value, or `null` for no upper bound.
  final num? max;
}

/// Limits the length of a `String`, in UTF-16 code units, or of a `List`.
///
/// Without it, [StringCodec] and [ListCodec] accept up to 256.
@Target({TargetKind.parameter, TargetKind.field, TargetKind.getter})
final class MaxLength {
  /// Limits the length to [length].
  const MaxLength(this.length);

  /// The maximum length.
  final int length;
}

/// Encodes the annotated value with [codec].
///
/// Without it, a value's codec follows from its type:
///
/// | Type | Codec |
/// | ---- | ----- |
/// | `bool` | [BoolCodec] |
/// | `int` | [IntCodec], limited by [Range] |
/// | `double` | [DoubleCodec], limited by [Range] |
/// | `String` | [StringCodec], limited by [MaxLength] |
/// | `List<T>` | [ListCodec], limited by [MaxLength], of the codec of `T` |
/// | `T?` | [NullableCodec] of the codec of `T` |
/// | a [NetworkCodec] class | its generated codec |
///
/// Any other type needs this annotation. [codec] must encode exactly the
/// annotated type, and it cannot be combined with [Range] or [MaxLength].
///
/// ```dart
/// const arenaPoint = Vector2Codec(
///   x: DoubleCodec(min: 0, max: 1920),
///   y: DoubleCodec(min: 0, max: 1080),
/// );
///
/// @RpcMethod('arena.player.fire', caller: RpcCaller.owner)
/// void fire(@UseCodec(arenaPoint) Vector2 at) { ... }
/// ```
@Target({TargetKind.parameter, TargetKind.field, TargetKind.getter})
final class UseCodec {
  /// Encodes the annotated value with [codec].
  const UseCodec(this.codec);

  /// The codec of the annotated value.
  final ValueCodec<Object?> codec;
}
