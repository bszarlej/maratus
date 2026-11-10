part of '../core/multiplayer_session.dart';

/// Transfers the authority of replicated and static entities on a host, and
/// applies the host's transfers on a client.
///
/// The host is the single source of authority: it changes an entity's
/// authority at once, then replicates the change in revision order. Each
/// client that the transfer makes, or stops being, the entity's authority
/// acknowledges it, so the host can tell the state that client sent before
/// it applied the transfer from the state it sent afterward.
final class _AuthorityReplicator {
  _AuthorityReplicator(this.session);

  final MultiplayerSession session;

  /// On a host, the acknowledgements it awaits, by entity: for each client
  /// that a transfer made, or stopped being, the entity's authority, the
  /// revision of the latest such transfer.
  final _awaited = <NetworkEntity, Map<PeerId, int>>{};

  /// Forgets the transfers of a previous session.
  void clear() => _awaited.clear();

  bool transfer(NetworkEntity entity, PeerId authority) {
    if (session._state != SessionState.hosting) {
      throw StateError('Only a hosting session transfers authority.');
    }
    if (!_isTransferable(entity)) {
      throw ArgumentError.value(
        entity,
        'entity',
        'must be a replicated or static entity of this session',
      );
    }
    if (authority != PeerId.host && !session.isReady(authority)) {
      throw ArgumentError.value(
        authority.value,
        'authority',
        'must be the host or a ready client',
      );
    }
    if (entity.authority == authority) return false;
    _transfer(entity, authority);
    return true;
  }

  /// Makes [authority] the authority of [entity] on the host, replicates
  /// the transfer to every joined client, and sends a previous client
  /// authority the values that the host accepted from it.
  void _transfer(NetworkEntity entity, PeerId authority) {
    session._checkRevisionsLeft();
    final previous = entity.authority;
    _change(entity, authority);
    final revision = session._replicate(
      AuthorityMessage(entity: entity.id, authority: authority),
    );
    // Clients whose transports refused the transfer have left, and their
    // departure may have despawned the entity or transferred it again.
    if (entity.state == EntityState.removed) return;
    for (final peer in {previous, authority}) {
      if (peer == PeerId.host || !session._peers.containsKey(peer)) continue;
      (_awaited[entity] ??= {})[peer] = revision;
    }
    final remote = session._peers[previous];
    if (remote != null) session._states.resync(remote, entity);
  }

  /// Whether the host awaits [peer]'s acknowledgement of a transfer of
  /// [entity], so that state [peer] sends about it predates the transfer.
  bool awaits(NetworkEntity entity, PeerId peer) =>
      _awaited[entity]?.containsKey(peer) ?? false;

  /// Records [peer]'s acknowledgement of the transfer of [message]'s entity
  /// with [revision]. Returns `false` if no such revision was assigned,
  /// which is a protocol violation.
  ///
  /// An acknowledgement of an earlier transfer, or of a transfer of an
  /// entity despawned since, changes nothing.
  bool acknowledge(PeerId peer, AuthorityAckMessage message, int revision) {
    if (revision > session._revision) return false;
    final entity = session.registry[message.entity];
    final awaited = entity == null ? null : _awaited[entity];
    if (awaited == null || awaited[peer] != revision) return true;
    awaited.remove(peer);
    if (awaited.isEmpty) _awaited.remove(entity);
    return true;
  }

  /// Forgets the acknowledgements awaited from [peer], which left.
  void forget(PeerId peer) {
    for (final awaited in _awaited.values) {
      awaited.remove(peer);
    }
    _awaited.removeWhere(
      (entity, awaited) =>
          awaited.isEmpty || entity.state == EntityState.removed,
    );
  }

  /// Transfers the authority of the live replicated and static entities
  /// whose authority was [peer], which left, to the host.
  ///
  /// This includes an entity whose transfer to [peer] it never
  /// acknowledged. The host continues from the latest values it accepted.
  void reclaim(PeerId peer) {
    final entities = [
      for (final record in session._spawns._records.values) record.entity,
      ...session._staticEntities.values,
    ];
    for (final entity in entities) {
      // A departure during an earlier transfer may have despawned the
      // entity or reclaimed it already.
      if (entity.authority == peer && _isTransferable(entity)) {
        _transfer(entity, PeerId.host);
      }
    }
  }

  /// Sends the authority of each static entity that the host no longer
  /// writes as part of [remote]'s baseline. Returns `false` if its
  /// transport refused one, which removes [remote].
  ///
  /// Spawn records in the baseline carry the current authority of their
  /// entities instead.
  bool sendBaseline(_Remote remote) {
    for (final entity in session._staticEntities.values.toList()) {
      if (entity.authority == PeerId.host) continue;
      if (!session._send(
        remote,
        AuthorityMessage(entity: entity.id, authority: entity.authority),
        revision: session._revision,
      )) {
        return false;
      }
    }
    return true;
  }

  /// Applies a transfer from the host, which has [revision], and
  /// acknowledges it if it makes this client, or stops it being, the
  /// entity's authority. Returns `false` if the transfer does not change
  /// the authority of a live replicated or static entity, which is a
  /// protocol violation.
  bool apply(AuthorityMessage message, int revision) {
    final entity = session.registry[message.entity];
    if (entity == null ||
        !_isTransferable(entity) ||
        entity.authority == message.authority) {
      return false;
    }
    final previous = entity.authority;
    final local = session._localPeer;
    _change(entity, message.authority);
    final host = session._peers[PeerId.host];
    if (host != null && (previous == local || message.authority == local)) {
      // Any state this client sent before follows its own authority; the
      // state it sends from now on follows this acknowledgement.
      session._send(
        host,
        AuthorityAckMessage(entity: entity.id),
        revision: revision,
      );
    }
    return true;
  }

  bool _isTransferable(NetworkEntity entity) =>
      identical(session.registry[entity.id], entity) &&
      entity.state != EntityState.removed &&
      (session._spawns._recordOf(entity) != null ||
          session._staticEntities.containsValue(entity));

  void _change(NetworkEntity entity, PeerId authority) {
    final previous = entity.authority;
    changeAuthority(entity, authority);
    session._states.transferred(entity, previous);
    session._emit(
      AuthorityChanged(
        entity: entity.id,
        previous: previous,
        authority: authority,
      ),
    );
  }
}
