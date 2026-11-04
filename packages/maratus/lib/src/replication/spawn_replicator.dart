part of '../core/multiplayer_session.dart';

/// What the host does with a spawned entity when its owner leaves.
enum OwnerLeftPolicy {
  /// Keep the entity for the remaining peers, with its original metadata.
  ///
  /// Peer IDs are never reused within a session, so no other peer can act
  /// as the entity's owner afterward.
  keep,

  /// Despawn the entity and its descendants for the remaining peers.
  despawn,
}

/// Creates the local representation of a replicated entity, such as a
/// component.
typedef SpawnHandler<T> = void Function(SpawnContext<T> context);

/// Releases the local representation of a replicated entity that was
/// despawned, or whose session ended.
typedef DespawnHandler = void Function(NetworkEntity entity);

/// A replicated entity and the construction data it was spawned with.
final class SpawnContext<T> {
  const SpawnContext._({
    required this.entity,
    required this.data,
    required this.parent,
  });

  /// The spawned entity, with its owner and fixed authority.
  ///
  /// Like other registry entities, it starts pending until an attachment or
  /// [EntityRegistry.markReady] makes it ready.
  final NetworkEntity entity;

  /// This handler's own copy of the construction data.
  final T data;

  /// The replicated entity that [entity] was spawned under, if any.
  final NetworkEntity? parent;
}

/// Spawn and despawn handlers bound to one spawn type of a session.
///
/// While live, a binding is told about every replicated entity of its type:
/// those that already exist when it is bound, then each one spawned later.
/// It is told again when each of those entities is despawned, including when
/// the session ends. Bindings stay live across session restarts until
/// disposed.
final class SpawnBinding {
  SpawnBinding._(this._replicator, this.type, this._spawn, this._despawn);

  final _SpawnReplicator _replicator;
  final void Function(NetworkEntity entity, Object? data, NetworkEntity? parent)
  _spawn;
  final DespawnHandler? _despawn;
  var _disposed = false;

  /// The spawn type whose entities this binding handles.
  final SpawnTypeId type;

  /// Whether this binding was disposed.
  bool get isDisposed => _disposed;

  /// Stops calling this binding's handlers. The entities remain spawned.
  ///
  /// Repeated disposal has no effect.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _replicator._unbind(this);
  }
}

final class _SpawnReplicator {
  _SpawnReplicator(this.session);

  final MultiplayerSession session;
  final _bindings = <SpawnTypeId, SpawnBinding>{};

  /// The live replicated entities, in spawn order, so parents precede their
  /// children.
  final _records = <EntityId, _SpawnRecord>{};

  /// On a joining client, the baseline records whose entities may still be
  /// pending.
  final _baseline = <_SpawnRecord>{};
  var _baselineFailed = false;
  var _lifetime = 0;
  var _invocationDepth = 0;

  bool get isInvoking => _invocationDepth != 0;

  /// The live baseline entities that are not ready yet.
  int get pendingBaselineCount {
    // Neither a ready nor a despawned entity can become pending again.
    _baseline.removeWhere(
      (record) => !_isLive(record) || record.entity.state == EntityState.ready,
    );
    return _baseline.length;
  }

  /// Whether a spawn handler failed for a baseline entity that was not ready
  /// yet, so this client cannot install a complete baseline.
  bool get baselineFailed => _baselineFailed;

  /// Forgets the entities of a previous session. Bindings stay live.
  void clear() {
    _lifetime++;
    _records.clear();
    _baseline.clear();
    _baselineFailed = false;
  }

  SpawnBinding bind<T>(
    SpawnType<T> type, {
    required SpawnHandler<T> onSpawn,
    DespawnHandler? onDespawn,
  }) {
    _checkHandle(type);
    if (_bindings[type.id] case final existing? when !existing._disposed) {
      throw StateError('Spawn type ${type.id.value} already has a binding.');
    }
    final binding = SpawnBinding._(
      this,
      type.id,
      (entity, data, parent) => onSpawn(
        SpawnContext._(entity: entity, data: data as T, parent: parent),
      ),
      onDespawn,
    );
    _bindings[type.id] = binding;
    for (final record in _records.values.toList()) {
      if (record.type == type.id) _announce(record);
    }
    return binding;
  }

  void _unbind(SpawnBinding binding) {
    if (identical(_bindings[binding.type], binding)) {
      _bindings.remove(binding.type);
    }
  }

  NetworkEntity spawn<T>(
    SpawnType<T> type,
    T data, {
    required PeerId owner,
    required PeerId authority,
    required NetworkEntity? parent,
    required OwnerLeftPolicy onOwnerLeft,
  }) {
    if (session._state != SessionState.hosting) {
      throw StateError('Only a hosting session spawns entities.');
    }
    _checkHandle(type);
    if (owner != PeerId.host && !session._peers.containsKey(owner)) {
      throw ArgumentError.value(
        owner.value,
        'owner',
        'must be the host or a joined client',
      );
    }
    if (authority != PeerId.host && authority != owner) {
      throw ArgumentError.value(
        authority.value,
        'authority',
        'must be the host or the owner',
      );
    }
    final parentRecord = parent == null ? null : _recordOf(parent);
    if (parent != null && parentRecord == null) {
      throw ArgumentError.value(
        parent,
        'parent',
        'must be a replicated entity of this session',
      );
    }
    if (session._revision == IntCodec.maxSafe) {
      throw StateError('No replication revisions are left in this session.');
    }
    SpawnMessage record(EntityId entity) => SpawnMessage(
      entity: entity,
      type: type.id,
      data: data,
      owner: owner,
      authority: authority,
      parent: parent?.id,
    );
    // The largest ID encodes the largest record, so a valid placeholder
    // proves that the allocated ID fits as well.
    _canonical(record(const EntityId(IntCodec.maxSafe)));
    final entity = session.registry.create(owner: owner, authority: authority);
    final Uint8List bytes;
    try {
      bytes = _canonical(record(entity.id));
    } on ArgumentError {
      session.registry.remove(entity.id);
      rethrow;
    }
    final spawned = _add(entity, type.id, parentRecord, bytes, onOwnerLeft);
    session._replicate(_decode(bytes), session._nextRevision());
    _announce(spawned);
    return entity;
  }

  bool despawn(NetworkEntity entity) {
    if (session._state != SessionState.hosting) {
      throw StateError('Only a hosting session despawns entities.');
    }
    final record = _recordOf(entity);
    if (record != null) {
      _despawn(record);
      return true;
    }
    if (identical(session.registry[entity.id], entity) &&
        entity.state == EntityState.removed) {
      return false;
    }
    throw ArgumentError.value(
      entity,
      'entity',
      'must be a replicated entity of this session',
    );
  }

  /// Despawns the entities that [peer] owned with [OwnerLeftPolicy.despawn].
  void peerLeft(PeerId peer) {
    for (final record in _records.values.toList()) {
      if (record.entity.owner == peer &&
          record.policy == OwnerLeftPolicy.despawn &&
          _isLive(record)) {
        _despawn(record);
      }
    }
  }

  /// Sends the live entities, parents first, as part of [remote]'s
  /// baseline. Returns `false` if its transport refused one, which removes
  /// [remote].
  bool sendBaseline(_Remote remote) {
    for (final record in _records.values.toList()) {
      if (!session._send(
        remote,
        _decode(record.bytes),
        revision: session._revision,
      )) {
        return false;
      }
    }
    return true;
  }

  /// Applies a spawn record from the host, part of this client's [baseline]
  /// or a later change. Returns `false` if it conflicts with the replicated
  /// entities, which is a protocol violation.
  bool applySpawn(SpawnMessage message, {bool baseline = false}) {
    final parentId = message.parent;
    final parent = parentId == null ? null : _records[parentId];
    if (session.registry[message.entity] != null ||
        (parentId != null && parent == null) ||
        (message.authority != PeerId.host &&
            message.authority != message.owner)) {
      return false;
    }
    final Uint8List bytes;
    try {
      bytes = _canonical(message);
    } on ArgumentError {
      return false;
    }
    final entity = session.registry.register(
      message.entity,
      owner: message.owner,
      authority: message.authority,
    );
    final record = _add(
      entity,
      message.type,
      parent,
      bytes,
      OwnerLeftPolicy.keep,
    );
    if (baseline) _baseline.add(record);
    _announce(record);
    return true;
  }

  /// Applies a despawn record from the host. Returns `false` if it does not
  /// name a live replicated entity, which is a protocol violation.
  bool applyDespawn(DespawnMessage message) {
    final record = _records[message.entity];
    if (record == null) return false;
    _release(_remove(record));
    return true;
  }

  /// Forgets the entities of a session that disconnected, and returns them
  /// for [release] once the registry has been cleared.
  List<_SpawnRecord> end() {
    final ended = _records.values.toList();
    _records.clear();
    _baseline.clear();
    _baselineFailed = false;
    return ended;
  }

  /// Tells the bindings that [ended] entities no longer exist.
  void release(List<_SpawnRecord> ended) => _release(ended);

  void _checkHandle<T>(SpawnType<T> type) {
    if (!identical(session._schema.spawnTypeDefinition(type.id), type)) {
      throw ArgumentError.value(
        type,
        'type',
        'must belong to the session schema',
      );
    }
  }

  _SpawnRecord? _recordOf(NetworkEntity entity) {
    final record = _records[entity.id];
    return record != null && identical(record.entity, entity) ? record : null;
  }

  bool _isLive(_SpawnRecord record) =>
      identical(_records[record.entity.id], record);

  _SpawnRecord _add(
    NetworkEntity entity,
    SpawnTypeId type,
    _SpawnRecord? parent,
    Uint8List bytes,
    OwnerLeftPolicy policy,
  ) {
    final record = _SpawnRecord(entity, type, parent, bytes, policy);
    _records[entity.id] = record;
    parent?.children.add(record);
    return record;
  }

  /// Encodes [message] as a canonical record that receivers can decode.
  ///
  /// Throws an [ArgumentError] if its codec or the wire limits reject it.
  Uint8List _canonical(SpawnMessage message) {
    final bytes = session._codec.encode(MessageEnvelope(message));
    try {
      session._codec.decode(bytes);
    } on ProtocolException catch (error) {
      throw ArgumentError('Spawn data cannot be decoded: $error');
    }
    return bytes;
  }

  /// A fresh copy of a canonical record, with its own construction data.
  SpawnMessage _decode(Uint8List bytes) =>
      session._codec.decode(bytes).message as SpawnMessage;

  void _despawn(_SpawnRecord record) {
    final revision = session._nextRevision();
    final removed = _remove(record);
    session._replicate(DespawnMessage(entity: record.entity.id), revision);
    _release(removed);
  }

  /// Removes [root] and its descendants, parents first, from the records,
  /// the registry, and the synchronized values.
  List<_SpawnRecord> _remove(_SpawnRecord root) {
    root.parent?.children.remove(root);
    final removed = <_SpawnRecord>[];
    final pending = [root];
    while (pending.isNotEmpty) {
      final record = pending.removeLast();
      removed.add(record);
      final id = record.entity.id;
      _records.remove(id);
      session._states.forget(id);
      if (identical(session.registry[id], record.entity)) {
        session.registry.remove(id);
      }
      pending.addAll(record.children.reversed);
    }
    return removed;
  }

  /// Calls the spawn handler bound to [record]'s type, unless the entity was
  /// despawned or the binding was already told.
  void _announce(_SpawnRecord record) {
    final binding = _bindings[record.type];
    if (binding == null ||
        binding._disposed ||
        identical(record.announced, binding) ||
        !_isLive(record)) {
      return;
    }
    record.announced = binding;
    // A pending baseline entity without its local representation would leave
    // this client's world incomplete.
    final required =
        _baseline.contains(record) &&
        record.entity.state == EntityState.pending;
    final data = _decode(record.bytes).data;
    final created = _invoke(
      record,
      () => binding._spawn(record.entity, data, record.parent?.entity),
    );
    if (!created && required && _isLive(record)) _baselineFailed = true;
  }

  /// Calls the despawn handlers of the bindings told about [records],
  /// children before their parents.
  void _release(List<_SpawnRecord> records) {
    for (final record in records.reversed) {
      final binding = record.announced;
      record.announced = null;
      final onDespawn = binding?._despawn;
      if (binding == null || binding._disposed || onDespawn == null) continue;
      _invoke(record, () => onDespawn(record.entity));
    }
  }

  /// Calls a [handler] of [record], reporting its failure. Returns whether
  /// the handler completed.
  bool _invoke(_SpawnRecord record, void Function() handler) {
    final lifetime = _lifetime;
    _invocationDepth++;
    try {
      handler();
      return true;
    } on Object catch (error, stackTrace) {
      if (_lifetime == lifetime) {
        session._emit(
          SpawnHandlerFailed(
            entity: record.entity.id,
            type: record.type,
            error: error,
            stackTrace: stackTrace,
          ),
        );
      }
      return false;
    } finally {
      _invocationDepth--;
    }
  }
}

final class _SpawnRecord {
  _SpawnRecord(this.entity, this.type, this.parent, this.bytes, this.policy);

  final NetworkEntity entity;
  final SpawnTypeId type;
  final _SpawnRecord? parent;

  /// The canonical spawn record. Decoding it gives each consumer its own
  /// copy of the construction data.
  final Uint8List bytes;
  final OwnerLeftPolicy policy;
  final children = <_SpawnRecord>[];

  /// The binding told about this entity, which is told when it despawns.
  SpawnBinding? announced;
}
