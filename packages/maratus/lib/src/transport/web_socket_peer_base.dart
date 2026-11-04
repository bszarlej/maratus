import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'multiplayer_peer.dart';
import 'web_socket_driver_base.dart';

/// Shared, platform-independent WebSocket event and queue implementation.
///
/// This is an implementation detail; applications use the public host/client.
final class WebSocketPeerBase implements MultiplayerPeer {
  /// Creates a peer with bounded per-connection payload queues.
  WebSocketPeerBase({
    required this.isHost,
    this.incomingLimits = const QueueLimits(),
    this.outgoingLimits = const QueueLimits(),
    this.maxConnections = 64,
    Future<void> Function()? onClose,
  }) : _onClose = onClose {
    for (final limits in [incomingLimits, outgoingLimits]) {
      if (limits.maxMessages <= 0 || limits.maxBytes <= 0) {
        throw ArgumentError.value(limits, 'limits', 'must be positive');
      }
    }
    if (maxConnections <= 0) {
      throw ArgumentError.value(
        maxConnections,
        'maxConnections',
        'must be positive',
      );
    }
  }

  @override
  final bool isHost;

  /// Limits on received payloads that have not been polled.
  final QueueLimits incomingLimits;

  /// Limits on sent payloads that have not been acknowledged by remote polling.
  final QueueLimits outgoingLimits;

  /// Bounds live connections and closed connections with unpolled events.
  final int maxConnections;

  final Future<void> Function()? _onClose;
  final _events = Queue<PeerEvent>();
  final _connections = <WebSocketConnection>{};
  final _cleanup = <Future<void>>{};
  final _done = Completer<void>();
  var _closed = false;

  /// Whether this peer has been explicitly closed.
  bool get isClosed => _closed;

  /// Completes when explicit close has released platform resources.
  Future<void> get done => _done.future;

  @override
  TransportCapabilities get capabilities =>
      TransportCapabilities(canHost: isHost);

  /// Attaches an established socket, or closes it if admission is full.
  WebSocketConnection? attach(WebSocketDriver driver) {
    if (_closed || _connections.length >= (isHost ? maxConnections : 1)) {
      _track(Future<void>.sync(driver.close));
      return null;
    }
    final connection = WebSocketConnection._(this, driver);
    _connections.add(connection);
    _events.add(ConnectionOpened(connection));
    connection._listen();
    return connection;
  }

  /// Reports one failed outgoing connection attempt without an open event.
  void connectFailed() {
    if (_closed || _connections.isNotEmpty) return;
    final connection = WebSocketConnection._(this, null)
      .._open = false
      .._closeReason = CloseReason.connectFailed;
    _connections.add(connection);
    _events.add(ConnectionClosed(connection, CloseReason.connectFailed));
  }

  @override
  PeerEvent? poll() {
    if (_events.isEmpty) return null;
    final event = _events.removeFirst();
    final connection = event.connection as WebSocketConnection;
    if (event is MessageReceived) {
      connection._taken(event.message.length);
    } else if (event is ConnectionOpened) {
      connection._openedPolled = true;
      if (connection._closeReason == CloseReason.local) {
        _connections.remove(connection);
      }
    } else if (event is ConnectionClosed) {
      _connections.remove(connection);
    }
    return event;
  }

  void _discardMessages(WebSocketConnection connection) {
    _events.removeWhere(
      (event) => event is MessageReceived && event.connection == connection,
    );
    connection._incomingBytes = 0;
    connection._incomingSequences.clear();
  }

  void _track(Future<void> operation) {
    // Socket close/cancellation errors must not escape into the game loop.
    late final Future<void> guarded;
    guarded = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _cleanup.remove(guarded));
    _cleanup.add(guarded);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final connection in _connections.toList()) {
      connection.close();
      _discardMessages(connection);
    }
    _events.clear();
    _connections.clear();
    if (_onClose != null) _track(Future<void>.sync(_onClose));
    unawaited(_finishClose());
  }

  Future<void> _finishClose() async {
    while (_cleanup.isNotEmpty) {
      await Future.wait(_cleanup.toList());
    }
    _done.complete();
  }
}

/// One ordered binary WebSocket connection used by the shared peer engine.
final class WebSocketConnection implements PeerConnection {
  WebSocketConnection._(this._peer, this._driver);

  final WebSocketPeerBase _peer;
  final WebSocketDriver? _driver;
  StreamSubscription<Object>? _subscription;
  final _outstanding = Queue<({int sequence, int bytes})>();
  final _incomingSequences = Queue<int>();
  var _outgoingBytes = 0;
  var _incomingBytes = 0;
  var _nextSent = 1;
  var _nextReceived = 1;
  var _open = true;
  var _openedPolled = false;
  var _cleanedUp = false;
  CloseReason? _closeReason;

  @override
  bool get isOpen => _open;

  @override
  CloseReason? get closeReason => _closeReason;

  @override
  QueueDepth get incoming =>
      (messages: _incomingSequences.length, bytes: _incomingBytes);

  @override
  QueueDepth get outgoing =>
      (messages: _outstanding.length, bytes: _outgoingBytes);

  void _listen() {
    _subscription = _driver!.messages.listen(
      _receive,
      onError: (Object error) => _end(CloseReason.lost, discardIncoming: false),
      onDone: () => _end(
        _driver.closeCode == 1000 || _driver.closeCode == 1001
            ? CloseReason.remote
            : CloseReason.lost,
        discardIncoming: false,
      ),
    );
  }

  @override
  bool send(
    Uint8List message, {
    DeliveryMode mode = DeliveryMode.reliable,
    int channel = 0,
  }) {
    if (!_peer.capabilities.supports(mode, channel: channel)) {
      throw UnsupportedError(
        'WebSockets support only reliable delivery on channel 0.',
      );
    }
    if (!_open) return false;
    if (!_peer.outgoingLimits.accepts(outgoing, message.length)) {
      _end(CloseReason.overflow, discardIncoming: true);
      return false;
    }
    final frame = Uint8List(message.length + 5);
    ByteData.sublistView(frame).setUint32(1, _nextSent);
    frame.setRange(5, frame.length, message);
    _outstanding.add((sequence: _nextSent, bytes: message.length));
    _outgoingBytes += message.length;
    _nextSent = _advance(_nextSent);
    return _write(frame);
  }

  bool _write(Uint8List frame) {
    try {
      _driver!.send(frame);
      return true;
    } on Object {
      final normalClose =
          _driver!.closeCode == 1000 || _driver.closeCode == 1001;
      _end(
        normalClose ? CloseReason.remote : CloseReason.lost,
        discardIncoming: !normalClose,
      );
      return false;
    }
  }

  void _receive(Object data) {
    if (!_open) return;
    if (data is! List<int> || data.length < 5) {
      _end(CloseReason.lost, discardIncoming: true);
      return;
    }
    // The platform returns binary frames as bytes. Do not retain its buffer.
    final frame = data is Uint8List ? data : Uint8List.fromList(data);
    final sequence = ByteData.sublistView(frame).getUint32(1);
    if (frame[0] == 1) {
      if (frame.length != 5 ||
          _outstanding.isEmpty ||
          _outstanding.first.sequence != sequence) {
        _end(CloseReason.lost, discardIncoming: true);
        return;
      }
      _outgoingBytes -= _outstanding.removeFirst().bytes;
    } else if (frame[0] == 0 && sequence == _nextReceived) {
      final size = frame.length - 5;
      if (!_peer.incomingLimits.accepts(incoming, size)) {
        _end(CloseReason.overflow, discardIncoming: true);
        return;
      }
      _nextReceived = _advance(_nextReceived);
      _incomingSequences.add(sequence);
      _incomingBytes += size;
      _peer._events.add(
        MessageReceived(this, Uint8List.fromList(frame.sublist(5))),
      );
    } else {
      _end(CloseReason.lost, discardIncoming: true);
    }
  }

  void _taken(int size) {
    final sequence = _incomingSequences.removeFirst();
    _incomingBytes -= size;
    if (!_open) return;
    // The socket can have entered its closing handshake before its ordered
    // stream delivers onDone. A consumed message needs no ACK at that point;
    // wait for the stream to report the reason after all preceding payloads.
    if (!_driver!.isOpen) return;
    final acknowledgement = Uint8List(5)..[0] = 1;
    ByteData.sublistView(acknowledgement).setUint32(1, sequence);
    try {
      _driver.send(acknowledgement);
    } on Object {
      // The remote closing handshake can race this bookkeeping write. Let the
      // socket's ordered stream report its failure/closure after any remaining
      // payloads; cancelling it here could discard data sent before close.
    }
  }

  @override
  void close() => _end(CloseReason.local, discardIncoming: true);

  void _end(CloseReason reason, {required bool discardIncoming}) {
    if (!_open) return;
    _open = false;
    _closeReason = reason;
    _outstanding.clear();
    _outgoingBytes = 0;
    if (discardIncoming) _peer._discardMessages(this);
    if (reason != CloseReason.local && !_peer.isClosed) {
      _peer._events.add(ConnectionClosed(this, reason));
    } else if (_openedPolled) {
      _peer._connections.remove(this);
    }
    _cleanup();
  }

  void _cleanup() {
    if (_cleanedUp) return;
    _cleanedUp = true;
    final cancellation = _subscription?.cancel();
    if (cancellation != null) _peer._track(cancellation);
    final driver = _driver;
    if (driver != null) _peer._track(Future<void>.sync(driver.close));
  }
}

int _advance(int sequence) => sequence == 0xffffffff ? 1 : sequence + 1;
