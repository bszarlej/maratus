part of '../core/multiplayer_session.dart';

/// When an entity's authority sends a synchronized property.
enum SyncMode {
  /// Send the value when it differs from the last value sent, checking once
  /// per synchronizer interval.
  onChange,

  /// Send the value at every synchronizer interval, changed or not.
  always,
}

/// Binds a synchronized field to a local value through a getter and a setter.
///
/// The entity's authority samples [get] and sends the field as [mode]
/// describes; every other peer receives it and passes a copy to [set]. A
/// sample is the field codec's encoding of the value, so sampling copies
/// mutable values such as vectors, and a value is unchanged while its encoding
/// is unchanged.
final class SyncProperty<T> {
  /// Describes how [field] is read with [get] and written with [set].
  ///
  /// Without [set], received values are only kept as snapshots, for code that
  /// reads them itself, for example to smooth them before display.
  const SyncProperty(
    this.field, {
    required this.get,
    this.set,
    this.mode = SyncMode.onChange,
  });

  /// The registered field that this property replicates.
  final SyncField<T> field;

  /// Reads the local value. The authority calls it when sampling.
  final T Function() get;

  /// Writes a received value. Peers other than the authority call it.
  ///
  /// A thrown error produces [PropertySyncFailed]. The same encoded value
  /// is not applied again until it changes or a replacement synchronizer
  /// is attached, avoiding repeated failures on every update.
  final void Function(T value)? set;

  /// When the authority sends this property.
  final SyncMode mode;

  // Callers hold properties as SyncProperty<Object?>, where reading [set]
  // directly would fail Dart's covariance check. These members read the
  // fields with the actual type argument.
  Object? _get() => get();

  bool get _hasSetter => set != null;

  void _set(Object? value) => set?.call(value as T);
}

/// Creates [SyncProperty] descriptors whose value type comes from their
/// field.
///
/// Prefer `field.property(...)` inside a list of properties: a
/// [SyncProperty] constructor there infers its type from the list instead,
/// so typed getters and setters do not match without an explicit type
/// argument.
extension SyncFieldProperty<T> on SyncField<T> {
  /// Describes how this field is read with [get] and written with [set].
  SyncProperty<T> property({
    required T Function() get,
    void Function(T value)? set,
    SyncMode mode = SyncMode.onChange,
  }) => SyncProperty(this, get: get, set: set, mode: mode);
}

/// The latest authoritative value of a synchronized field on this peer.
final class SyncSnapshot<T> {
  const SyncSnapshot._(this.value, this.time);

  /// A copy of the value, which the caller may change.
  final T value;

  /// When this peer sent or received the value, on the session's clock.
  final Duration time;
}

/// Replicates selected properties of one attached entity from its authority
/// to every other peer.
///
/// Create one with [EntityAttachment.synchronize]. On the entity's authority,
/// [MultiplayerSession.captureState] samples the [properties] at most once per
/// [interval] of the session's clock, independent of how often it is called,
/// and sends the fields that are due in one message. On every other peer,
/// [MultiplayerSession.update] passes the latest authoritative values to the
/// setters while the attachment is ready, so a component that becomes ready
/// later still receives the current values. Applying received values never
/// sends anything, so it cannot cause a replication feedback loop.
final class MultiplayerSynchronizer {
  MultiplayerSynchronizer._(
    this._replicator,
    this._attachment,
    this.properties,
    this.interval,
  );

  final _StateReplicator _replicator;
  final EntityAttachment _attachment;
  final _applied = <FieldId, Uint8List>{};
  Duration? _due;
  var _disposed = false;

  /// The properties that this synchronizer replicates.
  final List<SyncProperty<Object?>> properties;

  /// The minimum time between two samples on the authority.
  final Duration interval;

  /// The entity whose properties this synchronizer replicates.
  NetworkEntity get entity => _attachment.entity;

  /// Whether this synchronizer was disposed, by itself or with its attachment.
  bool get isDisposed => _disposed || _attachment.isDisposed;

  /// The latest authoritative value of [field] for this entity on this peer,
  /// or `null` if none was sent or received.
  ///
  /// On the authority, this is the last value sent; elsewhere, the last value
  /// received. Values are kept with the entity, not with this synchronizer.
  /// Throws an [ArgumentError] for a foreign [field] handle.
  SyncSnapshot<T>? snapshot<T>(SyncField<T> field) =>
      _replicator._snapshot(entity, field);

  /// Stops sampling and applying values. Repeated disposal has no effect.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _replicator._unbind(this);
  }
}

final class _StateReplicator {
  _StateReplicator(this.session);

  final MultiplayerSession session;
  final _synchronizers = <EntityId, MultiplayerSynchronizer>{};

  /// The latest authoritative values of each entity, by field: the last ones
  /// sent on the authority, and the last ones received elsewhere.
  final _values = <NetworkEntity, Map<FieldId, _FieldValue>>{};
  var _lifetime = 0;
  var _capturing = false;

  bool get isCapturing => _capturing;

  /// Forgets the values of a previous session.
  void clear() {
    _lifetime++;
    _values.clear();
  }

  /// Forgets the values of a despawned entity.
  void forget(EntityId entity) =>
      _values.removeWhere((key, _) => key.id == entity);

  void _prune() => _values.removeWhere(
    (entity, _) =>
        entity.state == EntityState.removed ||
        !identical(session.registry[entity.id], entity),
  );

  MultiplayerSynchronizer synchronize(
    EntityAttachment attachment,
    List<SyncProperty<Object?>> properties,
    Duration interval,
  ) {
    if (!session._attachments._isLive(attachment)) {
      throw StateError('This entity attachment is no longer live.');
    }
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'must be positive');
    }
    if (properties.isEmpty) {
      throw ArgumentError.value(properties, 'properties', 'must not be empty');
    }
    final fields = <FieldId>{};
    for (final property in properties) {
      final field = property.field;
      if (!identical(session._schema.fieldDefinition(field.id), field)) {
        throw ArgumentError.value(
          field,
          'properties',
          'must use fields of the session schema',
        );
      }
      if (!fields.add(field.id)) {
        throw ArgumentError.value(
          field.id.value,
          'properties',
          'binds a field more than once',
        );
      }
    }
    final entity = attachment.entity;
    if (_synchronizers[entity.id] case final existing?
        when !existing.isDisposed) {
      throw StateError('This entity already has a synchronizer.');
    }
    final synchronizer = MultiplayerSynchronizer._(
      this,
      attachment,
      List.unmodifiable(properties),
      interval,
    );
    _synchronizers[entity.id] = synchronizer;
    attachment._synchronizer = synchronizer;
    return synchronizer;
  }

  void _unbind(MultiplayerSynchronizer synchronizer) {
    final id = synchronizer.entity.id;
    if (identical(_synchronizers[id], synchronizer)) _synchronizers.remove(id);
  }

  bool _isLive(MultiplayerSynchronizer synchronizer) {
    if (!synchronizer.isDisposed &&
        identical(_synchronizers[synchronizer.entity.id], synchronizer) &&
        identical(
          session._attachments.forEntity(synchronizer.entity),
          synchronizer._attachment,
        ) &&
        !synchronizer.isDisposed) {
      return true;
    }
    synchronizer.dispose();
    return false;
  }

  bool _isCurrent(MultiplayerSynchronizer synchronizer, int lifetime) =>
      _lifetime == lifetime && _isLive(synchronizer) && _lifetime == lifetime;

  /// Samples the ready synchronizers of entities this peer is the authority
  /// for, and sends the fields that are due.
  void capture() {
    final local = session._localPeer;
    if (local == null) return;
    _capturing = true;
    try {
      _prune();
      final lifetime = _lifetime;
      final now = session._clock.now;
      for (final synchronizer in _synchronizers.values.toList()) {
        if (_lifetime != lifetime) return;
        if (!_isCurrent(synchronizer, lifetime) ||
            synchronizer.entity.authority != local ||
            !synchronizer._attachment._isReady() ||
            !_isCurrent(synchronizer, lifetime)) {
          continue;
        }
        final due = synchronizer._due;
        if (due != null && now < due) continue;
        // A late capture starts a fresh interval instead of catching up
        // with closely spaced samples on subsequent frames.
        synchronizer._due = now + synchronizer.interval;
        _sample(synchronizer, now);
        if (session._peer == null) return;
      }
    } finally {
      _capturing = false;
    }
  }

  void _sample(MultiplayerSynchronizer synchronizer, Duration now) {
    final lifetime = _lifetime;
    final entity = synchronizer.entity;
    final sent = _values[entity];
    final due = <FieldId, Uint8List>{};
    for (final property in synchronizer.properties) {
      final field = property.field.id;
      final Uint8List bytes;
      try {
        bytes = _encode(field, property._get());
      } on Object catch (error, stackTrace) {
        if (!_isCurrent(synchronizer, lifetime)) return;
        _fail(entity.id, field, error, stackTrace);
        continue;
      }
      if (!_isCurrent(synchronizer, lifetime)) return;
      if (property.mode == SyncMode.always ||
          !_sameBytes(sent?[field]?.bytes, bytes)) {
        due[field] = bytes;
      }
    }
    for (final message in _messages(entity, due)) {
      if (!_isCurrent(synchronizer, lifetime)) return;
      _retain(entity, {
        for (final field in message.values.keys) field: due[field]!,
      }, now);
      if (session._isHost) {
        session._replicate(message, session._nextRevision());
      } else {
        final host = session._peers[PeerId.host];
        if (host == null || !session._send(host, message)) return;
      }
      if (session._peer == null) return;
    }
  }

  /// Applies a state message that [sender] sent, if it may write the entity.
  ///
  /// A host relays accepted messages from [origin] to the other clients.
  void receive(PeerId sender, MessageEnvelope envelope, {_Remote? origin}) {
    final lifetime = _lifetime;
    final message = envelope.message as StateMessage;
    final entity = session.registry[message.entity];
    if (entity == null) {
      _reject(message.entity, sender, StateRejection.unknownEntity);
      return;
    }
    // A late update for a removed entity is a harmless race.
    if (entity.state == EntityState.removed) return;
    final writer = session._isHost
        ? entity.authority == sender
        : entity.authority != session._localPeer;
    if (!writer) {
      _reject(entity.id, sender, StateRejection.notAuthority);
      return;
    }
    final received = <FieldId, Uint8List>{};
    for (final MapEntry(key: field, :value) in message.values.entries) {
      try {
        received[field] = _encode(field, value);
      } on Object catch (error, stackTrace) {
        if (_lifetime != lifetime) return;
        _fail(entity.id, field, error, stackTrace);
      }
      if (_lifetime != lifetime) return;
    }
    for (final accepted in _messages(entity, received)) {
      if (_lifetime != lifetime ||
          entity.state == EntityState.removed ||
          !identical(session.registry[entity.id], entity)) {
        return;
      }
      _retain(entity, {
        for (final field in accepted.values.keys) field: received[field]!,
      }, session._clock.now);
      if (session._isHost) {
        session._replicate(accepted, session._nextRevision(), except: origin);
        if (_lifetime != lifetime) return;
      }
    }
    session._onMessage?.call(sender, envelope);
  }

  /// Sends the retained values as part of [remote]'s baseline. Returns
  /// `false` if its transport refused one, which removes [remote].
  bool sendBaseline(_Remote remote) {
    _prune();
    for (final MapEntry(key: entity, value: fields)
        in _values.entries.toList()) {
      final values = {
        for (final MapEntry(key: field, :value) in fields.entries)
          field: value.bytes,
      };
      for (final message in _messages(entity, values)) {
        if (!session._send(remote, message, revision: session._revision)) {
          return false;
        }
      }
    }
    return true;
  }

  /// Passes the latest authoritative values to the setters of ready
  /// synchronizers on peers other than the entity's authority.
  void apply() {
    _prune();
    final lifetime = _lifetime;
    final local = session._localPeer;
    for (final synchronizer in _synchronizers.values.toList()) {
      if (_lifetime != lifetime) return;
      if (!_isCurrent(synchronizer, lifetime) ||
          synchronizer.entity.authority == local) {
        continue;
      }
      final values = _values[synchronizer.entity];
      if (values == null) continue;
      for (final property in synchronizer.properties) {
        if (!_isCurrent(synchronizer, lifetime) ||
            !synchronizer._attachment._isReady() ||
            !_isCurrent(synchronizer, lifetime)) {
          break;
        }
        final field = property.field.id;
        final value = values[field];
        if (value == null ||
            _sameBytes(synchronizer._applied[field], value.bytes)) {
          continue;
        }
        synchronizer._applied[field] = value.bytes;
        if (!property._hasSetter) continue;
        try {
          property._set(_decode(field, value.bytes));
        } on Object catch (error, stackTrace) {
          if (_lifetime == lifetime) {
            _fail(synchronizer.entity.id, field, error, stackTrace);
          }
        }
        if (session._peer == null) return;
        if (!_isLive(synchronizer)) break;
      }
    }
  }

  SyncSnapshot<T>? _snapshot<T>(NetworkEntity entity, SyncField<T> field) {
    if (!identical(session._schema.fieldDefinition(field.id), field)) {
      throw ArgumentError.value(
        field,
        'field',
        'must belong to the session schema',
      );
    }
    final value = _values[entity]?[field.id];
    if (value == null ||
        entity.state == EntityState.removed ||
        !identical(session.registry[entity.id], entity)) {
      return null;
    }
    return SyncSnapshot._(_decode(field.id, value.bytes) as T, value.time);
  }

  void _retain(
    NetworkEntity entity,
    Map<FieldId, Uint8List> fields,
    Duration at,
  ) {
    if (fields.isEmpty) return;
    final values = _values.putIfAbsent(entity, () => {});
    for (final MapEntry(key: field, value: bytes) in fields.entries) {
      values[field] = _FieldValue(bytes, at);
    }
  }

  /// Splits [fields] into state messages within the wire limits: one for
  /// all of them when possible, otherwise one for each field.
  List<StateMessage> _messages(
    NetworkEntity entity,
    Map<FieldId, Uint8List> fields,
  ) {
    if (fields.isEmpty) return const [];
    final lifetime = _lifetime;
    final values = <FieldId, Object?>{};
    for (final MapEntry(key: field, value: bytes) in fields.entries) {
      try {
        values[field] = _decode(field, bytes);
      } on Object catch (error, stackTrace) {
        if (_lifetime != lifetime) return const [];
        _fail(entity.id, field, error, stackTrace);
      }
      if (_lifetime != lifetime) return const [];
    }
    if (values.isEmpty) return const [];
    final combined = StateMessage(entity: entity.id, values: values);
    try {
      _checkFits(combined);
      return [combined];
    } on Object catch (error, stackTrace) {
      if (_lifetime != lifetime) return const [];
      if (values.length == 1) {
        _fail(entity.id, values.keys.single, error, stackTrace);
        return const [];
      }
      // The combined message may exceed the byte, depth or collection
      // limits. Check each field independently so valid fields still send.
    }
    final messages = <StateMessage>[];
    for (final MapEntry(key: field, :value) in values.entries) {
      final single = StateMessage(entity: entity.id, values: {field: value});
      try {
        _checkFits(single);
        messages.add(single);
      } on Object catch (error, stackTrace) {
        if (_lifetime != lifetime) return const [];
        _fail(entity.id, field, error, stackTrace);
      }
      if (_lifetime != lifetime) return const [];
    }
    return messages;
  }

  /// Checks [message] against the wire limits with any connection generation
  /// and revision, including envelopes containing only one field.
  void _checkFits(StateMessage message) {
    session._codec.encode(
      MessageEnvelope(
        message,
        generation: IntCodec.maxSafe,
        revision: IntCodec.maxSafe,
      ),
    );
  }

  /// The canonical encoding of a value of [field], which serves as its
  /// snapshot. Throws an [ArgumentError] if the field's codec or the wire
  /// limits reject it.
  Uint8List _encode(FieldId field, Object? value) {
    final wire = session._schema.field(field)!.encode(value);
    try {
      checkWireValue(wire, session._codec.limits);
    } on ProtocolException catch (error) {
      throw ArgumentError(
        'The value of ${field.value} cannot be encoded: ${error.message}',
      );
    }
    return session._codec.wire.encode(wire);
  }

  /// A fresh copy of the value of [field] encoded in [bytes].
  Object? _decode(FieldId field, Uint8List bytes) =>
      session._schema.field(field)!.decode(session._codec.wire.decode(bytes));

  void _reject(EntityId entity, PeerId sender, StateRejection reason) => session
      ._emit(StateRejected(entity: entity, sender: sender, reason: reason));

  void _fail(
    EntityId entity,
    FieldId field,
    Object error,
    StackTrace stackTrace,
  ) => session._emit(
    PropertySyncFailed(
      entity: entity,
      field: field,
      error: error,
      stackTrace: stackTrace,
    ),
  );

  static bool _sameBytes(Uint8List? a, Uint8List b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

final class _FieldValue {
  const _FieldValue(this.bytes, this.time);

  /// The canonical encoding of the value.
  final Uint8List bytes;

  /// When this peer sent or received the value.
  final Duration time;
}
