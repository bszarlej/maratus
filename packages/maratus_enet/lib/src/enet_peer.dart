import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:maratus/maratus.dart';

import 'enet_driver.dart';
import 'enet_driver_native.dart';
import 'enet_peer_base.dart';

/// A native IPv4 ENet listener for a [MultiplayerSession] host.
///
/// Events remain queued until [poll]. Native network service runs independently
/// of application polling, preserving bounded queues for stalled consumers.
/// Requires a native C compiler when building the bundled ENet code asset.
final class EnetHost implements MultiplayerPeer {
  EnetHost._(this._base, this.address, this.port);

  /// Binds a UDP listener. Port zero selects an available port.
  ///
  /// The default address accepts only local clients. Use `0.0.0.0` to listen on
  /// all IPv4 interfaces and give clients the host's reachable address.
  /// [channelCount] must be 1..85 and match the clients' configuration. Each
  /// logical channel has independent lanes for the three delivery modes.
  ///
  /// Queue limits apply per connection. Reliable sends count until the remote
  /// application polls them; unreliable sends count until ENet sends or drops
  /// their native packets. Exceeding a queue closes that connection, except
  /// that a received unreliable message that does not fit the incoming queue
  /// is discarded. Unreliable payloads may contain at most 1000 bytes, keeping
  /// datagrams small.
  /// [maxConnections] includes unpolled lifecycle events.
  ///
  /// Closing allows native sends to drain for at most [closeTimeout]; [done]
  /// completes once the native host is released. Bind and resolution failures
  /// throw. This transport does not provide encryption or NAT traversal.
  static Future<EnetHost> bind({
    String address = '127.0.0.1',
    int port = 7777,
    int channelCount = 1,
    int maxConnections = 64,
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
    Duration closeTimeout = const Duration(seconds: 2),
  }) async {
    _validate(
      address: address,
      port: port,
      hosting: true,
      channelCount: channelCount,
      maxConnections: maxConnections,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      closeTimeout: closeTimeout,
    );
    final resolved = await _resolve(address);
    final driver = _createDriver(
      address: resolved,
      port: port,
      maxConnections: maxConnections,
      channelCount: channelCount,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
    );
    final base = EnetPeerBase(
      driver: driver,
      isHost: true,
      channelCount: channelCount,
      maxConnections: maxConnections,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      closeTimeout: closeTimeout,
    );
    return EnetHost._(base, address, driver.port);
  }

  final EnetPeerBase _base;

  /// The interface address supplied to [bind].
  final String address;

  /// The actual listening UDP port.
  final int port;

  /// Whether [close] has been called.
  bool get isClosed => _base.isClosed;

  /// Completes after [close] releases the UDP socket and native resources.
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

/// A native IPv4 ENet client for a [MultiplayerSession].
///
/// Pass the result of [EnetClient.connect] to [MultiplayerSession.join] and keep
/// updating the session. Resolution, refused connections, and connect timeouts
/// produce [ConnectionClosed] with [CloseReason.connectFailed].
final class EnetClient implements MultiplayerPeer {
  EnetClient._(this._base, this.address, this.port) {
    unawaited(
      _resolve(address).then<void>(
        (resolved) => _base.startConnect(resolved, port),
        onError: (Object _, StackTrace _) => _base.connectFailed(),
      ),
    );
  }

  /// Starts connecting to an IPv4 address or hostname and UDP [port].
  ///
  /// Invalid arguments and native-host allocation failures throw immediately.
  /// [connectTimeout] includes address resolution. [channelCount] must match
  /// the host and be 1..85. Queues and delivery modes follow [EnetHost.bind].
  /// Native code service continues without polling, but application events are
  /// delivered only through [poll]. [close] cancels pending connection work.
  factory EnetClient.connect(
    String address, {
    int port = 7777,
    int channelCount = 1,
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
    Duration connectTimeout = const Duration(seconds: 10),
    Duration closeTimeout = const Duration(seconds: 2),
  }) {
    _validate(
      address: address,
      port: port,
      hosting: false,
      channelCount: channelCount,
      maxConnections: 1,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      connectTimeout: connectTimeout,
      closeTimeout: closeTimeout,
    );
    final driver = _createDriver(
      address: null,
      port: 0,
      maxConnections: 1,
      channelCount: channelCount,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
    );
    return EnetClient._(
      EnetPeerBase(
        driver: driver,
        isHost: false,
        channelCount: channelCount,
        maxConnections: 1,
        incomingLimits: incomingLimits,
        outgoingLimits: outgoingLimits,
        connectTimeout: connectTimeout,
        closeTimeout: closeTimeout,
      ),
      address,
      port,
    );
  }

  final EnetPeerBase _base;

  /// The host address or hostname supplied to [EnetClient.connect].
  final String address;

  /// The remote host's UDP port.
  final int port;

  /// Whether [close] has been called.
  bool get isClosed => _base.isClosed;

  /// Completes when this client's native host and timers have been released.
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

EnetDriver _createDriver({
  required String? address,
  required int port,
  required int maxConnections,
  required int channelCount,
  required QueueLimits incomingLimits,
  required QueueLimits outgoingLimits,
}) => createEnetDriver(
  address: address,
  port: port,
  maxConnections: maxConnections,
  channelCount: channelCount * 3,
  maxPacketBytes: max(incomingLimits.maxBytes, outgoingLimits.maxBytes) + 10,
  maxWaitingBytes: incomingLimits.maxBytes + incomingLimits.maxMessages * 10,
);

void _validate({
  required String address,
  required int port,
  required bool hosting,
  required int channelCount,
  required int maxConnections,
  required QueueLimits incomingLimits,
  required QueueLimits outgoingLimits,
  Duration connectTimeout = const Duration(seconds: 10),
  required Duration closeTimeout,
}) {
  if (address.isEmpty || address.contains('\u0000')) {
    throw ArgumentError.value(address, 'address', 'must be a hostname or IPv4');
  }
  final parsed = InternetAddress.tryParse(address);
  if (parsed != null && parsed.type != InternetAddressType.IPv4) {
    throw ArgumentError.value(address, 'address', 'only IPv4 is supported');
  }
  if (port < (hosting ? 0 : 1) || port > 65535) {
    throw ArgumentError.value(port, 'port');
  }
  validateEnetOptions(
    channelCount: channelCount,
    maxConnections: maxConnections,
    incomingLimits: incomingLimits,
    outgoingLimits: outgoingLimits,
    serviceInterval: const Duration(milliseconds: 2),
    connectTimeout: connectTimeout,
    closeTimeout: closeTimeout,
  );
}

Future<String> _resolve(String address) async {
  final parsed = InternetAddress.tryParse(address);
  if (parsed != null) return parsed.address;
  final addresses = await InternetAddress.lookup(
    address,
    type: InternetAddressType.IPv4,
  );
  if (addresses.isEmpty) {
    throw SocketException('No IPv4 address for $address');
  }
  return addresses.first.address;
}
