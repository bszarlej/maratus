import 'dart:collection';
import 'dart:typed_data';

import 'package:maratus_webrtc/maratus_webrtc.dart';
import 'package:maratus_webrtc/src/webrtc_driver.dart';

/// A platform boundary controlled entirely by its test.
final class FakeWebRtcDriver implements WebRtcDriver {
  /// Events returned by the next calls to [poll].
  final events = Queue<WebRtcDriverEvent>();

  /// Connections created by [open], in order.
  final opened = <({int connection, int laneCount, List<IceServer> servers})>[];

  /// Connections asked to create an offer.
  final offersCreated = <int>[];

  /// Remote offers applied with [acceptOffer].
  final offers = <({int connection, String sdp})>[];

  /// Remote answers applied with [acceptAnswer].
  final answers = <({int connection, String sdp})>[];

  /// Remote candidates added with [addCandidate].
  final candidates = <({int connection, String candidate, String? mid})>[];

  /// Copies of the data accepted by [send].
  final sent = <FakeFrame>[];

  /// Connections released with [close], in order.
  final closed = <int>[];

  /// Unsent bytes reported for each connection and lane.
  final buffered = <(int, int), int>{};

  /// The identifier returned by the next [open].
  int nextConnection = 1;

  /// Whether [open] throws.
  bool throwOpen = false;

  /// Whether [createOffer] throws.
  bool throwCreateOffer = false;

  /// Whether [acceptOffer] and [acceptAnswer] throw.
  bool throwAccept = false;

  /// Whether [addCandidate] throws.
  bool throwCandidate = false;

  /// Whether [send] throws.
  bool throwSend = false;

  /// Whether [bufferedAmount] throws.
  bool throwBuffered = false;

  /// Whether [poll] throws.
  bool throwPoll = false;

  /// Whether [close] throws after recording the call.
  bool throwClose = false;

  /// Whether [dispose] throws after recording the call.
  bool throwDispose = false;

  /// Number of [dispose] calls.
  int disposeCalls = 0;

  @override
  int open(int laneCount, List<IceServer> iceServers) {
    if (throwOpen) throw StateError('open failed');
    final connection = nextConnection++;
    opened.add((
      connection: connection,
      laneCount: laneCount,
      servers: iceServers,
    ));
    return connection;
  }

  @override
  void createOffer(int connection) {
    if (throwCreateOffer) throw StateError('createOffer failed');
    offersCreated.add(connection);
  }

  @override
  void acceptOffer(int connection, String sdp) {
    if (throwAccept) throw StateError('acceptOffer failed');
    offers.add((connection: connection, sdp: sdp));
  }

  @override
  void acceptAnswer(int connection, String sdp) {
    if (throwAccept) throw StateError('acceptAnswer failed');
    answers.add((connection: connection, sdp: sdp));
  }

  @override
  void addCandidate(int connection, String candidate, String? mid) {
    if (throwCandidate) throw StateError('addCandidate failed');
    candidates.add((connection: connection, candidate: candidate, mid: mid));
  }

  @override
  void send(int connection, int lane, Uint8List bytes) {
    if (throwSend) throw StateError('send failed');
    sent.add(FakeFrame(connection, lane, Uint8List.fromList(bytes)));
  }

  @override
  int bufferedAmount(int connection, int lane) {
    if (throwBuffered) throw StateError('bufferedAmount failed');
    return buffered[(connection, lane)] ?? 0;
  }

  @override
  void close(int connection) {
    closed.add(connection);
    if (throwClose) throw StateError('close failed');
  }

  @override
  WebRtcDriverEvent? poll() {
    if (throwPoll) throw StateError('poll failed');
    return events.isEmpty ? null : events.removeFirst();
  }

  @override
  void dispose() {
    disposeCalls++;
    if (throwDispose) throw StateError('dispose failed');
  }

  /// Removes and returns the data sent on [connection].
  List<FakeFrame> take([int? connection]) {
    final taken = [
      for (final frame in sent)
        if (connection == null || frame.connection == connection) frame,
    ];
    sent.removeWhere(taken.contains);
    return taken;
  }

  /// Reports every lane of [connection] as open.
  void openLanes(int connection, int laneCount) {
    for (var lane = 0; lane < laneCount; lane++) {
      events.add(WebRtcDriverLaneOpened(connection, lane));
    }
  }
}

/// Data accepted by [FakeWebRtcDriver.send].
final class FakeFrame {
  /// Records [bytes] sent on [lane] of [connection].
  const FakeFrame(this.connection, this.lane, this.bytes);

  /// The sending connection.
  final int connection;

  /// The lane the data was sent on.
  final int lane;

  /// A copy of the sent bytes.
  final Uint8List bytes;

  /// The frame kind.
  int get kind => bytes[0];

  /// The frame's delivery-mode byte.
  int get mode => bytes[1];

  /// The frame's sequence number.
  int get sequence => ByteData.sublistView(bytes).getUint32(2);

  /// The frame's payload.
  Uint8List get payload => Uint8List.sublistView(bytes, 6);

  @override
  String toString() =>
      'FakeFrame($connection, lane $lane, kind $kind, seq $sequence, '
      '${payload.length} bytes)';
}
