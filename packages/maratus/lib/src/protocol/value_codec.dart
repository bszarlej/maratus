import 'protocol_exception.dart';

/// Converts values of type [T] to and from wire values.
///
/// Codecs are explicit: each one defines how a value is represented on the
/// wire and validates received input, so untrusted data never reaches
/// gameplay code unchecked. Wire values are trees made of `null`, [bool],
/// finite [num], [String], `List<Object?>`, and `Map<String, Object?>`.
///
/// Implement a codec for a custom type by extending this class and
/// composing the built-in codecs:
///
/// ```dart
/// class MoveInputCodec extends ValueCodec<MoveInput> {
///   const MoveInputCodec();
///
///   static const _axis = DoubleCodec(min: -1, max: 1);
///
///   @override
///   String get descriptor => 'game.move_input@1';
///
///   @override
///   Object? encode(MoveInput value) =>
///       {'x': _axis.encode(value.x), 'y': _axis.encode(value.y)};
///
///   @override
///   MoveInput decode(Object? wire) {
///     final object = WireObject(wire, const {'x', 'y'});
///     return MoveInput(object.read('x', _axis), object.read('y', _axis));
///   }
/// }
/// ```
abstract class ValueCodec<T> {
  /// Allows subclasses to define const constructors.
  const ValueCodec();

  /// A stable description of this codec's wire representation and
  /// constraints.
  ///
  /// Descriptors are part of the schema fingerprint that peers compare when
  /// connecting, so peers whose codecs have different descriptors cannot
  /// connect. Give custom codecs an explicit name and version, such as
  /// `game.move_input@1`, and change the version whenever the
  /// representation changes. Do not derive descriptors from `runtimeType`,
  /// which can differ between builds.
  String get descriptor;

  /// Converts [value] to a wire value.
  ///
  /// Throws an [ArgumentError] if [value] cannot be represented.
  Object? encode(T value);

  /// Converts a received [wire] value to a value of type [T].
  ///
  /// Throws a [ProtocolException] if [wire] is not a valid representation.
  /// Any other error thrown while decoding received data is also treated as
  /// invalid input.
  T decode(Object? wire);
}

/// A codec for [bool] values.
final class BoolCodec extends ValueCodec<bool> {
  /// Creates a codec for booleans.
  const BoolCodec();

  @override
  String get descriptor => 'bool';

  @override
  Object? encode(bool value) => value;

  @override
  bool decode(Object? wire) {
    if (wire is bool) return wire;
    throw const ProtocolException(
      ProtocolErrorCode.invalidValue,
      'expected a boolean',
    );
  }
}

/// A codec for [int] values within a range.
///
/// The range is limited to integers that native and web platforms both
/// represent exactly, from [minSafe] to [maxSafe].
final class IntCodec extends ValueCodec<int> {
  /// Creates a codec for integers from [min] to [max], inclusive.
  const IntCodec({this.min = minSafe, this.max = maxSafe})
    : assert(min >= minSafe),
      assert(max <= maxSafe),
      assert(min <= max);

  /// The smallest integer represented exactly on every platform,
  /// -(2^53 - 1).
  static const int minSafe = -9007199254740991;

  /// The largest integer represented exactly on every platform, 2^53 - 1.
  static const int maxSafe = 9007199254740991;

  /// The smallest accepted value.
  final int min;

  /// The largest accepted value.
  final int max;

  @override
  String get descriptor => _describe('int', [
    if (min != minSafe) 'min=$min',
    if (max != maxSafe) 'max=$max',
  ]);

  @override
  Object? encode(int value) {
    if (value < min || value > max) {
      throw ArgumentError.value(value, 'value', 'must be from $min to $max');
    }
    return value;
  }

  @override
  int decode(Object? wire) {
    if (wire is! num ||
        (wire is double &&
            (!wire.isFinite || wire != wire.truncateToDouble()))) {
      throw const ProtocolException(
        ProtocolErrorCode.invalidValue,
        'expected an integer',
      );
    }
    if (wire < min || wire > max) {
      throw ProtocolException(
        ProtocolErrorCode.invalidValue,
        'expected an integer from $min to $max, got $wire',
      );
    }
    return wire.toInt();
  }
}

/// A codec for finite [double] values within a range.
final class DoubleCodec extends ValueCodec<double> {
  /// Creates a codec for finite numbers from [min] to [max], inclusive.
  const DoubleCodec({
    this.min = double.negativeInfinity,
    this.max = double.infinity,
  }) : assert(min <= max);

  /// The smallest accepted value.
  final double min;

  /// The largest accepted value.
  final double max;

  @override
  String get descriptor => _describe('double', [
    if (min != double.negativeInfinity) 'min=${_formatDouble(min)}',
    if (max != double.infinity) 'max=${_formatDouble(max)}',
  ]);

  @override
  Object? encode(double value) {
    if (!value.isFinite || value < min || value > max) {
      throw ArgumentError.value(value, 'value', 'must be $_range');
    }
    return value;
  }

  @override
  double decode(Object? wire) {
    if (wire is! num || !wire.isFinite || wire < min || wire > max) {
      throw ProtocolException(
        ProtocolErrorCode.invalidValue,
        'expected $_range, got $wire',
      );
    }
    return wire.toDouble();
  }

  String get _range => switch ((min.isFinite, max.isFinite)) {
    (false, false) => 'a finite number',
    (true, false) => 'a finite number from $min',
    (false, true) => 'a finite number up to $max',
    (true, true) => 'a number from $min to $max',
  };
}

/// A codec for [String] values up to a maximum length.
final class StringCodec extends ValueCodec<String> {
  /// Creates a codec for strings of at most [maxLength] UTF-16 code units.
  const StringCodec({this.maxLength = 256}) : assert(maxLength >= 0);

  /// The maximum length, in UTF-16 code units.
  final int maxLength;

  @override
  String get descriptor => 'string(maxLength=$maxLength)';

  @override
  Object? encode(String value) {
    if (value.length > maxLength) {
      throw ArgumentError.value(
        value,
        'value',
        'is longer than $maxLength characters',
      );
    }
    return value;
  }

  @override
  String decode(Object? wire) {
    if (wire is! String) {
      throw const ProtocolException(
        ProtocolErrorCode.invalidValue,
        'expected a string',
      );
    }
    if (wire.length > maxLength) {
      throw ProtocolException(
        ProtocolErrorCode.limitExceeded,
        'string has ${wire.length} characters, more than the limit of '
        '$maxLength',
      );
    }
    return wire;
  }
}

/// A codec for lists whose elements are encoded with [element].
///
/// Decoded lists are unmodifiable.
final class ListCodec<T> extends ValueCodec<List<T>> {
  /// Creates a codec for lists of at most [maxLength] elements.
  const ListCodec(this.element, {this.maxLength = 256})
    : assert(maxLength >= 0);

  /// The codec for each element.
  final ValueCodec<T> element;

  /// The maximum number of elements.
  final int maxLength;

  @override
  String get descriptor => 'list<${element.descriptor}>(maxLength=$maxLength)';

  @override
  Object? encode(List<T> value) {
    if (value.length > maxLength) {
      throw ArgumentError.value(
        value,
        'value',
        'has more than $maxLength elements',
      );
    }
    return [for (final item in value) element.encode(item)];
  }

  @override
  List<T> decode(Object? wire) {
    if (wire is! List<Object?>) {
      throw const ProtocolException(
        ProtocolErrorCode.invalidValue,
        'expected a list',
      );
    }
    if (wire.length > maxLength) {
      throw ProtocolException(
        ProtocolErrorCode.limitExceeded,
        'list has ${wire.length} elements, more than the limit of '
        '$maxLength',
      );
    }
    return List<T>.unmodifiable([
      for (var i = 0; i < wire.length; i++)
        _decodeWithin('$i', element, wire[i]),
    ]);
  }
}

/// A codec for optional values that represents `null` as a wire `null`.
final class NullableCodec<T extends Object> extends ValueCodec<T?> {
  /// Creates a codec that encodes non-null values with [inner].
  const NullableCodec(this.inner);

  /// The codec for non-null values.
  final ValueCodec<T> inner;

  @override
  String get descriptor => 'nullable<${inner.descriptor}>';

  @override
  Object? encode(T? value) {
    if (value == null) return null;
    final wire = inner.encode(value);
    if (wire == null) {
      throw ArgumentError.value(
        value,
        'value',
        'encodes as null, which $descriptor reserves for absent values',
      );
    }
    return wire;
  }

  @override
  T? decode(Object? wire) => wire == null ? null : inner.decode(wire);
}

/// Reads an object-shaped wire value with a fixed set of keys.
///
/// Use it in [ValueCodec.decode] to reject missing and unexpected keys and
/// to report where an invalid value is located.
final class WireObject {
  /// Validates that [wire] is an object whose keys are exactly [keys].
  ///
  /// Throws a [ProtocolException] if [wire] is not an object or its keys
  /// differ from [keys].
  factory WireObject(Object? wire, Set<String> keys) {
    if (wire is! Map<String, Object?>) {
      throw const ProtocolException(
        ProtocolErrorCode.invalidValue,
        'expected an object',
      );
    }
    for (final key in keys) {
      if (!wire.containsKey(key)) {
        throw ProtocolException(
          ProtocolErrorCode.invalidValue,
          'missing key "$key"',
        );
      }
    }
    if (wire.length != keys.length) {
      final unexpected = wire.keys.firstWhere((key) => !keys.contains(key));
      throw ProtocolException(
        ProtocolErrorCode.invalidValue,
        'unexpected key "${_preview(unexpected)}"',
      );
    }
    return WireObject._(wire);
  }

  const WireObject._(this._values);

  final Map<String, Object?> _values;

  /// The raw wire value at [key].
  ///
  /// Throws an [ArgumentError] if [key] is not one of the object's keys.
  Object? operator [](String key) {
    if (!_values.containsKey(key)) {
      throw ArgumentError.value(key, 'key', 'is not a key of this object');
    }
    return _values[key];
  }

  /// Decodes the value at [key] with [codec].
  ///
  /// A [ProtocolException] thrown by [codec] is reported at [key].
  T read<T>(String key, ValueCodec<T> codec) =>
      _decodeWithin(key, codec, this[key]);
}

T _decodeWithin<T>(String segment, ValueCodec<T> codec, Object? wire) {
  try {
    return codec.decode(wire);
  } on ProtocolException catch (error) {
    throw error.within(segment);
  }
}

String _describe(String name, List<String> parameters) =>
    parameters.isEmpty ? name : '$name(${parameters.join(',')})';

/// Formats [value] identically on native and web platforms, which print
/// integral doubles differently.
String _formatDouble(double value) {
  if (value == value.truncateToDouble() && value.abs() <= IntCodec.maxSafe) {
    return value.toInt().toString();
  }
  final text = value.toString();
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

String _preview(String text) =>
    text.length <= 32 ? text : '${text.substring(0, 32)}...';
