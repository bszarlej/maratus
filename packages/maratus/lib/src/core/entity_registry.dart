import '../protocol/identifiers.dart';
import '../protocol/value_codec.dart';

/// The lifecycle of a [NetworkEntity].
enum EntityState {
  /// Registered but not yet taking part in gameplay, for example because its
  /// component is still loading.
  pending,

  /// Taking part in gameplay.
  ready,

  /// Removed from the session. Its ID is never used again in the session.
  removed,
}

/// A networked entity in an [EntityRegistry].
final class NetworkEntity {
  NetworkEntity._(this.id, this.owner, this.authority);

  /// The ID of this entity, unique within its session.
  final EntityId id;

  /// The peer that controls this entity's input, and so may call its
  /// owner-only RPCs.
  final PeerId owner;

  /// The peer whose copy of this entity is the source of truth. It is fixed
  /// for the entity's lifetime.
  final PeerId authority;

  /// The lifecycle state of this entity.
  EntityState get state => _state;
  EntityState _state = EntityState.pending;

  @override
  String toString() =>
      'NetworkEntity(${id.value}, owner ${owner.value}, '
      'authority ${authority.value}, ${_state.name})';
}

/// The networked entities of a session, by ID.
///
/// IDs are scoped to the session and never reused within it: a removed
/// entity keeps its ID, so a late message about it cannot affect a newer
/// entity. The registry does not depend on a transport, and is used the
/// same way by hosts and clients.
final class EntityRegistry {
  final _entities = <EntityId, NetworkEntity>{};
  var _nextId = 1;

  /// The entity with [id], including a removed one, or `null` if no entity
  /// with [id] was registered.
  NetworkEntity? operator [](EntityId id) => _entities[id];

  /// The entities that have not been removed, in the order they were
  /// registered.
  Iterable<NetworkEntity> get entities =>
      _entities.values.where((entity) => entity._state != EntityState.removed);

  /// The entities owned by [peer] that have not been removed.
  Iterable<NetworkEntity> ownedBy(PeerId peer) =>
      entities.where((entity) => entity.owner == peer);

  /// Registers a pending entity under a new ID, higher than every ID
  /// registered so far.
  ///
  /// Throws an [ArgumentError] if [owner] or [authority] is outside the
  /// valid peer ID range, and a [StateError] if no entity IDs are left.
  NetworkEntity create({required PeerId owner, required PeerId authority}) {
    if (_nextId > IntCodec.maxSafe) {
      throw StateError('No entity IDs are left in this session.');
    }
    return register(EntityId(_nextId), owner: owner, authority: authority);
  }

  /// Registers a pending entity under [id], such as an ID that the host
  /// assigned.
  ///
  /// Throws an [ArgumentError] if [id], [owner], or [authority] is outside
  /// its valid range, or [id] was already registered, even if that entity
  /// has been removed.
  NetworkEntity register(
    EntityId id, {
    required PeerId owner,
    required PeerId authority,
  }) {
    if (id.value < 1 || id.value > IntCodec.maxSafe) {
      throw ArgumentError.value(
        id.value,
        'id',
        'must be from 1 to ${IntCodec.maxSafe}',
      );
    }
    if (_entities.containsKey(id)) {
      throw ArgumentError.value(id.value, 'id', 'is already registered');
    }
    _checkPeer(owner, 'owner');
    _checkPeer(authority, 'authority');
    if (id.value >= _nextId) _nextId = id.value + 1;
    return _entities[id] = NetworkEntity._(id, owner, authority);
  }

  /// Marks the pending entity [id] ready.
  ///
  /// Returns `false`, without changing anything, if the entity was removed
  /// in the meantime, for example while its component was loading.
  ///
  /// Throws an [ArgumentError] if no entity with [id] was registered, and a
  /// [StateError] if it is already ready.
  bool markReady(EntityId id) {
    final entity = _lookUp(id);
    switch (entity._state) {
      case EntityState.pending:
        entity._state = EntityState.ready;
        return true;
      case EntityState.ready:
        throw StateError('$entity is already ready.');
      case EntityState.removed:
        return false;
    }
  }

  /// Removes the entity [id]. Removing an entity again has no effect.
  ///
  /// Throws an [ArgumentError] if no entity with [id] was registered.
  void remove(EntityId id) => _lookUp(id)._state = EntityState.removed;

  /// Marks every entity removed and forgets it, so that IDs start from 1
  /// again in a new session.
  void clear() {
    for (final entity in _entities.values) {
      entity._state = EntityState.removed;
    }
    _entities.clear();
    _nextId = 1;
  }

  static void _checkPeer(PeerId peer, String name) {
    if (peer.value < 1 || peer.value > IntCodec.maxSafe) {
      throw ArgumentError.value(
        peer.value,
        name,
        'must be from 1 to ${IntCodec.maxSafe}',
      );
    }
  }

  NetworkEntity _lookUp(EntityId id) =>
      _entities[id] ??
      (throw ArgumentError.value(id.value, 'id', 'is not registered'));
}
