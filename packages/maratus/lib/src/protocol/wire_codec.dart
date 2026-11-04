import 'dart:convert';
import 'dart:typed_data';

import 'protocol_exception.dart';

/// Converts wire values to and from bytes.
///
/// Wire values are trees made of `null`, [bool], finite [num], [String],
/// `List<Object?>`, and `Map<String, Object?>`. Typed codecs produce and
/// consume wire values, so the byte representation can be replaced without
/// changing them.
abstract interface class WireCodec {
  /// Encodes the wire [value] as bytes.
  Uint8List encode(Object? value);

  /// Decodes [bytes] into a wire value.
  ///
  /// Throws a [ProtocolException] with [ProtocolErrorCode.malformed] if
  /// [bytes] are not a valid encoding.
  Object? decode(Uint8List bytes);
}

/// A [WireCodec] that represents wire values as UTF-8 encoded JSON.
final class JsonWireCodec implements WireCodec {
  /// Creates a JSON wire codec.
  const JsonWireCodec();

  @override
  Uint8List encode(Object? value) => utf8.encode(jsonEncode(value));

  @override
  Object? decode(Uint8List bytes) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException catch (error) {
      throw ProtocolException(
        ProtocolErrorCode.malformed,
        'not valid UTF-8 JSON: ${error.message}',
      );
    }
  }
}

/// Size limits for encoded messages and their wire values.
final class WireLimits {
  /// Creates limits for message size, nesting, and collection length.
  const WireLimits({
    this.maxMessageBytes = 64 * 1024,
    this.maxDepth = 32,
    this.maxCollectionLength = 1024,
  }) : assert(maxMessageBytes > 0),
       assert(maxDepth > 0),
       assert(maxCollectionLength >= 0);

  /// The maximum size of an encoded message, in bytes.
  final int maxMessageBytes;

  /// The maximum nesting depth of lists and objects.
  final int maxDepth;

  /// The maximum number of elements in a list or entries in an object.
  final int maxCollectionLength;
}

/// Checks that [value] is a wire value within [limits].
///
/// Throws a [ProtocolException] with [ProtocolErrorCode.malformed] for
/// values outside the wire value model, such as non-finite numbers, and
/// with [ProtocolErrorCode.limitExceeded] for values that are nested too
/// deeply or have too many elements.
void checkWireValue(Object? value, WireLimits limits) {
  _checkWireValue(value, limits, 0);
}

void _checkWireValue(Object? value, WireLimits limits, int depth) {
  switch (value) {
    case null || bool() || String():
      return;
    case num():
      if (!value.isFinite) {
        throw const ProtocolException(
          ProtocolErrorCode.malformed,
          'numbers must be finite',
        );
      }
    case List<Object?>():
      _checkCollection(value.length, limits, depth);
      for (final element in value) {
        _checkWireValue(element, limits, depth + 1);
      }
    case Map<String, Object?>():
      _checkCollection(value.length, limits, depth);
      for (final element in value.values) {
        _checkWireValue(element, limits, depth + 1);
      }
    default:
      throw const ProtocolException(
        ProtocolErrorCode.malformed,
        'unsupported wire value',
      );
  }
}

void _checkCollection(int length, WireLimits limits, int depth) {
  if (depth >= limits.maxDepth) {
    throw ProtocolException(
      ProtocolErrorCode.limitExceeded,
      'nested deeper than ${limits.maxDepth} levels',
    );
  }
  if (length > limits.maxCollectionLength) {
    throw ProtocolException(
      ProtocolErrorCode.limitExceeded,
      'collection has $length elements, more than the limit of '
      '${limits.maxCollectionLength}',
    );
  }
}
