part of '../core/multiplayer_session.dart';

/// Decides whether the host shows the replicated [entity] to the client
/// [peer], together with the other filters of the session.
///
/// See [MultiplayerSession.addVisibilityFilter].
typedef VisibilityFilter = bool Function(NetworkEntity entity, PeerId peer);

/// Shows and hides replicated entities for each client of a host, as their
/// visibility decides.
///
/// A client sees a replicated entity while it has the entity's spawn
/// record. The host sends a client the record, marked as shown, and then
/// the entity's latest values when the entity comes into the client's view,
/// and a despawn record when it leaves. Every client sees the static
/// entities.
///
/// The visibility of an entity for a client follows from the entity's
/// owner and authority, its parent's visibility, the client's own setting,
/// the entity's public visibility, and the filters' decision, which the
/// host keeps from their latest evaluation.
final class _VisibilityReplicator {
  _VisibilityReplicator(this.session);

  final MultiplayerSession session;
  final _filters = <VisibilityFilter>[];
  var _filtering = 0;

  /// Whether a filter is running.
  bool get isFiltering => _filtering != 0;

  /// Throws a [StateError] if a filter is running, so filters cannot change
  /// the session while it decides what clients see.
  void checkNotFiltering() {
    if (isFiltering) {
      throw StateError('A visibility filter is running.');
    }
  }

  void addFilter(VisibilityFilter filter) {
    checkNotFiltering();
    if (!_filters.contains(filter)) _filters.add(filter);
  }

  bool removeFilter(VisibilityFilter filter) {
    checkNotFiltering();
    return _filters.remove(filter);
  }

  /// The clients that see [entity], or `null` if every peer does: on a
  /// client, and for the host's static entities.
  Set<PeerId>? audience(NetworkEntity entity) =>
      session._isHost ? session._spawns._recordOf(entity)?.visibleTo : null;

  /// Whether [peer] sees [entity]. Only a host hides entities, and only
  /// replicated entities from clients.
  bool sees(PeerId peer, NetworkEntity entity) =>
      peer == PeerId.host || (audience(entity)?.contains(peer) ?? true);

  bool isVisibleTo(NetworkEntity entity, PeerId peer) {
    _checkHosting();
    final record = session._spawns._recordOf(entity);
    if (record == null &&
        (entity.state == EntityState.removed ||
            !identical(session.registry[entity.id], entity) ||
            !session._staticEntities.containsValue(entity))) {
      throw ArgumentError.value(
        entity,
        'entity',
        'must be a replicated or static entity of this session',
      );
    }
    if (peer == PeerId.host) return true;
    if (!session._peers.containsKey(peer)) return false;
    return record == null || record.visibleTo.contains(peer);
  }

  void setPublic(NetworkEntity entity, bool visible) {
    checkNotFiltering();
    _checkHosting();
    final record = _replicated(entity);
    if (record.public == visible) return;
    session._checkRevisionsLeft();
    record.public = visible;
    _refresh([record], session._peers.values.toList());
  }

  void setFor(NetworkEntity entity, PeerId peer, bool? visible) {
    checkNotFiltering();
    _checkHosting();
    final record = _replicated(entity);
    final remote = _client(peer);
    if (record.visibility[peer] == visible) return;
    session._checkRevisionsLeft();
    if (visible == null) {
      record.visibility.remove(peer);
    } else {
      record.visibility[peer] = visible;
    }
    _refresh([record], [remote]);
  }

  void update(PeerId? peer) {
    checkNotFiltering();
    _checkHosting();
    final remotes = peer == null
        ? session._peers.values.toList()
        : [_client(peer)];
    session._checkRevisionsLeft();
    _filter(session._spawns._records.values.toList(), remotes);
    if (session._state != SessionState.hosting) return;
    _refresh(_roots(), remotes);
  }

  /// Decides which entities the joining [remote] sees, before the host
  /// sends its baseline.
  void joined(_Remote remote) {
    final records = session._spawns._records.values.toList();
    _filter(records, [remote]);
    if (!_isClient(remote)) return;
    final peer = remote.peer!;
    for (final root in _roots()) {
      for (final record in _decide(_subtree(root), peer)) {
        record.visibleTo.add(peer);
      }
    }
  }

  /// Decides which clients see the new entity of [record], first showing
  /// its hidden ancestors to the clients that own it or are its authority,
  /// which always see it.
  ///
  /// Returns the clients whose transports refused, for the caller to remove
  /// once it has sent them nothing more.
  List<_Remote> spawned(_SpawnRecord record) {
    final remotes = session._peers.values.toList();
    _filter([record], remotes);
    final refused = <_Remote>[];
    if (!session._spawns._isLive(record)) return refused;
    final entity = record.entity;
    final parent = record.parent;
    for (final remote in remotes) {
      if (!_isClient(remote)) continue;
      final peer = remote.peer!;
      if (entity.owner == peer || entity.authority == peer) {
        if (!_reveal(remote, parent)) {
          refused.add(remote);
          continue;
        }
        record.visibleTo.add(peer);
      } else if ((parent == null || parent.visibleTo.contains(peer)) &&
          _accepts(record, peer)) {
        record.visibleTo.add(peer);
      }
    }
    return refused;
  }

  /// Shows the replicated [entity] and its hidden ancestors to the client
  /// [peer], which is about to become the entity's authority. Removes
  /// [peer] if its transport refuses.
  void reveal(NetworkEntity entity, PeerId peer) {
    final record = session._spawns._recordOf(entity);
    final remote = session._peers[peer];
    if (record == null || remote == null) return;
    if (!_reveal(remote, record)) session._refused(remote);
  }

  /// Shows and hides the replicated [entity], its ancestors, and their
  /// descendants for the client [previous], which stopped being the
  /// entity's authority.
  void transferred(NetworkEntity entity, PeerId previous) {
    final record = session._spawns._recordOf(entity);
    final remote = session._peers[previous];
    if (record == null || remote == null) return;
    var root = record;
    for (var parent = root.parent; parent != null; parent = parent.parent) {
      root = parent;
    }
    _refresh([root], [remote]);
  }

  /// Forgets the visibility of the entities for [peer], which left.
  void left(PeerId peer) {
    for (final record in session._spawns._records.values) {
      record.visibleTo.remove(peer);
      record.visibility.remove(peer);
      record.rejected.remove(peer);
    }
  }

  void _checkHosting() {
    if (session._state != SessionState.hosting) {
      throw StateError('Only a hosting session decides visibility.');
    }
  }

  _SpawnRecord _replicated(NetworkEntity entity) =>
      session._spawns._recordOf(entity) ??
      (throw ArgumentError.value(
        entity,
        'entity',
        'must be a replicated entity of this session',
      ));

  _Remote _client(PeerId peer) =>
      session._peers[peer] ??
      (throw ArgumentError.value(
        peer.value,
        'peer',
        'must be a client of this host',
      ));

  bool _isClient(_Remote remote) =>
      identical(session._peers[remote.peer], remote);

  /// The live entities without a parent, in spawn order.
  List<_SpawnRecord> _roots() => [
    for (final record in session._spawns._records.values)
      if (record.parent == null) record,
  ];

  /// [root] and its descendants, parents first.
  static List<_SpawnRecord> _subtree(_SpawnRecord root) {
    final records = <_SpawnRecord>[];
    final pending = [root];
    while (pending.isNotEmpty) {
      final record = pending.removeLast();
      records.add(record);
      pending.addAll(record.children.reversed);
    }
    return records;
  }

  /// Whether [peer]'s own visibility of [record]'s entity, or else the
  /// entity's public visibility and the filters, let [peer] see it.
  static bool _accepts(_SpawnRecord record, PeerId peer) =>
      record.visibility[peer] ??
      (record.public && !record.rejected.contains(peer));

  /// The records of [subtree], parents first, that [peer] sees.
  ///
  /// A client sees the entities that it owns or is the authority of, and
  /// their ancestors. It sees no entity whose parent it does not see, and
  /// otherwise the entities that it accepts.
  static Set<_SpawnRecord> _decide(List<_SpawnRecord> subtree, PeerId peer) {
    final required = <_SpawnRecord>{};
    for (final record in subtree.reversed) {
      final entity = record.entity;
      if (entity.owner == peer ||
          entity.authority == peer ||
          record.children.any(required.contains)) {
        required.add(record);
      }
    }
    final root = subtree.first;
    final visible = <_SpawnRecord>{};
    for (final record in subtree) {
      final parent = record.parent;
      final parentVisible =
          parent == null ||
          (identical(record, root)
              ? parent.visibleTo.contains(peer)
              : visible.contains(parent));
      if (required.contains(record) ||
          (parentVisible && _accepts(record, peer))) {
        visible.add(record);
      }
    }
    return visible;
  }

  /// Evaluates the filters for [records] and the clients [remotes], and
  /// keeps which clients they reject each entity for. A filter that throws
  /// rejects the entity, and is reported.
  void _filter(List<_SpawnRecord> records, List<_Remote> remotes) {
    final verdicts = <(_SpawnRecord, PeerId, bool)>[];
    final filters = _filters.toList();
    _filtering++;
    try {
      for (final record in records) {
        for (final remote in remotes) {
          // A filter may have closed the session or kicked a client.
          if (session._state != SessionState.hosting) return;
          if (!_isClient(remote)) continue;
          final peer = remote.peer!;
          verdicts.add((record, peer, _accepted(filters, record.entity, peer)));
        }
      }
    } finally {
      _filtering--;
    }
    for (final (record, peer, accepted) in verdicts) {
      if (!session._spawns._isLive(record) ||
          !session._peers.containsKey(peer)) {
        continue;
      }
      if (accepted) {
        record.rejected.remove(peer);
      } else {
        record.rejected.add(peer);
      }
    }
  }

  bool _accepted(
    List<VisibilityFilter> filters,
    NetworkEntity entity,
    PeerId peer,
  ) {
    for (final filter in filters) {
      try {
        if (!filter(entity, peer)) return false;
      } on Object catch (error, stackTrace) {
        session._emit(
          VisibilityFilterFailed(
            entity: entity.id,
            peer: peer,
            error: error,
            stackTrace: stackTrace,
          ),
        );
        return false;
      }
    }
    return true;
  }

  /// Shows and hides [roots] and their descendants for [remotes], as their
  /// visibility now decides, then removes the clients whose transports
  /// refused.
  ///
  /// The callers keep each tree's visibility consistent above [roots]: a
  /// client sees the parent of each of the roots it sees.
  void _refresh(List<_SpawnRecord> roots, List<_Remote> remotes) {
    final refused = <_Remote>[];
    for (final remote in remotes) {
      if (_isClient(remote) && !_refreshFor(remote, roots)) {
        refused.add(remote);
      }
    }
    refused.forEach(session._refused);
  }

  /// Hides the entities of [roots]' trees that [remote] no longer sees,
  /// then shows the ones it now sees, parents first. Returns `false` if its
  /// transport refused.
  bool _refreshFor(_Remote remote, List<_SpawnRecord> roots) {
    final peer = remote.peer!;
    final hidden = <_SpawnRecord>[];
    final shown = <_SpawnRecord>[];
    for (final root in roots) {
      if (!session._spawns._isLive(root)) continue;
      final subtree = _subtree(root);
      final visible = _decide(subtree, peer);
      for (final record in subtree) {
        final seen = record.visibleTo.contains(peer);
        if (!seen && visible.contains(record)) {
          shown.add(record);
        } else if (seen &&
            !visible.contains(record) &&
            // A despawn record also removes the descendants.
            (identical(record, root) || visible.contains(record.parent))) {
          hidden.add(record);
        }
      }
    }
    for (final record in hidden) {
      if (!_hide(remote, record)) return false;
    }
    for (final record in shown) {
      if (!_show(remote, record)) return false;
    }
    return true;
  }

  /// Shows [record]'s entity and its ancestors that [remote] does not see,
  /// parents first. Returns `false` if its transport refused.
  bool _reveal(_Remote remote, _SpawnRecord? record) {
    final peer = remote.peer!;
    final hidden = <_SpawnRecord>[];
    for (
      var next = record;
      next != null && !next.visibleTo.contains(peer);
      next = next.parent
    ) {
      hidden.add(next);
    }
    for (final record in hidden.reversed) {
      if (!_show(remote, record)) return false;
    }
    return true;
  }

  /// Sends [remote] the spawn record of [record]'s entity, marked as shown,
  /// then its latest values, as in a baseline, each with a new revision.
  /// Returns `false` if its transport refused.
  bool _show(_Remote remote, _SpawnRecord record) {
    record.visibleTo.add(remote.peer!);
    if (!session._offerChange(remote, session._spawns.shown(record))) {
      return false;
    }
    for (final message in session._states.current(record.entity)) {
      if (!session._offerChange(remote, message)) return false;
    }
    return true;
  }

  /// Despawns [record]'s entity and its descendants for [remote], dropping
  /// the state held for them. Returns `false` if its transport refused.
  bool _hide(_Remote remote, _SpawnRecord record) {
    final peer = remote.peer!;
    final entities = <EntityId>{};
    for (final member in _subtree(record)) {
      member.visibleTo.remove(peer);
      entities.add(member.entity.id);
    }
    remote.held.removeWhere((key, _) => entities.contains(key.entity));
    return session._offerChange(
      remote,
      DespawnMessage(entity: record.entity.id),
    );
  }
}
