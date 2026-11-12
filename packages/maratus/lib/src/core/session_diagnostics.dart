part of 'multiplayer_session.dart';

/// Counts of messages and their bytes, in total and by [MessageKind].
///
/// Counts refer to logical messages; a state batch can carry several in one
/// transport packet. Bytes include batch framing once, excluding transport
/// framing. Totals also
/// include received messages that could not be decoded, which have no kind.
final class TrafficCounts {
  TrafficCounts._(_Traffic traffic)
    : messages = traffic.messages,
      bytes = traffic.bytes,
      _byKind = Map.unmodifiable(traffic.byKind);

  /// The number of messages.
  final int messages;

  /// The total size of the messages, in bytes.
  final int bytes;

  final Map<MessageKind, ({int messages, int bytes})> _byKind;

  /// The messages of [kind] and their total size in bytes.
  ({int messages, int bytes}) operator [](MessageKind kind) =>
      _byKind[kind] ?? (messages: 0, bytes: 0);
}

/// A snapshot of one peer's connection to this session: a client on a
/// host, or the host on a client.
final class PeerDiagnostics {
  const PeerDiagnostics._({
    required this.peer,
    required this.isReady,
    required this.incoming,
    required this.outgoing,
    required this.roundTripTime,
    required this.smoothedRoundTripTime,
    required this.lastReceivedAt,
    required this.sent,
    required this.received,
    required this.heldState,
    required this.coalescedStates,
  });

  /// The peer at the other end of the connection.
  final PeerId peer;

  /// Whether the peer takes part in gameplay, as by
  /// [MultiplayerSession.isReady].
  final bool isReady;

  /// The messages received from the peer that the session has not polled.
  final QueueDepth incoming;

  /// The messages sent to the peer that its transport still counts, as
  /// [PeerConnection.outgoing] describes.
  final QueueDepth outgoing;

  /// The latest round trip of a ping to the peer, or `null` before the
  /// first answer.
  ///
  /// A round trip runs from sending a ping until handling its answer, so it
  /// includes the time each side takes to reach its next update.
  final Duration? roundTripTime;

  /// An exponentially weighted average of the round trips, each weighing
  /// one eighth, or `null` before the first answer.
  final Duration? smoothedRoundTripTime;

  /// When this session last handled a message from the peer, on the
  /// session's clock, or `null` if none since the peer was accepted.
  final Duration? lastReceivedAt;

  /// The messages sent to the peer since it was accepted.
  final TrafficCounts sent;

  /// The messages received from the peer since it was accepted.
  final TrafficCounts received;

  /// The state waiting for this congested connection to drain: one entry
  /// per entity and writer, and the encoded size of its values. See
  /// [MultiplayerSession.stateBackpressure].
  final QueueDepth heldState;

  /// How many times newer state for an entity replaced held state that had
  /// not been sent to this peer.
  final int coalescedStates;
}

/// A snapshot of a session's resources and traffic.
///
/// Read [MultiplayerSession.diagnostics] for a new snapshot, for example to
/// display network conditions or to check in tests that repeated sessions
/// release their resources. Counts cover the current session: they start
/// over when it hosts or joins again.
final class SessionDiagnostics {
  const SessionDiagnostics._({
    required this.entities,
    required this.replicatedEntities,
    required this.attachments,
    required this.synchronizers,
    required this.rpcBindings,
    required this.spawnBindings,
    required this.pendingRpcs,
    required this.pendingBaselineEntities,
    required this.pendingConnections,
    required this.staleMessages,
    required this.obsoleteMessages,
    required this.sent,
    required this.received,
    required this.heldState,
    required this.coalescedStates,
    required this.peers,
  });

  /// The live entities of the registry, static and replicated.
  final int entities;

  /// The live replicated entities.
  final int replicatedEntities;

  /// The live entity attachments.
  ///
  /// An attachment whose validity predicate has turned false is counted
  /// until the next update discards it.
  final int attachments;

  /// The live synchronizers.
  final int synchronizers;

  /// The live RPC bindings, with and without attachments.
  final int rpcBindings;

  /// The live spawn bindings. They survive session restarts.
  final int spawnBindings;

  /// The local RPCs that wait for an attached entity's update boundary, and
  /// their encoded size, as [MultiplayerSession.pendingRpcCount] and
  /// [MultiplayerSession.pendingRpcBytes] count them.
  final QueueDepth pendingRpcs;

  /// While a client synchronizes, the entities of its baseline that are not
  /// ready yet, as [MultiplayerSession.pendingBaselineCount] counts them.
  final int pendingBaselineEntities;

  /// On a host, the connections that have not completed the handshake.
  final int pendingConnections;

  /// The messages dropped because they carried another connection's
  /// generation.
  final int staleMessages;

  /// The replicated messages dropped because their revision was not newer.
  final int obsoleteMessages;

  /// The messages this session sent.
  final TrafficCounts sent;

  /// The messages this session received, including malformed ones.
  final TrafficCounts received;

  /// The state waiting for congested connections to drain, over all peers.
  final QueueDepth heldState;

  /// How many times newer state replaced held state that had not been sent,
  /// over all peers.
  final int coalescedStates;

  /// The peers this session exchanges messages with: on a host, its
  /// clients, in the order of [MultiplayerSession.peers]; on a client, the
  /// host.
  final List<PeerDiagnostics> peers;
}

/// Accumulates the counts of a [TrafficCounts].
final class _Traffic {
  var messages = 0;
  var bytes = 0;
  final byKind = <MessageKind, ({int messages, int bytes})>{};

  void add(MessageKind? kind, int size) {
    messages++;
    bytes += size;
    if (kind == null) return;
    final count = byKind[kind] ?? (messages: 0, bytes: 0);
    byKind[kind] = (messages: count.messages + 1, bytes: count.bytes + size);
  }

  void clear() {
    messages = 0;
    bytes = 0;
    byKind.clear();
  }
}
