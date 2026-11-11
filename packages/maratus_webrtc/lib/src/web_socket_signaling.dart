import 'dart:async';

import 'package:web_socket/web_socket.dart';

import 'relay_protocol.dart';
import 'signaling.dart';
import 'signaling_protocol.dart';

/// A signaling server refused a request or broke the signaling protocol.
final class SignalingException implements Exception {
  /// Creates an exception describing [message].
  const SignalingException(this.message);

  /// Why signaling failed, such as `room-unavailable`, `unknown-room`, or
  /// `full` for refusals by a signaling server.
  final String message;

  @override
  String toString() => 'SignalingException: $message';
}

/// A host's signaling through a room on a `SignalingServer`.
///
/// Pass it to `WebRtcHost` and share [room] with the players who should
/// join. Each client that joins the room is delivered by [clients].
final class WebSocketHostSignaling implements HostSignaling {
  WebSocketHostSignaling._(this._socket) {
    _opened.future.ignore();
    _subscription = _socket.events.listen(
      _event,
      onError: (Object error, StackTrace _) => _end(error),
      onDone: () => _end(null),
    );
  }

  /// Connects to the signaling server at [server] and opens a room.
  ///
  /// [server] is a `ws:` or `wss:` URL. The server generates the room's name
  /// unless [room] requests one: 1..64 letters, digits, `_`, or `-`.
  /// Connecting and opening the room must finish within [timeout].
  ///
  /// Throws a [SignalingException] if the server refuses the room, for
  /// example because its name is already open, and a [TimeoutException] or
  /// `WebSocketException` if the server cannot be reached.
  static Future<WebSocketHostSignaling> connect(
    Uri server, {
    String? room,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (room != null && !isValidRoom(room)) {
      throw ArgumentError.value(
        room,
        'room',
        'must be 1..64 letters, digits, "_", or "-"',
      );
    }
    _validateTimeout(timeout);
    final elapsed = Stopwatch()..start();
    final signaling = WebSocketHostSignaling._(await _connect(server, timeout));
    try {
      signaling._write(RelayHost(room));
      final remaining = timeout - elapsed.elapsed;
      await signaling._opened.future.timeout(
        remaining.isNegative ? Duration.zero : remaining,
      );
    } on Object {
      signaling.close();
      rethrow;
    }
    return signaling;
  }

  final WebSocket _socket;
  late final StreamSubscription<WebSocketEvent> _subscription;
  final _opened = Completer<void>();
  final _clients = StreamController<SignalingChannel>();
  final _channels = <int, _RelayChannel>{};
  String? _room;
  var _closed = false;

  /// The name of the room, which clients pass to
  /// [WebSocketSignalingChannel.join].
  String get room => _room!;

  @override
  Stream<SignalingChannel> get clients => _clients.stream;

  void _event(WebSocketEvent event) {
    switch (event) {
      case TextDataReceived(:final text):
        _message(text);
      case BinaryDataReceived():
        _end(const SignalingException(RelayError.protocol));
      case CloseReceived():
        _end(null);
    }
  }

  void _message(String text) {
    final RelayMessage message;
    try {
      message = RelayMessage.decode(text);
    } on FormatException {
      _end(const SignalingException(RelayError.protocol));
      return;
    }
    if (!_opened.isCompleted) {
      switch (message) {
        case RelayRoom(:final room):
          _room = room;
          _opened.complete();
        case RelayError(:final reason):
          _end(SignalingException(reason));
        default:
          _end(const SignalingException(RelayError.protocol));
      }
      return;
    }
    switch (message) {
      case RelayJoined(:final client) when !_channels.containsKey(client):
        final channel = _RelayChannel(this, client);
        _channels[client] = channel;
        _clients.add(channel);
      case RelaySignal(:final data, client: final client?):
        // Messages can still arrive for a client the host just closed.
        _channels[client]?._receive(data);
      case RelayLeave(:final client):
        _channels.remove(client)?._ended();
      default:
        _end(const SignalingException(RelayError.protocol));
    }
  }

  void _write(RelayMessage message) {
    if (_closed) return;
    try {
      _socket.sendText(message.encode());
    } on Object catch (error) {
      _end(error);
    }
  }

  void _end(Object? error) {
    if (_closed) return;
    _closed = true;
    if (!_opened.isCompleted) {
      _opened.completeError(
        error ?? const SignalingException('The server closed the connection.'),
      );
    }
    for (final channel in _channels.values.toList()) {
      channel._ended();
    }
    _channels.clear();
    unawaited(_subscription.cancel());
    unawaited(_closeQuietly(_socket));
    unawaited(_clients.close());
  }

  /// Closes the room. Clients still negotiating are disconnected, and
  /// established connections are unaffected.
  @override
  void close() => _end(null);
}

final class _RelayChannel implements SignalingChannel {
  _RelayChannel(this._host, this._client);

  final WebSocketHostSignaling _host;
  final int _client;
  final _messages = StreamController<String>();
  var _closed = false;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  void send(String message) {
    _checkLength(message);
    if (_closed) return;
    _host._write(RelaySignal(message, client: _client));
  }

  void _receive(String data) {
    if (!_closed) _messages.add(data);
  }

  void _ended() {
    if (_closed) return;
    _closed = true;
    unawaited(_messages.close());
  }

  @override
  void close() {
    if (_closed) return;
    _host._channels.remove(_client);
    _host._write(RelayLeave(_client));
    _ended();
  }
}

/// A client's signaling through a room on a `SignalingServer`.
///
/// Pass it to `WebRtcClient.connect`. The channel connects in the
/// background; messages sent before then are delivered once it has joined
/// the room. A refusal by the server, such as for an unknown room, is
/// reported as a [SignalingException] by [messages].
final class WebSocketSignalingChannel implements SignalingChannel {
  WebSocketSignalingChannel._(Uri server, String room, Duration timeout) {
    unawaited(_open(server, room, timeout));
  }

  /// Connects to the signaling server at [server] and joins [room].
  ///
  /// [server] is a `ws:` or `wss:` URL, and [room] is the name opened by the
  /// host. Connecting must finish within [timeout].
  factory WebSocketSignalingChannel.join(
    Uri server, {
    required String room,
    Duration timeout = const Duration(seconds: 10),
  }) {
    if (!isValidRoom(room)) {
      throw ArgumentError.value(
        room,
        'room',
        'must be 1..64 letters, digits, "_", or "-"',
      );
    }
    _validateTimeout(timeout);
    return WebSocketSignalingChannel._(server, room, timeout);
  }

  final _messages = StreamController<String>();
  final _pending = <String>[];
  WebSocket? _socket;
  StreamSubscription<WebSocketEvent>? _subscription;
  var _closed = false;

  @override
  Stream<String> get messages => _messages.stream;

  Future<void> _open(Uri server, String room, Duration timeout) async {
    final WebSocket socket;
    try {
      socket = await _connect(server, timeout);
    } on Object catch (error) {
      _fail(error);
      return;
    }
    if (_closed) {
      await _closeQuietly(socket);
      return;
    }
    _socket = socket;
    _subscription = socket.events.listen(
      _event,
      onError: (Object error, StackTrace _) => _fail(error),
      onDone: close,
    );
    _write(RelayJoin(room));
    for (final message in _pending) {
      _write(RelaySignal(message));
    }
    _pending.clear();
  }

  void _event(WebSocketEvent event) {
    switch (event) {
      case TextDataReceived(:final text):
        final RelayMessage message;
        try {
          message = RelayMessage.decode(text);
        } on FormatException {
          _fail(const SignalingException(RelayError.protocol));
          return;
        }
        switch (message) {
          case RelaySignal(:final data, client: null):
            if (!_closed) _messages.add(data);
          case RelayError(:final reason):
            _fail(SignalingException(reason));
          default:
            _fail(const SignalingException(RelayError.protocol));
        }
      case BinaryDataReceived():
        _fail(const SignalingException(RelayError.protocol));
      case CloseReceived():
        close();
    }
  }

  @override
  void send(String message) {
    _checkLength(message);
    if (_closed) return;
    if (_socket == null) {
      _pending.add(message);
    } else {
      _write(RelaySignal(message));
    }
  }

  void _write(RelayMessage message) {
    try {
      _socket!.sendText(message.encode());
    } on Object catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    _messages.addError(error);
    close();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    unawaited(_subscription?.cancel());
    final socket = _socket;
    if (socket != null) unawaited(_closeQuietly(socket));
    unawaited(_messages.close());
  }
}

void _validateTimeout(Duration timeout) {
  if (timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, 'timeout', 'must be positive');
  }
}

void _checkLength(String message) {
  // The server would refuse the whole connection for an oversized message.
  if (message.length > maxSignalingMessageLength) {
    throw ArgumentError.value(
      message.length,
      'message.length',
      'must not exceed $maxSignalingMessageLength',
    );
  }
}

Future<WebSocket> _connect(Uri server, Duration timeout) async {
  final connecting = WebSocket.connect(
    server,
    protocols: const [relaySubprotocol],
  );
  final WebSocket socket;
  try {
    socket = await connecting.timeout(timeout);
  } on TimeoutException {
    unawaited(connecting.then<void>(_closeQuietly, onError: (Object _) {}));
    rethrow;
  }
  if (socket.protocol != relaySubprotocol) {
    await _closeQuietly(socket);
    throw const SignalingException(
      'The server does not speak $relaySubprotocol.',
    );
  }
  return socket;
}

Future<void> _closeQuietly(WebSocket socket) async {
  try {
    await socket.close(1000);
  } on Object {
    // The socket is already closed or failed.
  }
}
