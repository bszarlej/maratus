import 'dart:convert';

/// The version of the signaling messages and the data-channel framing.
const webRtcProtocolVersion = 1;

/// The longest signaling message the transport accepts, in UTF-16 code units.
const maxSignalingMessageLength = 64 * 1024;

const _maxSdpLength = 32 * 1024;
const _maxCandidateLength = 1024;
const _maxMidLength = 64;
const _maxReasonLength = 64;

/// A message exchanged through a signaling channel while a connection is
/// negotiated.
///
/// Messages are JSON objects with a `type` field. Unknown fields are ignored
/// so that later versions can add information without breaking decoding.
sealed class SignalingMessage {
  const SignalingMessage();

  /// Decodes [text], throwing a [FormatException] if it is not a valid
  /// signaling message.
  factory SignalingMessage.decode(String text) {
    if (text.length > maxSignalingMessageLength) {
      throw const FormatException('The signaling message is too long.');
    }
    final Object? json = jsonDecode(text);
    if (json is! Map<String, Object?>) {
      throw const FormatException('A signaling message must be an object.');
    }
    return switch (json['type']) {
      'offer' => OfferMessage(
        version: _integer(json, 'version'),
        channelCount: _integer(json, 'channels'),
        sdp: _string(json, 'sdp', _maxSdpLength),
      ),
      'answer' => AnswerMessage(_string(json, 'sdp', _maxSdpLength)),
      'candidate' => CandidateMessage(
        _string(json, 'candidate', _maxCandidateLength),
        _optionalString(json, 'mid', _maxMidLength),
      ),
      'reject' => RejectMessage(_string(json, 'reason', _maxReasonLength)),
      _ => throw const FormatException('Unknown signaling message type.'),
    };
  }

  /// The JSON object representing this message.
  Map<String, Object?> toJson();

  /// Encodes this message as text for a signaling channel.
  String encode() => jsonEncode(toJson());
}

/// A client's request to connect, describing its side of the connection.
final class OfferMessage extends SignalingMessage {
  /// Creates an offer of [sdp] for a connection with [channelCount] logical
  /// channels.
  const OfferMessage({
    required this.sdp,
    required this.channelCount,
    this.version = webRtcProtocolVersion,
  });

  /// The version of the client's transport protocol.
  final int version;

  /// The number of logical channels the client uses.
  final int channelCount;

  /// The client's session description.
  final String sdp;

  @override
  Map<String, Object?> toJson() => {
    'type': 'offer',
    'version': version,
    'channels': channelCount,
    'sdp': sdp,
  };
}

/// The host's acceptance of an offer, describing its side of the connection.
final class AnswerMessage extends SignalingMessage {
  /// Creates an answer carrying the host's session description [sdp].
  const AnswerMessage(this.sdp);

  /// The host's session description.
  final String sdp;

  @override
  Map<String, Object?> toJson() => {'type': 'answer', 'sdp': sdp};
}

/// A network address at which the sender might be reachable.
final class CandidateMessage extends SignalingMessage {
  /// Creates a message carrying an ICE [candidate] for the media section
  /// identified by [mid].
  const CandidateMessage(this.candidate, [this.mid]);

  /// The ICE candidate line.
  final String candidate;

  /// The identifier of the session description's media section, if known.
  final String? mid;

  @override
  Map<String, Object?> toJson() => {
    'type': 'candidate',
    'candidate': candidate,
    'mid': ?mid,
  };
}

/// The host's refusal of a client's offer.
final class RejectMessage extends SignalingMessage {
  /// Creates a refusal for [reason].
  const RejectMessage(this.reason);

  /// The host accepts no further connections.
  static const full = 'full';

  /// The client's protocol version or channel count differs from the host's.
  static const incompatible = 'incompatible';

  /// Why the host refused, such as [full] or [incompatible].
  final String reason;

  @override
  Map<String, Object?> toJson() => {'type': 'reject', 'reason': reason};
}

int _integer(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('The signaling field "$key" must be an integer.');
  }
  return value;
}

String _string(Map<String, Object?> json, String key, int maxLength) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > maxLength) {
    throw FormatException(
      'The signaling field "$key" must be a string of 1..$maxLength '
      'characters.',
    );
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key, int maxLength) {
  if (json[key] == null) return null;
  return _string(json, key, maxLength);
}
