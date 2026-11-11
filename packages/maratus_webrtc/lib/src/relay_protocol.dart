import 'dart:convert';

import 'signaling_protocol.dart';

/// The WebSocket subprotocol spoken between signaling clients and servers.
const relaySubprotocol = 'maratus-signaling-v1';

/// The longest relay message, which leaves room around a signaling message.
const maxRelayMessageLength = maxSignalingMessageLength + 1024;

/// The largest client number a room assigns.
const maxRelayClient = 0x7fffffff;

final _roomPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Whether [room] is a valid room name: 1..64 letters, digits, `_`, or `-`.
bool isValidRoom(String room) => _roomPattern.hasMatch(room);

/// A message between a signaling client and a signaling server.
///
/// A host opens a room with [RelayHost], and the server names it with
/// [RelayRoom]. A client enters with [RelayJoin], and the host learns its
/// number from [RelayJoined]. Both then exchange [RelaySignal] messages,
/// which the server relays, until either side ends the client with
/// [RelayLeave]. A refused request is answered by [RelayError].
sealed class RelayMessage {
  const RelayMessage();

  /// Decodes [text], throwing a [FormatException] if it is not a valid relay
  /// message.
  factory RelayMessage.decode(String text) {
    if (text.length > maxRelayMessageLength) {
      throw const FormatException('The relay message is too long.');
    }
    final Object? json = jsonDecode(text);
    if (json is! Map<String, Object?>) {
      throw const FormatException('A relay message must be an object.');
    }
    return switch (json['type']) {
      'host' => RelayHost(_room(json, required: false)),
      'room' => RelayRoom(_room(json, required: true)!),
      'join' => RelayJoin(_room(json, required: true)!),
      'joined' => RelayJoined(_client(json, required: true)!),
      'signal' => RelaySignal(
        _text(json, 'data', maxSignalingMessageLength),
        client: _client(json, required: false),
      ),
      'leave' => RelayLeave(_client(json, required: true)!),
      'error' => RelayError(_text(json, 'reason', 64)),
      _ => throw const FormatException('Unknown relay message type.'),
    };
  }

  /// The JSON object representing this message.
  Map<String, Object?> toJson();

  /// Encodes this message as WebSocket text.
  String encode() => jsonEncode(toJson());
}

/// A host's request to open a room, named [room] or by the server.
final class RelayHost extends RelayMessage {
  /// Creates a request for [room], or for a generated name if `null`.
  const RelayHost([this.room]);

  /// The requested room name.
  final String? room;

  @override
  Map<String, Object?> toJson() => {'type': 'host', 'room': ?room};
}

/// The server's confirmation that a host's room is open.
final class RelayRoom extends RelayMessage {
  /// Creates a confirmation naming [room].
  const RelayRoom(this.room);

  /// The room's name, which clients use to join.
  final String room;

  @override
  Map<String, Object?> toJson() => {'type': 'room', 'room': room};
}

/// A client's request to enter [room].
final class RelayJoin extends RelayMessage {
  /// Creates a request to enter [room].
  const RelayJoin(this.room);

  /// The room to enter.
  final String room;

  @override
  Map<String, Object?> toJson() => {'type': 'join', 'room': room};
}

/// The server's notice to a host that [client] entered its room.
final class RelayJoined extends RelayMessage {
  /// Creates a notice for [client].
  const RelayJoined(this.client);

  /// The client's number within the room.
  final int client;

  @override
  Map<String, Object?> toJson() => {'type': 'joined', 'client': client};
}

/// A signaling message relayed between a host and one of its clients.
///
/// The host's messages name the [client]. A client's messages do not.
final class RelaySignal extends RelayMessage {
  /// Creates a relay of [data], to or from [client] on the host's side.
  const RelaySignal(this.data, {this.client});

  /// The signaling message.
  final String data;

  /// The client's number, on the host's side.
  final int? client;

  @override
  Map<String, Object?> toJson() => {
    'type': 'signal',
    'client': ?client,
    'data': data,
  };
}

/// The end of [client]'s signaling, sent by the host or by the server.
final class RelayLeave extends RelayMessage {
  /// Creates the end of [client]'s signaling.
  const RelayLeave(this.client);

  /// The client's number within the room.
  final int client;

  @override
  Map<String, Object?> toJson() => {'type': 'leave', 'client': client};
}

/// The server's refusal of a request, before it closes the connection.
final class RelayError extends RelayMessage {
  /// Creates a refusal for [reason].
  const RelayError(this.reason);

  /// The room name is invalid or already open.
  static const roomUnavailable = 'room-unavailable';

  /// No room has the requested name.
  static const unknownRoom = 'unknown-room';

  /// The room or the server accepts no further connections.
  static const full = 'full';

  /// A message broke the relay protocol.
  static const protocol = 'protocol';

  /// The server did not receive a request in time.
  static const timeout = 'timeout';

  /// Why the server refused.
  final String reason;

  @override
  Map<String, Object?> toJson() => {'type': 'error', 'reason': reason};
}

String? _room(Map<String, Object?> json, {required bool required}) {
  final value = json['room'];
  if (value == null && !required) return null;
  if (value is! String || !isValidRoom(value)) {
    throw const FormatException('The relay field "room" is invalid.');
  }
  return value;
}

int? _client(Map<String, Object?> json, {required bool required}) {
  final value = json['client'];
  if (value == null && !required) return null;
  if (value is! int || value < 1 || value > maxRelayClient) {
    throw const FormatException('The relay field "client" is invalid.');
  }
  return value;
}

String _text(Map<String, Object?> json, String key, int maxLength) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > maxLength) {
    throw FormatException('The relay field "$key" is invalid.');
  }
  return value;
}
