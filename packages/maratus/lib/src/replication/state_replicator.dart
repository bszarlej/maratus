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

  /// Reads the local value. The authority calls it when sampling.
  final T Function() get;

  /// Writes a received value. Peers other than the authority call it.
  ///
  /// A peer that becomes the entity's authority also calls it, with the
  /// values it received before, ahead of its first sample. A peer that
  /// stops being the authority calls it with the latest values that the
  /// host accepted, which replace any local changes since then.
  ///
  /// A thrown error produces [PropertySyncFailed]. The same encoded value
  /// is not applied again until it changes, a replacement synchronizer is
  /// attached, or this peer stops being the authority, avoiding repeated
  /// failures on every update.
  final void Function(T value)? set;

  /// When the authority sends this property.
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
///
/// Properties with a [SyncProperty.interpolator] also keep their recent
/// samples, so [interpolated] can present smoothed values between them.
///
/// When [MultiplayerSession.transferAuthority] moves the entity's
/// authority, synchronizers switch roles as each peer applies the transfer.
/// The previous authority stops sampling and applies the values it
/// receives: first the latest ones the host accepted, then the new
/// authority's. The new authority applies the values it received before,
/// then samples its local state from the next capture.
final class MultiplayerSynchronizer {
  MultiplayerSynchronizer._(
    this._replicator,
    this._attachment,
    this.properties,
    this.interval,
    this.interpolationDelay,
  ) {
    for (final property in properties) {
      if (!property._interpolates) continue;
      _interpolators[property.field.id] = property;
      _samples[property.field.id] = _Samples();
    }
    if (_samples.isNotEmpty) _timeline = _Timeline(interpolationDelay);
  }

  final _StateReplicator _replicator;
  final EntityAttachment _attachment;
  final _applied = <FieldId, Uint8List>{};
  final _interpolators = <FieldId, SyncProperty<Object?>>{};
  final _samples = <FieldId, _Samples>{};
  _Timeline? _timeline;
  Duration? _due;
  var _disposed = false;

  /// The properties that this synchronizer replicates.
  final List<SyncProperty<Object?>> properties;

  /// The minimum time between two samples on the authority.
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

  /// The latest authoritative value of [field] for this entity on this peer,
  /// or `null` if none was sent or received.
  ///
  /// On the authority, this is the last value sent; elsewhere, the last value
  /// received. Values are kept with the entity, not with this synchronizer.
  /// Throws an [ArgumentError] for a foreign [field] handle.
  SyncSnapshot<T>? snapshot<T>(SyncField<T> field) =>
      _replicator._snapshot(entity, field);

  /// The value of [field] to present now, smoothed by its property's
  /// [SyncProperty.interpolator].
  ///
  /// Received samples are placed on a timeline that follows the times the
  /// authority sampled them, so bursts and frame jitter in their arrival do
  /// not distort motion. The value presented is the one that timeline
  /// reached [interpolationDelay] behind the newest sample. Between two
  /// samples it is blended; with no newer sample yet it holds the newest,
  /// without extrapolating; a teleport shows as a jump. The presentation
  /// time never moves backwards. See [InterpolationState].
  ///
  /// Samples from different authorities are never blended, as their clocks
  /// are not comparable: an authority transfer restarts the timeline, and
  /// until the new authority's first sample arrives, the latest value holds.
  ///
  /// Returns `null` on the entity's authority, which presents its own
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

  /// Forgets the samples of the previous authority, whose clock the next
  /// authority's sample times are not comparable with.
  void _restartPresentation() {
    if (_timeline == null) return;
    _timeline = _Timeline(interpolationDelay);
    for (final field in _samples.keys) {
      _samples[field] = _Samples();
    }
  }
}

final class _StateReplicator {
  _StateReplicator(this.session);

  final MultiplayerSession session;
  final _synchronizers = <EntityId, MultiplayerSynchronizer>{};

  /// The latest authoritative values of each entity, by field: the last ones
  /// sent on the authority, and the last ones received elsewhere.
  final _values = <NetworkEntity, Map<FieldId, _FieldValue>>{};

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
    _catchingUp.clear();
  }

  /// Forgets the values of a despawned entity.
  void forget(EntityId entity) {
    _values.removeWhere((key, _) => key.id == entity);
    _catchingUp.removeWhere((key) => key.id == entity);
  }

  void _prune() {
    bool gone(NetworkEntity entity) =>
        entity.state == EntityState.removed ||
        !identical(session.registry[entity.id], entity);
    _values.removeWhere((entity, _) => gone(entity));
    _catchingUp.removeWhere(gone);
  }

  /// Switches the roles of [entity]'s synchronizer after its authority
  /// moved from [previous] on this peer.
  void transferred(NetworkEntity entity, PeerId previous) {
    final local = session._localPeer;
    final values = _values[entity];
    if (!session._isHost && previous == local) {
      // The host may have rejected values that this client sent, and it
      // follows the transfer with the values it accepted. Held values
      // would be rejected too.
      _values.remove(entity);
      session._peers[PeerId.host]?.held.remove(entity.id);
    } else if (values != null) {
      // The values were sampled on the previous authority's clock.
      values.updateAll(
        (_, value) => _FieldValue(value.bytes, value.time, null),
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
    if (previous == local) synchronizer._applied.clear();
    synchronizer._restartPresentation();
  }

  /// Sends [remote], the previous authority of [entity], the values that
  /// the host accepted from it, without sample times, to replace any values
  /// it sent after the transfer. Returns `false` if its transport refused
  /// one, which removes [remote].
  bool resync(_Remote remote, NetworkEntity entity) {
    final fields = _values[entity];
    if (fields == null) return true;
    final values = {
      for (final MapEntry(key: field, :value) in fields.entries)
        field: value.bytes,
    };
    for (final message in _messages(entity, values, sampledAt: null)) {
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
    if (retained != null && entity.authority != session._localPeer) {
      for (final MapEntry(key: field, :value) in retained.entries) {
        _buffer(synchronizer, field, value.bytes, value.time, value.sampledAt);
      }
    }
    return synchronizer;
  }

  /// Adds a received value of [field] to [synchronizer]'s presentation, if
  /// it interpolates the field. The value arrived [at] this peer's time.
  ///
  /// A value without a sample time on the current authority's clock is
  /// never blended, as its time is not comparable with the others.
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
    synchronizer._timeline!.observe(at, sampledAt);
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
    // A late update for a removed entity is a harmless race, and so is state
    // that a client sent before applying a transfer of the entity's
    // authority that the host has made.
    if (entity.state == EntityState.removed ||
        (session._isHost && session._authorities.awaits(entity, sender))) {
      return;
    }
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
    for (final accepted in _messages(
      entity,
      received,
      sampledAt: message.sampledAt,
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
  /// Values that the entity's current authority sampled keep its latest
  /// sample time; values that a previous authority sampled are sent
  /// without one.
  bool sendBaseline(_Remote remote) {
    _prune();
    for (final MapEntry(key: entity, value: fields)
        in _values.entries.toList()) {
      final settled = <FieldId, Uint8List>{};
      final sampled = <FieldId, Uint8List>{};
      Duration? sampledAt;
      for (final MapEntry(key: field, :value) in fields.entries) {
        final time = value.sampledAt;
        if (time == null) {
          settled[field] = value.bytes;
          continue;
        }
        sampled[field] = value.bytes;
        // Each capture samples every property of the entity, and a field it
        // did not send was unchanged, so all values that the authority
        // sampled were current at its latest sample.
        if (sampledAt == null || time > sampledAt) sampledAt = time;
      }
      for (final message in [
        ..._messages(entity, settled, sampledAt: null),
        ..._messages(entity, sampled, sampledAt: sampledAt),
      ]) {
        if (!session._send(remote, message, revision: session._revision)) {
          return false;
        }
      }
    }
    return true;
  }

  /// Passes the latest authoritative values to the setters of ready
  /// synchronizers on peers other than the entity's authority, and on an
  /// authority that has not applied the values it received before it
  /// became the authority.
  void apply() {
    _prune();
    final lifetime = _lifetime;
    final local = session._localPeer;
    for (final synchronizer in _synchronizers.values.toList()) {
      if (_lifetime != lifetime) return;
      final entity = synchronizer.entity;
      if (!_isCurrent(synchronizer, lifetime) ||
          (entity.authority == local && !_catchingUp.contains(entity))) {
        continue;
      }
      final completed = _applyValues(synchronizer, lifetime);
      if (_lifetime != lifetime || session._peer == null) return;
      if (completed && entity.authority == local) _catchingUp.remove(entity);
    }
  }

  /// Passes the retained values of [synchronizer]'s entity that it has not
  /// applied yet to its setters. Returns whether every property was
  /// handled while the synchronizer stayed live and ready.
  bool _applyValues(MultiplayerSynchronizer synchronizer, int lifetime) {
    final values = _values[synchronizer.entity];
    if (values == null) return true;
    for (final property in synchronizer.properties) {
      if (!_isCurrent(synchronizer, lifetime) ||
          !synchronizer._attachment._isReady() ||
          !_isCurrent(synchronizer, lifetime)) {
        return false;
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
        synchronizer.entity.authority == session._localPeer) {
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
    final time = synchronizer._timeline!.presentationAt(session._clock.now);
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

  /// Splits [fields] into state messages within the wire limits, stamped
  /// with the authority's [sampledAt], if any: one for all of them when
  /// possible, otherwise one for each field.
  List<StateMessage> _messages(
    NetworkEntity entity,
    Map<FieldId, Uint8List> fields, {
    required Duration? sampledAt,
  }) {
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
    final combined = StateMessage(
      entity: entity.id,
      values: values,
      sampledAt: sampledAt,
    );
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
      final single = StateMessage(
        entity: entity.id,
        values: {field: value},
        sampledAt: sampledAt,
      );
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
  const _FieldValue(this.bytes, this.time, this.sampledAt);

  /// The canonical encoding of the value.
  final Uint8List bytes;

  /// When this peer sent or received the value.
  final Duration time;

  /// When the entity's authority sampled the value, on its own clock, or
  /// `null` if the current authority did not sample it.
  final Duration? sampledAt;
}
