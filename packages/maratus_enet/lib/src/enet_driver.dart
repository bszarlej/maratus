import 'dart:typed_data';

import 'package:maratus/maratus.dart';

/// Internal boundary between the transport and the native ENet host.
abstract interface class EnetDriver {
  /// The bound UDP port.
  int get port;

  /// Starts a connection and returns its stable local identifier.
  int connect(String address, int port, int channelCount);

  /// Services ENet without blocking and returns one event, if available.
  EnetDriverEvent? poll();

  /// Copies and queues a packet, optionally reporting its release by [token].
  bool send(
    int peer,
    int channel,
    Uint8List bytes,
    DeliveryMode mode, {
    int? token,
  });

  /// Disconnects after queued packets have been sent.
  void disconnect(int peer);

  /// Immediately discards a connection and its packets.
  void reset(int peer);

  /// Releases the host and all native allocations.
  void close();
}

/// An internal native event referring to a stable local peer identifier.
sealed class EnetDriverEvent {
  /// Creates an event for [peer].
  const EnetDriverEvent(this.peer);

  /// Stable local connection identifier, never reused by a driver.
  final int peer;
}

/// A native connection was established.
final class EnetDriverConnected extends EnetDriverEvent {
  /// Creates a connection event with the negotiated [channelCount].
  const EnetDriverConnected(super.peer, this.channelCount);

  /// Number of negotiated native channels.
  final int channelCount;
}

/// A copied packet received on [channel].
final class EnetDriverReceived extends EnetDriverEvent {
  /// Creates a received packet event.
  const EnetDriverReceived(super.peer, this.channel, this.bytes);

  /// Native channel number.
  final int channel;

  /// Packet bytes owned by Dart.
  final Uint8List bytes;
}

/// A native connection ended.
final class EnetDriverDisconnected extends EnetDriverEvent {
  /// Creates a disconnect event.
  const EnetDriverDisconnected(super.peer, this.graceful);

  /// Whether the remote endpoint sent the graceful-disconnect marker.
  final bool graceful;
}

/// A tracked packet left ENet's outgoing queue, delivered or dropped.
final class EnetDriverSent extends EnetDriverEvent {
  /// Creates a native packet-release event.
  const EnetDriverSent(super.peer, this.token);

  /// The token supplied to [EnetDriver.send].
  final int token;
}
