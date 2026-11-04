/// Categories of [ProtocolException].
enum ProtocolErrorCode {
  /// The bytes are not a valid encoding of wire values, for example because
  /// they are truncated or contain a non-finite number.
  malformed,

  /// A size limit was exceeded, such as the message size, nesting depth,
  /// collection length, or string length.
  limitExceeded,

  /// The message uses a protocol version this peer does not support.
  unsupportedVersion,

  /// The message kind is not part of the protocol.
  unknownKind,

  /// The message refers to a spawn type, RPC, or synchronized field that is
  /// not registered in the schema.
  unknownIdentifier,

  /// A value does not have the expected type, shape, or range.
  invalidValue,
}

/// Thrown when received data violates the protocol.
///
/// Decoding untrusted input reports every failure as a [ProtocolException],
/// so the receiver can reject the message before any handler runs.
final class ProtocolException implements Exception {
  /// Creates an exception with an error [code] and a [message] describing
  /// the failure.
  const ProtocolException(this.code, this.message, {this.path = const []});

  /// The category of the failure.
  final ProtocolErrorCode code;

  /// A description of the failure.
  final String message;

  /// The location of the failure within the decoded value, outermost key
  /// first. Empty when the failure applies to the whole value.
  final List<String> path;

  /// Returns a copy of this exception located inside [segment].
  ProtocolException within(String segment) =>
      ProtocolException(code, message, path: [segment, ...path]);

  @override
  String toString() {
    final location = path.isEmpty ? '' : ' at ${path.join('/')}';
    return 'ProtocolException(${code.name})$location: $message';
  }
}
