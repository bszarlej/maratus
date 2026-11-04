import 'dart:typed_data';

/// The local end of a transport that a session runs over.
///
/// A peer is either a host, which accepts connections from clients, or a
/// client, which has a single connection to a host. Everything a peer
/// observes is reported as a [PeerEvent] that waits until it is taken with
/// [poll], so transport activity is handled at a point the caller chooses,
/// such as the start of a game update, rather than in callbacks.
abstract interface class MultiplayerPeer {
  /// Whether this peer is a host rather than a client.
  bool get isHost;

  /// The features of the transport this peer runs on.
  TransportCapabilities get capabilities;

  /// Removes and returns the oldest pending event, or returns `null` if
  /// there is none.
  ///
  /// The events of each connection are reported in order: first
  /// [ConnectionOpened], then a [MessageReceived] for each message in the
  /// order it was sent, and finally [ConnectionClosed]. A client's
  /// connection that cannot be established is reported only by
  /// [ConnectionClosed] with [CloseReason.connectFailed].
  PeerEvent? poll();

  /// Closes this peer and all of its connections.
  ///
  /// Each open connection is closed as by [PeerConnection.close], and a
  /// client that is still connecting gives up. A host stops accepting
  /// connections. Pending events are discarded, and [poll] returns `null`
  /// from then on. Closing a peer again has no effect.
  void close();
}

/// A connection between a [MultiplayerPeer] and a remote peer.
abstract interface class PeerConnection {
  /// Whether this connection is open, so that messages can be sent on it.
  bool get isOpen;

  /// Why this connection closed, or `null` if it has not closed.
  CloseReason? get closeReason;

  /// The messages received on this connection that have not been taken with
  /// [MultiplayerPeer.poll] yet.
  QueueDepth get incoming;

  /// The messages sent on this connection that the remote peer has not
  /// consumed yet.
  ///
  /// The provided transports count a message until the remote peer polls
  /// it and their acknowledgement arrives, so a remote peer that stops
  /// polling fills this queue. A closed connection counts nothing.
  QueueDepth get outgoing;

  /// Sends [message] to the remote peer.
  ///
  /// Returns whether the message was accepted for delivery. A message is
  /// accepted only while the connection is open and its outgoing queue has
  /// room for it; if the queue is full, the connection closes with
  /// [CloseReason.overflow] instead. An accepted message is delivered as
  /// [mode] describes, unless the connection closes first. [message] is
  /// copied, so it can be reused once this method returns.
  ///
  /// Throws an [UnsupportedError] if the transport does not support [mode]
  /// on [channel].
  bool send(
    Uint8List message, {
    DeliveryMode mode = DeliveryMode.reliable,
    int channel = 0,
  });

  /// Closes this connection.
  ///
  /// Messages already sent are still delivered, and the remote peer then
  /// reports the connection closed with [CloseReason.remote]. Messages
  /// received on this connection and not yet polled are discarded, and no
  /// [ConnectionClosed] event is reported for it locally. Closing a
  /// connection again has no effect.
  void close();
}

/// Something that a [MultiplayerPeer] observed on one of its connections.
sealed class PeerEvent {
  const PeerEvent(this.connection);

  /// The connection this event concerns.
  final PeerConnection connection;
}

/// A [connection] opened: a host accepted it, or a client's connection to
/// its host was established.
final class ConnectionOpened extends PeerEvent {
  /// Creates an event reporting that [connection] opened.
  const ConnectionOpened(super.connection);

  @override
  String toString() => 'ConnectionOpened($connection)';
}

/// A [message] arrived on [connection].
final class MessageReceived extends PeerEvent {
  /// Creates an event reporting that [message] arrived on [connection].
  const MessageReceived(super.connection, this.message);

  /// The received bytes.
  final Uint8List message;

  @override
  String toString() => 'MessageReceived($connection, ${message.length} bytes)';
}

/// A [connection] closed for [reason]. It reports no further events.
final class ConnectionClosed extends PeerEvent {
  /// Creates an event reporting that [connection] closed for [reason].
  const ConnectionClosed(super.connection, this.reason);

  /// Why the connection closed.
  final CloseReason reason;

  @override
  String toString() => 'ConnectionClosed($connection, ${reason.name})';
}

/// Why a [PeerConnection] closed.
enum CloseReason {
  /// This side closed the connection.
  local,

  /// The remote peer closed the connection.
  remote,

  /// The connection could not be established, for example because no host
  /// was accepting connections.
  connectFailed,

  /// The connection broke without being closed, for example because the
  /// network failed. Messages that were still in transit are lost.
  lost,

  /// This side closed the connection because a message did not fit within
  /// the [QueueLimits] of its incoming or outgoing queue.
  ///
  /// A reliable connection cannot drop a message, so it closes instead.
  overflow,
}

/// How a message is delivered.
enum DeliveryMode {
  /// Each message arrives exactly once, in the order it was sent on its
  /// channel, unless the connection closes first.
  reliable,

  /// Messages can be lost, and a message that arrives after a newer one on
  /// its channel is discarded.
  unreliableOrdered,

  /// Messages can be lost or arrive in a different order than they were
  /// sent.
  unreliable,
}

/// The features of a transport.
final class TransportCapabilities {
  /// Creates a description of a transport's features.
  ///
  /// [deliveryModes] must include [DeliveryMode.reliable], which every
  /// transport supports.
  const TransportCapabilities({
    required this.canHost,
    this.deliveryModes = const {DeliveryMode.reliable},
    this.channelCount = 1,
  }) : assert(channelCount > 0);

  /// Whether the transport can host sessions on the current platform.
  final bool canHost;

  /// The modes that messages can be delivered with.
  final Set<DeliveryMode> deliveryModes;

  /// The number of channels, numbered from 0. Ordering guarantees apply
  /// within each channel.
  final int channelCount;

  /// Whether messages can be sent with [mode] on [channel].
  bool supports(DeliveryMode mode, {int channel = 0}) =>
      deliveryModes.contains(mode) && channel >= 0 && channel < channelCount;
}

/// The number of messages in a queue and their total size in bytes.
typedef QueueDepth = ({int messages, int bytes});

/// Limits on the messages queued in one direction of a connection.
final class QueueLimits {
  /// Creates limits on the number of queued messages and their total size.
  const QueueLimits({this.maxMessages = 1024, this.maxBytes = 4 * 1024 * 1024})
    : assert(maxMessages > 0),
      assert(maxBytes > 0);

  /// The maximum number of queued messages.
  final int maxMessages;

  /// The maximum total size of queued messages, in bytes.
  final int maxBytes;

  /// Whether a queue holding [depth] can take another message of [size]
  /// bytes.
  bool accepts(QueueDepth depth, int size) =>
      depth.messages < maxMessages && depth.bytes + size <= maxBytes;
}
