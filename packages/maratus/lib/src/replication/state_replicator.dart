part of '../core/multiplayer_session.dart';

/// When the writer of a synchronized property sends it.
enum SyncMode {
  /// Send the value when it differs from the last value sent, checking once
  /// per synchronizer interval.
  onChange,

  /// Send the value at every synchronizer interval, changed or not.
  always,
}

/// Binds a synchronized field to a local value through a getter and a setter.
///
/// The field's writer, the entity's authority or its owner as
/// [SyncField.writer] selects, samples [get] and sends the field as [mode]
/// describes; every other peer receives it and passes a copy to [set]. A
/// sample is the field codec's encoding of the value, so sampling copies
/// mutable values such as vectors, and a value is unchanged while its encoding
/// is unchanged. Fields with unreliable delivery require [SyncMode.always],
/// so the next sample repairs a lost update even if its value is unchanged.
final class SyncProperty<T> {
  /// Describes how [field] is read with [get] and written with [set].
  ///
  /// Without [set], received values are only kept for code that reads them
  /// itself: as snapshots, and with an [interpolator], as values smoothed
  /// for display by [MultiplayerSynchronizer.interpolated].
  const SyncProperty(
    this.field, {
    required this.get,
    this.set,
    this.mode = SyncMode.onChange,
    this.interpolator,
  });

  /// The registered field that this property replicates.
  final SyncField<T> field;

  /// Reads the local value. The field's writer calls it when sampling.
  final T Function() get;

  /// Writes a received value. Peers other than the field's writer call it,
  /// so the owner of an entity never receives its own owner-written values.
  ///
  /// For an authority-written field, a peer that becomes the entity's
  /// authority also calls it, with the values it received before, ahead of
  /// its first sample. A peer that stops being the authority calls it with
  /// the latest values that the host accepted, which replace any local
  /// changes since then.
  ///
  /// A thrown error produces [PropertySyncFailed]. The same encoded value
  /// is not applied again until it changes, a replacement synchronizer is
  /// attached, or this peer stops being the authority, avoiding repeated
  /// failures on every update.
  final void Function(T value)? set;

  /// When the field's writer sends this property.
  final SyncMode mode;

  /// Blends received values for [MultiplayerSynchronizer.interpolated], or
  /// `null` if this property is not interpolated.
  ///
  /// Interpolation only affects presentation: [set] and snapshots still
  /// receive every authoritative value as it arrives.
  final Interpolator<T>? interpolator;

  // Callers hold properties as SyncProperty<Object?>, where reading [set]
  // directly would fail Dart's covariance check. These members read the
  // fields with the actual type argument.
  Object? _get() => get();

  bool get _hasSetter => set != null;

  void _set(Object? value) => set?.call(value as T);

  bool get _interpolates => interpolator != null;

  Object? _lerp(Object? from, Object? to, double t) =>
      interpolator!.lerp(from as T, to as T, t);

  bool _isTeleport(Object? from, Object? to) =>
      interpolator!.isTeleport(from as T, to as T);
}

/// Creates [SyncProperty] descriptors whose value type comes from their
/// field.
///
/// Prefer `field.property(...)` inside a list of properties: a
/// [SyncProperty] constructor there infers its type from the list instead,
/// so typed getters and setters do not match without an explicit type
/// argument.
extension SyncFieldProperty<T> on SyncField<T> {
  /// Describes how this field is read with [get] and written with [set],
  /// and optionally smoothed for display with [interpolator].
  SyncProperty<T> property({
    required T Function() get,
    void Function(T value)? set,
    SyncMode mode = SyncMode.onChange,
    Interpolator<T>? interpolator,
  }) => SyncProperty(
    this,
    get: get,
    set: set,
    mode: mode,
    interpolator: interpolator,
  );
}

/// The latest value of a synchronized field on this peer, as its writer sent
/// it.
final class SyncSnapshot<T> {
  const SyncSnapshot._(this.value, this.time);

  /// A copy of the value, which the caller may change.
  final T value;

  /// When this peer sent or received the value, on the session's clock.
  final Duration time;
}

/// Replicates selected properties of one attached entity from the peers
/// that write them to every other peer.
///
/// Each property's field selects its writer with [SyncField.writer]: the
/// entity's authority, or its owner, so one synchronizer can combine the
/// input that an owner writes with the state that the authority computes
/// from it.
///
/// Create one with [EntityAttachment.synchronize]. On a peer that writes
/// some of the [properties], [MultiplayerSession.captureState] samples them
/// at most once per [interval] of the session's clock, independent of how
/// often it is called, and groups the fields that are due by writer,
/// delivery mode, and channel. [MultiplayerSession.update] passes the
/// latest values of the properties that this peer does not write to their
/// setters while the attachment is ready, so a component that becomes ready
/// later still receives the current values. Applying received values never
/// sends anything, so it cannot cause a replication feedback loop.
///
/// Properties with a [SyncProperty.interpolator] also keep their recent
/// samples, so [interpolated] can present smoothed values between them.
///
/// When [MultiplayerSession.transferAuthority] moves the entity's
/// authority, synchronizers switch the roles of authority-written
/// properties as each peer applies the transfer. The previous authority
/// stops sampling them and applies the values it receives: first the latest
/// ones the host accepted, then the new authority's. The new authority
/// applies the values it received before, then samples its local state from
/// the next capture. Owner-written properties keep their writer.
final class MultiplayerSynchronizer {
  MultiplayerSynchronizer._(
    this._replicator,
    this._attachment,
    this.properties,
    this.interval,
    this.interpolationDelay,
  ) {
    for (final property in properties) {
      _writers.add(property.field.writer);
      if (!property._interpolates) continue;
      _interpolators[property.field.id] = property;
      _samples[property.field.id] = _Samples();
      // Each writer samples on its own clock.
      _timelines.putIfAbsent(
        property.field.writer,
        () => _Timeline(interpolationDelay),
      );
    }
  }

  final _StateReplicator _replicator;
  final EntityAttachment _attachment;
  final _writers = <FieldWriter>{};
  final _applied = <FieldId, Uint8List>{};
  final _interpolators = <FieldId, SyncProperty<Object?>>{};
  final _samples = <FieldId, _Samples>{};
  final _timelines = <FieldWriter, _Timeline>{};
  Duration? _due;
  var _disposed = false;

  /// The properties that this synchronizer replicates.
  final List<SyncProperty<Object?>> properties;

  /// The minimum time between two samples on a peer that writes some of the
  /// [properties].
  final Duration interval;

  /// How far [interpolated] values trail the newest sample, after the
  /// estimated transit time.
  ///
  /// A delay of a few sample intervals leaves a newer sample to blend
  /// toward even when one arrives late; a shorter one shows changes sooner
  /// and holds values more often.
  final Duration interpolationDelay;

  /// The entity whose properties this synchronizer replicates.
  NetworkEntity get entity => _attachment.entity;

  /// Whether this synchronizer was disposed, by itself or with its attachment.
  bool get isDisposed => _disposed || _attachment.isDisposed;

  /// The latest value of [field] for this entity on this peer, or `null` if
  /// none was sent or received.
  ///
  /// On the field's writer, this is the last value sent; elsewhere, the last
  /// value received. Values are kept with the entity, not with this
  /// synchronizer. Throws an [ArgumentError] for a foreign [field] handle.
  SyncSnapshot<T>? snapshot<T>(SyncField<T> field) =>
      _replicator._snapshot(entity, field);

  /// The value of [field] to present now, smoothed by its property's
  /// [SyncProperty.interpolator].
  ///
  /// Received samples are placed on a timeline that follows the times the
  /// field's writer sampled them, so bursts and frame jitter in their
  /// arrival do not distort motion. The value presented is the one that
  /// timeline reached [interpolationDelay] behind the newest sample. Between
  /// two samples it is blended; with no newer sample yet it holds the
  /// newest, without extrapolating; a teleport shows as a jump. The
  /// presentation time never moves backwards. See [InterpolationState].
  ///
  /// Authority-written and owner-written fields follow separate timelines,
  /// as their writers' clocks are not comparable. For the same reason,
  /// samples from different authorities are never blended: an authority
  /// transfer restarts the timeline of authority-written fields, and until
  /// the new authority's first sample arrives, the latest value holds.
  ///
  /// Returns `null` on the peer that writes [field], which presents its own
  /// state, before any value of [field] was received, and once this
  /// synchronizer is disposed. The value is a copy that the caller may
  /// change. Throws an [ArgumentError] for a foreign [field] handle, or a
  /// field without an interpolator in this synchronizer.
  InterpolatedValue<T>? interpolated<T>(SyncField<T> field) =>
      _replicator._interpolated(this, field);

  /// Stops sampling and applying values. Repeated disposal has no effect.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _replicator._unbind(this);
  }

  /// Forgets the samples of authority-written fields from the previous
  /// authority, whose clock the next authority's sample times are not
  /// comparable with.
  void _restartPresentation() {
    if (!_timelines.containsKey(FieldWriter.authority)) return;
    _timelines[FieldWriter.authority] = _Timeline(interpolationDelay);
    for (final property in _interpolators.values) {
      if (property.field.writer != FieldWriter.authority) continue;
      _samples[property.field.id] = _Samples();
    }
  }
}

final class _StateReplicator {
  _StateReplicator(this.session);

  final MultiplayerSession session;
  final _synchronizers = <EntityId, MultiplayerSynchronizer>{};

  /// The latest values of each entity, by field: the last ones sent on the
  /// field's writer, and the last ones received elsewhere.
  final _values = <NetworkEntity, Map<FieldId, _FieldValue>>{};

  /// The newest independent-lane sample accepted for each field. Sequences
  /// are compared per field because different channels may arrive out of order.
  final _sequences = <NetworkEntity, Map<FieldId, int>>{};

  /// The entities that this peer became the authority of, whose
  /// synchronizers apply the values received before that ahead of their
  /// first sample.
  final _catchingUp = <NetworkEntity>{};
  var _lifetime = 0;
  var _capturing = false;

  bool get isCapturing => _capturing;

  /// Forgets the values of a previous session.
  void clear() {
    _lifetime++;
    _values.clear();
    _sequences.clear();
    _catchingUp.clear();
  }

  /// Forgets the values of a despawned entity.
  void forget(EntityId entity) {
    session._authorities.forgetEntity(entity);
    _values.removeWhere((key, _) => key.id == entity);
    _sequences.removeWhere((key, _) => key.id == entity);
    _catchingUp.removeWhere((key) => key.id == entity);
  }

  void _prune() {
    session._authorities.prune();
    bool gone(NetworkEntity entity) =>
        entity.state == EntityState.removed ||
        !identical(session.registry[entity.id], entity);
    _values.removeWhere((entity, _) => gone(entity));
    _sequences.removeWhere((entity, _) => gone(entity));
    _catchingUp.removeWhere(gone);
  }

  /// Which peer writes [field]: the entity's authority or its owner.
  FieldWriter writerOf(FieldId field) =>
      session._schema.fieldDefinition(field)!.writer;

  /// The peer that writes [field] of [entity].
  PeerId _writer(NetworkEntity entity, FieldId field) =>
      writerOf(field) == FieldWriter.owner ? entity.owner : entity.authority;

  bool _byAuthority(FieldId field) => writerOf(field) == FieldWriter.authority;

  /// Whether [local] writes any of [synchronizer]'s properties.
  bool _writesAny(MultiplayerSynchronizer synchronizer, PeerId local) {
    final entity = synchronizer.entity;
    return (entity.authority == local &&
            synchronizer._writers.contains(FieldWriter.authority)) ||
        (entity.owner == local &&
            synchronizer._writers.contains(FieldWriter.owner));
  }

  /// Switches the roles of [entity]'s synchronizer after its authority
  /// moved from [previous] on this peer.
  ///
  /// Only authority-written fields change their writer. Owner-written
  /// fields keep their values, sample times, and sequences.
  void transferred(NetworkEntity entity, PeerId previous) {
    _sequences[entity]?.removeWhere((field, _) => _byAuthority(field));
    final local = session._localPeer;
    final values = _values[entity];
    if (!session._isHost && previous == local) {
      // The host may have rejected values that this client sent, and it
      // follows the transfer with the values it accepted. Held values
      // would be rejected too.
      values?.removeWhere((field, _) => _byAuthority(field));
      session._peers[PeerId.host]?.held.remove((
        entity: entity.id,
        writer: FieldWriter.authority,
      ));
    } else if (values != null) {
      // The values were sampled on the previous authority's clock.
      values.updateAll(
        (field, value) => _byAuthority(field)
            ? _FieldValue(value.bytes, value.time, null)
            : value,
      );
    }
    if (entity.authority == local) {
      _catchingUp.add(entity);
    } else {
      _catchingUp.remove(entity);
    }
    final synchronizer = _synchronizers[entity.id];
    if (synchronizer == null || !identical(synchronizer.entity, entity)) {
      return;
    }
    // A new authority samples at its next capture.
    synchronizer._due = null;
    // Values this peer sent replace the ones it applied before, so apply
    // the replicated values again.
    if (previous == local) {
      synchronizer._applied.removeWhere((field, _) => _byAuthority(field));
    }
    synchronizer._restartPresentation();
  }

  /// Sends [remote], the previous authority of [entity], the values of its
  /// authority-written fields that the host accepted from it, without
  /// sample times, to replace any values it sent after the transfer.
  /// Returns `false` if its transport refused one, which removes [remote].
  bool resync(_Remote remote, NetworkEntity entity) {
    final fields = _values[entity];
    if (fields == null) return true;
    final values = {
      for (final MapEntry(key: field, :value) in fields.entries)
        if (_byAuthority(field)) field: value.bytes,
    };
    for (final message in _messages(
      entity,
      values,
      sampledAt: null,
      reliable: true,
    )) {
      if (!session._sendChange(remote, message)) return false;
    }
    return true;
  }

  MultiplayerSynchronizer synchronize(
    EntityAttachment attachment,
    List<SyncProperty<Object?>> properties,
    Duration interval,
    Duration? interpolationDelay,
  ) {
    if (!session._attachments._isLive(attachment)) {
      throw StateError('This entity attachment is no longer live.');
    }
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'must be positive');
    }
    final delay = interpolationDelay ?? interval * 2;
    if (delay <= Duration.zero) {
      throw ArgumentError.value(
        interpolationDelay,
        'interpolationDelay',
        'must be positive',
      );
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
      if (field.deliveryMode != DeliveryMode.reliable &&
          property.mode != SyncMode.always) {
        throw ArgumentError.value(
          field.id.value,
          'properties',
          'unreliable fields must use SyncMode.always',
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
      delay,
    );
    _synchronizers[entity.id] = synchronizer;
    attachment._synchronizer = synchronizer;
    // Start presentation from the values received before this binding.
    final retained = _values[entity];
    if (retained != null) {
      for (final MapEntry(key: field, :value) in retained.entries) {
        if (_writer(entity, field) == session._localPeer) continue;
        _buffer(synchronizer, field, value.bytes, value.time, value.sampledAt);
      }
    }
    return synchronizer;
  }

  /// Adds a received value of [field] to [synchronizer]'s presentation, if
  /// it interpolates the field. The value arrived [at] this peer's time.
  ///
  /// A value without a sample time on its current writer's clock is never
  /// blended, as its time is not comparable with the others.
  void _buffer(
    MultiplayerSynchronizer synchronizer,
    FieldId field,
    Uint8List bytes,
    Duration at,
    Duration? sampledAt,
  ) {
    final samples = synchronizer._samples[field];
    if (samples == null || sampledAt == null) return;
    final Object? value;
    try {
      value = _decode(field, bytes);
    } on Object {
      // Received values were decoded before they were accepted, so only a
      // codec that cannot repeat its round trip fails here. Applying the
      // value reports that failure.
      return;
    }
    synchronizer._timelines[writerOf(field)]!.observe(at, sampledAt);
    samples.add(sampledAt, bytes, value);
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

  /// Samples the ready synchronizers with properties that this peer writes,
  /// and sends the fields that are due.
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
            !_writesAny(synchronizer, local) ||
            !synchronizer._attachment._isReady() ||
            !_isCurrent(synchronizer, lifetime)) {
          continue;
        }
        final entity = synchronizer.entity;
        if (_catchingUp.contains(entity)) {
          // Continue from the values received before this peer became the
          // authority, rather than from older local state.
          final caughtUp = _applyValues(synchronizer, lifetime);
          if (_lifetime != lifetime || session._peer == null) return;
          if (!caughtUp) continue;
          _catchingUp.remove(entity);
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
    final local = session._localPeer;
    final sent = _values[entity];
    final due = <FieldId, Uint8List>{};
    for (final property in synchronizer.properties) {
      final field = property.field.id;
      if (_writer(entity, field) != local) continue;
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
    for (final message in _messages(entity, due, sampledAt: now)) {
      if (!_isCurrent(synchronizer, lifetime)) return;
      final fields = {
        for (final field in message.values.keys) field: due[field]!,
      };
      _retain(entity, fields, now, sampledAt: now);
      if (session._isHost) {
        session._replicateState(entity, message, fields);
      } else {
        final host = session._peers[PeerId.host];
        if (host == null ||
            !session._sendState(host, entity, message, fields)) {
          return;
        }
      }
      if (session._peer == null) return;
    }
  }

  /// Applies a state message that [sender] sent, if it may write each of
  /// its fields.
  ///
  /// A host accepts each field only from its writer, and relays accepted
  /// messages from [origin] to the other clients. A client accepts the
  /// fields that it does not write itself.
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
    // So is authority-written state that a client sent before applying a
    // transfer of the entity's authority that the host has made.
    final transferring =
        session._isHost && session._authorities.awaits(entity, sender);
    final local = session._localPeer;
    final fields = <FieldId>[];
    for (final field in message.values.keys) {
      final byAuthority = _byAuthority(field);
      if (transferring && byAuthority) continue;
      final writer = _writer(entity, field);
      if (session._isHost ? writer != sender : writer == local) {
        _reject(
          entity.id,
          sender,
          byAuthority ? StateRejection.notAuthority : StateRejection.notOwner,
        );
        return;
      }
      fields.add(field);
    }
    if (fields.isEmpty) return;
    final received = <FieldId, Uint8List>{};
    final sequence = message.sequence;
    var current = sequence == null;
    for (final field in fields) {
      final value = message.values[field];
      final previous = _sequences[entity]?[field];
      if (sequence != null && previous != null && sequence <= previous) {
        continue;
      }
      current = true;
      try {
        received[field] = _encode(field, value);
      } on Object catch (error, stackTrace) {
        if (_lifetime != lifetime) return;
        _fail(entity.id, field, error, stackTrace);
      }
      if (_lifetime != lifetime) return;
    }
    // A sample that is older than the newest one of each of its fields is
    // obsolete, like a control change with an old revision.
    if (!current) return;
    for (final accepted in _messages(
      entity,
      received,
      sampledAt: message.sampledAt,
      reliable: sequence == null,
    )) {
      if (_lifetime != lifetime ||
          entity.state == EntityState.removed ||
          !identical(session.registry[entity.id], entity)) {
        return;
      }
      final now = session._clock.now;
      final fields = {
        for (final field in accepted.values.keys) field: received[field]!,
      };
      _retain(entity, fields, now, sampledAt: message.sampledAt);
      if (sequence != null) {
        final sequences = _sequences.putIfAbsent(entity, () => {});
        for (final field in fields.keys) {
          sequences[field] = sequence;
        }
      }
      final synchronizer = _synchronizers[entity.id];
      if (synchronizer != null &&
          !synchronizer.isDisposed &&
          identical(synchronizer.entity, entity)) {
        for (final field in accepted.values.keys) {
          _buffer(
            synchronizer,
            field,
            received[field]!,
            now,
            message.sampledAt,
          );
        }
      }
      if (session._isHost) {
        session._replicateState(entity, accepted, fields, except: origin);
        if (_lifetime != lifetime) return;
      }
    }
    session._onMessage?.call(sender, envelope);
  }

  /// Sends the retained values as part of [remote]'s baseline. Returns
  /// `false` if its transport refused one, which removes [remote].
  ///
  /// Values that their current writer sampled keep its latest sample time;
  /// values that a previous authority sampled are sent without one.
  bool sendBaseline(_Remote remote) {
    _prune();
    for (final MapEntry(key: entity, value: fields)
        in _values.entries.toList()) {
      final settled = <FieldId, Uint8List>{};
      final sampled = <FieldWriter, Map<FieldId, Uint8List>>{};
      final sampledAt = <FieldWriter, Duration>{};
      for (final MapEntry(key: field, :value) in fields.entries) {
        final time = value.sampledAt;
        if (time == null) {
          settled[field] = value.bytes;
          continue;
        }
        final writer = writerOf(field);
        (sampled[writer] ??= {})[field] = value.bytes;
        // Each capture samples every property that its peer writes, and a
        // field it did not send was unchanged, so all values that a writer
        // sampled were current at its latest sample. The authority and the
        // owner sample on their own clocks.
        final latest = sampledAt[writer];
        if (latest == null || time > latest) sampledAt[writer] = time;
      }
      for (final message in [
        ..._messages(entity, settled, sampledAt: null, reliable: true),
        for (final MapEntry(key: writer, value: values) in sampled.entries)
          ..._messages(
            entity,
            values,
            sampledAt: sampledAt[writer],
            reliable: true,
          ),
      ]) {
        if (!session._send(remote, message, revision: session._revision)) {
          return false;
        }
      }
    }
    return true;
  }

  /// Passes the latest values of the fields that this peer does not write
  /// to the setters of ready synchronizers, as well as the values that a new
  /// authority received before it became the authority.
  void apply() {
    _prune();
    final lifetime = _lifetime;
    final local = session._localPeer;
    for (final synchronizer in _synchronizers.values.toList()) {
      if (_lifetime != lifetime) return;
      final entity = synchronizer.entity;
      if (!_isCurrent(synchronizer, lifetime) ||
          (!_catchingUp.contains(entity) &&
              synchronizer.properties.every(
                (property) => _writer(entity, property.field.id) == local,
              ))) {
        continue;
      }
      final completed = _applyValues(synchronizer, lifetime);
      if (_lifetime != lifetime || session._peer == null) return;
      if (completed && entity.authority == local) _catchingUp.remove(entity);
    }
  }

  /// Passes the retained values of [synchronizer]'s entity that it has not
  /// applied yet to its setters, except for the fields that this peer
  /// writes. A new authority that is catching up also applies the values of
  /// authority-written fields that it received before. Returns whether every
  /// property was handled while the synchronizer stayed live and ready.
  bool _applyValues(MultiplayerSynchronizer synchronizer, int lifetime) {
    final entity = synchronizer.entity;
    final values = _values[entity];
    if (values == null) return true;
    final local = session._localPeer;
    final catchingUp = _catchingUp.contains(entity);
    for (final property in synchronizer.properties) {
      final field = property.field.id;
      if (_writer(entity, field) == local &&
          !(catchingUp && _byAuthority(field))) {
        continue;
      }
      if (!_isCurrent(synchronizer, lifetime) ||
          !synchronizer._attachment._isReady() ||
          !_isCurrent(synchronizer, lifetime)) {
        return false;
      }
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
      if (session._peer == null || _lifetime != lifetime) return false;
      if (!_isLive(synchronizer)) return false;
    }
    return true;
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

  InterpolatedValue<T>? _interpolated<T>(
    MultiplayerSynchronizer synchronizer,
    SyncField<T> field,
  ) {
    if (!identical(session._schema.fieldDefinition(field.id), field)) {
      throw ArgumentError.value(
        field,
        'field',
        'must belong to the session schema',
      );
    }
    final property = synchronizer._interpolators[field.id];
    final samples = synchronizer._samples[field.id];
    if (property == null || samples == null) {
      throw ArgumentError.value(
        field.id.value,
        'field',
        'is not interpolated by this synchronizer',
      );
    }
    if (synchronizer.isDisposed ||
        _writer(synchronizer.entity, field.id) == session._localPeer) {
      return null;
    }
    if (samples.isEmpty) {
      // After a transfer, the latest value holds until the new authority's
      // first sample arrives.
      final latest = _values[synchronizer.entity]?[field.id];
      if (latest == null) return null;
      try {
        return InterpolatedValue._(
          _decode(field.id, latest.bytes) as T,
          InterpolationState.holding,
        );
      } on Object {
        return null;
      }
    }
    final time = synchronizer._timelines[field.writer]!.presentationAt(
      session._clock.now,
    );
    if (time == null) return null;
    return samples.evaluate<T>(
      time,
      interval: synchronizer.interval,
      property: property,
      copy: (bytes) => _decode(field.id, bytes) as T,
    );
  }

  void _retain(
    NetworkEntity entity,
    Map<FieldId, Uint8List> fields,
    Duration at, {
    required Duration? sampledAt,
  }) {
    if (fields.isEmpty) return;
    final values = _values.putIfAbsent(entity, () => {});
    for (final MapEntry(key: field, value: bytes) in fields.entries) {
      values[field] = _FieldValue(bytes, at, sampledAt);
    }
  }

  /// Groups [fields] by writer, delivery mode, and channel, then splits
  /// groups to fit the wire and transport limits, stamped with their
  /// writer's [sampledAt], if any. Baselines and authority resyncs use
  /// [reliable] delivery on the control channel regardless of field
  /// configuration, so their fields are grouped by writer only.
  ///
  /// Keeping each message to the fields of one writer lets receivers handle
  /// owner-written values independently of authority transfers.
  List<StateMessage> _messages(
    NetworkEntity entity,
    Map<FieldId, Uint8List> fields, {
    required Duration? sampledAt,
    bool reliable = false,
  }) {
    if (fields.isEmpty) return const [];
    final lifetime = _lifetime;
    final groups =
        <({FieldWriter writer, _Delivery delivery}), Map<FieldId, Object?>>{};
    for (final MapEntry(key: field, value: bytes) in fields.entries) {
      try {
        final value = _decode(field, bytes);
        final definition = session._schema.fieldDefinition(field)!;
        final group = (
          writer: definition.writer,
          delivery: reliable
              ? _defaultDelivery
              : (mode: definition.deliveryMode, channel: definition.channel),
        );
        groups.putIfAbsent(group, () => {})[field] = value;
      } on Object catch (error, stackTrace) {
        if (_lifetime != lifetime) return const [];
        _fail(entity.id, field, error, stackTrace);
      }
      if (_lifetime != lifetime) return const [];
    }
    final messages = <StateMessage>[];
    for (final values in groups.values) {
      final combined = StateMessage(
        entity: entity.id,
        values: values,
        sampledAt: sampledAt,
      );
      try {
        _checkFits(combined, reliable: reliable);
        messages.add(combined);
        continue;
      } on Object catch (error, stackTrace) {
        if (_lifetime != lifetime) return const [];
        if (values.length == 1) {
          _fail(entity.id, values.keys.single, error, stackTrace);
          if (_lifetime != lifetime) return const [];
          continue;
        }
        // A combined message may exceed the wire or transport limits.
        // Check fields independently so valid fields still send.
      }
      for (final MapEntry(key: field, :value) in values.entries) {
        final single = StateMessage(
          entity: entity.id,
          values: {field: value},
          sampledAt: sampledAt,
        );
        try {
          _checkFits(single, reliable: reliable);
          messages.add(single);
        } on Object catch (error, stackTrace) {
          if (_lifetime != lifetime) return const [];
          _fail(entity.id, field, error, stackTrace);
        }
        if (_lifetime != lifetime) return const [];
      }
    }
    return messages;
  }

  /// Checks [message] against the wire limits with any connection generation
  /// and revision, including envelopes containing only one field.
  void _checkFits(StateMessage message, {bool reliable = false}) {
    // Live updates on an independent lane also carry a sequence.
    final sequenced = !reliable && session._delivery.independent(message);
    final bytes = session._codec.encode(
      MessageEnvelope(
        sequenced
            ? StateMessage(
                entity: message.entity,
                values: message.values,
                sampledAt: message.sampledAt,
                sequence: IntCodec.maxSafe,
              )
            : message,
        generation: IntCodec.maxSafe,
        revision: IntCodec.maxSafe,
      ),
    );
    final maximum = session._peer?.capabilities.maxUnreliableMessageBytes;
    if (sequenced &&
        maximum != null &&
        bytes.length > maximum &&
        session._delivery.lane(message).mode != DeliveryMode.reliable) {
      throw ArgumentError(
        'The state message exceeds the transport limit of $maximum bytes '
        'for unreliable delivery.',
      );
    }
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
  const _FieldValue(this.bytes, this.time, this.sampledAt);

  /// The canonical encoding of the value.
  final Uint8List bytes;

  /// When this peer sent or received the value.
  final Duration time;

  /// When the field's writer sampled the value, on its own clock, or `null`
  /// if its current writer did not sample it.
  final Duration? sampledAt;
}
