part of 'multiplayer_session.dart';

/// Session-wide limits for local RPCs deferred by entity attachments.
final class PendingRpcLimits {
  /// Creates positive count, encoded-byte, and monotonic-age limits.
  const PendingRpcLimits({
    this.maxMessages = 256,
    this.maxBytes = 1024 * 1024,
    this.maxAge = const Duration(seconds: 10),
  });

  /// Maximum number of queued local invocations across all attachments.
  final int maxMessages;

  /// Maximum sum of their encoded, normalized delivery-envelope sizes.
  final int maxBytes;

  /// Maximum time from accepting a local call until dispatch.
  final Duration maxAge;
}

/// Owns an entity's local lifecycle and RPC bindings for one session lifetime.
///
/// Calls accepted while this attachment is live are delivered only from
/// [MultiplayerSession.update], when its readiness predicate is true. Disposing
/// it discards its pending calls and bindings without removing the registry
/// entity. A replacement attachment never receives the former one's calls.
final class EntityAttachment {
  EntityAttachment._(this._manager, this.entity, this._isReady, this._isValid);

  final _EntityAttachments _manager;
  final bool Function() _isReady;
  final bool Function() _isValid;
  final _bindings = <RpcBinding>{};
  MultiplayerSynchronizer? _synchronizer;
  var _disposed = false;

  /// The exact registry entity whose lifecycle this handle owns.
  final NetworkEntity entity;

  /// Whether explicitly disposed, removed, or no longer in this registry.
  bool get isDisposed =>
      _disposed ||
      entity.state == EntityState.removed ||
      !identical(_manager.session.registry[entity.id], entity);

  /// Binds a handler owned by this attachment, even while it is not ready.
  ///
  /// Disposing the returned binding also discards its pending invocations.
  /// Throws [StateError] if the attachment has been disposed or invalidated.
  RpcBinding bindRpc<T>(Rpc<T> rpc, RpcHandler<T> handler) {
    if (!_manager._isLive(this)) {
      throw StateError('This entity attachment is no longer live.');
    }
    final binding = _manager.session._rpcDispatcher.bind(
      entity,
      rpc,
      handler,
      attachment: this,
    );
    _bindings.add(binding);
    return binding;
  }

  /// Synchronizes [properties] of this attachment's entity between its
  /// authority and every other peer, sampling at most once per [interval].
  ///
  /// The entity's authority sends the properties when
  /// [MultiplayerSession.captureState] runs; every other peer applies the
  /// latest authoritative values during [MultiplayerSession.update] while
  /// this attachment is ready. Values received before then, including those
  /// in a joining client's baseline, are applied once it is ready. Disposing
  /// this attachment disposes the synchronizer; the values stay with the
  /// entity, so a replacement attachment receives them again.
  ///
  /// Throws an [ArgumentError] if [properties] is empty, binds a field twice,
  /// or uses a field handle of another schema, or if [interval] is not
  /// positive. Throws a [StateError] if this attachment is no longer live or
  /// its entity already has a live synchronizer.
  MultiplayerSynchronizer synchronize(
    List<SyncProperty<Object?>> properties, {
    Duration interval = const Duration(milliseconds: 50),
  }) => _manager.session._states.synchronize(this, properties, interval);

  /// Discards this attachment's pending calls and disposes all its handlers
  /// and its synchronizer.
  ///
  /// This does not remove the entity from the session registry. Repeated
  /// disposal has no effect.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _manager._remove(this);
    for (final binding in _bindings.toList()) {
      binding.dispose();
    }
    _bindings.clear();
    _synchronizer?.dispose();
  }
}

final class _EntityAttachments {
  _EntityAttachments(this.session);

  final MultiplayerSession session;
  final _attached = <EntityId, EntityAttachment>{};
  final _pending = <_PendingRpc>{};
  var _pendingBytes = 0;

  int get pendingCount => _pending.length;
  int get pendingBytes => _pendingBytes;

  EntityAttachment attach(
    NetworkEntity entity, {
    required bool Function() isReady,
    required bool Function() isValid,
  }) {
    session._rpcDispatcher.prune();
    if (!identical(session.registry[entity.id], entity) ||
        entity.state == EntityState.removed) {
      throw ArgumentError.value(
        entity,
        'entity',
        'must belong to this registry',
      );
    }
    if (_attached.containsKey(entity.id)) {
      throw StateError('This entity already has a live attachment.');
    }
    if (session._rpcDispatcher._bindings.values.any(
      (binding) => identical(binding._entity, entity),
    )) {
      throw StateError(
        'Dispose unmanaged bindings before attaching this entity.',
      );
    }
    return _attached[entity.id] = EntityAttachment._(
      this,
      entity,
      isReady,
      isValid,
    );
  }

  EntityAttachment? forEntity(NetworkEntity entity) {
    final attachment = _attached[entity.id];
    return attachment != null &&
            identical(attachment.entity, entity) &&
            _isLive(attachment)
        ? attachment
        : null;
  }

  bool _isLive(EntityAttachment attachment) {
    if (attachment.isDisposed ||
        !identical(_attached[attachment.entity.id], attachment) ||
        !attachment._isValid()) {
      attachment.dispose();
      return false;
    }
    return true;
  }

  void prune() {
    for (final attachment in _attached.values.toList()) {
      _isLive(attachment);
    }
  }

  void _remove(EntityAttachment attachment) {
    if (identical(_attached[attachment.entity.id], attachment)) {
      _attached.remove(attachment.entity.id);
    }
    for (final call in _pending.toList()) {
      if (identical(call.attachment, attachment)) _take(call);
    }
  }

  void discardBinding(RpcBinding binding) {
    _attached[binding._entity.id]?._bindings.remove(binding);
    for (final call in _pending.toList()) {
      if (identical(call.binding, binding)) _take(call);
    }
  }

  void clear() {
    for (final attachment in _attached.values.toList()) {
      attachment.dispose();
    }
    _pending.clear();
    _pendingBytes = 0;
  }

  void reconcile() {
    prune();
    for (final attachment in _attached.values.toList()) {
      if (_isLive(attachment) && attachment._isReady()) _markReady(attachment);
    }
    for (final call in _pending.toList()) {
      _expire(call);
    }
  }

  void _markReady(EntityAttachment attachment) {
    if (attachment.entity.state == EntityState.pending) {
      session.registry.markReady(attachment.entity.id);
    }
  }

  bool enqueue(
    EntityAttachment attachment,
    RpcBinding binding,
    RpcContext context,
    Object? payload,
  ) {
    final envelope = MessageEnvelope(
      RpcDeliveryMessage(
        entity: context.entity,
        rpc: context.rpc,
        payload: payload,
        sender: context.sender,
        target: context.target,
      ),
      generation: session.generation ?? 0,
    );
    final Uint8List bytes;
    final RpcDeliveryMessage normalized;
    try {
      bytes = session._codec.encode(envelope);
      normalized = session._codec.decode(bytes).message as RpcDeliveryMessage;
    } on ArgumentError {
      return _reject(context, RpcRejection.invalidPayload);
    } on ProtocolException {
      return _reject(context, RpcRejection.invalidPayload);
    }
    final limits = session.pendingRpcLimits;
    if (_pending.length >= limits.maxMessages ||
        _pendingBytes + bytes.length > limits.maxBytes) {
      return _reject(context, RpcRejection.pendingQueueFull);
    }
    _pending.add(
      _PendingRpc(
        attachment,
        binding,
        context,
        normalized.payload,
        bytes.length,
        session._clock.now,
      ),
    );
    _pendingBytes += bytes.length;
    return true;
  }

  void flush() {
    // Handler-enqueued calls belong to a later update, preventing recursive
    // local calls from making one frame drain an unbounded amount of work.
    for (final call in _pending.toList()) {
      if (!_pending.contains(call)) continue;
      final attachment = call.attachment;
      if (!_isLive(attachment) ||
          call.binding.isDisposed ||
          !identical(
            session._rpcDispatcher._bindings[(
              call.context.entity,
              call.context.rpc,
            )],
            call.binding,
          )) {
        _take(call);
        continue;
      }
      if (_expire(call) || !attachment._isReady()) continue;
      // Readiness may depend on a component tree that changed in an earlier
      // invocation. Check it for each call, not just once at the frame start.
      if (!_isLive(attachment)) continue;
      _markReady(attachment);
      _take(call);
      session._rpcDispatcher.invokeBound(
        call.binding,
        call.context,
        call.payload,
      );
    }
  }

  bool _expire(_PendingRpc call) {
    if (session._clock.now - call.acceptedAt <
        session.pendingRpcLimits.maxAge) {
      return false;
    }
    if (_take(call)) _reject(call.context, RpcRejection.readinessTimeout);
    return true;
  }

  bool _take(_PendingRpc call) {
    if (!_pending.remove(call)) return false;
    _pendingBytes -= call.bytes;
    return true;
  }

  bool _reject(RpcContext context, RpcRejection reason) =>
      session._rpcDispatcher._reject(
        context.entity,
        context.rpc,
        context.sender,
        reason,
        target: context.target,
      );
}

final class _PendingRpc {
  const _PendingRpc(
    this.attachment,
    this.binding,
    this.context,
    this.payload,
    this.bytes,
    this.acceptedAt,
  );

  final EntityAttachment attachment;
  final RpcBinding binding;
  final RpcContext context;
  final Object? payload;
  final int bytes;
  final Duration acceptedAt;
}
