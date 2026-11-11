import 'dart:typed_data';

import 'ice_server.dart';

/// Internal boundary between the transport and a platform WebRTC stack.
///
/// Each connection has a number of lanes: data channels that both sides
/// create before negotiation, using the lane numbers as their negotiated
/// stream identifiers. Even lanes are reliable and ordered. Odd lanes are
/// unordered and never retransmit. A connection reports
/// [WebRtcDriverLaneOpened] for a lane before any [WebRtcDriverMessage]
/// arriving on it.
abstract interface class WebRtcDriver {
  /// Creates a peer connection with [laneCount] lanes and returns an
  /// identifier that this driver never reuses.
  int open(int laneCount, List<IceServer> iceServers);

  /// Creates an offer and applies it locally.
  ///
  /// The offer is reported as a [WebRtcDriverDescription], followed by
  /// [WebRtcDriverCandidate] events as local candidates are found.
  void createOffer(int connection);

  /// Applies a remote offer, then creates and applies an answer, which is
  /// reported as a [WebRtcDriverDescription].
  void acceptOffer(int connection, String sdp);

  /// Applies the remote answer to the offer from [createOffer].
  void acceptAnswer(int connection, String sdp);

  /// Adds a remote candidate. Candidates that cannot be used are ignored.
  void addCandidate(int connection, String candidate, String? mid);

  /// Queues a copy of [bytes] on [lane], throwing if the lane cannot accept
  /// it.
  void send(int connection, int lane, Uint8List bytes);

  /// The number of bytes queued on [lane] that have not been sent yet.
  int bufferedAmount(int connection, int lane);

  /// Closes a connection and releases its resources.
  ///
  /// The transport calls this exactly once for every opened connection, and
  /// no events are reported for the connection afterwards.
  void close(int connection);

  /// Removes and returns the oldest event, or returns `null` if there is
  /// none.
  WebRtcDriverEvent? poll();

  /// Releases the driver after all of its connections have been closed.
  void dispose();
}

/// An event reported by a [WebRtcDriver] for one of its connections.
sealed class WebRtcDriverEvent {
  /// Creates an event for [connection].
  const WebRtcDriverEvent(this.connection);

  /// The identifier returned by [WebRtcDriver.open].
  final int connection;
}

/// A local session description was created and applied.
final class WebRtcDriverDescription extends WebRtcDriverEvent {
  /// Creates an event carrying the local description [sdp].
  const WebRtcDriverDescription(super.connection, this.sdp);

  /// The local offer or answer.
  final String sdp;
}

/// A local candidate was found.
final class WebRtcDriverCandidate extends WebRtcDriverEvent {
  /// Creates an event carrying the local [candidate] for [mid].
  const WebRtcDriverCandidate(super.connection, this.candidate, this.mid);

  /// The ICE candidate line.
  final String candidate;

  /// The identifier of the media section the candidate belongs to.
  final String? mid;
}

/// A lane opened and can carry data.
final class WebRtcDriverLaneOpened extends WebRtcDriverEvent {
  /// Creates an event reporting that [lane] opened.
  const WebRtcDriverLaneOpened(super.connection, this.lane);

  /// The lane that opened.
  final int lane;
}

/// Data arrived on a lane.
final class WebRtcDriverMessage extends WebRtcDriverEvent {
  /// Creates an event carrying [bytes] received on [lane].
  const WebRtcDriverMessage(super.connection, this.lane, this.bytes);

  /// The lane the data arrived on.
  final int lane;

  /// The received bytes, owned by Dart.
  final Uint8List bytes;
}

/// The connection failed or was closed by the remote side.
///
/// The transport still calls [WebRtcDriver.close] to release it.
final class WebRtcDriverClosed extends WebRtcDriverEvent {
  /// Creates an event reporting that [connection] ended.
  const WebRtcDriverClosed(super.connection);
}
