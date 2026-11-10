import 'dart:collection';
import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus_enet/src/enet_driver.dart';

/// A native boundary controlled entirely by its test.
final class FakeEnetDriver implements EnetDriver {
  /// Events returned by the next native service calls.
  final events = Queue<EnetDriverEvent>();

  /// Copies of packets accepted by the native boundary.
  final sent = <FakeEnetPacket>[];

  /// Connection attempts in their original order.
  final connections = <({String address, int port, int channelCount})>[];

  /// Connections asked to drain and disconnect.
  final disconnected = <int>[];

  /// Connections immediately reset.
  final resets = <int>[];

  /// The identifier returned by the next connection attempt.
  int nextPeer = 1;

  /// Whether sending fails without accepting a packet.
  bool failSend = false;

  /// Whether native connection establishment throws.
  bool throwConnect = false;

  /// Whether native service throws.
  bool throwPoll = false;

  /// Whether native sending throws.
  bool throwSend = false;

  /// Whether native graceful disconnect throws.
  bool throwDisconnect = false;

  /// Whether native reset throws.
  bool throwReset = false;

  /// Whether native disposal throws after being recorded.
  bool throwClose = false;

  /// Number of native service calls.
  int pollCalls = 0;

  /// Number of native host disposal calls.
  int closeCalls = 0;

  @override
  int get port => 12345;

  @override
  int connect(String address, int port, int channelCount) {
    if (throwConnect) throw StateError('Native connect failed');
    connections.add((address: address, port: port, channelCount: channelCount));
    return nextPeer++;
  }

  @override
  EnetDriverEvent? poll() {
    pollCalls++;
    if (throwPoll) throw StateError('Native service failed');
    return events.isEmpty ? null : events.removeFirst();
  }

  @override
  bool send(
    int peer,
    int channel,
    Uint8List bytes,
    DeliveryMode mode, {
    int? token,
  }) {
    if (throwSend) throw StateError('Native send failed');
    if (failSend) return false;
    sent.add(
      FakeEnetPacket(peer, channel, Uint8List.fromList(bytes), mode, token),
    );
    return true;
  }

  @override
  void disconnect(int peer) {
    disconnected.add(peer);
    if (throwDisconnect) throw StateError('Native disconnect failed');
  }

  @override
  void reset(int peer) {
    resets.add(peer);
    if (throwReset) throw StateError('Native reset failed');
  }

  @override
  void close() {
    closeCalls++;
    if (throwClose) throw StateError('Native disposal failed');
  }
}

/// A packet accepted by [FakeEnetDriver].
final class FakeEnetPacket {
  /// Records an outgoing native packet.
  const FakeEnetPacket(
    this.peer,
    this.channel,
    this.bytes,
    this.mode,
    this.token,
  );

  /// Destination connection identifier.
  final int peer;

  /// Native ENet channel.
  final int channel;

  /// Copied wire bytes.
  final Uint8List bytes;

  /// Native ENet delivery guarantee.
  final DeliveryMode mode;

  /// Optional native packet release identifier.
  final int? token;
}
