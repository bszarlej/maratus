part of '../core/multiplayer_session.dart';

/// Advances [state] by one tick of [input] and returns the new state.
///
/// The owner of an entity calls it to predict, and the host calls it with
/// the same inputs to compute the authoritative state, so both must use the
/// same step, which must return equal states for equal arguments. Each call
/// receives its own copies of the state and the input, which it may change.
///
/// The step sees only the entity's state and one input. Anything else that
/// it reads, such as a level captured in its closure, must be the same on
/// the host and the owner. The owner does not predict how other entities
/// affect the state, such as collisions with moving objects: the host's
/// state corrects the prediction when it arrives.
typedef PredictionStep<S, I> = S Function(S state, I input);

/// Predicts the state of an entity on its owner from the owner's inputs,
/// and reconciles the prediction with the state that the host computes from
/// the same inputs.
///
/// Create one with [EntityAttachment.predict] on every peer, before
/// synchronizing the entity, and bind its [field] with [property] in the
/// entity's synchronizer. While the host is the entity's authority and a
/// client owns it:
///
/// - The owner calls [advance] with its input every frame. Each whole tick
///   of the [input] stream numbers the input, runs the step, and keeps the
///   input until the host reports that it applied it. The session sends the
///   inputs that the host has not acknowledged during
///   [MultiplayerSession.captureState].
/// - The host applies each input once, in order, during
///   [MultiplayerSession.update], at most one tick of inputs per tick of its
///   clock after a short burst, and reports the latest input it applied
///   with the state it samples. It waits for late inputs, or keeps the
///   entity moving with an idle input, as [EntityAttachment.predict]
///   describes.
/// - When the host's state arrives, the owner resets to it and applies the
///   inputs that it does not include again, during
///   [MultiplayerSession.update]. If that differs from the prediction, the
///   [interpolator] blends the correction out over [smoothing].
///
/// The step sees only the state and one input, so the owner predicts only
/// what follows from them; see [PredictionStep]. To change the state in
/// other ways, such as to respawn a player, the authority sets [state].
///
/// The values that the step receives and returns pass through the codecs of
/// [field] and [input], so the owner predicts with exactly the values that
/// the host applies. On the entity's authority, when it is the owner, [advance]
/// applies the inputs directly; the authority's state replicates as usual.
/// While another client is the authority, the owner's prediction pauses:
/// [advance] records no inputs and returns the state that the authority
/// sends, until the host or the owner is the authority again.
///
/// Every other peer follows the authority's state, and [presented] shows it
/// interpolated when the synchronizer interpolates [field].
final class Prediction<S, I> {
  Prediction._(
    this._inputs,
    this._attachment,
    this.field,
    this.input,
    this._step,
    this.interpolator,
    this.smoothing,
    this._idle,
    this._current,
  );

  final _InputReplicator _inputs;
  final EntityAttachment _attachment;
  final PredictionStep<S, I> _step;

  /// The canonical encoding of the input that the host applies while the
  /// owner's inputs are late, or `null` if the host waits for them.
  final Uint8List? _idle;

  /// The authority-written field that holds the predicted state.
  final SyncField<S> field;

  /// The input stream whose inputs advance the state.
  final InputStream<I> input;

  /// Blends states for [presented], or `null` to present each state as it
  /// is.
  ///
  /// On the owner, it blends between the states of the last two ticks, and
  /// out of a correction. [property] also interpolates the state with it on
  /// the peers that follow the authority's state.
  final Interpolator<S>? interpolator;

  /// How long a correction of the owner's prediction takes to blend out,
  /// with an [interpolator]. Corrections that it treats as teleports show at
  /// once.
  final Duration smoothing;

  /// The canonical encoding of the latest state: after the latest tick on
  /// the owner, as applied on the authority, and as received elsewhere.
  Uint8List _current;

  /// The state before the latest tick, which the owner blends from, or
  /// `null` if there is none to blend from.
  Uint8List? _previous;

  /// The trajectory that a correction blends out of, if one is blending.
  ({Uint8List? previous, Uint8List current})? _stale;
  Duration _correctedAt = Duration.zero;

  /// The time that [advance] has covered, and the part of it that no tick
  /// covers yet.
  Duration _time = Duration.zero;
  Duration _accumulated = Duration.zero;

  /// The authoritative state and the input it includes that the owner last
  /// reconciled with.
  ({Uint8List bytes, int input})? _reconciled;
  var _disposed = false;

  /// The entity whose state this prediction advances.
  NetworkEntity get entity => _attachment.entity;

  /// Whether this prediction was disposed, by itself or with its
  /// attachment.
  bool get isDisposed => _disposed || _attachment.isDisposed;

  /// The latest state of the entity on this peer, as a copy that the caller
  /// may change: on the owner while it predicts, the state after the latest
  /// tick; on the authority, the authoritative state; elsewhere, the latest
  /// state received.
  ///
  /// The entity's authority can set it outside the step, such as to respawn
  /// or knock back a player. The new state shows at once on the authority
  /// and replicates as usual. The owner, while it predicts, resets to it
  /// when it arrives and applies its later inputs again, blending the
  /// difference out as for any correction.
  ///
  /// Setting it has no effect once the prediction is disposed. Throws a
  /// [StateError] if this peer is not the entity's authority, and an
  /// [ArgumentError] if [field] cannot encode the state.
  S get state => _decode(_current);

  set state(S state) {
    if (!_inputs._isLive(this)) return;
    if (_role case _PredictionRole.predicting || _PredictionRole.following) {
      throw StateError(
        "Only the entity's authority sets the state of its prediction.",
      );
    }
    _current = _encode(state);
    _previous = null;
    _stale = null;
  }

  /// The state to present on this peer, which the caller may change.
  ///
  /// On the owner while it predicts, and on an owner that is the authority,
  /// this is [state] blended by the [interpolator] from the state of the
  /// previous tick, by the part of a tick that has passed since the latest
  /// one, and out of any correction still blending. On the host while it
  /// applies a client's inputs, it is [state]. Elsewhere, it is the
  /// synchronizer's interpolated value of [field] once there is one, and
  /// [state] otherwise.
  S get presented {
    switch (_role) {
      case _PredictionRole.following:
        final synchronizer = _attachment._synchronizer;
        if (!isDisposed &&
            synchronizer != null &&
            !synchronizer.isDisposed &&
            synchronizer._interpolators.containsKey(field.id)) {
          if (synchronizer.interpolated(field) case final shown?) {
            return shown.value;
          }
        }
        return state;
      case _PredictionRole.applying:
        return state;
      case _PredictionRole.predicting || _PredictionRole.advancing:
        return _presentTrajectory();
    }
  }

  /// The inputs that wait: on the owner while it predicts, the inputs that
  /// the host has not acknowledged; on the host, the received inputs that
  /// it has not applied yet. Zero elsewhere.
  int get pendingInputs {
    final log = _inputs._logs[entity];
    if (log == null || log.stream != input.id) return 0;
    return switch (_role) {
      _PredictionRole.predicting => log.history.length,
      _PredictionRole.applying => log.queue.length,
      _ => 0,
    };
  }

  /// Advances the prediction by [elapsed] with [input] on the entity's
  /// owner, and returns the state to present, as [presented] does.
  ///
  /// Call it once per frame, with the input to apply even when there is
  /// none: the blending between ticks and out of corrections follows the
  /// time that it receives.
  ///
  /// Runs one step for each whole tick of the [InputStream.tick] that the
  /// elapsed time completes, with [input] for each, covering at most a
  /// quarter of a second per call so that a long frame does not cause a
  /// burst. While the host is the authority, each tick numbers the input
  /// for the host; on an owner that is the authority, the steps apply
  /// directly. While another client is the authority, nothing is recorded.
  /// Once the input numbers, which run to 2^53 - 1, are exhausted, ticks no
  /// longer run.
  ///
  /// Has no effect once the prediction is disposed. Throws a [StateError] if
  /// this peer is not the entity's owner, an [ArgumentError] if [elapsed] is
  /// negative or [input] cannot be encoded and sent, or if a step returns a
  /// state that its field cannot encode, and rethrows what the step throws.
  /// A failed tick changes nothing and is not sent, and the elapsed time
  /// that it would have covered is dropped.
  S advance(I input, Duration elapsed) {
    if (elapsed.isNegative) {
      throw ArgumentError.value(elapsed, 'elapsed', 'must not be negative');
    }
    if (!_inputs._isLive(this)) return presented;
    final role = _role;
    if (_inputs.session._localPeer != entity.owner) {
      throw StateError('Only the owner of an entity advances its prediction.');
    }
    if (role == _PredictionRole.following) return presented;
    final encoded = _inputs._encodeInput(this, input);
    _time += elapsed;
    final tick = this.input.tick.inMicroseconds;
    final total = _accumulated.inMicroseconds + elapsed.inMicroseconds;
    final ticks = min(total ~/ tick, _InputReplicator._ticks(this.input.tick));
    _accumulated = Duration(microseconds: total % tick);
    for (var i = 0; i < ticks; i++) {
      final next = _stepOnce(_current, encoded);
      if (role == _PredictionRole.predicting &&
          !_inputs._record(this, encoded)) {
        break;
      }
      _advanceStale(encoded);
      _previous = _current;
      _current = next;
    }
    _finishCorrection();
    return presented;
  }

  /// Describes the synchronized property of [field], to bind in the entity's
  /// synchronizer: its authority samples [state], the owner reconciles its
  /// prediction with the values it receives, and every other peer follows
  /// them, interpolated by the [interpolator]. The property sends as [mode]
  /// describes.
  SyncProperty<S> property({SyncMode mode = SyncMode.onChange}) =>
      SyncProperty<S>._predicted(this, mode);

  /// Stops predicting. Repeated disposal has no effect.
  ///
  /// The inputs that the owner recorded and that the host received stay
  /// with the entity, so a replacement prediction continues with them.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _inputs._unbind(this);
  }

  _PredictionRole get _role {
    final local = _inputs.session._localPeer;
    final entity = this.entity;
    if (local == null) return _PredictionRole.following;
    if (entity.authority == local) {
      return entity.owner == local
          ? _PredictionRole.advancing
          : _PredictionRole.applying;
    }
    if (entity.owner == local && entity.authority == PeerId.host) {
      return _PredictionRole.predicting;
    }
    return _PredictionRole.following;
  }

  /// Whether this peer is the owner and predicts the host's state.
  bool get _predicts => _role == _PredictionRole.predicting;

  S _decode(Uint8List bytes) =>
      _inputs.session._states._decode(field.id, bytes) as S;

  Uint8List _encode(S state) =>
      _inputs.session._states._encode(field.id, state);

  /// The canonical state after one step from [state] with the input whose
  /// canonical encoding is [input].
  Uint8List _stepOnce(Uint8List state, Uint8List input) =>
      _encode(_step(_decode(state), _inputs._decodeInput(this, input) as I));

  /// Applies one input that the host received from the owner, reporting a
  /// failed step as [PropertySyncFailed] and leaving the state unchanged.
  void _apply(Object? input) {
    try {
      _current = _encode(_step(_decode(_current), input as I));
      _previous = null;
    } on Object catch (error, stackTrace) {
      _inputs.session._states._fail(entity.id, field.id, error, stackTrace);
    }
  }

  /// Takes the latest state that the authority sent, on a peer that
  /// follows it or that becomes the authority.
  void _receive(Uint8List bytes) {
    _current = bytes;
    _previous = null;
    _stale = null;
    _reconciled = null;
  }

  /// Resets the owner's prediction to the authoritative state [bytes],
  /// which includes the inputs up to [applied], and applies the inputs that
  /// it does not include again.
  void _reconcile(Uint8List bytes, int? applied) {
    final acknowledged = applied ?? 0;
    final reconciled = _reconciled;
    if (reconciled != null &&
        reconciled.input == acknowledged &&
        _StateReplicator._sameBytes(reconciled.bytes, bytes)) {
      return;
    }
    _reconciled = (bytes: bytes, input: acknowledged);
    final history = _inputs._acknowledge(this, acknowledged);
    Uint8List? previous;
    var current = bytes;
    try {
      for (final input in history) {
        previous = current;
        current = _stepOnce(current, input.bytes);
      }
    } on Object catch (error, stackTrace) {
      _inputs.session._states._fail(entity.id, field.id, error, stackTrace);
      // Continue from the authoritative state alone.
      _inputs._forgetHistory(this);
      previous = null;
      current = bytes;
    }
    if (_StateReplicator._sameBytes(current, _current)) return;
    _correct(previous, current);
  }

  /// Replaces the owner's trajectory with the corrected one, blending out
  /// of what it presents now, unless the change is a teleport.
  void _correct(Uint8List? previous, Uint8List current) {
    final interpolator = this.interpolator;
    if (interpolator != null && smoothing > Duration.zero) {
      final from = _presentedTrajectory();
      if (!interpolator.isTeleport(_decode(from.current), _decode(current))) {
        _stale = from;
        _correctedAt = _time;
      } else {
        _stale = null;
      }
    }
    _previous = previous;
    _current = current;
  }

  /// The trajectory presented now: the latest one, or a blend out of a
  /// correction.
  ({Uint8List? previous, Uint8List current}) _presentedTrajectory() {
    final stale = _stale;
    final progress = _progress;
    if (stale == null || progress == null) {
      return (previous: _previous, current: _current);
    }
    Uint8List blend(Uint8List? from, Uint8List? to) {
      if (from == null || to == null) return to ?? _current;
      if (progress <= 0) return from;
      return _encode(interpolator!.lerp(_decode(from), _decode(to), progress));
    }

    return (
      previous: _previous == null ? null : blend(stale.previous, _previous),
      current: blend(stale.current, _current),
    );
  }

  /// The part of a correction that has blended out, from 0 to 1, or `null`
  /// if none is blending.
  double? get _progress {
    if (_stale == null) return null;
    final progress =
        (_time - _correctedAt).inMicroseconds / smoothing.inMicroseconds;
    return progress < 1 ? max(0, progress) : null;
  }

  /// Advances the trajectory that a correction blends out of with the same
  /// input as the prediction, so the blend follows the motion.
  void _advanceStale(Uint8List input) {
    final stale = _stale;
    if (stale == null) return;
    try {
      _stale = (
        previous: stale.current,
        current: _stepOnce(stale.current, input),
      );
    } on Object {
      // The blend ends early; the prediction itself is unaffected.
      _stale = null;
    }
  }

  void _finishCorrection() {
    if (_stale != null && _progress == null) _stale = null;
  }

  S _presentTrajectory() {
    final alpha = _accumulated.inMicroseconds / input.tick.inMicroseconds;
    final main = _blend(_previous, _current, alpha);
    final stale = _stale;
    final progress = _progress;
    if (stale == null || progress == null) return main;
    final from = _blend(stale.previous, stale.current, alpha);
    if (progress <= 0) return from;
    return interpolator!.lerp(from, main, progress);
  }

  /// The state between [previous] and [current], the fraction [alpha] of
  /// a tick after [previous].
  S _blend(Uint8List? previous, Uint8List current, double alpha) {
    final interpolator = this.interpolator;
    if (interpolator == null || previous == null) return _decode(current);
    if (alpha <= 0) return _decode(previous);
    final from = _decode(previous);
    final to = _decode(current);
    if (interpolator.isTeleport(from, to)) return to;
    return interpolator.lerp(from, to, alpha);
  }

  /// Ends any correction and forgets the reconciled state, after a transfer
  /// changes which peer computes the authoritative state.
  void _transferred() {
    _stale = null;
    _reconciled = null;
  }
}

/// What a prediction does on this peer.
enum _PredictionRole {
  /// The owner predicts the host's authoritative state.
  predicting,

  /// The owner is the authority and applies its own inputs.
  advancing,

  /// The host applies the inputs that the owner sends.
  applying,

  /// The peer follows the authority's state.
  following,
}

/// The inputs of one entity's stream on this peer: on its owner, the
/// numbered inputs that the host has not acknowledged, and on the host, the
/// inputs it received and applied.
final class _InputLog {
  _InputLog(this.stream);

  /// The input stream of the inputs.
  final InputId stream;

  /// On the owner, the number of the next input.
  var next = 1;

  /// On the owner, the inputs that the host has not acknowledged, oldest
  /// first, with consecutive numbers.
  final history = ListQueue<({int sequence, Uint8List bytes})>();

  /// On the owner, the number of the newest input sent, and when it last
  /// sent inputs.
  var sent = 0;
  Duration? sentAt;

  /// On the host, the number of the newest input received.
  var received = 0;

  /// On the host, the number of the newest input applied, which it reports
  /// with the entity's state.
  var applied = 0;

  /// On the host, the received inputs that wait to be applied, oldest
  /// first.
  final queue = ListQueue<({int sequence, Object? value})>();

  /// On the host, how many microseconds of inputs it may still apply, and
  /// when that was last updated.
  var credit = 0;
  Duration? creditAt;

  /// On the host, while no input waits, since when, and how many ticks it
  /// covered with idle inputs since then.
  Duration? waitingSince;
  var idled = 0;
}

/// Records, sends, applies, and acknowledges the inputs of predicted
/// entities.
final class _InputReplicator {
  _InputReplicator(this.session);

  final MultiplayerSession session;
  final _predictions = <EntityId, Prediction<Object?, Object?>>{};

  /// The inputs of each entity, which outlive its predictions, so a
  /// replacement prediction continues their numbering.
  final _logs = <NetworkEntity, _InputLog>{};
  var _lifetime = 0;

  /// The most time that one call to [Prediction.advance] covers, and that
  /// the host's credit for applying inputs accumulates.
  static const _catchUp = Duration(milliseconds: 250);

  /// The most time that the owner's unacknowledged inputs cover; older ones
  /// are dropped.
  static const _history = Duration(seconds: 2);

  /// The most inputs that one message carries.
  static const _maxInputsPerMessage = 64;

  /// The number of whole ticks of [tick] in [span], at least one.
  static int _ticks(Duration tick, [Duration span = _catchUp]) =>
      max(1, span.inMicroseconds ~/ tick.inMicroseconds);

  /// Forgets the inputs of a previous session.
  void clear() {
    _lifetime++;
    _logs.clear();
  }

  /// Forgets the inputs of a despawned entity.
  void forget(EntityId entity) =>
      _logs.removeWhere((key, _) => key.id == entity);

  void prune() {
    bool gone(NetworkEntity entity) =>
        entity.state == EntityState.removed ||
        !identical(session.registry[entity.id], entity);
    _logs.removeWhere((entity, _) => gone(entity));
  }

  Prediction<S, I> predict<S, I>(
    EntityAttachment attachment, {
    required SyncField<S> state,
    required InputStream<I> input,
    required S initial,
    required PredictionStep<S, I> step,
    required Interpolator<S>? interpolator,
    required Duration smoothing,
    required I? idleInput,
  }) {
    if (!session._attachments._isLive(attachment)) {
      throw StateError('This entity attachment is no longer live.');
    }
    if (!identical(session._schema.fieldDefinition(state.id), state)) {
      throw ArgumentError.value(
        state,
        'state',
        'must belong to the session schema',
      );
    }
    if (state.writer != FieldWriter.authority) {
      throw ArgumentError.value(
        state.id.value,
        'state',
        'must be written by the authority',
      );
    }
    if (!identical(session._schema.inputDefinition(input.id), input)) {
      throw ArgumentError.value(
        input,
        'input',
        'must belong to the session schema',
      );
    }
    if (smoothing.isNegative) {
      throw ArgumentError.value(smoothing, 'smoothing', 'must not be negative');
    }
    final entity = attachment.entity;
    if (_predictions[entity.id] case final existing? when _isLive(existing)) {
      throw StateError('This entity already has a prediction.');
    }
    if (attachment._synchronizer case final synchronizer?
        when !synchronizer.isDisposed) {
      throw StateError(
        'Predict before synchronizing the entity, so that its synchronizer '
        'can bind the prediction.',
      );
    }
    final prediction = Prediction<S, I>._(
      this,
      attachment,
      state,
      input,
      step,
      interpolator,
      smoothing,
      idleInput == null ? null : _canonicalInput(input, idleInput),
      session._states._encode(state.id, initial),
    );
    _predictions[entity.id] = prediction;
    attachment._prediction = prediction;
    return prediction;
  }

  void _unbind(Prediction<Object?, Object?> prediction) {
    final id = prediction.entity.id;
    if (identical(_predictions[id], prediction)) _predictions.remove(id);
  }

  bool _isLive(Prediction<Object?, Object?> prediction) {
    if (!prediction.isDisposed &&
        identical(_predictions[prediction.entity.id], prediction) &&
        identical(
          session._attachments.forEntity(prediction.entity),
          prediction._attachment,
        ) &&
        !prediction.isDisposed) {
      return true;
    }
    prediction.dispose();
    return false;
  }

  /// The live prediction of [attachment], if any.
  Prediction<Object?, Object?>? forAttachment(EntityAttachment attachment) {
    final prediction = attachment._prediction;
    return prediction != null && _isLive(prediction) ? prediction : null;
  }

  /// The live predictions, for diagnostics.
  int get count =>
      _predictions.values.where((prediction) => !prediction.isDisposed).length;

  _InputLog _log(Prediction<Object?, Object?> prediction) {
    final entity = prediction.entity;
    final log = _logs[entity];
    if (log != null && log.stream == prediction.input.id) return log;
    return _logs[entity] = _InputLog(prediction.input.id);
  }

  /// The canonical encoding of [input] for [prediction]'s stream.
  ///
  /// Throws an [ArgumentError] unless the input's codec accepts it and a
  /// message with it alone fits the wire limits and, for unreliable
  /// delivery, the transport's limit.
  Uint8List _encodeInput(
    Prediction<Object?, Object?> prediction,
    Object? input,
  ) {
    final stream = prediction.input;
    final bytes = _canonicalInput(stream, input);
    final Uint8List message;
    try {
      message = session._codec.encode(
        MessageEnvelope(
          InputMessage(
            entity: prediction.entity.id,
            input: stream.id,
            sequence: IntCodec.maxSafe,
            values: [input],
          ),
          generation: IntCodec.maxSafe,
          revision: IntCodec.maxSafe,
        ),
      );
    } on ProtocolException catch (error) {
      throw ArgumentError('The input cannot be encoded: ${error.message}');
    }
    final maximum = session._peer?.capabilities.maxUnreliableMessageBytes;
    if (stream.deliveryMode != DeliveryMode.reliable &&
        maximum != null &&
        message.length > maximum) {
      throw ArgumentError(
        'The input exceeds the transport limit of $maximum bytes for '
        'unreliable delivery.',
      );
    }
    return bytes;
  }

  /// The canonical encoding of [input] for [stream].
  ///
  /// Throws an [ArgumentError] unless the stream's codec accepts the input
  /// within the wire limits.
  Uint8List _canonicalInput(InputStream<Object?> stream, Object? input) {
    final wire = session._schema.input(stream.id)!.encode(input);
    try {
      checkWireValue(wire, session._codec.limits);
    } on ProtocolException catch (error) {
      throw ArgumentError('The input cannot be encoded: ${error.message}');
    }
    return session._codec.wire.encode(wire);
  }

  /// A fresh copy of the input of [prediction]'s stream encoded in [bytes].
  Object? _decodeInput(
    Prediction<Object?, Object?> prediction,
    Uint8List bytes,
  ) => session._schema
      .input(prediction.input.id)!
      .decode(session._codec.wire.decode(bytes));

  /// Numbers the owner's [input] and keeps it until the host acknowledges
  /// it. Returns `false`, recording nothing, once the numbers are
  /// exhausted.
  bool _record(Prediction<Object?, Object?> prediction, Uint8List input) {
    final log = _log(prediction);
    if (log.next > IntCodec.maxSafe) return false;
    log.history.add((sequence: log.next++, bytes: input));
    final limit = _ticks(prediction.input.tick, _history);
    while (log.history.length > limit) {
      log.history.removeFirst();
    }
    return true;
  }

  /// Drops the owner's inputs up to [applied], which the host applied, and
  /// returns the ones that remain.
  Iterable<({int sequence, Uint8List bytes})> _acknowledge(
    Prediction<Object?, Object?> prediction,
    int applied,
  ) {
    final log = _log(prediction);
    while (log.history.isNotEmpty && log.history.first.sequence <= applied) {
      log.history.removeFirst();
    }
    return log.history;
  }

  void _forgetHistory(Prediction<Object?, Object?> prediction) {
    final log = _log(prediction);
    log.history.clear();
    log.sent = log.next - 1;
  }

  /// The number of the latest input of [entity] that the host applied, to
  /// report with its state, or `null` if this peer reports none: only the
  /// host does, while it applies the inputs of a client that owns [entity].
  int? applied(NetworkEntity entity) {
    if (!session._isHost ||
        entity.authority != PeerId.host ||
        entity.owner == PeerId.host) {
      return null;
    }
    return _logs[entity]?.applied ?? 0;
  }

  /// Sends the inputs that the owner recorded since it last sent.
  ///
  /// Inputs that travel unreliably are sent with the ones that the host has
  /// not acknowledged yet, which are also sent again once per tick while no
  /// new input follows them, so that a lost message is repaired.
  void send() {
    final host = session._peers[PeerId.host];
    if (session._isHost || host == null) return;
    final lifetime = _lifetime;
    final now = session._clock.now;
    for (final prediction in _predictions.values.toList()) {
      if (_lifetime != lifetime || session._peer == null) return;
      if (!_isLive(prediction) || !prediction._predicts) continue;
      final log = _logs[prediction.entity];
      if (log == null ||
          log.stream != prediction.input.id ||
          log.history.isEmpty) {
        continue;
      }
      final stream = prediction.input;
      final reliable = stream.deliveryMode == DeliveryMode.reliable;
      final sentAt = log.sentAt;
      final due =
          log.history.last.sequence > log.sent ||
          (!reliable && (sentAt == null || now - sentAt >= stream.tick));
      if (!due) continue;
      // Unsent inputs wait for a congested connection; they are sent again
      // with the next ones.
      if (!reliable && session._congested(host)) continue;
      final messages = reliable
          ? _messages(prediction, [
              for (final input in log.history)
                if (input.sequence > log.sent) input,
            ])
          : [_newest(prediction, log.history.toList())];
      log
        ..sent = log.history.last.sequence
        ..sentAt = now;
      for (final message in messages) {
        if (!session._send(host, message)) return;
      }
    }
  }

  /// Messages that carry [inputs], consecutive and oldest first, each
  /// within the wire limits.
  List<InputMessage> _messages(
    Prediction<Object?, Object?> prediction,
    List<({int sequence, Uint8List bytes})> inputs,
  ) {
    final messages = <InputMessage>[];
    var start = 0;
    while (start < inputs.length) {
      var count = min(_maxInputsPerMessage, inputs.length - start);
      var message = _message(prediction, inputs.sublist(start, start + count));
      while (count > 1 && !_fits(prediction, message)) {
        count = (count + 1) ~/ 2;
        message = _message(prediction, inputs.sublist(start, start + count));
      }
      messages.add(message);
      start += count;
    }
    return messages;
  }

  /// A message that carries as many of the newest [inputs] as fit, so that
  /// a lost message is repaired by the next one.
  InputMessage _newest(
    Prediction<Object?, Object?> prediction,
    List<({int sequence, Uint8List bytes})> inputs,
  ) {
    var count = min(_maxInputsPerMessage, inputs.length);
    var message = _message(prediction, inputs.sublist(inputs.length - count));
    while (count > 1 && !_fits(prediction, message)) {
      count = (count + 1) ~/ 2;
      message = _message(prediction, inputs.sublist(inputs.length - count));
    }
    return message;
  }

  InputMessage _message(
    Prediction<Object?, Object?> prediction,
    List<({int sequence, Uint8List bytes})> inputs,
  ) => InputMessage(
    entity: prediction.entity.id,
    input: prediction.input.id,
    sequence: inputs.first.sequence,
    values: [for (final input in inputs) _decodeInput(prediction, input.bytes)],
  );

  /// Whether [message] fits the wire limits and, for unreliable delivery,
  /// the transport's limit.
  bool _fits(Prediction<Object?, Object?> prediction, InputMessage message) {
    final Uint8List bytes;
    try {
      bytes = session._codec.encode(
        MessageEnvelope(
          message,
          generation: IntCodec.maxSafe,
          revision: IntCodec.maxSafe,
        ),
      );
    } on ArgumentError {
      return false;
    }
    final maximum = session._peer?.capabilities.maxUnreliableMessageBytes;
    return prediction.input.deliveryMode == DeliveryMode.reliable ||
        maximum == null ||
        bytes.length <= maximum;
  }

  /// Queues the inputs that the client [sender] sent, if it owns the entity
  /// and the host applies its inputs.
  ///
  /// Each input is queued once, in order; inputs that an earlier message
  /// carried are skipped, and missing ones are not waited for. Inputs that
  /// arrive after the host stopped being the entity's authority are
  /// ignored.
  void receive(PeerId sender, InputMessage message) {
    final entity = session.registry[message.entity];
    if (entity == null) {
      _reject(message, sender, InputRejection.unknownEntity);
      return;
    }
    if (entity.state == EntityState.removed) return;
    if (sender != entity.owner) {
      _reject(message, sender, InputRejection.notOwner);
      return;
    }
    if (entity.authority != PeerId.host) return;
    final prediction = _predictions[entity.id];
    if (prediction == null ||
        !_isLive(prediction) ||
        prediction.input.id != message.input) {
      _reject(message, sender, InputRejection.notPredicted);
      return;
    }
    final log = _log(prediction);
    var sequence = message.sequence;
    for (final value in message.values) {
      if (sequence > log.received) {
        log.queue.add((sequence: sequence, value: value));
        log.received = sequence;
      }
      sequence++;
    }
    // Inputs that keep arriving faster than the host may apply them are
    // dropped, oldest first, to bound the delay.
    final limit = 2 * _ticks(prediction.input.tick);
    while (log.queue.length > limit) {
      log.queue.removeFirst();
    }
  }

  /// Applies the queued inputs of the entities whose owners' inputs the
  /// host applies, at most one tick of inputs per tick of its clock, after
  /// a burst of up to a quarter of a second.
  ///
  /// A prediction with an idle input keeps its entity moving while no input
  /// waits: once the host has waited a quarter of a second, it applies the
  /// idle input for each further tick of its clock. When inputs arrive
  /// after that, it applies the newest quarter of a second of them at once
  /// and skips the older ones, which the idle ticks replaced, so that they
  /// do not delay the inputs that follow.
  void simulate() {
    final local = session._localPeer;
    if (local == null) return;
    final lifetime = _lifetime;
    final now = session._clock.now;
    for (final prediction in _predictions.values.toList()) {
      if (_lifetime != lifetime || session._peer == null) return;
      if (!_isLive(prediction) ||
          prediction._role != _PredictionRole.applying) {
        continue;
      }
      final idle = prediction._idle;
      final existing = _logs[prediction.entity];
      if (idle == null &&
          (existing == null || existing.stream != prediction.input.id)) {
        continue;
      }
      final log = _log(prediction);
      final tick = prediction.input.tick.inMicroseconds;
      final burst = tick * _ticks(prediction.input.tick);
      final creditAt = log.creditAt;
      log.credit = creditAt == null
          ? burst
          : min(burst, log.credit + (now - creditAt).inMicroseconds);
      log.creditAt = now;
      if (log.queue.isNotEmpty) {
        // The host waited the whole burst before it idled, so the credit is
        // a full burst: what it cannot apply at once, the idle ticks
        // replaced.
        if (log.idled > 0) {
          final skipped = log.queue.length - max(1, log.credit ~/ tick);
          for (var i = 0; i < skipped; i++) {
            log.applied = log.queue.removeFirst().sequence;
          }
        }
        log
          ..waitingSince = null
          ..idled = 0;
      }
      while (log.queue.isNotEmpty && log.credit >= tick) {
        final input = log.queue.removeFirst();
        log.credit -= tick;
        log.applied = input.sequence;
        prediction._apply(input.value);
        if (_lifetime != lifetime || session._peer == null) return;
        if (!_isLive(prediction)) break;
      }
      if (idle == null || log.queue.isNotEmpty || !_isLive(prediction)) {
        continue;
      }
      final since = log.waitingSince ??= now;
      final due = ((now - since).inMicroseconds - burst) ~/ tick;
      if (due <= log.idled) continue;
      // After a long frame, the ticks beyond a quarter of a second are
      // dropped, as for the owner's.
      final ticks = min(due - log.idled, _ticks(prediction.input.tick));
      log.idled = due;
      for (var i = 0; i < ticks; i++) {
        prediction._apply(_decodeInput(prediction, idle));
        if (_lifetime != lifetime || session._peer == null) return;
        if (!_isLive(prediction)) break;
      }
    }
  }

  /// Adjusts the inputs of [entity] after its authority moved from
  /// [previous] on this peer.
  ///
  /// The host applies inputs only while it is the authority, and the owner
  /// predicts only then, so each drops the inputs it held for that.
  void transferred(NetworkEntity entity, PeerId previous) {
    final log = _logs[entity];
    if (log != null) {
      if (session._isHost) {
        if (entity.authority != PeerId.host) {
          log
            ..queue.clear()
            ..creditAt = null
            ..waitingSince = null
            ..idled = 0;
        }
      } else if (entity.owner == session._localPeer) {
        log.history.clear();
        log.sent = log.next - 1;
      }
    }
    final prediction = _predictions[entity.id];
    if (prediction != null && identical(prediction.entity, entity)) {
      prediction._transferred();
    }
  }

  void _reject(InputMessage message, PeerId sender, InputRejection reason) =>
      session._emit(
        InputRejected(
          entity: message.entity,
          input: message.input,
          sender: sender,
          reason: reason,
        ),
      );
}
