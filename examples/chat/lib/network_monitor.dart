import 'package:maratus_flame/maratus_flame.dart';

/// Summarizes a session's diagnostics in a few lines for the example's
/// overlay, with traffic rates between snapshots.
final class NetworkMonitor {
  /// Watches [session], timing rates by [clock].
  NetworkMonitor(this.session, {required MonotonicClock clock})
    : _clock = clock;

  /// How often [sample] produces new lines.
  static const period = Duration(milliseconds: 500);

  /// The session whose diagnostics are summarized.
  final MultiplayerSession session;
  final MonotonicClock _clock;
  ({Duration at, SessionDiagnostics diagnostics})? _previous;

  /// Returns new lines once per [period], and `null` in between.
  ///
  /// [smoothing] holds the smoothing state of each avatar shown.
  List<String>? sample(Iterable<InterpolationState?> smoothing) {
    final now = _clock.now;
    final previous = _previous;
    if (previous != null && now - previous.at < period) return null;
    final diagnostics = session.diagnostics;
    _previous = (at: now, diagnostics: diagnostics);
    return describeDiagnostics(
      diagnostics,
      since: previous == null
          ? null
          : (elapsed: now - previous.at, diagnostics: previous.diagnostics),
      smoothing: smoothing,
    );
  }
}

/// Describes [diagnostics] in short lines: one for each peer, traffic rates
/// [since] an earlier snapshot, resources and held state, and how the
/// [smoothing] states of the avatars were produced.
List<String> describeDiagnostics(
  SessionDiagnostics diagnostics, {
  ({Duration elapsed, SessionDiagnostics diagnostics})? since,
  Iterable<InterpolationState?> smoothing = const [],
}) {
  final lines = [
    for (final peer in diagnostics.peers) _describePeer(peer),
    if (diagnostics.peers.isEmpty) 'No peers',
  ];
  if (since != null && since.elapsed > Duration.zero) {
    final seconds =
        since.elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    String rate(TrafficCounts now, TrafficCounts before) {
      final messages = (now.messages - before.messages) / seconds;
      final kilobytes = (now.bytes - before.bytes) / seconds / 1000;
      return '${messages.clamp(0, double.infinity).round()} msg/s, '
          '${kilobytes.clamp(0, double.infinity).toStringAsFixed(1)} kB/s';
    }

    lines.add(
      'Out ${rate(diagnostics.sent, since.diagnostics.sent)} · '
      'In ${rate(diagnostics.received, since.diagnostics.received)}',
    );
  }
  lines.add(
    'Entities ${diagnostics.entities} · '
    'held ${diagnostics.heldState.messages} · '
    'coalesced ${diagnostics.coalescedStates}',
  );
  final states = smoothing.nonNulls.toList();
  if (states.isNotEmpty) {
    final counts = [
      for (final state in InterpolationState.values)
        if (states.where((shown) => shown == state).length case final count
            when count > 0)
          '$count ${state.name}',
    ];
    lines.add('Smoothing: ${counts.join(', ')}');
  }
  return lines;
}

String _describePeer(PeerDiagnostics peer) {
  final roundTrip = peer.roundTripTime;
  return [
    'Peer ${peer.peer.value}${peer.isReady ? '' : ' (joining)'}',
    'RTT ${roundTrip == null ? '-' : '${roundTrip.inMilliseconds} ms'}',
    'queued ${peer.outgoing.messages} out, ${peer.incoming.messages} in',
    if (peer.heldState.messages > 0) 'held ${peer.heldState.messages}',
  ].join(' · ');
}
