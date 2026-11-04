part of 'multiplayer_scope.dart';

/// Connects a Flame component to its nearest [MultiplayerScope].
///
/// For a static component, register [networkEntity] in the scope's session
/// before adding this component. A [MultiplayerSpawner] creates components for
/// replicated entities instead, through a factory that receives the entity.
/// Override [onNetworkAttach] to bind RPCs and synchronize properties through
/// the supplied attachment.
/// When overriding [onLoad], call `super.onLoad()` before any asynchronous work
/// so RPCs can wait safely while assets load. Never await a child's mounting
/// from an ancestor's load path.
///
/// Call super in [onMount] and [onRemove] overrides. Removing or reparenting a
/// component disposes its bindings and queued calls, without despawning the
/// entity. Remounting creates fresh bindings. A component that finishes
/// loading after its scope was disposed mounts without an attachment. Reusing
/// the component in another session requires assigning an entity from that
/// session first.
mixin NetworkedComponent on Component {
  /// The identity of this component in its session: an entity registered
  /// there directly, or one that a [MultiplayerSpawner] created this
  /// component for.
  NetworkEntity get networkEntity;

  MultiplayerScope? _networkScope;
  EntityAttachment? _networkAttachment;

  /// The current scope; throws [StateError] when there is no live attachment.
  MultiplayerScope get multiplayerScope {
    if (!_hasValidAttachment) {
      throw StateError('This component has no live multiplayer attachment.');
    }
    return _networkScope!;
  }

  /// The session associated with this component's live attachment.
  MultiplayerSession get multiplayerSession => multiplayerScope.session;

  bool get _hasValidAttachment {
    final scope = _networkScope;
    final attachment = _networkAttachment;
    return scope != null &&
        !scope.isDisposed &&
        attachment != null &&
        !attachment.isDisposed &&
        identical(attachment.entity, networkEntity) &&
        identical(MultiplayerScope.of(this), scope) &&
        identical(scope.session.registry[networkEntity.id], networkEntity) &&
        networkEntity.state != EntityState.removed &&
        !_hasRemovingAncestor;
  }

  bool get _hasRemovingAncestor {
    for (
      Component? component = this;
      component != null;
      component = component.parent
    ) {
      if (component.isRemoving || component.isRemoved) return true;
    }
    return false;
  }

  /// Whether this instance is mounted in its live scope and can handle RPCs.
  bool get isNetworkReady {
    if (!_hasValidAttachment) return false;
    for (
      Component? component = this;
      component != null;
      component = component.parent
    ) {
      if (!component.isMounted) return false;
      if (identical(component, _networkScope)) return true;
    }
    return false;
  }

  /// Binds this instance's typed handlers and synchronized properties, once per
  /// attachment lifetime.
  ///
  /// Use [EntityAttachment.bindRpc] and [EntityAttachment.synchronize]. The
  /// scope samples synchronized properties after gameplay and applies received
  /// values before gameplay while this component is ready. A remount calls this
  /// again after disposing the old bindings and synchronizer; callbacks must
  /// not retain attachments from earlier mounts.
  void onNetworkAttach(EntityAttachment attachment) {}

  /// Called after this scope's gameplay updates while the attachment is ready.
  ///
  /// Use this optional hook to prepare values before the scope automatically
  /// samples synchronized properties. Every ready component's hook runs before
  /// sampling begins. Do not call [MultiplayerSession.captureState] here.
  void captureNetworkState(double dt) {}

  /// Discards bindings and queued calls before a custom parent detaches this
  /// component. Remounting creates a new attachment.
  ///
  /// [removeFromParent] and removal directly through [MultiplayerScope] do this
  /// automatically. Call explicitly when an ordinary parent removes and reuses
  /// a loading component between updates: Flame emits no removal callback then.
  /// Descendant attachments belonging to this scope are discarded too.
  void detachNetwork() {
    _networkScope?.detachSubtree(this);
    _detachNetwork();
  }

  @override
  void removeFromParent() {
    detachNetwork();
    super.removeFromParent();
  }

  @override
  set parent(Component? value) {
    if (!identical(parent, value)) detachNetwork();
    super.parent = value;
  }

  @override
  @mustCallSuper
  FutureOr<void> onLoad() {
    _attachNetwork();
    return super.onLoad();
  }

  @override
  @mustCallSuper
  void onMount() {
    // A scope disposed while this component loaded ends its game lifecycle,
    // so the component mounts detached instead.
    if (MultiplayerScope.of(this)?.isDisposed != true) _attachNetwork();
    super.onMount();
  }

  @override
  @mustCallSuper
  void onRemove() {
    _detachNetwork();
    super.onRemove();
  }

  void _attachNetwork() {
    if (_hasValidAttachment) return;
    _detachNetwork();
    final scope = MultiplayerScope.of(this);
    if (scope == null || scope.isDisposed) {
      throw StateError('A NetworkedComponent needs a live MultiplayerScope.');
    }
    _networkScope = scope;
    final attachment = scope.session.attachEntity(
      networkEntity,
      isReady: () => isNetworkReady,
      isValid: () => _hasValidAttachment,
    );
    _networkAttachment = attachment;
    scope._components.add(this);
    try {
      onNetworkAttach(attachment);
    } on Object {
      _detachNetwork();
      rethrow;
    }
  }

  void _detachNetwork() {
    _networkAttachment?.dispose();
    _networkAttachment = null;
    _networkScope?._components.remove(this);
    _networkScope = null;
  }
}
