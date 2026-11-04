part of 'multiplayer_scope.dart';

/// Creates the component that represents a replicated entity on this peer.
///
/// Return a new component whose [NetworkedComponent.networkEntity] is
/// `context.entity`.
typedef SpawnFactory<T> = NetworkedComponent Function(SpawnContext<T> context);

/// Creates components for the replicated entities of registered spawn types.
///
/// Add a spawner inside a [MultiplayerScope] and [register] a factory for each
/// spawn type it handles. A type belongs to at most one spawner per session.
/// Spawn and despawn entities with the scope's [MultiplayerSession.spawn] and
/// [MultiplayerSession.despawn]; every peer's spawner then creates or removes
/// the matching component. A component is created while its spawn record is
/// applied: on the host inside [MultiplayerSession.spawn], and on a client
/// during the scope's session update. Its attachment therefore exists before
/// RPCs that arrive in the same update are dispatched, provided the component
/// calls `super.onLoad()` before any asynchronous work. Entities that already
/// exist when the spawner is added get components too.
///
/// A joining client reports ready once the components of the entities in its
/// baseline have mounted. A factory that throws for one of those entities
/// ends the join with [DisconnectReason.bootstrapFailed].
///
/// A spawned component is added under the component of its entity's parent
/// when that component is attached in the same scope, and under the spawner
/// otherwise. Despawning, including the end of the session, removes the
/// component, even while it is still loading. Removing a spawned component
/// locally does not despawn its entity, and the spawner does not recreate it.
///
/// Removing the spawner stops it from creating components. Its components
/// leave the tree with it; when it is added again, it removes those whose
/// entities were despawned meanwhile and creates components for new ones.
class MultiplayerSpawner extends Component {
  /// Creates a spawner. [register] factories before or after adding it.
  MultiplayerSpawner({super.children, super.priority, super.key});

  final _factories = <SpawnTypeId, _SpawnerFactory<Object?>>{};
  final _bindings = <SpawnBinding>[];
  final _spawned = <NetworkEntity, NetworkedComponent>{};
  MultiplayerScope? _spawnerScope;

  /// The components this spawner created, by entity, until their entities
  /// despawn. A component that was removed locally stays listed.
  Map<NetworkEntity, NetworkedComponent> get spawnedComponents =>
      UnmodifiableMapView(_spawned);

  /// Registers [factory] to create the components of [type]'s entities.
  ///
  /// Throws a [StateError] if this spawner already has a factory for [type],
  /// or, once attached to a scope, if another spawner handles [type] in its
  /// session. Throws an [ArgumentError] once attached if [type] is not a
  /// handle of the session's schema.
  void register<T>(SpawnType<T> type, SpawnFactory<T> factory) {
    if (_factories.containsKey(type.id)) {
      throw StateError(
        'This spawner already has a factory for ${type.id.value}.',
      );
    }
    final entry = _SpawnerFactory<T>(type, factory);
    final scope = _spawnerScope;
    if (scope != null) _bindings.add(entry.bind(this, scope.session));
    _factories[type.id] = entry;
  }

  @override
  @mustCallSuper
  FutureOr<void> onLoad() {
    _attachSpawner();
    return super.onLoad();
  }

  @override
  @mustCallSuper
  void onMount() {
    _attachSpawner();
    super.onMount();
  }

  @override
  @mustCallSuper
  void onRemove() {
    _detachSpawner();
    super.onRemove();
  }

  @override
  void removeFromParent() {
    _detachSpawner();
    super.removeFromParent();
  }

  bool get _hasLiveScope {
    final scope = _spawnerScope;
    if (scope == null ||
        scope.isDisposed ||
        !identical(MultiplayerScope.of(this), scope)) {
      return false;
    }
    for (
      Component? component = this;
      component != null;
      component = component.parent
    ) {
      if (component.isRemoving || component.isRemoved) return false;
    }
    return true;
  }

  void _attachSpawner() {
    final scope = MultiplayerScope.of(this);
    if (scope == null || scope.isDisposed) {
      throw StateError('A MultiplayerSpawner needs a live MultiplayerScope.');
    }
    if (identical(scope, _spawnerScope)) return;
    _detachSpawner();
    _spawnerScope = scope;
    scope._spawners.add(this);
    final session = scope.session;
    for (final MapEntry(key: entity, value: component)
        in _spawned.entries.toList()) {
      if (entity.state == EntityState.removed ||
          !identical(session.registry[entity.id], entity)) {
        _spawned.remove(entity);
        component.removeFromParent();
      }
    }
    try {
      for (final entry in _factories.values) {
        _bindings.add(entry.bind(this, session));
      }
    } on Object {
      _detachSpawner();
      rethrow;
    }
  }

  void _detachSpawner() {
    for (final binding in _bindings) {
      binding.dispose();
    }
    _bindings.clear();
    _spawnerScope?._spawners.remove(this);
    _spawnerScope = null;
  }

  void _spawn(
    NetworkEntity entity,
    NetworkEntity? parent,
    NetworkedComponent Function() create,
  ) {
    final scope = _spawnerScope;
    if (scope == null || !_hasLiveScope) {
      _detachSpawner();
      return;
    }
    if (_spawned.containsKey(entity)) return;
    final component = create();
    if (!identical(component.networkEntity, entity)) {
      throw StateError(
        'A spawn factory must create a component for the spawned entity.',
      );
    }
    _spawned[entity] = component;
    final container =
        (parent == null ? null : scope._attachedComponent(parent)) ?? this;
    final loading = container.add(component);
    if (loading is Future<void>) unawaited(loading);
  }

  void _despawn(NetworkEntity entity) =>
      _spawned.remove(entity)?.removeFromParent();
}

final class _SpawnerFactory<T> {
  _SpawnerFactory(this.type, this.create);

  final SpawnType<T> type;
  final SpawnFactory<T> create;

  SpawnBinding bind(MultiplayerSpawner spawner, MultiplayerSession session) =>
      session.bindSpawn<T>(
        type,
        onSpawn: (context) => spawner._spawn(
          context.entity,
          context.parent,
          () => create(context),
        ),
        onDespawn: spawner._despawn,
      );
}
