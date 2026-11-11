import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:maratus/maratus.dart';

import 'ice_server.dart';
import 'signaling.dart';
import 'signaling_protocol.dart';
import 'webrtc_driver.dart';

/// The largest number of logical channels a connection can use.
const maxWebRtcChannels = 64;

/// The largest number of connections a host can accept.
const maxWebRtcConnections = 1024;

/// The largest reliable payload carried by one data-channel message.
///
/// Larger reliable messages are split into chunks of this size, which every
/// WebRTC implementation can deliver.
const reliableChunkBytes = 16 * 1024;

/// The largest unreliable payload, which keeps a message within one packet.
const maxUnreliableBytes = 1000;

// Every data-channel message starts with a kind, a delivery mode, and a
// 32-bit sequence number.
const _headerSize = 6;
const _kindMessage = 0;
const _kindAck = 1;
const _kindClose = 2;
const _kindPart = 3;

const _maxRemoteCandidates = 128;
const _maxEarlyFrames = 64;
const _maxEventsPerService = 256;

/// Validates options before any WebRTC resources are created.
void validateWebRtcOptions({
  required int channelCount,
  required int maxConnections,
  required QueueLimits incomingLimits,
  required QueueLimits outgoingLimits,
  required List<IceServer> iceServers,
  required Duration serviceInterval,
  required Duration connectTimeout,
  required Duration closeTimeout,
}) {
  if (channelCount < 1 || channelCount > maxWebRtcChannels) {
    throw ArgumentError.value(
      channelCount,
      'channelCount',
      'must be 1..$maxWebRtcChannels',
    );
  }
  if (maxConnections < 1 || maxConnections > maxWebRtcConnections) {
    throw ArgumentError.value(
      maxConnections,
      'maxConnections',
      'must be 1..$maxWebRtcConnections',
    );
  }
  for (final limits in [incomingLimits, outgoingLimits]) {
    if (limits.maxMessages <= 0 || limits.maxBytes <= 0) {
      throw ArgumentError.value(limits, 'limits', 'must be positive');
    }
  }
  validateIceServers(iceServers);
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

/// Internal polled-event engine shared by WebRTC hosts and clients.
///
/// Connections are negotiated through signaling and then carry framed
/// payloads over a driver's lanes. Each logical channel uses a reliable
/// ordered lane and an unordered lane without retransmissions. Reliable
/// payloads hold outgoing credit until the receiving application polls them
/// and its acknowledgement arrives. Unreliable payloads hold credit until
/// the driver has handed them to the network.
final class WebRtcPeerBase implements MultiplayerPeer {
  WebRtcPeerBase._({
    required WebRtcDriver driver,
    required this.isHost,
    required this.iceServers,
    required this.channelCount,
    required this.maxConnections,
    required this.incomingLimits,
    required this.outgoingLimits,
    required this.clock,
    required this.serviceInterval,
    required this.connectTimeout,
    required this.closeTimeout,
  }) : _driver = driver {
    validateWebRtcOptions(
      channelCount: channelCount,
      maxConnections: maxConnections,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      iceServers: iceServers,
      serviceInterval: serviceInterval,
      connectTimeout: connectTimeout,
      closeTimeout: closeTimeout,
    );
    _scheduleService();
  }

  /// Creates a host that accepts clients arriving through [signaling].
  factory WebRtcPeerBase.host({
    required WebRtcDriver driver,
    required HostSignaling signaling,
    List<IceServer> iceServers = const [],
    int channelCount = 1,
    int maxConnections = 64,
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
    MonotonicClock clock = const SystemClock(),
    Duration serviceInterval = const Duration(milliseconds: 2),
    Duration connectTimeout = const Duration(seconds: 15),
    Duration closeTimeout = const Duration(seconds: 2),
  }) {
    final peer = WebRtcPeerBase._(
      driver: driver,
      isHost: true,
      iceServers: iceServers,
      channelCount: channelCount,
      maxConnections: maxConnections,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      clock: clock,
      serviceInterval: serviceInterval,
      connectTimeout: connectTimeout,
      closeTimeout: closeTimeout,
    );
    peer._hostSignaling = signaling;
    peer._clients = signaling.clients.listen(
      peer._accept,
      onError: (Object _, StackTrace _) {},
    );
    return peer;
  }

  /// Creates a client that connects to the host reachable through
  /// [signaling].
  factory WebRtcPeerBase.client({
    required WebRtcDriver driver,
    required SignalingChannel signaling,
    List<IceServer> iceServers = const [],
    int channelCount = 1,
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
    MonotonicClock clock = const SystemClock(),
    Duration serviceInterval = const Duration(milliseconds: 2),
    Duration connectTimeout = const Duration(seconds: 15),
    Duration closeTimeout = const Duration(seconds: 2),
  }) {
    final peer = WebRtcPeerBase._(
      driver: driver,
      isHost: false,
      iceServers: iceServers,
      channelCount: channelCount,
      maxConnections: 1,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      clock: clock,
      serviceInterval: serviceInterval,
      connectTimeout: connectTimeout,
      closeTimeout: closeTimeout,
    );
    peer._dial(signaling);
    return peer;
  }

  final WebRtcDriver _driver;

  @override
  final bool isHost;

  /// The STUN and TURN servers used to find network paths.
  final List<IceServer> iceServers;

  /// The number of logical channels, each with a reliable and an unreliable
  /// lane.
  final int channelCount;

  /// Bound on negotiating and live connections, and on closed connections
  /// whose terminal events have not been polled.
  final int maxConnections;

  /// Per-connection limits on received payloads that have not been polled.
  final QueueLimits incomingLimits;

  /// Per-connection limits on outstanding sent payloads.
  final QueueLimits outgoingLimits;

  /// Clock driving driver service, negotiation deadlines, and cleanup.
  final MonotonicClock clock;

  /// How often driver events are processed and sent data is accounted for.
  final Duration serviceInterval;

  /// Maximum duration of a connection's negotiation.
  final Duration connectTimeout;

  /// Maximum time a locally closed connection may drain before release.
  final Duration closeTimeout;

  final _events = Queue<PeerEvent>();
  final _connections = <_WebRtcConnection>{};
  final _links = <int, _WebRtcConnection>{};
  final _draining = <int, Duration>{};
  final _done = Completer<void>();
  HostSignaling? _hostSignaling;
  StreamSubscription<SignalingChannel>? _clients;
  Timer? _serviceTimer;
  var _clientFinished = false;
  var _closed = false;
  var _disposed = false;

  int get _laneCount => channelCount * 2;

  /// Bound on data a reliable lane may hold before it accepts another
  /// acknowledgement: outgoing credit with its framing, and one
  /// acknowledgement per queued message.
  int get _reliableBufferLimit =>
      outgoingLimits.maxBytes +
      (2 * outgoingLimits.maxMessages +
              outgoingLimits.maxBytes ~/ reliableChunkBytes +
              channelCount) *
          _headerSize;

  /// Whether the caller has closed this peer.
  bool get isClosed => _closed;

  /// Completes once the driver and the service timer have been released.
  Future<void> get done => _done.future;

  @override
  late final TransportCapabilities capabilities = TransportCapabilities(
    canHost: true,
    deliveryModes: const {
      DeliveryMode.reliable,
      DeliveryMode.unreliableOrdered,
      DeliveryMode.unreliable,
    },
    channelCount: channelCount,
    maxUnreliableMessageBytes: maxUnreliableBytes,
  );

  @override
  PeerEvent? poll() {
    if (_closed || _events.isEmpty) return null;
    final event = _events.removeFirst();
    final connection = event.connection as _WebRtcConnection;
    switch (event) {
      case MessageReceived():
        connection._taken(event);
      case ConnectionOpened():
        connection._openedPolled = true;
        if (connection.closeReason == CloseReason.local) {
          _connections.remove(connection);
        }
      case ConnectionClosed():
        _connections.remove(connection);
    }
    return event;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _stopSignaling();
    for (final connection in _connections.toList()) {
      if (connection._negotiating) {
        connection._handshakeFailed();
      } else {
        connection.close();
        _discardIncoming(connection);
      }
    }
    _events.clear();
    _connections.clear();
    _disposeIfIdle();
  }

  void _accept(SignalingChannel signaling) {
    if (_closed || _connections.length >= maxConnections) {
      try {
        signaling.send(const RejectMessage(RejectMessage.full).encode());
        signaling.close();
      } on Object {
        // A refused client's signaling must not affect the host.
      }
      return;
    }
    final connection = _WebRtcConnection(this, signaling);
    _connections.add(connection);
    connection._start();
  }

  void _dial(SignalingChannel signaling) {
    final connection = _WebRtcConnection(this, signaling);
    _connections.add(connection);
    connection._start();
    if (!connection._negotiating) return;
    try {
      final id = _driver.open(_laneCount, iceServers);
      connection._id = id;
      _links[id] = connection;
      _driver.createOffer(id);
    } on Object {
      connection._handshakeFailed();
    }
  }

  void _stopSignaling() {
    unawaited(_clients?.cancel());
    _clients = null;
    final signaling = _hostSignaling;
    _hostSignaling = null;
    try {
      signaling?.close();
    } on Object {
      // Releasing signaling is best effort.
    }
  }

  void _scheduleService() {
    if (_disposed) return;
    _serviceTimer = clock.schedule(serviceInterval, () {
      _serviceTimer = null;
      _service();
      _scheduleService();
    });
  }

  void _service() {
    try {
      // A busy or malicious remote cannot monopolize the event loop.
      for (var count = 0; count < _maxEventsPerService; count++) {
        if (_disposed) break;
        final event = _driver.poll();
        if (event == null) break;
        _links[event.connection]?._driverEvent(event);
      }
      for (final connection in _links.values.toList()) {
        connection._releaseSent();
      }
      final now = clock.now;
      for (final entry in _draining.entries.toList()) {
        if (now >= entry.value) _release(entry.key);
      }
    } on Object {
      _fail();
    }
    _disposeIfIdle();
  }

  /// Ends every connection after the driver itself failed.
  void _fail() {
    for (final connection in _connections.toList()) {
      if (connection._negotiating) {
        connection._handshakeFailed();
      } else {
        connection._end(CloseReason.lost, discardIncoming: false);
      }
    }
    for (final id in _links.keys.toList()) {
      _release(id);
    }
    _stopSignaling();
    _dispose();
  }

  void _discardIncoming(_WebRtcConnection connection) {
    _events.removeWhere(
      (event) => event is MessageReceived && event.connection == connection,
    );
    connection._incoming.clear();
    connection._incomingBytes = 0;
  }

  /// Sends close markers after the data already queued on [id], and
  /// releases the connection once the remote closes it or [closeTimeout]
  /// passes.
  void _drain(int id) {
    if (!_links.containsKey(id) || _draining.containsKey(id)) return;
    try {
      for (var channel = 0; channel < channelCount; channel++) {
        _driver.send(id, channel * 2, _control(_kindClose, 0));
      }
    } on Object {
      _release(id);
      return;
    }
    _draining[id] = clock.now + closeTimeout;
  }

  void _release(int id) {
    _draining.remove(id);
    if (_links.remove(id) == null || _disposed) return;
    try {
      _driver.close(id);
    } on Object {
      // Cleanup must not escape into the application's update loop.
    }
  }

  void _disposeIfIdle() {
    if (_disposed || _links.isNotEmpty) return;
    if (_closed || (!isHost && _clientFinished)) _dispose();
  }

  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    _serviceTimer?.cancel();
    _serviceTimer = null;
    _links.clear();
    _draining.clear();
    _stopSignaling();
    try {
      _driver.dispose();
    } on Object {
      // Disposal is best effort after a driver failure.
    }
    _done.complete();
  }
}

final class _WebRtcConnection implements PeerConnection {
  _WebRtcConnection(this._peer, this._signaling)
    : _sentBytes = List<int>.filled(_peer._laneCount, 0);

  final WebRtcPeerBase _peer;

  // Negotiation.
  SignalingChannel? _signaling;
  StreamSubscription<String>? _signals;
  Timer? _deadline;
  int? _id;
  var _negotiating = true;
  var _described = false;
  var _remoteDescribed = false;
  var _remoteCandidates = 0;
  final _openLanes = <int>{};
  final _early = <WebRtcDriverMessage>[];

  // Data.
  final _incoming = <MessageReceived, int>{};
  final _outstanding = <int, ({int bytes, int channel, DeliveryMode mode})>{};
  final List<int> _sentBytes;
  final _unsent = <int, Queue<({int sequence, int end})>>{};
  final _partial = <int, ({int sequence, BytesBuilder bytes})>{};
  final _lastOrdered = <int, int>{};
  final _closedChannels = <int>{};
  var _incomingBytes = 0;
  var _outgoingBytes = 0;
  var _nextSequence = 1;
  var _open = false;
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

  void _start() {
    _deadline = _peer.clock.schedule(_peer.connectTimeout, _handshakeFailed);
    _signals = _signaling!.messages.listen(
      _signal,
      onError: (Object _, StackTrace _) => _signalingEnded(),
      onDone: _signalingEnded,
    );
  }

  void _signal(String text) {
    if (!_negotiating) return;
    final SignalingMessage message;
    try {
      message = SignalingMessage.decode(text);
    } on FormatException {
      _handshakeFailed();
      return;
    }
    if (_peer.isHost) {
      _hostSignal(message);
    } else {
      _clientSignal(message);
    }
  }

  void _hostSignal(SignalingMessage message) {
    switch (message) {
      case OfferMessage() when !_remoteDescribed:
        if (message.version != webRtcProtocolVersion ||
            message.channelCount != _peer.channelCount) {
          _send(const RejectMessage(RejectMessage.incompatible));
          _handshakeFailed();
          return;
        }
        _remoteDescribed = true;
        try {
          final id = _peer._driver.open(_peer._laneCount, _peer.iceServers);
          _id = id;
          _peer._links[id] = this;
          _peer._driver.acceptOffer(id, message.sdp);
        } on Object {
          _handshakeFailed();
        }
      case CandidateMessage() when _remoteDescribed:
        _addCandidate(message);
      default:
        _handshakeFailed();
    }
  }

  void _clientSignal(SignalingMessage message) {
    switch (message) {
      case AnswerMessage() when _described && !_remoteDescribed:
        _remoteDescribed = true;
        try {
          _peer._driver.acceptAnswer(_id!, message.sdp);
        } on Object {
          _handshakeFailed();
        }
      case CandidateMessage() when _remoteDescribed:
        _addCandidate(message);
      default:
        _handshakeFailed();
    }
  }

  void _addCandidate(CandidateMessage message) {
    if (++_remoteCandidates > _maxRemoteCandidates) {
      _handshakeFailed();
      return;
    }
    try {
      _peer._driver.addCandidate(_id!, message.candidate, message.mid);
    } on Object {
      // An unusable candidate leaves the other network paths to be tried.
    }
  }

  void _signalingEnded() {
    _closeSignaling();
    // Negotiation can finish without signaling once the remote description
    // has been applied; candidates already exchanged may suffice.
    if (_negotiating && !_remoteDescribed) _handshakeFailed();
  }

  bool _send(SignalingMessage message) {
    final signaling = _signaling;
    if (signaling == null) return false;
    try {
      signaling.send(message.encode());
      return true;
    } on Object {
      return false;
    }
  }

  void _closeSignaling() {
    unawaited(_signals?.cancel());
    _signals = null;
    final signaling = _signaling;
    _signaling = null;
    try {
      signaling?.close();
    } on Object {
      // Releasing signaling is best effort.
    }
  }

  void _driverEvent(WebRtcDriverEvent event) {
    switch (event) {
      case WebRtcDriverDescription(:final sdp):
        if (!_negotiating || _described) return;
        _described = true;
        final SignalingMessage message = _peer.isHost
            ? AnswerMessage(sdp)
            : OfferMessage(sdp: sdp, channelCount: _peer.channelCount);
        if (!_send(message)) _handshakeFailed();
      case WebRtcDriverCandidate(:final candidate, :final mid):
        if (_negotiating) _send(CandidateMessage(candidate, mid));
      case WebRtcDriverLaneOpened(:final lane):
        if (!_negotiating) return;
        if (lane < 0 || lane >= _peer._laneCount) {
          _handshakeFailed();
          return;
        }
        _openLanes.add(lane);
        if (_openLanes.length == _peer._laneCount) _opened();
      case WebRtcDriverMessage():
        if (!_negotiating) {
          _receive(event.lane, event.bytes);
        } else if (_early.length < _maxEarlyFrames) {
          // Lanes open with the association, but their events can be
          // reported after the first data on an earlier lane.
          _early.add(event);
        } else {
          _handshakeFailed();
        }
      case WebRtcDriverClosed():
        _driverClosed();
    }
  }

  void _opened() {
    _negotiating = false;
    _deadline?.cancel();
    _deadline = null;
    _closeSignaling();
    _open = true;
    _peer._events.add(ConnectionOpened(this));
    final early = List.of(_early);
    _early.clear();
    for (final frame in early) {
      _receive(frame.lane, frame.bytes);
    }
  }

  /// Abandons negotiation. Only a client reports the failure.
  void _handshakeFailed() {
    if (!_negotiating) return;
    _negotiating = false;
    _deadline?.cancel();
    _deadline = null;
    _early.clear();
    _closeSignaling();
    if (_peer.isHost) {
      _peer._connections.remove(this);
    } else {
      _closeReason = CloseReason.connectFailed;
      _peer._clientFinished = true;
      if (!_peer._closed) {
        _peer._events.add(ConnectionClosed(this, CloseReason.connectFailed));
      }
    }
    final id = _id;
    if (id != null) _peer._release(id);
    _peer._disposeIfIdle();
  }

  void _driverClosed() {
    if (_negotiating) {
      _handshakeFailed();
      return;
    }
    _end(CloseReason.lost, discardIncoming: false);
    _peer._release(_id!);
    _peer._disposeIfIdle();
  }

  @override
  bool send(
    Uint8List message, {
    DeliveryMode mode = DeliveryMode.reliable,
    int channel = 0,
  }) {
    if (!_peer.capabilities.supports(mode, channel: channel)) {
      throw UnsupportedError(
        'WebRTC channel must be 0..${_peer.channelCount - 1}.',
      );
    }
    if (mode != DeliveryMode.reliable && message.length > maxUnreliableBytes) {
      throw ArgumentError.value(
        message.length,
        'message.length',
        'unreliable payloads must not exceed $maxUnreliableBytes bytes',
      );
    }
    if (!_open) return false;
    if (!_peer.outgoingLimits.accepts(outgoing, message.length)) {
      _end(CloseReason.overflow, discardIncoming: true);
      return false;
    }
    final sequence = _nextSequence;
    _nextSequence = sequence == 0xffffffff ? 1 : sequence + 1;
    // Do not reuse a sequence while an earlier payload with it is pending.
    if (_outstanding.containsKey(sequence)) {
      _end(CloseReason.overflow, discardIncoming: true);
      return false;
    }
    _outstanding[sequence] = (
      bytes: message.length,
      channel: channel,
      mode: mode,
    );
    _outgoingBytes += message.length;
    final driver = _peer._driver;
    final id = _id!;
    try {
      if (mode == DeliveryMode.reliable) {
        final lane = channel * 2;
        var start = 0;
        while (message.length - start > reliableChunkBytes) {
          final end = start + reliableChunkBytes;
          driver.send(
            id,
            lane,
            _frame(_kindPart, mode, sequence, message, start, end),
          );
          start = end;
        }
        driver.send(
          id,
          lane,
          _frame(_kindMessage, mode, sequence, message, start, message.length),
        );
      } else {
        final lane = channel * 2 + 1;
        final frame = _frame(
          _kindMessage,
          mode,
          sequence,
          message,
          0,
          message.length,
        );
        driver.send(id, lane, frame);
        final end = _sentBytes[lane] += frame.length;
        (_unsent[lane] ??= Queue()).add((sequence: sequence, end: end));
      }
      return true;
    } on Object {
      _end(CloseReason.lost, discardIncoming: true);
      return false;
    }
  }

  void _receive(int lane, Uint8List frame) {
    if (!_open) {
      _receiveWhileDraining(lane, frame);
      return;
    }
    if (lane < 0 || lane >= _peer._laneCount || frame.length < _headerSize) {
      _end(CloseReason.lost, discardIncoming: true);
      return;
    }
    final kind = frame[0];
    final mode = frame[1];
    final sequence = ByteData.sublistView(frame).getUint32(2);
    final channel = lane >> 1;
    if (_closedChannels.contains(channel)) {
      // Nothing follows a close marker on its reliable lane. A late
      // unordered datagram is discarded.
      if (lane.isEven) _end(CloseReason.lost, discardIncoming: true);
      return;
    }
    if (lane.isOdd) {
      _receiveDatagram(channel, kind, mode, sequence, frame);
      return;
    }
    switch (kind) {
      case _kindAck:
        _acknowledged(channel, mode, sequence, frame);
      case _kindClose:
        if (frame.length != _headerSize ||
            mode != 0 ||
            sequence != 0 ||
            _partial.containsKey(lane)) {
          _end(CloseReason.lost, discardIncoming: true);
          return;
        }
        _closedChannels.add(channel);
        if (_closedChannels.length == _peer.channelCount) {
          _end(CloseReason.remote, discardIncoming: false);
        }
      case _kindMessage || _kindPart:
        _receiveReliable(lane, kind, mode, sequence, frame);
      default:
        _end(CloseReason.lost, discardIncoming: true);
    }
  }

  /// Releases a locally closed connection once the remote has closed it too,
  /// so that closing both ends at once need not wait for the close timeout.
  void _receiveWhileDraining(int lane, Uint8List frame) {
    if (lane.isOdd ||
        lane >= _peer._laneCount ||
        frame.length != _headerSize ||
        frame[0] != _kindClose) {
      return;
    }
    _closedChannels.add(lane >> 1);
    if (_closedChannels.length == _peer.channelCount) {
      _peer._release(_id!);
      _peer._disposeIfIdle();
    }
  }

  void _acknowledged(int channel, int mode, int sequence, Uint8List frame) {
    final pending = _outstanding[sequence];
    if (frame.length != _headerSize ||
        mode != DeliveryMode.reliable.index ||
        pending == null ||
        pending.mode != DeliveryMode.reliable ||
        pending.channel != channel) {
      _end(CloseReason.lost, discardIncoming: true);
      return;
    }
    _outstanding.remove(sequence);
    _outgoingBytes -= pending.bytes;
  }

  void _receiveReliable(
    int lane,
    int kind,
    int mode,
    int sequence,
    Uint8List frame,
  ) {
    final chunk = frame.length - _headerSize;
    final partial = _partial[lane];
    if (mode != DeliveryMode.reliable.index ||
        sequence == 0 ||
        (partial != null && partial.sequence != sequence) ||
        chunk > reliableChunkBytes ||
        (kind == _kindPart && chunk != reliableChunkBytes) ||
        (partial != null && chunk == 0)) {
      _end(CloseReason.lost, discardIncoming: true);
      return;
    }
    final size = (partial?.bytes.length ?? 0) + chunk;
    if (!_peer.incomingLimits.accepts(incoming, size)) {
      _end(CloseReason.overflow, discardIncoming: true);
      return;
    }
    final bytes = partial?.bytes ?? BytesBuilder();
    bytes.add(Uint8List.sublistView(frame, _headerSize));
    if (kind == _kindPart) {
      _partial[lane] = (sequence: sequence, bytes: bytes);
      return;
    }
    _partial.remove(lane);
    _deliver(bytes.takeBytes(), DeliveryMode.reliable, lane >> 1, sequence);
  }

  void _receiveDatagram(
    int channel,
    int kind,
    int mode,
    int sequence,
    Uint8List frame,
  ) {
    final size = frame.length - _headerSize;
    if (kind != _kindMessage ||
        sequence == 0 ||
        (mode != DeliveryMode.unreliableOrdered.index &&
            mode != DeliveryMode.unreliable.index) ||
        size > maxUnreliableBytes) {
      _end(CloseReason.lost, discardIncoming: true);
      return;
    }
    // A datagram may be lost anyway, so one that does not fit is dropped.
    if (!_peer.incomingLimits.accepts(incoming, size)) return;
    final deliveryMode = DeliveryMode.values[mode];
    if (deliveryMode == DeliveryMode.unreliableOrdered) {
      final last = _lastOrdered[channel];
      if (last != null && !_isNewer(sequence, last)) return;
      _lastOrdered[channel] = sequence;
    }
    _deliver(
      Uint8List.fromList(Uint8List.sublistView(frame, _headerSize)),
      deliveryMode,
      channel,
      sequence,
    );
  }

  void _deliver(Uint8List message, DeliveryMode mode, int channel, int seq) {
    final event = MessageReceived(this, message, mode: mode, channel: channel);
    _incoming[event] = seq;
    _incomingBytes += message.length;
    _peer._events.add(event);
  }

  void _taken(MessageReceived event) {
    final sequence = _incoming.remove(event)!;
    _incomingBytes -= event.message.length;
    if (!_open || event.mode != DeliveryMode.reliable) return;
    final driver = _peer._driver;
    final id = _id!;
    final lane = event.channel * 2;
    try {
      // A remote that never reads its lane cannot make acknowledgements
      // accumulate without bound.
      if (driver.bufferedAmount(id, lane) > _peer._reliableBufferLimit) {
        _end(CloseReason.overflow, discardIncoming: true);
        return;
      }
      driver.send(id, lane, _control(_kindAck, sequence));
    } on Object {
      // A failing connection is reported by the driver in event order.
    }
  }

  void _releaseSent() {
    if (!_open || _unsent.isEmpty) return;
    final id = _id!;
    for (final MapEntry(key: lane, value: queue) in _unsent.entries.toList()) {
      final int buffered;
      try {
        buffered = _peer._driver.bufferedAmount(id, lane);
      } on Object {
        _end(CloseReason.lost, discardIncoming: true);
        return;
      }
      final sent = _sentBytes[lane] - buffered;
      while (queue.isNotEmpty && queue.first.end <= sent) {
        final pending = _outstanding.remove(queue.removeFirst().sequence);
        if (pending != null) _outgoingBytes -= pending.bytes;
      }
      if (queue.isEmpty) _unsent.remove(lane);
    }
  }

  @override
  void close() => _end(CloseReason.local, discardIncoming: true);

  void _end(CloseReason reason, {required bool discardIncoming}) {
    if (!_open) return;
    _open = false;
    _closeReason = reason;
    _outstanding.clear();
    _unsent.clear();
    _partial.clear();
    _outgoingBytes = 0;
    if (discardIncoming) _peer._discardIncoming(this);
    if (reason != CloseReason.local && !_peer._closed) {
      _peer._events.add(ConnectionClosed(this, reason));
    } else if (_openedPolled) {
      _peer._connections.remove(this);
    }
    if (!_peer.isHost) _peer._clientFinished = true;
    final id = _id!;
    if (reason == CloseReason.local || reason == CloseReason.overflow) {
      _peer._drain(id);
    } else {
      _peer._release(id);
    }
    _peer._disposeIfIdle();
  }
}

bool _isNewer(int sequence, int last) {
  final distance = (sequence - last) & 0xffffffff;
  return distance != 0 && distance < 0x80000000;
}

Uint8List _frame(
  int kind,
  DeliveryMode mode,
  int sequence,
  Uint8List payload,
  int start,
  int end,
) {
  final frame = Uint8List(_headerSize + end - start);
  frame[0] = kind;
  frame[1] = mode.index;
  ByteData.sublistView(frame).setUint32(2, sequence);
  frame.setRange(_headerSize, frame.length, payload, start);
  return frame;
}

Uint8List _control(int kind, int sequence) {
  final frame = Uint8List(_headerSize)..[0] = kind;
  ByteData.sublistView(frame).setUint32(2, sequence);
  return frame;
}
