part of 'multiplayer_session.dart';

/// Handles a validated RPC. An asynchronous result is not a network response.
typedef RpcHandler<T> = FutureOr<void> Function(RpcContext context, T payload);

/// Immutable identity and entity metadata captured for one RPC invocation.
final class RpcContext {
  const RpcContext._({
    required this.entity,
    required this.rpc,
    required this.sender,
    required this.target,
    required this.owner,
    required this.authority,
    required this.epoch,
  });

  /// The entity addressed by this invocation.
  final EntityId entity;

  /// The stable method identifier.
  final RpcId rpc;

  /// The original caller, authenticated by the host's connection mapping.
  final PeerId sender;

  /// The peer executing this handler.
  final PeerId target;

  /// The entity's input owner when the call was accepted locally.
  final PeerId owner;

  /// The entity's fixed authority.
  final PeerId authority;

  /// The host session in which the call was accepted.
  final int epoch;
}

/// A disposable handler binding for one entity and RPC.
final class RpcBinding {
  RpcBinding._(this._entity, this._handler, this._remove);

  final NetworkEntity _entity;
  final RpcHandler<Object?> _handler;
  final void Function() _remove;
  var _disposed = false;

  /// Whether the binding was disposed or its entity removed.
  bool get isDisposed => _disposed || _entity.state == EntityState.removed;

  /// Removes this handler. Repeated disposal has no effect.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _remove();
  }
}

final class _RpcDispatcher {
  _RpcDispatcher(this.session);

  final MultiplayerSession session;
  final _bindings = <(EntityId, RpcId), RpcBinding>{};
  var _lifetime = 0;
  var _invocationDepth = 0;

  bool get isInvoking => _invocationDepth != 0;

  void prune() {
    session._attachments.prune();
    for (final binding in _bindings.values.toList()) {
      if (binding.isDisposed ||
          !identical(session.registry[binding._entity.id], binding._entity)) {
        binding.dispose();
      }
    }
  }

  void clear() {
    _lifetime++;
    session._attachments.clear();
    for (final binding in _bindings.values.toList()) {
      binding.dispose();
    }
  }

  void _checkHandle<T>(Rpc<T> rpc) {
    if (!identical(session._schema.rpcDefinition(rpc.id), rpc)) {
      throw ArgumentError.value(
        rpc,
        'rpc',
        'must belong to the session schema',
      );
    }
  }

  RpcBinding bind<T>(
    NetworkEntity entity,
    Rpc<T> rpc,
    RpcHandler<T> handler, {
    EntityAttachment? attachment,
  }) {
    prune();
    _checkHandle(rpc);
    if (!identical(session.registry[entity.id], entity) ||
        entity.state == EntityState.removed) {
      throw ArgumentError.value(
        entity,
        'entity',
        'must belong to this registry',
      );
    }
    if (!identical(session._attachments.forEntity(entity), attachment)) {
      throw StateError('Bind handlers through this entity\'s live attachment.');
    }
    final key = (entity.id, rpc.id);
    if (_bindings[key] case final existing? when !existing.isDisposed) {
      throw StateError(
        'This entity already has a handler for ${rpc.id.value}.',
      );
    }
    late final RpcBinding binding;
    binding = RpcBinding._(
      entity,
      (context, payload) => handler(context, payload as T),
      () {
        if (identical(_bindings[key], binding)) _bindings.remove(key);
        session._attachments.discardBinding(binding);
      },
    );
    return _bindings[key] = binding;
  }

  bool call<T>(NetworkEntity entity, Rpc<T> rpc, T payload, {PeerId? peer}) {
    prune();
    if (session.state != SessionState.hosting &&
        session.state != SessionState.ready) {
      throw StateError('Only a hosting or ready session can invoke RPCs.');
    }
    _checkHandle(rpc);
    final sender = session.localPeer!;
    if (!identical(session.registry[entity.id], entity)) {
      return _reject(entity.id, rpc.id, sender, RpcRejection.unknownEntity);
    }
    if (entity.state != EntityState.ready &&
        session._attachments.forEntity(entity) == null) {
      return _reject(entity.id, rpc.id, sender, RpcRejection.entityNotReady);
    }
    final request = RpcMessage(
      entity: entity.id,
      rpc: rpc.id,
      payload: payload,
      target: peer,
    );
    // Local calls cross the same wire validation/copy boundary as remote calls.
    final RpcMessage normalized;
    try {
      normalized =
          session._codec
                  .decode(session._codec.encode(MessageEnvelope(request)))
                  .message
              as RpcMessage;
    } on ProtocolException catch (error) {
      throw ArgumentError('RPC payload cannot be decoded: $error');
    }
    if (session.isHost) return route(sender, normalized);
    return session._send(session._peers[PeerId.host]!, normalized);
  }

  bool route(PeerId sender, RpcMessage request) {
    final entity = _entity(request.entity, request.rpc, sender);
    if (entity == null) return false;
    final rpc = session._schema.rpcDefinition(request.rpc);
    if (rpc == null) {
      return _reject(
        entity.id,
        request.rpc,
        sender,
        RpcRejection.unknownMethod,
      );
    }
    if (!_permitted(rpc, entity, sender)) {
      return _reject(entity.id, rpc.id, sender, RpcRejection.notAllowed);
    }
    if ((rpc.target == RpcTarget.peer) != (request.target != null)) {
      return _reject(entity.id, rpc.id, sender, RpcRejection.invalidTarget);
    }
    final targets = switch (rpc.target) {
      RpcTarget.host => [PeerId.host],
      RpcTarget.owner => [entity.owner],
      RpcTarget.authority => [entity.authority],
      RpcTarget.peer => [request.target!],
      RpcTarget.all => [PeerId.host, ...session.peers.where(session.isReady)],
    };
    for (final target in targets) {
      if (target != PeerId.host && !session.isReady(target)) {
        return _reject(
          entity.id,
          rpc.id,
          sender,
          RpcRejection.invalidTarget,
          target: target,
        );
      }
    }
    targets.removeWhere(
      (peer) => peer == sender && rpc.local == RpcLocal.exclude,
    );
    if (targets.isEmpty) return false;

    // Send remote copies before invoking local code, which may mutate payloads,
    // remove the entity, or close the session.
    var accepted = true;
    for (final target in targets.where((peer) => peer != PeerId.host)) {
      final delivery = RpcDeliveryMessage(
        entity: entity.id,
        rpc: rpc.id,
        payload: request.payload,
        sender: sender,
        target: target,
      );
      try {
        if (!session._send(session._peers[target]!, delivery)) accepted = false;
      } on ArgumentError {
        accepted = _reject(
          entity.id,
          rpc.id,
          sender,
          RpcRejection.invalidPayload,
          target: target,
        );
      }
    }
    if (targets.contains(PeerId.host)) {
      final invoked = _invoke(
        entity,
        rpc,
        sender,
        PeerId.host,
        request.payload,
      );
      accepted = accepted && invoked;
    }
    return accepted;
  }

  void deliver(RpcDeliveryMessage delivery) {
    final local = session.localPeer!;
    if (delivery.target != local) {
      _reject(
        delivery.entity,
        delivery.rpc,
        delivery.sender,
        RpcRejection.invalidTarget,
        target: delivery.target,
      );
      return;
    }
    final entity = _entity(delivery.entity, delivery.rpc, delivery.sender);
    if (entity == null) return;
    final rpc = session._schema.rpcDefinition(delivery.rpc)!;
    if (!_permitted(rpc, entity, delivery.sender)) {
      _reject(entity.id, rpc.id, delivery.sender, RpcRejection.notAllowed);
      return;
    }
    final selected = switch (rpc.target) {
      RpcTarget.host => local == PeerId.host,
      RpcTarget.owner => local == entity.owner,
      RpcTarget.authority => local == entity.authority,
      RpcTarget.all || RpcTarget.peer => true,
    };
    if (!selected ||
        (rpc.local == RpcLocal.exclude && delivery.sender == local)) {
      _reject(entity.id, rpc.id, delivery.sender, RpcRejection.invalidTarget);
      return;
    }
    _invoke(entity, rpc, delivery.sender, local, delivery.payload);
  }

  NetworkEntity? _entity(EntityId id, RpcId rpc, PeerId sender) {
    final entity = session.registry[id];
    if (entity == null) {
      _reject(id, rpc, sender, RpcRejection.unknownEntity);
      return null;
    }
    if (entity.state != EntityState.ready &&
        session._attachments.forEntity(entity) == null) {
      _reject(id, rpc, sender, RpcRejection.entityNotReady);
      return null;
    }
    return entity;
  }

  static bool _permitted(
    Rpc<Object?> rpc,
    NetworkEntity entity,
    PeerId sender,
  ) => switch (rpc.caller) {
    RpcCaller.anyPeer => true,
    RpcCaller.owner => sender == entity.owner,
    RpcCaller.authority => sender == entity.authority,
    RpcCaller.host => sender == PeerId.host,
  };

  bool _invoke(
    NetworkEntity entity,
    Rpc<Object?> rpc,
    PeerId sender,
    PeerId target,
    Object? payload,
  ) {
    final attachment = session._attachments.forEntity(entity);
    final binding = _bindings[(entity.id, rpc.id)];
    if (binding == null ||
        binding.isDisposed ||
        !identical(binding._entity, entity)) {
      return _reject(
        entity.id,
        rpc.id,
        sender,
        RpcRejection.missingHandler,
        target: target,
      );
    }
    final context = RpcContext._(
      entity: entity.id,
      rpc: rpc.id,
      sender: sender,
      target: target,
      owner: entity.owner,
      authority: entity.authority,
      epoch: session.epoch!,
    );
    if (attachment != null) {
      return session._attachments.enqueue(
        attachment,
        binding,
        context,
        payload,
      );
    }
    invokeBound(binding, context, payload);
    return true;
  }

  void invokeBound(RpcBinding binding, RpcContext context, Object? payload) {
    final lifetime = _lifetime;
    void report(Object error, StackTrace stackTrace) {
      if (_lifetime != lifetime) return;
      session._emit(
        RpcHandlerFailed(
          entity: context.entity,
          rpc: context.rpc,
          sender: context.sender,
          target: context.target,
          error: error,
          stackTrace: stackTrace,
        ),
      );
    }

    _invocationDepth++;
    try {
      final result = binding._handler(context, payload);
      if (result is Future<void>) {
        unawaited(result.then<void>((_) {}, onError: report));
      }
    } on Object catch (error, stackTrace) {
      report(error, stackTrace);
    } finally {
      _invocationDepth--;
    }
  }

  bool _reject(
    EntityId entity,
    RpcId rpc,
    PeerId sender,
    RpcRejection reason, {
    PeerId? target,
  }) {
    session._emit(
      RpcRejected(
        entity: entity,
        rpc: rpc,
        sender: sender,
        reason: reason,
        target: target,
      ),
    );
    return false;
  }
}
