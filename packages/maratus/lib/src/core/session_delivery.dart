part of 'multiplayer_session.dart';

typedef _Delivery = ({DeliveryMode mode, int channel});

const _defaultDelivery = (mode: DeliveryMode.reliable, channel: 0);

/// Keeps independent gameplay lanes from advancing lifecycle revisions.
final class _SessionDelivery {
  _SessionDelivery(this.session);

  final MultiplayerSession session;
  var _sequence = 0;

  void clear() => _sequence = 0;

  void checkCapabilities(TransportCapabilities capabilities) {
    void check(DeliveryMode mode, int channel, String name) {
      if (!capabilities.supports(mode, channel: channel)) {
        throw UnsupportedError(
          '$name requires ${mode.name} delivery on channel $channel.',
        );
      }
    }

    check(DeliveryMode.reliable, 0, 'Session control');
    for (final rpc in session._schema.rpcDefinitions) {
      check(rpc.deliveryMode, rpc.channel, rpc.id.value);
    }
    for (final field in session._schema.fieldDefinitions) {
      check(field.deliveryMode, field.channel, field.id.value);
    }
  }

  _Delivery _field(FieldId id) {
    final field = session._schema.fieldDefinition(id)!;
    return (mode: field.deliveryMode, channel: field.channel);
  }

  _Delivery _rpc(RpcId id) {
    final rpc = session._schema.rpcDefinition(id);
    return rpc == null
        ? _defaultDelivery
        : (mode: rpc.deliveryMode, channel: rpc.channel);
  }

  _Delivery outgoing(ProtocolMessage message) => switch (message) {
    RpcMessage(:final rpc) || RpcDeliveryMessage(:final rpc) => _rpc(rpc),
    StateMessage(sequence: _?, :final values) => _field(values.keys.first),
    _ => _defaultDelivery,
  };

  /// The delivery configured for [message]'s fields. Live state groups
  /// fields of one lane; reliable catch-up may combine several.
  _Delivery lane(StateMessage message) => _field(message.values.keys.first);

  /// Whether [message]'s fields use a lane other than the control channel.
  /// Their live updates carry a per-field sequence instead of a revision.
  bool independent(StateMessage message) => lane(message) != _defaultDelivery;

  /// Whether [message] reaches [remote] on its fields' own lane. A host
  /// catches up a client that is not ready yet on the control channel
  /// instead, in revision order.
  bool sequenced(_Remote remote, StateMessage message) =>
      independent(message) &&
      (!session._isHost || remote.state == _RemoteState.ready);

  /// Sends a live state [message] to [remote]. A message that is not
  /// [sequenced] takes [revision], or a new revision on a host if it is
  /// `null`.
  bool transmitState(_Remote remote, StateMessage message, {int? revision}) {
    // Bootstrap catches up reliably, including fields normally sent without
    // acknowledgements. Resyncs and baselines use _transmit directly.
    if (sequenced(remote, message)) {
      if (_sequence == IntCodec.maxSafe) {
        throw StateError('No state sequences are left in this session.');
      }
      return session._transmit(
        remote,
        StateMessage(
          entity: message.entity,
          values: message.values,
          sampledAt: message.sampledAt,
          sequence: ++_sequence,
        ),
        revision: session._isHost ? remote.sentRevision : session._revision,
      );
    }
    return session._transmit(
      remote,
      message,
      revision: revision ?? (session._isHost ? session._nextRevision() : 0),
    );
  }

  bool _valid(ProtocolMessage message, _Delivery delivery) {
    if (message case StateMessage(:final sequence, :final values)) {
      if (sequence == null) {
        return delivery == _defaultDelivery &&
            (!session._isHost ||
                values.keys.every((id) => _field(id) == _defaultDelivery));
      }
      return message.sampledAt != null &&
          values.isNotEmpty &&
          delivery != _defaultDelivery &&
          values.keys.every((id) => _field(id) == delivery);
    }
    return delivery == outgoing(message);
  }

  void receive(
    _Remote remote,
    MessageEnvelope envelope,
    DeliveryMode mode,
    int channel,
    int size,
  ) {
    final delivery = (mode: mode, channel: channel);
    if (!_valid(envelope.message, delivery)) {
      session._drop(remote, DisconnectReason.protocolViolation, notify: true);
      return;
    }
    if (delivery == _defaultDelivery) {
      session._dispatch(remote, envelope);
      return;
    }
    // An accepted peer can race Ready on the control channel; a peer still
    // handshaking or awaiting admission cannot send gameplay at all.
    if (remote.peer == null ||
        (session._isHost && envelope.revision > session._revision)) {
      session._drop(remote, DisconnectReason.protocolViolation, notify: true);
      return;
    }
    if (_staleAuthority(envelope)) return;
    final waiting =
        _waitsForControl(remote, envelope) ||
        (mode == DeliveryMode.reliable &&
            remote.pendingChannels.containsKey(channel));
    if (waiting) {
      if (mode != DeliveryMode.reliable) return;
      if (!session.pendingDeliveryLimits.accepts((
        messages: remote.pendingDelivery.length,
        bytes: remote.pendingDeliveryBytes,
      ), size)) {
        session._drop(remote, DisconnectReason.transportError);
        return;
      }
      remote.pendingDelivery.add(
        _PendingDelivery(envelope, channel, size, session._clock.now),
      );
      remote.pendingDeliveryBytes += size;
      remote.pendingChannels.update(
        channel,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      return;
    }
    _dispatch(remote, envelope);
  }

  bool _staleAuthority(MessageEnvelope envelope) {
    if (envelope.message case StateMessage(:final entity)) {
      final live = session.registry[entity];
      if (live != null &&
          envelope.revision < session._authorities.lastTransfer(live)) {
        return true;
      }
    }
    return false;
  }

  bool _waitsForControl(_Remote remote, MessageEnvelope envelope) {
    if (!session._isHost) return envelope.revision > session._revision;
    if (remote.state != _RemoteState.ready) return true;
    if (envelope.message case StateMessage(:final entity)) {
      final live = session.registry[entity];
      if (live != null && session._authorities.awaits(live, remote.peer!)) {
        return true;
      }
    }
    return false;
  }

  void _dispatch(_Remote remote, MessageEnvelope envelope) {
    // Sequenced state never raises the replication revision. It may share
    // a lifecycle revision with many subsequent samples and other fields.
    if (!session._isHost && envelope.message is StateMessage) {
      if (remote.state != _RemoteState.installing &&
          remote.state != _RemoteState.ready) {
        session._drop(remote, DisconnectReason.protocolViolation, notify: true);
        return;
      }
      session._states.receive(PeerId.host, envelope);
    } else {
      session._dispatch(remote, envelope);
    }
  }

  /// Dispatches the waiting messages whose dependencies arrived, in arrival
  /// order, and discards the stale ones. A waiting message blocks the later
  /// ones on its channel.
  void drain() {
    for (final remote in session._remotes.values.toList()) {
      final pendingDelivery = remote.pendingDelivery;
      final blockedChannels = <int>{};
      // Each message is taken from the front once. A message that keeps
      // waiting goes to the back, so the waiting ones keep their order.
      for (var left = pendingDelivery.length; left > 0; left--) {
        if (session._remotes[remote.connection] != remote) break;
        final pending = pendingDelivery.removeFirst();
        final stale = _staleAuthority(pending.envelope);
        if (!stale &&
            (blockedChannels.contains(pending.channel) ||
                _waitsForControl(remote, pending.envelope))) {
          if (session._clock.now - pending.receivedAt >=
              session.timeouts.bootstrap) {
            session._drop(remote, DisconnectReason.timeout, notify: true);
            break;
          }
          blockedChannels.add(pending.channel);
          pendingDelivery.add(pending);
          continue;
        }
        remote.pendingDeliveryBytes -= pending.size;
        if (remote.pendingChannels.update(
              pending.channel,
              (count) => count - 1,
            ) ==
            0) {
          remote.pendingChannels.remove(pending.channel);
        }
        if (!stale) _dispatch(remote, pending.envelope);
      }
    }
  }
}

final class _PendingDelivery {
  const _PendingDelivery(
    this.envelope,
    this.channel,
    this.size,
    this.receivedAt,
  );

  final MessageEnvelope envelope;
  final int channel;
  final int size;
  final Duration receivedAt;
}
