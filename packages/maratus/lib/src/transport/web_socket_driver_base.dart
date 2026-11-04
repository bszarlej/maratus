import 'dart:typed_data';

/// The WebSocket subprotocol used by this transport's binary framing.
const webSocketProtocol = 'maratus-v1';

/// An opening handshake that can be cancelled before a driver is ready.
abstract interface class WebSocketDial {
  /// Completes with the open socket, or with a connection error.
  Future<WebSocketDriver> get ready;

  /// Cancels an outstanding opening handshake and releases its resources.
  Future<void> cancel();
}

/// The platform-specific part of a connected WebSocket.
abstract interface class WebSocketDriver {
  /// Whether the socket still accepts outgoing messages.
  bool get isOpen;

  /// Incoming binary or text messages, followed by socket errors or closure.
  Stream<Object> get messages;

  /// The received close code, when one has been received.
  int? get closeCode;

  /// Enqueues binary data on the open socket.
  void send(Uint8List message);

  /// Closes the socket after already enqueued data, and releases resources.
  Future<void> close();
}

/// The platform-specific part of a WebSocket listener.
abstract interface class WebSocketListener {
  /// The actual bound port, including the selected port when zero was requested.
  int get port;

  /// Accepted sockets that selected [webSocketProtocol].
  Stream<WebSocketDriver> get connections;

  /// Stops accepting connections, leaving accepted sockets to their owners.
  Future<void> close();
}
