import 'package:maratus/maratus.dart';

import 'ice_server.dart';
import 'signaling.dart';
import 'webrtc_peer_base.dart';
import 'webrtc_platform.dart';

/// A WebRTC host for a [MultiplayerSession].
///
/// Clients ask to connect through [HostSignaling], and each accepted client
/// gets a direct data-channel connection, encrypted by WebRTC. Browsers can
/// host, so a whole session can run in browsers. Events remain queued until
/// [poll].
final class WebRtcHost implements MultiplayerPeer {
  WebRtcHost._(this._base);

  /// Starts accepting clients that ask to connect through [signaling].
  ///
  /// [iceServers] help peers on different networks find a path to each
  /// other; peers on the same network need none. [channelCount] must be
  /// 1..64 and match the clients' configuration. Each logical channel
  /// carries every delivery mode.
  ///
  /// Queue limits apply per connection. Reliable sends count until the
  /// remote application polls them; unreliable sends count until WebRTC has
  /// sent them. Exceeding a queue closes that connection, except that a
  /// received unreliable message that does not fit the incoming queue is
  /// discarded. Unreliable payloads may contain at most 1000 bytes.
  /// [maxConnections] includes clients still negotiating and unpolled
  /// lifecycle events; further clients are refused through signaling.
  ///
  /// A client that does not finish negotiating within [connectTimeout] is
  /// dropped. Closing allows sent data to drain for at most [closeTimeout];
  /// [done] completes once every connection has been released.
  ///
  /// Throws an [UnsupportedError] if this platform has no WebRTC support,
  /// and an [ArgumentError] for invalid options.
  factory WebRtcHost({
    required HostSignaling signaling,
    List<IceServer> iceServers = const [],
    int channelCount = 1,
    int maxConnections = 64,
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
    Duration connectTimeout = const Duration(seconds: 15),
    Duration closeTimeout = const Duration(seconds: 2),
  }) {
    _validate(
      channelCount: channelCount,
      maxConnections: maxConnections,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      iceServers: iceServers,
      connectTimeout: connectTimeout,
      closeTimeout: closeTimeout,
    );
    return WebRtcHost._(
      WebRtcPeerBase.host(
        driver: createWebRtcDriver(
          maxQueuedBytes: _maxQueuedBytes(incomingLimits),
        ),
        signaling: signaling,
        iceServers: List.of(iceServers),
        channelCount: channelCount,
        maxConnections: maxConnections,
        incomingLimits: incomingLimits,
        outgoingLimits: outgoingLimits,
        connectTimeout: connectTimeout,
        closeTimeout: closeTimeout,
      ),
    );
  }

  /// Whether this platform supports WebRTC connections.
  static bool get isSupported => supportsWebRtc;

  final WebRtcPeerBase _base;

  /// Whether [close] has been called.
  bool get isClosed => _base.isClosed;

  /// Completes once every connection and the WebRTC resources have been
  /// released after [close].
  Future<void> get done => _base.done;

  @override
  bool get isHost => true;

  @override
  TransportCapabilities get capabilities => _base.capabilities;

  @override
  PeerEvent? poll() => _base.poll();

  @override
  void close() => _base.close();
}

/// A WebRTC client for a [MultiplayerSession].
///
/// Pass the result of [WebRtcClient.connect] to [MultiplayerSession.join]
/// and keep updating the session. A refused or failed negotiation produces
/// [ConnectionClosed] with [CloseReason.connectFailed].
final class WebRtcClient implements MultiplayerPeer {
  WebRtcClient._(this._base);

  /// Starts connecting to the host reachable through [signaling].
  ///
  /// The client sends its offer through [signaling] and closes the channel
  /// once the connection is established or has failed. [channelCount] must
  /// match the host. [iceServers], queues, and delivery modes follow
  /// [WebRtcHost.new]. [connectTimeout] bounds the whole negotiation, and
  /// [close] abandons it.
  ///
  /// Throws an [UnsupportedError] if this platform has no WebRTC support,
  /// and an [ArgumentError] for invalid options.
  factory WebRtcClient.connect(
    SignalingChannel signaling, {
    List<IceServer> iceServers = const [],
    int channelCount = 1,
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
    Duration connectTimeout = const Duration(seconds: 15),
    Duration closeTimeout = const Duration(seconds: 2),
  }) {
    _validate(
      channelCount: channelCount,
      maxConnections: 1,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      iceServers: iceServers,
      connectTimeout: connectTimeout,
      closeTimeout: closeTimeout,
    );
    return WebRtcClient._(
      WebRtcPeerBase.client(
        driver: createWebRtcDriver(
          maxQueuedBytes: _maxQueuedBytes(incomingLimits),
        ),
        signaling: signaling,
        iceServers: List.of(iceServers),
        channelCount: channelCount,
        incomingLimits: incomingLimits,
        outgoingLimits: outgoingLimits,
        connectTimeout: connectTimeout,
        closeTimeout: closeTimeout,
      ),
    );
  }

  final WebRtcPeerBase _base;

  /// Whether [close] has been called.
  bool get isClosed => _base.isClosed;

  /// Completes once this client's connection and WebRTC resources have been
  /// released.
  Future<void> get done => _base.done;

  @override
  bool get isHost => false;

  @override
  TransportCapabilities get capabilities => _base.capabilities;

  @override
  PeerEvent? poll() => _base.poll();

  @override
  void close() => _base.close();
}

void _validate({
  required int channelCount,
  required int maxConnections,
  required QueueLimits incomingLimits,
  required QueueLimits outgoingLimits,
  required List<IceServer> iceServers,
  required Duration connectTimeout,
  required Duration closeTimeout,
}) => validateWebRtcOptions(
  channelCount: channelCount,
  maxConnections: maxConnections,
  incomingLimits: incomingLimits,
  outgoingLimits: outgoingLimits,
  iceServers: iceServers,
  serviceInterval: const Duration(milliseconds: 2),
  connectTimeout: connectTimeout,
  closeTimeout: closeTimeout,
);

/// Bounds a connection's received data that the transport has not polled:
/// twice the incoming queue, which leaves room for framing and for data that
/// arrives between polls.
int _maxQueuedBytes(QueueLimits incomingLimits) =>
    2 * incomingLimits.maxBytes + 1024 * 1024;
