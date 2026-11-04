import 'dart:async';
import 'dart:collection';

import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import 'package:maratus/maratus.dart';

part 'multiplayer_spawner.dart';
part 'networked_component.dart';

/// Drives one session for a subtree of Flame components.
///
/// Each update applies eligible incoming spawn records and RPCs, updates
/// gameplay, calls [NetworkedComponent.captureNetworkState], then samples
/// synchronized properties through [MultiplayerSession.captureState]. Socket
/// callbacks only enqueue transport events. Do not also update or capture
/// [session] elsewhere.
///
/// Networked children register their attachment at the start of `onLoad`;
/// readiness is checked at update boundaries, without awaiting child mounting.
/// A [MultiplayerSpawner] in the subtree creates components for replicated
/// entities. Nested scopes use independent sessions and their own capture
/// boundaries.
/// Removing a scope disposes it. Create a new scope for a new game lifecycle.
/// Removing its game (including GameWidget disposal) also disposes the scope
/// when the game's removal future completes, without waiting for another tick.
class MultiplayerScope extends Component {
  /// Binds [session] to this subtree, optionally taking ownership of its close.
  ///
  /// Throws [StateError] if another live scope already drives the session.
  MultiplayerScope({
    required this.session,
    this.ownsSession = true,
    super.children,
    super.priority,
  }) {
    if (_drivers[session] != null) {
      throw StateError('This session already belongs to a MultiplayerScope.');
    }
    _drivers[session] = this;
  }

  static final _drivers = Expando<MultiplayerScope>();
  final _components = <NetworkedComponent>{};
  final _spawners = <MultiplayerSpawner>{};
  Component? _watchedGame;
  var _disposed = false;

  /// The session driven before this subtree's gameplay updates.
  final MultiplayerSession session;

  /// Whether disposing or removing this scope also closes [session].
  final bool ownsSession;

  /// Whether this scope has permanently released its session and attachments.
  bool get isDisposed => _disposed;

  /// The nearest scope above [component], or `null` outside a scoped subtree.
  static MultiplayerScope? of(Component component) {
    for (
      var ancestor = component.parent;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      if (ancestor is MultiplayerScope) return ancestor;
    }
    return null;
  }

  /// Discards this scope's attachments in [subtree] without changing the tree.
  ///
  /// Use before a custom parent removes and reuses a loading subtree between
  /// updates. Flame does not report removal of never-mounted children. Normal
  /// removal through this scope or [NetworkedComponent.removeFromParent]
  /// invalidates attachments automatically. Remounting binds fresh handlers.
  /// Spawners in [subtree] stop creating components until they mount again.
  /// Nested scopes manage their own attachments and disposal independently.
  void detachSubtree(Component subtree) {
    for (final component in _components.toList()) {
      if (_isWithin(component, subtree)) component._detachNetwork();
    }
    for (final spawner in _spawners.toList()) {
      if (_isWithin(spawner, subtree)) spawner._detachSpawner();
    }
  }

  static bool _isWithin(Component component, Component subtree) {
    for (
      Component? ancestor = component;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      if (identical(ancestor, subtree)) return true;
    }
    return false;
  }

  /// The component attached to [entity] in this scope, if any.
  NetworkedComponent? _attachedComponent(NetworkEntity entity) {
    for (final component in _components) {
      if (identical(component.networkEntity, entity) &&
          component._hasValidAttachment) {
        return component;
      }
    }
    return null;
  }

  @override
  void remove(Component component) {
    detachSubtree(component);
    super.remove(component);
  }

  @override
  void removeAll(Iterable<Component> components) {
    components.toList().forEach(remove);
  }

  @override
  void removeWhere(bool Function(Component component) test) {
    removeAll(children.where(test));
  }

  void _watchGameRemoval() {
    final game = findGame();
    if (game == null || identical(_watchedGame, game)) return;
    _watchedGame = game;
    // GameWidget finalizes removal of the game itself without propagating
    // onRemove to its children. Observe that lifecycle boundary as well.
    unawaited(
      game.removed.then((_) {
        if (!identical(_watchedGame, game)) return;
        final currentGame = findGame();
        if (currentGame == null || identical(currentGame, game)) dispose();
      }),
    );
  }

  @override
  FutureOr<void> onLoad() {
    _watchGameRemoval();
    return super.onLoad();
  }

  @override
  void onMount() {
    if (_disposed) {
      throw StateError('A disposed scope cannot be mounted again.');
    }
    _watchGameRemoval();
    super.onMount();
  }

  @override
  void updateTree(double dt) {
    if (_disposed || isRemoving) return;
    // Removal during loading has no onRemove callback. Prune it here too.
    for (final component in _components.toList()) {
      if (!component._hasValidAttachment) component._detachNetwork();
    }
    for (final spawner in _spawners.toList()) {
      if (!spawner._hasLiveScope) spawner._detachSpawner();
    }
    session.update();
    if (_disposed || isRemoving) return;
    super.updateTree(dt);
    if (_disposed || isRemoving) return;
    for (final component in _components.toList()) {
      if (component.isNetworkReady) component.captureNetworkState(dt);
    }
    if (_disposed || isRemoving) return;
    session.captureState();
  }

  /// Releases attachments and spawners and, when [ownsSession], closes the
  /// transport.
  ///
  /// Call this explicitly if abandoning a scope before it mounts: Flame does
  /// not call `onRemove` for components that never mounted. Repeated calls are
  /// harmless. Component removal alone does not despawn network entities.
  /// Spawned components stay in the tree until it is removed.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _watchedGame = null;
    for (final component in _components.toList()) {
      component._detachNetwork();
    }
    for (final spawner in _spawners.toList()) {
      spawner._detachSpawner();
    }
    if (identical(_drivers[session], this)) _drivers[session] = null;
    if (ownsSession) session.close();
  }

  @override
  void onRemove() {
    dispose();
    super.onRemove();
  }
}
