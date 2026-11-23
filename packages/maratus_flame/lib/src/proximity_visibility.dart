part of 'multiplayer_scope.dart';

/// Shows each client of a host the positioned entities near the ones it owns.
///
/// Add it inside a [MultiplayerScope]:
///
/// ```dart
/// MultiplayerScope(
///   session: session,
///   children: [
///     spawner,
///     ProximityVisibility(showRange: 80, hideRange: 95, interval: 0.2),
///   ],
/// );
/// ```
///
/// While mounted, it adds a visibility filter to the scope's session, which
/// decides for the entities whose components in the scope are
/// [PositionComponent]s. A client sees such an entity once it comes within
/// [showRange] of one of the client's viewers, and stops seeing it only beyond
/// [hideRange], so entities at the edge do not keep leaving and returning. By
/// default, a client's viewers are the [PositionComponent]s of the entities
/// that it owns, such as its player; [viewersOf] chooses others. A client
/// without viewers sees no positioned entity, apart from those that it always
/// sees, such as the entities that it owns; see
/// [MultiplayerSession.isVisibleTo].
///
/// Distances are measured between the components' positions, in the
/// coordinates of the scope, so components nested under other spawned
/// components compare correctly. Entities whose components are not
/// [PositionComponent]s are left to the session's other rules, as are
/// entities that this scope does not represent with a component. A new
/// entity whose component has not attached yet, as when the host's spawner
/// is about to create it, is hidden until that component attaches.
///
/// As entities move, it runs [MultiplayerSession.updateVisibility] every
/// [interval] seconds while the session is hosting, and at its next update
/// after it mounts or a new entity's component attaches. Removing it removes
/// its filter, and the host shows the entities that the filter hid, as the
/// remaining rules decide.
///
/// Other visibility filters keep working next to it: a client sees an entity
/// only if every filter accepts it. On a client, it does nothing.
class ProximityVisibility extends Component {
  /// Creates a filter that shows entities within [showRange] of a client's
  /// viewers and hides them beyond [hideRange], which defaults to
  /// [showRange], updating every [interval] seconds.
  ///
  /// Throws an [ArgumentError] unless [showRange] is finite and not negative,
  /// [hideRange] is finite and not less than [showRange], and [interval] is
  /// positive and finite.
  ProximityVisibility({
    required this.showRange,
    double? hideRange,
    this.interval = 0.2,
    this.viewersOf,
    super.priority,
    super.key,
  }) : hideRange = hideRange ?? showRange {
    if (!showRange.isFinite || showRange < 0) {
      throw ArgumentError.value(
        showRange,
        'showRange',
        'must be finite and not negative',
      );
    }
    if (!this.hideRange.isFinite || this.hideRange < showRange) {
      throw ArgumentError.value(
        hideRange,
        'hideRange',
        'must be finite and not less than showRange',
      );
    }
    if (!interval.isFinite || interval <= 0) {
      throw ArgumentError.value(
        interval,
        'interval',
        'must be positive and finite',
      );
    }
  }

  /// How close an entity must come to one of a client's viewers to come into
  /// the client's view.
  final double showRange;

  /// How far an entity in a client's view must be from every one of the
  /// client's viewers to leave the view again.
  final double hideRange;

  /// How many seconds pass between the updates of what clients see.
  final double interval;

  /// Returns the components from which a client sees, given its ID, or with
  /// `null`, the default, a client sees from the [PositionComponent]s of the
  /// entities that it owns.
  ///
  /// It runs inside the visibility filter, so it must not change the
  /// session. Return components in this scope's subtree.
  final Iterable<PositionComponent> Function(PeerId peer)? viewersOf;

  MultiplayerScope? _proximityScope;
  var _indexedRevision = -1;
  var _indexedSessionRevision = -1;
  final _positioned = <NetworkEntity, PositionComponent>{};
  final _represented = <NetworkEntity>{};
  final _owned = <PeerId, List<PositionComponent>>{};
  final _unresolved = <NetworkEntity>{};
  var _sinceUpdate = 0.0;
  var _due = true;

  @override
  @mustCallSuper
  void onMount() {
    super.onMount();
    final scope = MultiplayerScope.of(this);
    if (scope == null || scope.isDisposed) {
      throw StateError('A ProximityVisibility needs a live MultiplayerScope.');
    }
    if (!identical(scope, _proximityScope)) {
      _detachProximity();
      _proximityScope = scope;
      scope.session.addVisibilityFilter(_accepts);
    }
    _due = true;
  }

  @override
  @mustCallSuper
  void onRemove() {
    final scope = _proximityScope;
    _detachProximity();
    if (scope != null &&
        !scope.isDisposed &&
        !_isRemoving(scope) &&
        scope.session.state == SessionState.hosting) {
      scope.session.updateVisibility();
    }
    super.onRemove();
  }

  @override
  void update(double dt) {
    super.update(dt);
    final scope = _proximityScope;
    if (scope == null || scope.isDisposed) return;
    final session = scope.session;
    if (session.state != SessionState.hosting) {
      _unresolved.clear();
      _due = true;
      return;
    }
    _sinceUpdate += dt;
    if (_unresolved.isNotEmpty) {
      _index(scope);
      _unresolved.removeWhere((entity) => entity.state == EntityState.removed);
      if (_unresolved.any(
        (entity) =>
            _represented.contains(entity) ||
            entity.state != EntityState.pending,
      )) {
        _due = true;
      }
    }
    if (!_due && _sinceUpdate < interval) return;
    _due = false;
    _sinceUpdate = 0;
    _unresolved.clear();
    session.updateVisibility();
  }

  void _detachProximity() {
    _proximityScope?.session.removeVisibilityFilter(_accepts);
    _proximityScope = null;
    _indexedRevision = -1;
    _indexedSessionRevision = -1;
    _positioned.clear();
    _represented.clear();
    _owned.clear();
    _unresolved.clear();
  }

  /// Whether [scope] or one of its ancestors is being removed, which ends
  /// the scope's game lifecycle.
  static bool _isRemoving(Component scope) {
    for (
      Component? component = scope;
      component != null;
      component = component.parent
    ) {
      if (component.isRemoving || component.isRemoved) return true;
    }
    return false;
  }

  /// The visibility filter: whether [peer] sees [entity].
  bool _accepts(NetworkEntity entity, PeerId peer) {
    final scope = _proximityScope;
    if (scope == null) return true;
    _index(scope);
    final target = _positioned[entity];
    if (target == null || !(target as NetworkedComponent)._hasValidAttachment) {
      if (_represented.contains(entity) ||
          entity.state != EntityState.pending) {
        return true;
      }
      _unresolved.add(entity);
      return false;
    }
    final viewers =
        viewersOf?.call(peer) ?? _owned[peer] ?? const <PositionComponent>[];
    // An entity in view leaves it only once it is beyond the larger range.
    final range = scope.session.isVisibleTo(entity, peer)
        ? hideRange
        : showRange;
    final limit = range * range;
    final position = _positionIn(scope, target);
    for (final viewer in viewers) {
      if (viewer case final NetworkedComponent networked
          when !networked._hasValidAttachment) {
        continue;
      }
      if (_positionIn(scope, viewer).distanceToSquared(position) <= limit) {
        return true;
      }
    }
    return false;
  }

  /// Indexes the components attached to [scope], unless none attached or
  /// detached, and the session replicated no change, such as a transfer of
  /// an entity's ownership, since the last time.
  void _index(MultiplayerScope scope) {
    final revision = scope.session.revision;
    if (_indexedRevision == scope._componentsRevision &&
        _indexedSessionRevision == revision) {
      return;
    }
    _indexedRevision = scope._componentsRevision;
    _indexedSessionRevision = revision;
    _positioned.clear();
    _represented.clear();
    _owned.clear();
    for (final component in scope._components) {
      if (!component._hasValidAttachment) continue;
      final entity = component.networkEntity;
      _represented.add(entity);
      if (component is! PositionComponent) continue;
      final positioned = component as PositionComponent;
      _positioned[entity] = positioned;
      (_owned[entity.owner] ??= []).add(positioned);
    }
  }

  /// The position of [component] in the coordinates of [scope].
  static Vector2 _positionIn(
    MultiplayerScope scope,
    PositionComponent component,
  ) {
    Vector2 point = component.position;
    for (
      var ancestor = component.parent;
      ancestor != null && !identical(ancestor, scope);
      ancestor = ancestor.parent
    ) {
      if (ancestor is PositionComponent) point = ancestor.positionOf(point);
    }
    return point;
  }
}
