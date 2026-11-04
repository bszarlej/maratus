import 'dart:async';

import 'multiplayer_peer.dart';
import 'web_socket_driver.dart' as platform;
import 'web_socket_peer_base.dart';

/// A native WebSocket listener for a `MultiplayerSession` host.
///
/// Pass an instance returned by [bind] to `session.host`. Browser clients can
/// connect, but browsers cannot listen. Events remain queued until [poll].
/// The listener uses the `maratus-v1` WebSocket subprotocol, with binary
/// framing for payloads and consumption acknowledgements.
final class WebSocketHost implements MultiplayerPeer {
  WebSocketHost._(
    this._listener, {
    required this.address,
    required this.path,
    required QueueLimits incomingLimits,
    required QueueLimits outgoingLimits,
    required int maxConnections,
  }) {
    _base = WebSocketPeerBase(
      isHost: true,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      maxConnections: maxConnections,
      onClose: _stop,
    );
    _subscription = _listener.connections.listen(
      _base.attach,
      onError: (Object error) => close(),
      onDone: close,
    );
  }

  /// Whether native listening is available on this platform.
  static bool get isSupported => platform.supportsWebSocketHosting;

  /// Binds a native listener, throwing if the address or port is unavailable.
  ///
  /// Port zero selects an available port; [port] reports the selected value.
  /// The default address accepts only local clients. Use `0.0.0.0` to accept
  /// IPv4 LAN connections and connect clients to the machine's reachable IP.
  /// Only upgrades at [path] with the maratus subprotocol are accepted.
  ///
  /// Each connection has independent queue limits. Outgoing payloads count
  /// until the receiver polls them; exceeding either queue closes that
  /// connection with [CloseReason.overflow]. [maxConnections] also bounds
  /// closed connections whose lifecycle events have not yet been polled.
  ///
  /// Throws [UnsupportedError] on the web. TLS can terminate at a reverse
  /// proxy forwarding this listener, while clients connect using `wss:`.
  static Future<WebSocketHost> bind({
    String address = '127.0.0.1',
    int port = 8080,
    String path = '/netcode',
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
    int maxConnections = 64,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('WebSocket hosting requires a native platform.');
    }
    _validateLimits(incomingLimits, outgoingLimits);
    if (address.isEmpty) throw ArgumentError.value(address, 'address');
    if (port < 0 || port > 65535) throw ArgumentError.value(port, 'port');
    if (!path.startsWith('/') || path.contains('?') || path.contains('#')) {
      throw ArgumentError.value(path, 'path', 'must be an absolute URL path');
    }
    if (maxConnections <= 0) {
      throw ArgumentError.value(
        maxConnections,
        'maxConnections',
        'must be positive',
      );
    }
    final listener = await platform.bindWebSocket(
      address: address,
      port: port,
      path: path,
      maxConnections: maxConnections,
    );
    return WebSocketHost._(
      listener,
      address: address,
      path: path,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      maxConnections: maxConnections,
    );
  }

  final platform.WebSocketListener _listener;
  late final WebSocketPeerBase _base;
  StreamSubscription<platform.WebSocketDriver>? _subscription;

  /// The interface address supplied to [bind].
  final String address;

  /// The HTTP path at which WebSocket upgrades are accepted.
  final String path;

  /// The actual listening port.
  int get port => _listener.port;

  /// Whether [close] has been called.
  bool get isClosed => _base.isClosed;

  /// Completes after [close] has released listener and transport resources.
  Future<void> get done => _base.done;

  @override
  bool get isHost => true;

  @override
  TransportCapabilities get capabilities =>
      const TransportCapabilities(canHost: true);

  @override
  PeerEvent? poll() => _base.poll();

  @override
  void close() => _base.close();

  Future<void> _stop() async {
    await _listener.close();
    await _subscription?.cancel();
    _subscription = null;
  }
}

/// A native or browser WebSocket client for a `MultiplayerSession`.
///
/// [WebSocketClient.connect] returns immediately; pass the result to `session.join` and keep
/// updating the session. A failed or timed-out opening handshake produces a
/// [ConnectionClosed] with [CloseReason.connectFailed], without an open event.
final class WebSocketClient implements MultiplayerPeer {
  WebSocketClient._(
    this.uri, {
    required QueueLimits incomingLimits,
    required QueueLimits outgoingLimits,
    required Duration connectTimeout,
  }) {
    _base = WebSocketPeerBase(
      isHost: false,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      maxConnections: 1,
      onClose: () => _dial.cancel(),
    );
    _dial = platform.connectWebSocket(uri, timeout: connectTimeout);
    unawaited(
      _dial.ready.then<void>(
        _base.attach,
        onError: (Object error, StackTrace stack) => _base.connectFailed(),
      ),
    );
  }

  /// Starts connecting to a `ws:` or `wss:` endpoint.
  ///
  /// [uri] must be absolute, have a host, and have no fragment or credentials.
  /// [connectTimeout] must be positive. Invalid arguments throw immediately;
  /// network errors are reported through [poll]. Browser security restrictions
  /// apply: an HTTPS page normally requires a trusted `wss:` endpoint.
  ///
  /// Outgoing payloads count against [outgoingLimits] until the receiver polls
  /// them. This transport acknowledgement is not a gameplay acknowledgement.
  /// Exceeding either queue closes the connection with [CloseReason.overflow].
  factory WebSocketClient.connect(
    Uri uri, {
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
    Duration connectTimeout = const Duration(seconds: 10),
  }) {
    _validateLimits(incomingLimits, outgoingLimits);
    if ((uri.scheme != 'ws' && uri.scheme != 'wss') ||
        uri.host.isEmpty ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      throw ArgumentError.value(
        uri,
        'uri',
        'must be a ws/wss URL without credentials or fragment',
      );
    }
    if (connectTimeout <= Duration.zero) {
      throw ArgumentError.value(
        connectTimeout,
        'connectTimeout',
        'must be positive',
      );
    }
    return WebSocketClient._(
      uri,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      connectTimeout: connectTimeout,
    );
  }

  /// The endpoint this client connects to.
  final Uri uri;
  late final WebSocketPeerBase _base;
  late final platform.WebSocketDial _dial;

  /// Whether [close] has been called.
  bool get isClosed => _base.isClosed;

  /// Completes after [close] has cancelled the dial and released resources.
  Future<void> get done => _base.done;

  @override
  bool get isHost => false;

  @override
  TransportCapabilities get capabilities =>
      TransportCapabilities(canHost: WebSocketHost.isSupported);

  @override
  PeerEvent? poll() => _base.poll();

  @override
  void close() => _base.close();
}

void _validateLimits(QueueLimits incoming, QueueLimits outgoing) {
  for (final limits in [incoming, outgoing]) {
    if (limits.maxMessages <= 0 || limits.maxBytes <= 0) {
      throw ArgumentError.value(limits, 'limits', 'must be positive');
    }
  }
}
