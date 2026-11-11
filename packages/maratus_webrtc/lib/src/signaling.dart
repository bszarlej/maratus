/// An ordered path for signaling messages between a host and one client.
///
/// Before WebRTC peers can connect directly, they exchange a connection
/// offer, an answer, and network candidates through signaling. The transport
/// encodes these as text messages. A channel delivers them unchanged and in
/// order, and needs no other knowledge of WebRTC.
abstract interface class SignalingChannel {
  /// The messages sent by the remote side, in the order they were sent.
  ///
  /// The stream is listened to at most once. It closes when the channel
  /// closes, and an error reports that the channel failed.
  Stream<String> get messages;

  /// Sends [message] to the remote side.
  ///
  /// A channel can buffer messages until it is connected. Messages sent
  /// after the channel closed are discarded.
  void send(String message);

  /// Closes this channel after delivering the messages already sent, and
  /// releases its resources. Closing a channel again has no effect.
  void close();
}

/// The host's side of signaling, through which clients ask to connect.
abstract interface class HostSignaling {
  /// A channel for each client that asks to connect.
  ///
  /// The stream is listened to at most once. It closes when no further
  /// clients can arrive, for example because a signaling server became
  /// unreachable. Connections that are already established are unaffected.
  Stream<SignalingChannel> get clients;

  /// Stops accepting clients and releases resources.
  ///
  /// Channels already delivered by [clients] stay open until they are
  /// closed. Closing again has no effect.
  void close();
}
