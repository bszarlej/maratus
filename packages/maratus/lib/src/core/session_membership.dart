part of 'multiplayer_session.dart';

/// Replicates the session's membership: on a host, it tells every client
/// which other clients joined, became ready, and left; on a client, it
/// applies what the host told it.
///
/// Membership changes are replicated changes, ordered by their revision with
/// spawning, despawning, authority, and state. A client therefore learns
/// that a peer joined before any entity that the peer owns, and a joining
/// client's baseline lists the clients that joined before it.
final class _SessionMembership {
  _SessionMembership(this.session);

  final MultiplayerSession session;

  /// On a client, the other clients of the session, in the order it learned
  /// about them, and whether each is ready. Empty on a host, which tracks
  /// its clients by their connections.
  final _members = <PeerId, bool>{};

  /// The other clients that this client knows about.
  Iterable<PeerId> get members => _members.keys;

  /// Whether this client knows [peer] as another client that is ready.
  bool isReady(PeerId peer) => _members[peer] ?? false;

  /// Forgets the members of a previous session.
  void clear() => _members.clear();

  /// Tells every joined client that [peer] joined. The host calls this
  /// before [peer] itself is welcomed, so [peer] is not told.
  void joined(PeerId peer) => session._replicate(PeerJoinedMessage(peer: peer));

  /// Tells every joined client except [remote] that [remote] is ready.
  void ready(_Remote remote) =>
      session._replicate(PeerReadyMessage(peer: remote.peer!), except: remote);

  /// Tells every remaining client that [peer] left for [reason].
  void left(PeerId peer, DisconnectReason reason) => session._replicate(
    PeerLeftMessage(peer: peer, reason: _departureReason(reason)),
  );

  /// Sends the other joined clients, and which of them are ready, as part
  /// of [remote]'s baseline. Returns `false` if its transport refused one,
  /// which removes [remote].
  bool sendBaseline(_Remote remote) {
    for (final MapEntry(key: peer, value: other)
        in session._peers.entries.toList()) {
      if (identical(other, remote)) continue;
      if (!session._send(
        remote,
        PeerJoinedMessage(peer: peer),
        revision: session._revision,
      )) {
        return false;
      }
      if (other.state == _RemoteState.ready &&
          !session._send(
            remote,
            PeerReadyMessage(peer: peer),
            revision: session._revision,
          )) {
        return false;
      }
    }
    return true;
  }

  /// Applies a membership [message] from the host and reports it. Returns
  /// `false` if it is inconsistent with the members this client knows,
  /// which is a protocol violation.
  ///
  /// A client joins only once and never as this client; only a member that
  /// is not ready yet becomes ready, and only a member leaves.
  bool apply(ProtocolMessage message) {
    switch (message) {
      case PeerJoinedMessage(:final peer)
          when peer != session._localPeer && !_members.containsKey(peer):
        _members[peer] = false;
        session._emit(PeerJoined(peer));
      case PeerReadyMessage(:final peer) when _members[peer] == false:
        _members[peer] = true;
        session._emit(PeerReady(peer));
      case PeerLeftMessage(:final peer, :final reason)
          when _members.containsKey(peer):
        _members.remove(peer);
        session._emit(PeerLeft(peer, _disconnectReason(reason)));
      default:
        return false;
    }
    return true;
  }

  /// The reason that other clients are given for a client that left the
  /// host for [reason].
  ///
  /// Rejections and mismatches turn away clients that have not joined. A
  /// joined client leaves with one only by stating it in its own goodbye, or
  /// by sending a later message with another protocol version, so a
  /// rejection counts as leaving and a mismatch as a protocol violation.
  static DepartureReason _departureReason(DisconnectReason reason) =>
      switch (reason) {
        DisconnectReason.closed ||
        DisconnectReason.remoteClosed ||
        DisconnectReason.rejected ||
        DisconnectReason.notAdmitting => DepartureReason.left,
        DisconnectReason.kicked => DepartureReason.kicked,
        DisconnectReason.timeout => DepartureReason.timeout,
        DisconnectReason.bootstrapFailed => DepartureReason.bootstrapFailed,
        DisconnectReason.versionMismatch ||
        DisconnectReason.schemaMismatch ||
        DisconnectReason.protocolViolation => DepartureReason.protocolViolation,
        DisconnectReason.transportError => DepartureReason.transportError,
      };

  /// The reason that a client reports for another client that left for
  /// [reason].
  static DisconnectReason _disconnectReason(DepartureReason reason) =>
      switch (reason) {
        DepartureReason.left => DisconnectReason.remoteClosed,
        DepartureReason.kicked => DisconnectReason.kicked,
        DepartureReason.timeout => DisconnectReason.timeout,
        DepartureReason.bootstrapFailed => DisconnectReason.bootstrapFailed,
        DepartureReason.protocolViolation => DisconnectReason.protocolViolation,
        DepartureReason.transportError => DisconnectReason.transportError,
      };
}
