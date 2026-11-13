import 'dart:math';

import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

const _tick = Duration(milliseconds: 50);
const _latency = Duration(milliseconds: 100);

List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

/// Moves one unit per tick in the direction of the input.
double _walk(double position, int input) => position + input;

/// The registrations shared by every session of a test: a mover whose
/// owner's inputs advance its authority-written position.
final class _Schema {
  _Schema() {
    final builder = ProtocolSchemaBuilder();
    mover = builder.addSpawnType(
      const SpawnTypeId('test.mover'),
      const BoolCodec(),
    );
    position = builder.addField(
      const FieldId('test.position'),
      const DoubleCodec(min: -1000, max: 1000),
    );
    aim = builder.addField(
      const FieldId('test.aim'),
      const IntCodec(min: -1, max: 1),
      writer: FieldWriter.owner,
    );
    move = builder.addInput(
      const InputId('test.move'),
      const IntCodec(min: -1, max: 1),
      tick: _tick,
    );
    nudge = builder.addInput(
      const InputId('test.nudge'),
      const IntCodec(min: -1, max: 1),
      tick: _tick,
      deliveryMode: DeliveryMode.unreliable,
      channel: 1,
    );
    board = builder.addStaticEntity(const StaticEntityId('test.board'));
    schema = builder.build();
  }

  late final SpawnType<bool> mover;
  late final SyncField<double> position;
  late final SyncField<int> aim;
  late final InputStream<int> move;
  late final InputStream<int> nudge;
  late final StaticEntity board;
  late final ProtocolSchema schema;
}

/// One peer's copy of a mover, which predicts its position from its owner's
/// inputs.
final class _Mover {
  _Mover(this.session, this.entity, this.harness) {
    attach();
  }

  final MultiplayerSession session;
  final NetworkEntity entity;
  final _Harness harness;
  late EntityAttachment attachment;
  late Prediction<double, int> prediction;
  late MultiplayerSynchronizer synchronizer;

  /// The input that the owner applies each frame while it [drives].
  var input = 0;

  /// Whether the owner advances its prediction each frame.
  var drives = false;

  bool get owns => entity.owner == session.localPeer;

  void attach({double initial = 0}) {
    attachment = session.attachEntity(
      entity,
      isReady: () => true,
      isValid: () => true,
    );
    prediction = attachment.predict(
      state: harness.schema.position,
      input: harness.unreliable ? harness.schema.nudge : harness.schema.move,
      initial: initial,
      step: session.isHost ? harness.hostStep : harness.step,
      interpolator: harness.interpolator,
      smoothing: harness.smoothing,
    );
    synchronizer = attachment.synchronize([
      prediction.property(),
    ], interval: _tick);
  }

  /// Replaces the attachment and its prediction, as a remounted component
  /// does.
  void remount() {
    final state = prediction.state;
    attachment.dispose();
    attach(initial: state);
  }
}

/// A host and the clients that join it over an in-memory network with two
/// channels, each with a mover for every spawned entity.
final class _Harness {
  _Harness({
    Duration latency = Duration.zero,
    this.step = _walk,
    PredictionStep<double, int>? hostStep,
    this.interpolator,
    this.unreliable = false,
    int? maxUnreliableMessageBytes,
    this.backpressure = const QueueLimits(
      maxMessages: 256,
      maxBytes: 1024 * 1024,
    ),
  }) : hostStep = hostStep ?? step {
    network = InMemoryNetwork(
      clock: clock,
      latency: latency,
      deliveryModes: DeliveryMode.values.toSet(),
      channelCount: 2,
      maxUnreliableMessageBytes: maxUnreliableMessageBytes,
    );
    host = _session()..host(network.host());
  }

  /// The owner's step, and the host's.
  final PredictionStep<double, int> step;
  final PredictionStep<double, int> hostStep;
  final Interpolator<double>? interpolator;

  /// How long a correction takes to blend out: two ticks.
  final smoothing = const Duration(milliseconds: 100);

  /// Whether inputs use the unreliable stream on channel one.
  final bool unreliable;
  final QueueLimits backpressure;
  final clock = ManualClock();
  final schema = _Schema();
  late final InMemoryNetwork network;
  late final MultiplayerSession host;
  final sessions = <MultiplayerSession>[];
  final _raw = <_RawClient>[];
  final _movers = <MultiplayerSession, Map<EntityId, _Mover>>{};

  /// The applied inputs that the state messages each session accepted
  /// reported.
  final reported = <MultiplayerSession, List<int?>>{};

  MultiplayerSession _session() {
    late final MultiplayerSession session;
    session = MultiplayerSession(
      schema: schema.schema,
      clock: clock,
      stateBackpressure: backpressure,
      onMessage: (sender, envelope) => (reported[session] ??= []).add(
        (envelope.message as StateMessage).inputSequence,
      ),
    );
    addTearDown(session.close);
    sessions.add(session);
    session.bindSpawn(
      schema.mover,
      onSpawn: (context) => (_movers[session] ??= {})[context.entity.id] =
          _Mover(session, context.entity, this),
    );
    return session;
  }

  /// Joins a new client and runs frames until it is ready.
  MultiplayerSession join() {
    final session = _session()..join(network.connect());
    until(() => session.state == SessionState.ready);
    return session;
  }

  /// Joins a client that speaks the protocol directly and reports ready.
  _RawClient rawClient() {
    final client = _RawClient(network.connect(), ProtocolCodec(schema.schema));
    _raw.add(client);
    until(() => client.connection != null);
    client.send(HelloMessage(fingerprint: schema.schema.fingerprint));
    until(() => client.id != null);
    client.ready();
    until(() => host.isReady(client.id!));
    return client;
  }

  /// Spawns a mover owned by [owner] and runs frames until every session
  /// has it.
  NetworkEntity spawn(
    PeerId owner, {
    PeerId authority = PeerId.host,
    OwnerLeftPolicy onOwnerLeft = OwnerLeftPolicy.keep,
  }) {
    final entity = host.spawn(
      schema.mover,
      true,
      owner: owner,
      authority: authority,
      onOwnerLeft: onOwnerLeft,
    );
    until(
      () => sessions.every(
        (session) =>
            session.state == SessionState.disconnected ||
            (_movers[session]?.containsKey(entity.id) ?? false),
      ),
    );
    return entity;
  }

  /// [session]'s mover of [entity].
  _Mover mover(MultiplayerSession session, NetworkEntity entity) =>
      _movers[session]![entity.id]!;

  /// Runs one frame of [elapsed]: the clock advances, every session that is
  /// not [stalled] updates, each owner that drives its mover advances its
  /// prediction, and every session captures state.
  void frame([
    Duration elapsed = _tick,
    Set<MultiplayerSession> stalled = const {},
  ]) {
    clock.advance(elapsed);
    for (final client in _raw) {
      client.update();
    }
    for (final session in sessions) {
      if (!stalled.contains(session)) session.update();
    }
    for (final session in sessions) {
      for (final mover in [...?_movers[session]?.values]) {
        if (mover.drives && mover.owns && !mover.prediction.isDisposed) {
          mover.prediction.advance(mover.input, elapsed);
        }
      }
    }
    for (final session in sessions) {
      session.captureState();
    }
  }

  void frames(int count, {Set<MultiplayerSession> stalled = const {}}) {
    for (var i = 0; i < count; i++) {
      frame(_tick, stalled);
    }
  }

  /// Runs frames until [done] holds, failing after [limit] frames.
  void until(bool Function() done, {int limit = 200}) {
    for (var i = 0; i < limit; i++) {
      if (done()) return;
      frame();
    }
    if (!done()) fail('The condition did not hold within $limit frames.');
  }
}

/// A client that speaks the protocol directly, to send what a session would
/// not.
final class _RawClient {
  _RawClient(this.peer, this.codec);

  final InMemoryClient peer;
  final ProtocolCodec codec;
  PeerConnection? connection;
  PeerId? id;
  var generation = 0;
  var baseline = 0;
  final received = <MessageEnvelope>[];

  void update() {
    for (var event = peer.poll(); event != null; event = peer.poll()) {
      switch (event) {
        case ConnectionOpened(:final connection):
          this.connection = connection;
        case MessageReceived(:final message):
          for (final envelope in codec.decodePacket(message)) {
            if (envelope.message case WelcomeMessage(:final peer)) {
              id = peer;
              generation = envelope.generation;
              baseline = envelope.revision;
            }
            received.add(envelope);
          }
        case ConnectionClosed():
          break;
      }
    }
  }

  void send(
    ProtocolMessage message, {
    DeliveryMode mode = DeliveryMode.reliable,
    int channel = 0,
    int revision = 0,
  }) => connection!.send(
    codec.encode(
      MessageEnvelope(message, generation: generation, revision: revision),
    ),
    mode: mode,
    channel: channel,
  );

  void ready() => send(const ReadyMessage(), revision: baseline);

  /// Sends [values] of the move stream for [entity], numbered from
  /// [sequence].
  void sendInputs(NetworkEntity entity, int sequence, List<int> values) => send(
    InputMessage(
      entity: entity.id,
      input: const InputId('test.move'),
      sequence: sequence,
      values: values,
    ),
  );

  /// The applied inputs that the state messages this client received
  /// reported.
  List<int?> get reported => [
    for (final envelope in received)
      if (envelope.message case StateMessage(:final inputSequence))
        inputSequence,
  ];
}

void main() {
  group('the owner', () {
    test('sees its input at once and converges with the host', () {
      final harness = _Harness(latency: _latency);
      final owner = harness.join();
      final observer = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final mine = harness.mover(owner, entity);
      final hosted = harness.mover(harness.host, entity);
      final seen = harness.mover(observer, entity);

      mine
        ..input = 1
        ..drives = true;
      harness.frame();

      expect(mine.prediction.state, 1);
      expect(mine.prediction.pendingInputs, 1);
      expect(hosted.prediction.state, 0);

      harness.frames(9);
      expect(mine.prediction.state, 10);
      expect(hosted.prediction.state, lessThan(10));

      mine.drives = false;
      harness.until(
        () => mine.prediction.pendingInputs == 0 && seen.prediction.state == 10,
      );
      expect(hosted.prediction.state, 10);
      expect(mine.prediction.state, 10);
      expect(hosted.prediction.pendingInputs, 0);
    });

    test('keeps a prediction that the host confirms', () {
      final harness = _Harness(latency: _latency);
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final mine = harness.mover(owner, entity)
        ..input = 1
        ..drives = true;

      final states = <double>[];
      for (var i = 0; i < 20; i++) {
        harness.frame();
        states.add(mine.prediction.state);
      }

      // Reconciling with each state from the host, which trails by the
      // round trip, applies the inputs it does not include again.
      expect(states, [for (var i = 1; i <= 20; i++) i.toDouble()]);
      final reported = harness.reported[owner]!.whereType<int>().toList();
      expect(reported, isNotEmpty);
      expect(reported, orderedEquals([...reported]..sort()));
      expect(reported.last, lessThan(20));
    });

    test('corrects a misprediction to the host state', () {
      final harness = _Harness(
        hostStep: (position, input) {
          return min(position + input, 3);
        },
      );
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final mine = harness.mover(owner, entity)
        ..input = 1
        ..drives = true;
      final hosted = harness.mover(harness.host, entity);

      // The owner predicts past the host's wall until the host's state
      // that includes the step into it arrives, two frames later.
      harness.frames(4);
      expect(mine.prediction.state, 4);
      expect(hosted.prediction.state, 3);
      mine.input = 0;
      harness.until(() => mine.prediction.state == 3);
      mine.drives = false;
      harness.until(() => mine.prediction.pendingInputs == 0);

      expect(hosted.prediction.state, 3);
      expect(mine.prediction.state, 3);
      expect(mine.prediction.presented, 3);
    });

    test('blends a correction out over the smoothing time', () {
      List<(double, double)> run({Interpolator<double>? interpolator}) {
        final harness = _Harness(
          hostStep: (position, input) => min(position + input, 2),
          interpolator: interpolator,
        );
        final owner = harness.join();
        final entity = harness.spawn(owner.localPeer!);
        final mine = harness.mover(owner, entity)
          ..input = 1
          ..drives = true;
        final frames = <(double, double)>[];
        for (var i = 0; i < 8; i++) {
          if (i == 4) mine.input = 0;
          harness.frame();
          frames.add((mine.prediction.state, mine.prediction.presented));
        }
        return frames;
      }

      // Each frame covers one tick, so the presented state blends from the
      // previous tick. The host stops the mover at 2, two ticks before the
      // owner's prediction does: the correction blends out over two ticks
      // while the prediction already shows the host's state.
      expect(run(interpolator: const DoubleInterpolator()), [
        (1, 0),
        (2, 1),
        (3, 2),
        (4, 3),
        (3, 3.5),
        (2, 2.75),
        (2, 2),
        (2, 2),
      ]);
      // Without an interpolator, the prediction shows each correction at
      // once.
      expect(run(), [
        (1, 1),
        (2, 2),
        (3, 3),
        (4, 4),
        (3, 3),
        (2, 2),
        (2, 2),
        (2, 2),
      ]);
      // A correction that the interpolator treats as a teleport shows at
      // once.
      expect(
        run(interpolator: const DoubleInterpolator(teleportDistance: 0.5))[4],
        (3, 3),
      );
    });

    test('blends between the states of the last two ticks', () {
      final harness = _Harness(interpolator: const DoubleInterpolator());
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final prediction = harness.mover(owner, entity).prediction;
      const quarter = Duration(milliseconds: 25);

      expect(prediction.advance(1, quarter), 0);
      expect(prediction.state, 0);
      expect(prediction.advance(1, _tick), 0.5);
      expect(prediction.state, 1);
      expect(prediction.advance(1, quarter), 1);
      expect(prediction.state, 2);
      expect(prediction.pendingInputs, 2);
    });

    test('runs at most a quarter of a second of ticks per call', () {
      final harness = _Harness();
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final prediction = harness.mover(owner, entity).prediction;

      prediction.advance(1, const Duration(seconds: 2));

      expect(prediction.state, 5);
      expect(prediction.pendingInputs, 5);
      prediction.advance(1, const Duration(milliseconds: 49));
      expect(prediction.state, 5);
    });

    test('rejects input that cannot be sent and changes nothing', () {
      final harness = _Harness();
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final prediction = harness.mover(owner, entity).prediction;

      expect(() => prediction.advance(2, _tick), throwsArgumentError);
      expect(
        () => prediction.advance(1, const Duration(microseconds: -1)),
        throwsArgumentError,
      );
      expect(prediction.state, 0);
      expect(prediction.pendingInputs, 0);
    });

    test('rethrows a failed step without sending its input', () {
      final harness = _Harness(
        step: (position, input) =>
            input < 0 ? throw StateError('blocked') : position + input,
      );
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final prediction = harness.mover(owner, entity).prediction;
      final hosted = harness.mover(harness.host, entity).prediction;

      prediction.advance(1, _tick);
      expect(() => prediction.advance(-1, _tick), throwsStateError);
      harness.until(() => prediction.pendingInputs == 0);

      expect(prediction.state, 1);
      expect(hosted.state, 1);
    });

    test('sends unreliable inputs again until the host has them', () {
      final harness = _Harness(unreliable: true);
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final mine = harness.mover(owner, entity)
        ..input = 1
        ..drives = true;
      final hosted = harness.mover(harness.host, entity);

      harness.network.dropNextUnreliable(count: 3, fromHost: false);
      harness.frames(6);
      // The last message before the owner stops is lost too.
      harness.network.dropNextUnreliable(fromHost: false);
      harness.frame();
      mine.drives = false;
      harness.until(() => mine.prediction.pendingInputs == 0);

      // Every input reached the host exactly once.
      expect(hosted.prediction.state, 7);
      expect(mine.prediction.state, 7);
    });

    test('fits unreliable inputs within the transport limit', () {
      final harness = _Harness(
        latency: const Duration(milliseconds: 300),
        unreliable: true,
        maxUnreliableMessageBytes: 48,
      );
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final mine = harness.mover(owner, entity)
        ..input = 1
        ..drives = true;
      final hosted = harness.mover(harness.host, entity);

      harness.frames(30);
      mine.drives = false;
      harness.until(() => mine.prediction.pendingInputs == 0);

      expect(hosted.prediction.state, 30);
      expect(mine.prediction.state, 30);
    });

    test('continues the numbering of a replaced prediction', () {
      final harness = _Harness(latency: _latency);
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final mine = harness.mover(owner, entity)
        ..input = 1
        ..drives = true;
      final hosted = harness.mover(harness.host, entity);

      harness.frames(5);
      mine.remount();
      harness.frames(5);
      mine.drives = false;
      harness.until(() => mine.prediction.pendingInputs == 0);

      expect(hosted.prediction.state, 10);
      expect(mine.prediction.state, 10);
    });

    test('only the owner advances its prediction', () {
      final harness = _Harness();
      final owner = harness.join();
      final observer = harness.join();
      final entity = harness.spawn(owner.localPeer!);

      expect(
        () => harness.mover(harness.host, entity).prediction.advance(1, _tick),
        throwsStateError,
      );
      expect(
        () => harness.mover(observer, entity).prediction.advance(1, _tick),
        throwsStateError,
      );
    });

    test('has no effect once disposed', () {
      final harness = _Harness();
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final prediction = harness.mover(owner, entity).prediction..dispose();

      expect(prediction.isDisposed, isTrue);
      expect(prediction.advance(1, _tick), 0);
      expect(prediction.state, 0);
      expect(prediction.pendingInputs, 0);
    });
  });

  group('the host', () {
    test('waits for inputs instead of repeating one', () {
      final harness = _Harness();
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final mine = harness.mover(owner, entity)
        ..input = 1
        ..drives = true;
      final hosted = harness.mover(harness.host, entity);

      harness.frames(3);
      mine.drives = false;
      harness.frames(20);

      expect(hosted.prediction.state, 3);
      expect(mine.prediction.state, 3);
    });

    test('applies at most one tick of inputs per tick of its clock', () {
      final harness = _Harness();
      final client = harness.rawClient();
      final entity = harness.spawn(client.id!);
      final hosted = harness.mover(harness.host, entity).prediction;

      client.sendInputs(entity, 1, List.filled(20, 1));
      harness.frame(Duration.zero);

      // The host keeps the newest inputs that may wait, ten ticks' worth,
      // and applies a burst of a quarter of a second at once.
      expect(hosted.state, 5);
      expect(hosted.pendingInputs, 5);
      harness.frame(Duration.zero);
      expect(hosted.state, 5);
      harness.frame();
      expect(hosted.state, 6);
      harness.frames(10);
      expect(hosted.state, 10);
      expect(hosted.pendingInputs, 0);
      expect(client.reported.last, 20);
    });

    test('applies each input once', () {
      final harness = _Harness();
      final client = harness.rawClient();
      final entity = harness.spawn(client.id!);
      final hosted = harness.mover(harness.host, entity).prediction;

      client
        ..sendInputs(entity, 1, [1, 1, 1])
        ..sendInputs(entity, 2, [1, 1, 1])
        ..sendInputs(entity, 6, [-1]);
      harness.frames(3);

      // Inputs 1 to 4 apply once; input 5 never arrives and is skipped.
      expect(hosted.state, 3);
      expect(client.reported.last, 6);
    });

    test('handles the largest input numbers', () {
      final harness = _Harness();
      final client = harness.rawClient();
      final entity = harness.spawn(client.id!);
      final hosted = harness.mover(harness.host, entity).prediction;

      client.sendInputs(entity, IntCodec.maxSafe - 1, [1, 1]);
      harness.frames(2);
      client.sendInputs(entity, 1, [1]);
      harness.frames(2);

      expect(hosted.state, 2);
      expect(client.reported.last, IntCodec.maxSafe);
      expect(harness.host.state, SessionState.hosting);
      expect(harness.host.isReady(client.id!), isTrue);
      expect(_drain(harness.host).whereType<PropertySyncFailed>(), isEmpty);
    });

    test('rejects inputs that it does not apply', () {
      final harness = _Harness();
      final client = harness.rawClient();
      final hostOwned = harness.spawn(PeerId.host);
      final owned = harness.spawn(client.id!);
      _drain(harness.host);

      client
        ..sendInputs(hostOwned, 1, [1])
        ..send(
          InputMessage(
            entity: const EntityId(999),
            input: const InputId('test.move'),
            sequence: 1,
            values: const [1],
          ),
        )
        ..send(
          InputMessage(
            entity: owned.id,
            input: const InputId('test.nudge'),
            sequence: 1,
            values: const [1],
          ),
          mode: DeliveryMode.unreliable,
          channel: 1,
        );
      harness.frame();
      harness.mover(harness.host, owned).prediction.dispose();
      client.sendInputs(owned, 1, [1]);
      harness.frame();

      expect(
        [
          for (final event in _drain(harness.host))
            if (event case InputRejected(
              :final entity,
              :final input,
              :final sender,
              :final reason,
            ))
              (entity, input, sender, reason),
        ],
        [
          (
            hostOwned.id,
            const InputId('test.move'),
            client.id!,
            InputRejection.notOwner,
          ),
          (
            const EntityId(999),
            const InputId('test.move'),
            client.id!,
            InputRejection.unknownEntity,
          ),
          (
            owned.id,
            const InputId('test.nudge'),
            client.id!,
            InputRejection.notPredicted,
          ),
          (
            owned.id,
            const InputId('test.move'),
            client.id!,
            InputRejection.notPredicted,
          ),
        ],
      );
      expect(harness.mover(harness.host, hostOwned).prediction.state, 0);
    });

    test('reports the latest applied input with state it held', () {
      final harness = _Harness(backpressure: const QueueLimits(maxMessages: 2));
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final mine = harness.mover(owner, entity)
        ..input = 1
        ..drives = true;
      final hosted = harness.mover(harness.host, entity);
      harness.frames(3);

      // The owner keeps sending inputs but stops polling, so the host holds
      // its state for the owner, each sample replacing the previous one.
      harness.frames(6, stalled: {owner});
      expect(harness.host.diagnostics.coalescedStates, greaterThan(0));
      mine.drives = false;
      harness.until(() => mine.prediction.pendingInputs == 0);

      expect(hosted.prediction.state, 9);
      expect(mine.prediction.state, 9);
      expect(harness.reported[owner]!.last, 9);
    });

    test('drops a client that reports applied inputs', () {
      final harness = _Harness();
      final client = harness.rawClient();
      final entity = harness.spawn(client.id!);
      _drain(harness.host);

      client.send(
        StateMessage(
          entity: entity.id,
          values: {harness.schema.aim.id: 1},
          sampledAt: Duration.zero,
          inputSequence: 1,
        ),
      );
      harness.frame();

      expect(
        _drain(harness.host),
        contains(PeerLeft(client.id!, DisconnectReason.protocolViolation)),
      );
    });

    test('reports a failed step and keeps applying inputs', () {
      final harness = _Harness(
        hostStep: (position, input) =>
            input < 0 ? throw StateError('blocked') : position + input,
        step: (position, input) => input < 0 ? position : position + input,
      );
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final mine = harness.mover(owner, entity).prediction;
      final hosted = harness.mover(harness.host, entity).prediction;
      _drain(harness.host);

      mine
        ..advance(1, _tick)
        ..advance(-1, _tick)
        ..advance(1, _tick);
      harness.until(() => mine.pendingInputs == 0);

      expect(hosted.state, 2);
      expect(mine.state, 2);
      expect(
        _drain(harness.host).whereType<PropertySyncFailed>().single.field,
        harness.schema.position.id,
      );
    });
  });

  group('the authority', () {
    test('sets the state, and the owner jumps to it', () {
      final harness = _Harness(
        latency: _latency,
        interpolator: const DoubleInterpolator(teleportDistance: 50),
      );
      final owner = harness.join();
      final observer = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final mine = harness.mover(owner, entity)
        ..input = 1
        ..drives = true;
      final hosted = harness.mover(harness.host, entity);
      final seen = harness.mover(observer, entity);

      harness.frames(5);
      final applied = hosted.prediction.state;
      hosted.prediction.state = 500;
      expect(hosted.prediction.state, 500);
      expect(hosted.prediction.presented, 500);

      final presented = <double>[];
      for (var i = 0; i < 10; i++) {
        harness.frame();
        presented.add(mine.prediction.presented);
      }
      mine.drives = false;
      harness.until(
        () =>
            mine.prediction.pendingInputs == 0 &&
            seen.prediction.state == hosted.prediction.state,
      );

      // The owner predicts on from where it was until the host's state
      // arrives, two frames later, and then shows it at once, with the
      // inputs that the host has not applied yet: the change is a teleport.
      expect(presented.takeWhile((value) => value < 50), hasLength(2));
      expect(
        presented.skipWhile((value) => value < 50),
        everyElement(greaterThanOrEqualTo(500)),
      );
      expect(hosted.prediction.state, 500 + 15 - applied);
      expect(mine.prediction.state, hosted.prediction.state);
    });

    test('is the only peer that sets the state', () {
      final harness = _Harness();
      final owner = harness.join();
      final observer = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final mine = harness.mover(owner, entity);
      final hosted = harness.mover(harness.host, entity).prediction;

      expect(() => mine.prediction.state = 1, throwsStateError);
      expect(
        () => harness.mover(observer, entity).prediction.state = 1,
        throwsStateError,
      );
      expect(() => hosted.state = 2000, throwsArgumentError);
      expect(hosted.state, 0);

      // An owner that becomes the authority sets the state, and the host
      // follows it.
      harness.host.transferAuthority(entity, owner.localPeer!);
      harness.until(() => mine.entity.authority == owner.localPeer);
      mine.prediction.state = 7;
      expect(mine.prediction.state, 7);
      expect(() => hosted.state = 1, throwsStateError);
      harness.until(() => hosted.state == 7);

      mine.prediction
        ..dispose()
        ..state = 9;
      expect(mine.prediction.state, 7);
    });
  });

  group('every other peer', () {
    test('follows the state, interpolated by the prediction', () {
      final harness = _Harness(
        latency: _latency,
        interpolator: const DoubleInterpolator(),
      );
      final owner = harness.join();
      final observer = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      harness.mover(owner, entity)
        ..input = 1
        ..drives = true;
      final seen = harness.mover(observer, entity).prediction;

      final presented = <double>[];
      for (var i = 0; i < 20; i++) {
        harness.frame();
        presented.add(seen.presented);
      }

      expect(seen.state, greaterThan(0));
      expect(seen.pendingInputs, 0);
      expect(presented, orderedEquals([...presented]..sort()));
      expect(presented.last, lessThan(seen.state));
      expect(
        harness.mover(harness.host, entity).prediction.presented,
        isA<double>(),
      );
    });

    test('a joining client starts from the latest state', () {
      final harness = _Harness();
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final mine = harness.mover(owner, entity)
        ..input = 1
        ..drives = true;
      harness.frames(5);
      mine.drives = false;
      harness.until(() => mine.prediction.pendingInputs == 0);

      final late = harness.join();

      expect(harness.mover(late, entity).prediction.state, 5);
      expect(harness.reported[late], contains(5));
    });

    test('the host advances an entity that it owns directly', () {
      final harness = _Harness();
      final client = harness.join();
      final entity = harness.spawn(PeerId.host);
      final hosted = harness.mover(harness.host, entity)
        ..input = 1
        ..drives = true;

      harness.frames(4);
      hosted.drives = false;
      harness.frames(2);

      expect(hosted.prediction.state, 4);
      expect(hosted.prediction.pendingInputs, 0);
      expect(harness.mover(client, entity).prediction.state, 4);
      expect(harness.reported[client]!.whereType<int>(), isEmpty);
    });
  });

  group('authority transfer', () {
    test('an owner that becomes the authority keeps its prediction', () {
      final harness = _Harness(latency: _latency);
      final owner = harness.join();
      final observer = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final mine = harness.mover(owner, entity)
        ..input = 1
        ..drives = true;

      final states = <double>[];
      for (var i = 0; i < 20; i++) {
        if (i == 5) harness.host.transferAuthority(entity, owner.localPeer!);
        harness.frame();
        states.add(mine.prediction.state);
      }

      expect(states, [for (var i = 1; i <= 20; i++) i.toDouble()]);
      expect(entity.authority, owner.localPeer);
      mine.drives = false;
      harness.until(
        () =>
            harness.mover(harness.host, entity).prediction.state == 20 &&
            harness.mover(observer, entity).prediction.state == 20,
      );
      expect(mine.prediction.pendingInputs, 0);
    });

    test('the host continues from the state it accepted from the owner', () {
      final harness = _Harness(latency: _latency);
      final owner = harness.join();
      final entity = harness.spawn(
        owner.localPeer!,
        authority: owner.localPeer!,
      );
      final mine = harness.mover(owner, entity)
        ..input = 1
        ..drives = true;
      final hosted = harness.mover(harness.host, entity);

      harness.frames(10);
      harness.host.transferAuthority(entity, PeerId.host);
      harness.frames(10);
      mine.drives = false;
      harness.until(
        () =>
            mine.prediction.pendingInputs == 0 &&
            hosted.prediction.state == mine.prediction.state,
      );

      // The owner loses the steps it took after the last state that the
      // host accepted, and every later input applies once.
      expect(mine.prediction.state, greaterThan(10));
      expect(mine.prediction.state, lessThanOrEqualTo(20));
    });

    test('the owner pauses while another client is the authority', () {
      final harness = _Harness();
      final owner = harness.join();
      final other = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final mine = harness.mover(owner, entity)
        ..input = 1
        ..drives = true;
      final hosted = harness.mover(harness.host, entity);

      harness.frames(3);
      harness.host.transferAuthority(entity, other.localPeer!);
      harness.frames(3);
      final paused = mine.prediction.state;
      harness.frames(5);

      expect(mine.prediction.state, paused);
      expect(mine.prediction.pendingInputs, 0);
      expect(hosted.prediction.pendingInputs, 0);
      expect(harness.mover(other, entity).prediction.state, paused);

      harness.host.transferAuthority(entity, PeerId.host);
      harness.frames(5);
      mine.drives = false;
      harness.until(() => mine.prediction.pendingInputs == 0);

      expect(mine.prediction.state, greaterThan(paused));
      expect(hosted.prediction.state, mine.prediction.state);
    });
  });

  group('lifecycle', () {
    test('predictions end with their entity and session', () {
      final harness = _Harness();
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);

      expect(harness.host.diagnostics.predictions, 1);
      expect(owner.diagnostics.predictions, 1);

      harness.host.despawn(entity);
      harness.frames(2);

      expect(harness.host.diagnostics.predictions, 0);
      expect(owner.diagnostics.predictions, 0);
      expect(harness.mover(owner, entity).prediction.isDisposed, isTrue);
    });

    test('the host keeps an entity whose owner left', () {
      final harness = _Harness();
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final hosted = harness.mover(harness.host, entity).prediction;
      harness.mover(owner, entity)
        ..input = 1
        ..drives = true;

      harness.frames(3);
      owner.close();
      harness.frames(5);

      expect(entity.state, isNot(EntityState.removed));
      expect(hosted.isDisposed, isFalse);
      expect(hosted.state, 3);
      expect(hosted.pendingInputs, 0);
    });

    test('validates predictions and their synchronizers', () {
      final harness = _Harness();
      final schema = harness.schema;
      final board = harness.host.staticEntity(schema.board);
      EntityAttachment attach() => harness.host.attachEntity(
        board,
        isReady: () => true,
        isValid: () => true,
      );

      final attachment = attach();
      Prediction<double, int> predict({
        SyncField<double>? state,
        InputStream<int>? input,
        double initial = 0,
        Duration smoothing = Duration.zero,
      }) => attachment.predict(
        state: state ?? schema.position,
        input: input ?? schema.move,
        initial: initial,
        step: _walk,
        smoothing: smoothing,
      );

      expect(
        () => attachment.predict(
          state: schema.aim,
          input: schema.move,
          initial: 0,
          step: (aim, input) => input,
        ),
        throwsArgumentError,
      );
      expect(
        () => predict(
          state: const SyncField(
            id: FieldId('test.position'),
            codec: DoubleCodec(min: -1000, max: 1000),
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => predict(
          input: const InputStream(
            id: InputId('test.move'),
            codec: IntCodec(min: -1, max: 1),
            tick: _tick,
          ),
        ),
        throwsArgumentError,
      );
      expect(() => predict(initial: 2000), throwsArgumentError);
      expect(
        () => predict(smoothing: const Duration(microseconds: -1)),
        throwsArgumentError,
      );

      final prediction = predict();
      expect(predict, throwsStateError);
      expect(
        () => attachment.synchronize([schema.position.property(get: () => 0)]),
        throwsArgumentError,
      );
      final synchronizer = attachment.synchronize([prediction.property()]);
      expect(synchronizer.isDisposed, isFalse);

      attachment.dispose();
      expect(prediction.isDisposed, isTrue);
      final next = attach();
      expect(
        () => next.synchronize([prediction.property()]),
        throwsArgumentError,
      );
      next.synchronize([schema.position.property(get: () => 0)]);
      expect(
        () => next.predict(
          state: schema.position,
          input: schema.move,
          initial: 0.0,
          step: _walk,
        ),
        throwsStateError,
      );
    });
  });
}
