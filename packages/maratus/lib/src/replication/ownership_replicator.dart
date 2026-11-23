part of '../core/multiplayer_session.dart';

/// Transfers the ownership of replicated and static entities on a host, and
/// applies the host's transfers on a client.
///
/// The host is the single source of ownership: it changes an entity's owner
/// at once, optionally with its authority, then replicates the change in
/// revision order. Each client that the transfer makes, or stops being, the
/// entity's owner or authority acknowledges it, so the host can tell the
/// inputs and state that client sent before it applied the transfer from
/// those it sent afterward.
final class _OwnershipReplicator {
  _OwnershipReplicator(this.session);

  final MultiplayerSession session;

  /// On a host, the acknowledgements it awaits, by entity: for each client
  /// that a transfer made, or stopped being, the entity's owner, the
  /// revision of the latest such transfer.
  final _awaited = <NetworkEntity, Map<PeerId, int>>{};

  /// The revision of the latest transfer of each entity's ownership.
  /// [forgetEntity] drops a despawned entity's entry, and [prune], which
  /// every update runs, the entries of entities removed otherwise.
  final _transfers = <NetworkEntity, int>{};

  int lastTransfer(NetworkEntity entity) => _transfers[entity] ?? 0;

  void forgetEntity(EntityId id) {
    _transfers.removeWhere((entity, _) => entity.id == id);
    _awaited.removeWhere((entity, _) => entity.id == id);
  }

  void prune() {
    bool gone(NetworkEntity entity) =>
        entity.state == EntityState.removed ||
        !identical(session.registry[entity.id], entity);
    _transfers.removeWhere((entity, _) => gone(entity));
    _awaited.removeWhere((entity, _) => gone(entity));
  }

  /// Forgets the transfers of a previous session.
  void clear() {
    _awaited.clear();
    _transfers.clear();
  }

  bool transfer(NetworkEntity entity, PeerId owner, bool withAuthority) {
    final authorities = session._authorities;
    session._visibility.checkNotFiltering();
    if (session._state != SessionState.hosting) {
      throw StateError('Only a hosting session transfers ownership.');
    }
    if (!authorities._isTransferable(entity)) {
      throw ArgumentError.value(
        entity,
        'entity',
        'must be a replicated or static entity of this session',
      );
    }
    if (owner != PeerId.host && !session.isReady(owner)) {
      throw ArgumentError.value(
        owner.value,
        'owner',
        'must be the host or a ready client',
      );
    }
    final authority = withAuthority && entity.authority != owner ? owner : null;
    if (entity.owner == owner) {
      return authority != null && authorities.transfer(entity, authority);
    }
    _transfer(entity, owner, authority);
    return true;
  }

  /// Makes [owner] the owner of [entity] on the host, and [authority], if
  /// given, its authority, replicates the transfer to every joined client
  /// that sees the entity, and sends the previous client owner and
  /// authority the values that the host accepted from them.
  ///
  /// A client [owner] receives the entity first if it does not see it, and
  /// a previous client owner or authority keeps seeing it only as its
  /// visibility decides.
  void _transfer(NetworkEntity entity, PeerId owner, PeerId? authority) {
    final authorities = session._authorities;
    session._checkRevisionsLeft();
    final previousOwner = entity.owner;
    final previousAuthority = entity.authority;
    session._visibility.reveal(entity, owner);
    // A client whose transport refused the entity has left, and its
    // departure may have despawned the entity.
    if (!authorities._isTransferable(entity) ||
        (owner != PeerId.host && !session._peers.containsKey(owner))) {
      return;
    }
    if (authority != null) authorities._change(entity, authority);
    _change(entity, owner);
    final revision = session._replicate(
      OwnershipMessage(entity: entity.id, owner: owner, authority: authority),
      to: session._visibility.audience(entity),
    );
    // Clients whose transports refused the transfer have left, and their
    // departure may have despawned the entity or transferred it again.
    if (entity.state == EntityState.removed) return;
    _transfers[entity] = max(_transfers[entity] ?? 0, revision);
    _await(entity, revision, {previousOwner, owner});
    if (authority != null) {
      authorities._record(entity, revision, {previousAuthority, authority});
    }
    final remoteOwner = session._peers[previousOwner];
    if (remoteOwner != null) {
      session._states.resync(remoteOwner, entity, FieldWriter.owner);
    }
    if (entity.state == EntityState.removed) return;
    if (authority != null) {
      final remoteAuthority = session._peers[previousAuthority];
      if (remoteAuthority != null) {
        session._states.resync(remoteAuthority, entity, FieldWriter.authority);
      }
      if (entity.state == EntityState.removed) return;
    }
    session._visibility.transferred(entity, previousOwner);
    if (authority != null &&
        previousAuthority != previousOwner &&
        entity.state != EntityState.removed) {
      session._visibility.transferred(entity, previousAuthority);
    }
  }

  void _await(NetworkEntity entity, int revision, Set<PeerId> peers) {
    for (final peer in peers) {
      if (peer == PeerId.host || !session._peers.containsKey(peer)) continue;
      (_awaited[entity] ??= {})[peer] = revision;
    }
  }

  /// Whether the host awaits [peer]'s acknowledgement of an ownership
  /// transfer of [entity], so that inputs and owner-written state that
  /// [peer] sends about it predate the transfer.
  bool awaits(NetworkEntity entity, PeerId peer) =>
      _awaited[entity]?.containsKey(peer) ?? false;

  /// Records [peer]'s acknowledgement of the transfer of [message]'s entity
  /// with [revision], including the authority that it may have moved.
  /// Returns `false` if no such revision was assigned, which is a protocol
  /// violation.
  ///
  /// An acknowledgement of an earlier transfer, or of a transfer of an
  /// entity despawned since, changes nothing.
  bool acknowledge(PeerId peer, OwnershipAckMessage message, int revision) {
    if (revision > session._revision) return false;
    session._authorities._settle(peer, message.entity, revision);
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

  /// Sends the owner of each static entity that the host no longer owns as
  /// part of [remote]'s baseline. Returns `false` if its transport refused
  /// one, which removes [remote].
  ///
  /// Spawn records in the baseline carry the current owner of their
  /// entities instead.
  bool sendBaseline(_Remote remote) {
    for (final entity in session._staticEntities.values.toList()) {
      if (entity.owner == PeerId.host) continue;
      if (!session._send(
        remote,
        OwnershipMessage(entity: entity.id, owner: entity.owner),
        revision: session._revision,
      )) {
        return false;
      }
    }
    return true;
  }

  /// Applies a transfer from the host, which has [revision], and
  /// acknowledges it if it makes this client, or stops it being, the
  /// entity's owner or authority. Returns `false` if the transfer does not
  /// change the owner of a live replicated or static entity, or names its
  /// current authority as a new one, which is a protocol violation.
  bool apply(OwnershipMessage message, int revision) {
    final authorities = session._authorities;
    final entity = session.registry[message.entity];
    final authority = message.authority;
    if (entity == null ||
        !authorities._isTransferable(entity) ||
        entity.owner == message.owner ||
        entity.authority == authority) {
      return false;
    }
    final previousOwner = entity.owner;
    final previousAuthority = entity.authority;
    final local = session._localPeer;
    _transfers[entity] = revision;
    if (authority != null) {
      authorities._transfers[entity] = revision;
      authorities._change(entity, authority);
    }
    _change(entity, message.owner);
    final host = session._peers[PeerId.host];
    final affected = {
      previousOwner,
      message.owner,
      if (authority != null) ...{previousAuthority, authority},
    };
    if (host != null && affected.contains(local)) {
      // Any inputs and state this client sent before follow its previous
      // roles; those it sends from now on follow this acknowledgement.
      session._send(
        host,
        OwnershipAckMessage(entity: entity.id),
        revision: revision,
      );
    }
    return true;
  }

  void _change(NetworkEntity entity, PeerId owner) {
    final previous = entity.owner;
    changeOwner(entity, owner);
    session._states.ownerTransferred(entity, previous);
    session._emit(
      OwnerChanged(entity: entity.id, previous: previous, owner: owner),
    );
  }
}
