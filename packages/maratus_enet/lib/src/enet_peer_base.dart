import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:maratus/maratus.dart';

import 'enet_driver.dart';

const _headerSize = 10;
const _maxUnreliableBytes = 1000;
const _magic = [0x6d, 0x45, 0x4e, 1];

/// Validates options before allocating a native host.
void validateEnetOptions({
  required int channelCount,
  required int maxConnections,
  required QueueLimits incomingLimits,
  required QueueLimits outgoingLimits,
  required Duration serviceInterval,
  required Duration connectTimeout,
  required Duration closeTimeout,
}) {
  if (channelCount < 1 || channelCount > 85) {
    throw ArgumentError.value(channelCount, 'channelCount', 'must be 1..85');
  }
  if (maxConnections < 1 || maxConnections > 4095) {
    throw ArgumentError.value(
      maxConnections,
      'maxConnections',
      'must be 1..4095',
    );
  }
  for (final limits in [incomingLimits, outgoingLimits]) {
    if (limits.maxMessages <= 0 || limits.maxBytes <= 0) {
      throw ArgumentError.value(limits, 'limits', 'must be positive');
    }
  }
  for (final entry in {
    'serviceInterval': serviceInterval,
    'connectTimeout': connectTimeout,
    'closeTimeout': closeTimeout,
  }.entries) {
    if (entry.value <= Duration.zero) {
      throw ArgumentError.value(entry.value, entry.key, 'must be positive');
    }
  }
}

/// Internal polled-event engine shared by native ENet hosts and clients.
final class EnetPeerBase implements MultiplayerPeer {
  /// Creates the bounded transport engine around [driver].
  EnetPeerBase({
    required EnetDriver driver,
    required this.isHost,
    this.channelCount = 1,
    this.maxConnections = 64,
    this.incomingLimits = const QueueLimits(),
    this.outgoingLimits = const QueueLimits(),
    this.clock = const SystemClock(),
    this.serviceInterval = const Duration(milliseconds: 2),
    this.connectTimeout = const Duration(seconds: 10),
    this.closeTimeout = const Duration(seconds: 2),
  }) : _driver = driver {
    validateEnetOptions(
      channelCount: channelCount,
      maxConnections: maxConnections,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      serviceInterval: serviceInterval,
      connectTimeout: connectTimeout,
      closeTimeout: closeTimeout,
    );
    if (!isHost) {
      _connecting = true;
      _connectTimer = clock.schedule(connectTimeout, connectFailed);
    }
    _scheduleService();
  }

  final EnetDriver _driver;

  @override
  final bool isHost;

  /// Number of logical channels, each with independent delivery-mode lanes.
  final int channelCount;

  /// Bound on live connections and unconsumed connection lifecycle events.
  final int maxConnections;

  /// Per-connection received payload limits.
  final QueueLimits incomingLimits;

  /// Per-connection outstanding payload limits.
  final QueueLimits outgoingLimits;

  /// Clock driving native service, connection deadlines, and cleanup.
  final MonotonicClock clock;

  /// How often ENet is serviced without blocking the caller.
  final Duration serviceInterval;

  /// Maximum duration of an outgoing connection attempt, including DNS.
  final Duration connectTimeout;

  /// Maximum time allowed for draining a closing native connection.
  final Duration closeTimeout;

  final _events = Queue<PeerEvent>();
  final _connections = <int, _EnetConnection>{};
  final _nativePeers = <int>{};
  final _closing = <int, Duration>{};
  final _done = Completer<void>();
  Timer? _serviceTimer;
  Timer? _connectTimer;
  int? _dialPeer;
  var _connecting = false;
  var _closed = false;
  var _driverClosed = false;

  /// Whether the caller has closed this peer.
  bool get isClosed => _closed;

  /// Completes once the native host and service timers have been released.
  Future<void> get done => _done.future;

  /// The local UDP port.
  int get port => _driver.port;

  @override
  late final TransportCapabilities capabilities = TransportCapabilities(
    canHost: true,
    deliveryModes: const {
      DeliveryMode.reliable,
      DeliveryMode.unreliableOrdered,
      DeliveryMode.unreliable,
    },
    channelCount: channelCount,
    maxUnreliableMessageBytes: _maxUnreliableBytes,
  );

  /// Starts the native connection after asynchronous address resolution.
  void startConnect(String address, int port) {
    if (_closed || !_connecting || _driverClosed || _dialPeer != null) return;
    try {
      final peer = _driver.connect(address, port, channelCount * 3);
      _dialPeer = peer;
      _nativePeers.add(peer);
    } on Object {
      connectFailed();
    }
  }

  /// Reports a failed dial once, without a preceding open event.
  void connectFailed() {
    if (_closed || !_connecting) return;
    _connecting = false;
    _connectTimer?.cancel();
    _connectTimer = null;
    final peer = _dialPeer;
    if (peer != null) _reset(peer);
    final connection = _EnetConnection(this, peer ?? -1)
      .._open = false
      .._closeReason = CloseReason.connectFailed;
    _connections[connection._id] = connection;
    _events.add(ConnectionClosed(connection, CloseReason.connectFailed));
    _disposeDriver();
  }

  @override
  PeerEvent? poll() {
    if (_closed || _events.isEmpty) return null;
    final event = _events.removeFirst();
    final connection = event.connection as _EnetConnection;
    if (event is MessageReceived) {
      connection._taken(event);
    } else if (event is ConnectionOpened) {
      connection._openedPolled = true;
      if (connection.closeReason == CloseReason.local) {
        _connections.remove(connection._id);
      }
    } else if (event is ConnectionClosed) {
      _connections.remove(connection._id);
    }
    return event;
  }

  void _scheduleService() {
    if (_driverClosed) return;
    _serviceTimer = clock.schedule(serviceInterval, () {
      _serviceTimer = null;
      _service();
      _scheduleService();
    });
  }

  void _service() {
    try {
      // A busy or malicious remote cannot monopolize the event loop.
      for (var count = 0; count < 256; count++) {
        if (_driverClosed) break;
        final event = _driver.poll();
        if (event == null) break;
        switch (event) {
          case EnetDriverConnected():
            _connected(event);
          case EnetDriverReceived():
            _connections[event.peer]?._receive(event.channel, event.bytes);
          case EnetDriverSent():
            _connections[event.peer]?._released(event.token);
          case EnetDriverDisconnected():
            _nativePeers.remove(event.peer);
            _closing.remove(event.peer);
            if (_connecting && event.peer == _dialPeer) {
              connectFailed();
            } else {
              _connections[event.peer]?._end(
                event.graceful ? CloseReason.remote : CloseReason.lost,
                discardIncoming: false,
                disconnect: false,
              );
            }
        }
      }
      for (final entry in _closing.entries.toList()) {
        if (clock.now >= entry.value) _reset(entry.key);
      }
      if ((_closed || (!isHost && !_connecting)) && _nativePeers.isEmpty) {
        _disposeDriver();
      }
    } on Object {
      if (_connecting) connectFailed();
      for (final connection in _connections.values.toList()) {
        connection._end(
          CloseReason.lost,
          discardIncoming: false,
          disconnect: false,
        );
      }
      _disposeDriver();
    }
  }

  void _connected(EnetDriverConnected event) {
    if (_closed ||
        event.channelCount != channelCount * 3 ||
        _connections.containsKey(event.peer) ||
        _connections.length >= (isHost ? maxConnections : 1) ||
        (!isHost && (!_connecting || event.peer != _dialPeer))) {
      _reset(event.peer);
      if (!isHost && _connecting) connectFailed();
      return;
    }
    _nativePeers.add(event.peer);
    if (!isHost) {
      _connecting = false;
      _connectTimer?.cancel();
      _connectTimer = null;
    }
    final connection = _EnetConnection(this, event.peer);
    _connections[event.peer] = connection;
    _events.add(ConnectionOpened(connection));
  }

  void _discardIncoming(_EnetConnection connection) {
    _events.removeWhere(
      (event) => event is MessageReceived && event.connection == connection,
    );
    connection._incoming.clear();
    connection._incomingBytes = 0;
  }

  void _disconnect(int peer) {
    if (_driverClosed || !_nativePeers.contains(peer)) return;
    if (_closing.containsKey(peer)) return;
    _closing[peer] = clock.now + closeTimeout;
    try {
      _driver.disconnect(peer);
    } on Object {
      _reset(peer);
    }
  }

  void _reset(int peer) {
    _nativePeers.remove(peer);
    _closing.remove(peer);
    if (_driverClosed) return;
    try {
      _driver.reset(peer);
    } on Object {
      // Cleanup must not escape into the application's update loop.
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _connectTimer?.cancel();
    _connectTimer = null;
    if (_connecting) {
      _connecting = false;
      final peer = _dialPeer;
      if (peer != null) _reset(peer);
    }
    for (final connection in _connections.values.toList()) {
      connection.close();
      _discardIncoming(connection);
    }
    _events.clear();
    _connections.clear();
    if (_nativePeers.isEmpty) _disposeDriver();
  }

  void _disposeDriver() {
    if (_driverClosed) return;
    _driverClosed = true;
    _serviceTimer?.cancel();
    _serviceTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    _nativePeers.clear();
    _closing.clear();
    try {
      _driver.close();
    } on Object {
      // Disposal is best effort after a native service failure.
    }
    _done.complete();
  }
}

final class _EnetConnection implements PeerConnection {
  _EnetConnection(this._peer, this._id);

  final EnetPeerBase _peer;
  final int _id;
  final _incoming = <MessageReceived, int>{};
  final _outstanding = <int, ({int bytes, int channel, DeliveryMode mode})>{};
  final _pendingAcks = <int>{};
  var _incomingBytes = 0;
  var _outgoingBytes = 0;
  var _nextSequence = 1;
  var _nextAckToken = -1;
  var _open = true;
  var _openedPolled = false;
  CloseReason? _closeReason;

  @override
  bool get isOpen => _open;

  @override
  CloseReason? get closeReason => _closeReason;

  @override
  QueueDepth get incoming =>
      (messages: _incoming.length, bytes: _incomingBytes);

  @override
  QueueDepth get outgoing =>
      (messages: _outstanding.length, bytes: _outgoingBytes);

  @override
  bool send(
    Uint8List message, {
    DeliveryMode mode = DeliveryMode.reliable,
    int channel = 0,
  }) {
    if (!_peer.capabilities.supports(mode, channel: channel)) {
      throw UnsupportedError(
        'ENet channel must be 0..${_peer.channelCount - 1}.',
      );
    }
    if (mode != DeliveryMode.reliable && message.length > _maxUnreliableBytes) {
      throw ArgumentError.value(
        message.length,
        'message.length',
        'unreliable payloads must not exceed $_maxUnreliableBytes bytes',
      );
    }
    if (!_open) return false;
    if (!_peer.outgoingLimits.accepts(outgoing, message.length)) {
      _end(CloseReason.overflow, discardIncoming: true);
      return false;
    }
    final sequence = _nextSequence;
    _nextSequence = sequence == 0xffffffff ? 1 : sequence + 1;
    // Do not reuse a sequence while an earlier packet with that identity lives.
    if (_outstanding.containsKey(sequence)) {
      _end(CloseReason.overflow, discardIncoming: true);
      return false;
    }
    final frame = _frame(0, mode, sequence, message.length);
    frame.setRange(_headerSize, frame.length, message);
    _outstanding[sequence] = (
      bytes: message.length,
      channel: channel,
      mode: mode,
    );
    _outgoingBytes += message.length;
    return _write(
      frame,
      channel * 3 + mode.index,
      mode,
      token: mode == DeliveryMode.reliable ? null : sequence,
    );
  }

  bool _write(
    Uint8List frame,
    int nativeChannel,
    DeliveryMode mode, {
    int? token,
  }) {
    try {
      if (_peer._driver.send(_id, nativeChannel, frame, mode, token: token)) {
        return true;
      }
    } on Object {
      // A failed native send closes just this connection.
    }
    _end(CloseReason.lost, discardIncoming: true);
    return false;
  }

  void _receive(int nativeChannel, Uint8List frame) {
    if (!_open) return;
    if (frame.length < _headerSize ||
        nativeChannel < 0 ||
        nativeChannel >= _peer.channelCount * 3 ||
        frame[0] != _magic[0] ||
        frame[1] != _magic[1] ||
        frame[2] != _magic[2] ||
        frame[3] != _magic[3] ||
        frame[5] >= DeliveryMode.values.length ||
        frame[5] != nativeChannel % 3) {
      _end(CloseReason.lost, discardIncoming: true);
      return;
    }
    final sequence = ByteData.sublistView(frame).getUint32(6);
    if (sequence == 0) {
      _end(CloseReason.lost, discardIncoming: true);
      return;
    }
    final channel = nativeChannel ~/ 3;
    final mode = DeliveryMode.values[frame[5]];
    if (frame[4] == 1) {
      final pending = _outstanding[sequence];
      if (frame.length != _headerSize ||
          mode != DeliveryMode.reliable ||
          pending == null ||
          pending.mode != DeliveryMode.reliable ||
          pending.channel != channel) {
        _end(CloseReason.lost, discardIncoming: true);
        return;
      }
      _outstanding.remove(sequence);
      _outgoingBytes -= pending.bytes;
      return;
    }
    if (frame[4] != 0 ||
        (mode != DeliveryMode.reliable &&
            frame.length - _headerSize > _maxUnreliableBytes)) {
      _end(CloseReason.lost, discardIncoming: true);
      return;
    }
    // ENet handles reliable ordering and retransmission deduplication. The
    // sequence is a consumption-credit identity shared across all channels;
    // a quiet channel may therefore observe arbitrarily large sequence gaps.
    final size = frame.length - _headerSize;
    if (!_peer.incomingLimits.accepts(incoming, size)) {
      // A datagram may be lost anyway; only reliable data must arrive.
      if (mode == DeliveryMode.reliable) {
        _end(CloseReason.overflow, discardIncoming: true);
      }
      return;
    }
    final event = MessageReceived(
      this,
      Uint8List.fromList(frame.sublist(_headerSize)),
      mode: mode,
      channel: channel,
    );
    _incoming[event] = sequence;
    _incomingBytes += size;
    _peer._events.add(event);
  }

  void _taken(MessageReceived event) {
    final sequence = _incoming.remove(event)!;
    _incomingBytes -= event.message.length;
    if (!_open || event.mode != DeliveryMode.reliable) return;
    // Control packets also need a native queue bound: a raw ENet sender may
    // consume our payloads without acknowledging these reliable ACK packets.
    if (_pendingAcks.length >= _peer.outgoingLimits.maxMessages) {
      _end(CloseReason.overflow, discardIncoming: true);
      return;
    }
    final token = _nextAckToken;
    _nextAckToken = token == -0x7fffffff ? -1 : token - 1;
    if (!_pendingAcks.add(token)) {
      _end(CloseReason.overflow, discardIncoming: true);
      return;
    }
    try {
      // ENet can enter its disconnect handshake before the service loop has
      // returned the terminal event. An ACK rejected in that state must not
      // discard payloads already accepted before the remote closed.
      final accepted = _peer._driver.send(
        _id,
        event.channel * 3,
        _frame(1, DeliveryMode.reliable, sequence, 0),
        DeliveryMode.reliable,
        token: token,
      );
      if (!accepted) _pendingAcks.remove(token);
    } on Object {
      _pendingAcks.remove(token);
      // Let native service report the connection outcome in event order.
    }
  }

  void _released(int token) {
    if (token < 0) {
      _pendingAcks.remove(token);
      return;
    }
    final pending = _outstanding[token];
    if (pending == null || pending.mode == DeliveryMode.reliable) return;
    _outstanding.remove(token);
    _outgoingBytes -= pending.bytes;
  }

  @override
  void close() => _end(CloseReason.local, discardIncoming: true);

  void _end(
    CloseReason reason, {
    required bool discardIncoming,
    bool disconnect = true,
  }) {
    if (!_open) return;
    _open = false;
    _closeReason = reason;
    _outstanding.clear();
    _pendingAcks.clear();
    _outgoingBytes = 0;
    if (discardIncoming) _peer._discardIncoming(this);
    if (reason != CloseReason.local && !_peer.isClosed) {
      _peer._events.add(ConnectionClosed(this, reason));
    } else if (_openedPolled) {
      _peer._connections.remove(_id);
    }
    if (disconnect) _peer._disconnect(_id);
  }
}

Uint8List _frame(int kind, DeliveryMode mode, int sequence, int payloadSize) {
  final frame = Uint8List(_headerSize + payloadSize);
  frame.setRange(0, _magic.length, _magic);
  frame[4] = kind;
  frame[5] = mode.index;
  ByteData.sublistView(frame).setUint32(6, sequence);
  return frame;
}
