import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

const _ms = Duration(milliseconds: 1);
const _interval = Duration(milliseconds: 50);
const _client1 = PeerId(2);

Matcher _shows(double value, InterpolationState state) =>
    isA<InterpolatedValue<double>>()
        .having((shown) => shown.value, 'value', closeTo(value, 1e-9))
        .having((shown) => shown.state, 'state', state);

/// A mutable two-dimensional point, like a vector.
final class _Point {
  _Point(this.x, this.y);

  double x;
  double y;
}

final class _PointCodec extends ValueCodec<_Point> {
  const _PointCodec();

  static const _axis = DoubleCodec();

  @override
  String get descriptor => 'test.point@1';

  @override
  Object? encode(_Point value) => [
    _axis.encode(value.x),
    _axis.encode(value.y),
  ];

  @override
  _Point decode(Object? wire) {
    final list = wire! as List<Object?>;
    return _Point(_axis.decode(list[0]), _axis.decode(list[1]));
  }
}

final class _PointInterpolator extends Interpolator<_Point> {
  const _PointInterpolator();

  @override
  _Point lerp(_Point from, _Point to, double t) =>
      _Point(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
}

/// The registrations shared by every session of a test.
final class _Schema {
  _Schema() {
    final builder = ProtocolSchemaBuilder();
    x = builder.addField(const FieldId('test.x'), const DoubleCodec());
    label = builder.addField(
      const FieldId('test.label'),
      const StringCodec(maxLength: 16),
    );
    point = builder.addField(const FieldId('test.point'), const _PointCodec());
    schema = builder.build();
  }

  late final SyncField<double> x;
  late final SyncField<String> label;
  late final SyncField<_Point> point;
  late final ProtocolSchema schema;
}

/// One peer's view of an entity whose `x` is interpolated.
final class _Avatar {
  _Avatar(
    this.session,
    NetworkEntity entity,
    this.schema, {
    Interpolator<double> interpolator = const DoubleInterpolator(),
    Duration? delay,
  }) {
    attachment = session.attachEntity(
      entity,
      isReady: () => true,
      isValid: () => true,
    );
    synchronizer = attachment.synchronize(
      [
        schema.x.property(
          get: () => x,
          set: (value) {
            x = value;
            applied.add(value);
          },
          interpolator: interpolator,
        ),
        schema.label.property(get: () => label, set: (value) => label = value),
      ],
      interval: _interval,
      interpolationDelay: delay,
    );
  }

  final MultiplayerSession session;
  final _Schema schema;
  late final EntityAttachment attachment;
  late final MultiplayerSynchronizer synchronizer;
  var x = 0.0;
  var label = '';
  final applied = <double>[];

  InterpolatedValue<double>? get shown => synchronizer.interpolated(schema.x);
}

/// A host and the clients that join it over an in-memory network.
final class _Harness {
  _Harness() {
    network = InMemoryNetwork(clock: clock);
    host = _session()..host(network.host());
  }

  final clock = ManualClock();
  final schema = _Schema();
  late final InMemoryNetwork network;
  late final MultiplayerSession host;
  final sessions = <MultiplayerSession>[];

  MultiplayerSession _session() {
    final session = MultiplayerSession(schema: schema.schema, clock: clock);
    addTearDown(session.close);
    sessions.add(session);
    return session;
  }

  (MultiplayerSession, InMemoryClient) join() {
    final peer = network.connect();
    return (_session()..join(peer), peer);
  }

  /// Registers static entity [id] on every session, in session order.
  List<NetworkEntity> register(
    int id, {
    PeerId owner = PeerId.host,
    PeerId authority = PeerId.host,
  }) => [
    for (final session in sessions)
      session.registry.register(
        EntityId(id),
        owner: owner,
        authority: authority,
      ),
  ];

  /// Delivers everything in transit and updates every session except the
  /// [stalled] ones.
  void settle({Set<MultiplayerSession> stalled = const {}}) {
    for (var i = 0; i < 6; i++) {
      clock.advance(Duration.zero);
      for (final session in sessions) {
        if (!stalled.contains(session)) session.update();
      }
    }
  }

  /// Moves the clock to [at], where [writer]'s authority samples [x], and
  /// delivers the sample.
  void sample(_Avatar writer, double x, {required Duration at}) {
    clock.advance(at - clock.now);
    writer.x = x;
    writer.session.captureState();
    settle();
  }

  /// Moves the clock to [at] and reads the value [reader] presents.
  InterpolatedValue<double>? showAt(_Avatar reader, Duration at) {
    clock.advance(at - clock.now);
    return reader.shown;
  }
}

void main() {
  test('blends between samples a delay behind the newest', () {
    final harness = _Harness();
    final (client, _) = harness.join();
    harness.settle();
    final [onHost, onClient] = harness.register(1);
    final writer = _Avatar(harness.host, onHost, harness.schema);
    final reader = _Avatar(client, onClient, harness.schema);
    expect(reader.shown, isNull);

    harness
      ..sample(writer, 0, at: Duration.zero)
      ..sample(writer, 10, at: _ms * 50)
      ..sample(writer, 20, at: _ms * 100);

    // Authoritative state arrives at once; presentation trails it.
    expect(reader.applied, [0, 10, 20]);
    expect(reader.synchronizer.snapshot(harness.schema.x)!.value, 20);
    expect(reader.synchronizer.interpolationDelay, _interval * 2);
    for (final (at, value, state) in [
      (100, 0.0, InterpolationState.interpolating),
      (125, 5.0, InterpolationState.interpolating),
      (150, 10.0, InterpolationState.interpolating),
      (175, 15.0, InterpolationState.interpolating),
      (200, 20.0, InterpolationState.holding),
      (300, 20.0, InterpolationState.holding),
    ]) {
      expect(
        harness.showAt(reader, _ms * at),
        _shows(value, state),
        reason: '$at ms',
      );
    }
    expect(reader.x, 20);
  });

  test('holds the newest value, then resumes over one interval', () {
    final harness = _Harness();
    final (client, _) = harness.join();
    harness.settle();
    final [onHost, onClient] = harness.register(1);
    final writer = _Avatar(harness.host, onHost, harness.schema);
    final reader = _Avatar(client, onClient, harness.schema);

    harness
      ..sample(writer, 0, at: Duration.zero)
      ..sample(writer, 10, at: _ms * 50);
    // An unchanged value is not sent, so no newer sample arrives.
    for (var at = 100; at < 1000; at += 50) {
      harness.sample(writer, 10, at: _ms * at);
    }
    expect(
      harness.showAt(reader, _ms * 950),
      _shows(10, InterpolationState.holding),
    );

    harness.sample(writer, 20, at: _ms * 1000);
    for (final (at, value) in [(1000, 10.0), (1050, 10.0), (1075, 15.0)]) {
      expect(
        harness.showAt(reader, _ms * at),
        _shows(value, InterpolationState.interpolating),
        reason: '$at ms',
      );
    }
    expect(
      harness.showAt(reader, _ms * 1100),
      _shows(20, InterpolationState.holding),
    );
  });

  test('teleports show as jumps', () {
    final harness = _Harness();
    final (client, _) = harness.join();
    harness.settle();
    final [onHost, onClient] = harness.register(1);
    final writer = _Avatar(harness.host, onHost, harness.schema);
    final reader = _Avatar(
      client,
      onClient,
      harness.schema,
      interpolator: const DoubleInterpolator(teleportDistance: 50),
    );

    harness
      ..sample(writer, 0, at: Duration.zero)
      ..sample(writer, 100, at: _ms * 50)
      ..sample(writer, 110, at: _ms * 100);

    expect(
      harness.showAt(reader, _ms * 125),
      _shows(0, InterpolationState.snapped),
    );
    expect(
      harness.showAt(reader, _ms * 150),
      _shows(100, InterpolationState.interpolating),
    );
    expect(
      harness.showAt(reader, _ms * 175),
      _shows(105, InterpolationState.interpolating),
    );
  });

  group('timeline', () {
    /// Runs [duration] of 10 ms frames: the host samples its time, in
    /// milliseconds, after updating, and the client presents it after
    /// updating, unless [clientStalled] says it is stalled.
    List<double> frames(
      _Harness harness,
      _Avatar writer,
      _Avatar reader,
      Duration duration, {
      bool Function(Duration now)? clientStalled,
    }) {
      final shown = <double>[];
      final end = harness.clock.now + duration;
      while (harness.clock.now < end) {
        harness.clock.advance(_ms * 10);
        final now = harness.clock.now;
        harness.host.update();
        writer.x = now.inMicroseconds / 1000;
        harness.host.captureState();
        if (clientStalled?.call(now) ?? false) continue;
        reader.session.update();
        if (reader.shown case final value?) shown.add(value.value);
      }
      return shown;
    }

    test('follows sample times through latency and never rewinds', () {
      final harness = _Harness();
      final (client, peer) = harness.join();
      harness.settle();
      final [onHost, onClient] = harness.register(1);
      final writer = _Avatar(harness.host, onHost, harness.schema);
      final reader = _Avatar(client, onClient, harness.schema);
      peer.link.latency = _ms * 20;

      final steady = frames(harness, writer, reader, _second);
      // Values equal the time they were sampled: 20 ms in transit plus the
      // 100 ms delay behind the clock.
      expect(steady.last, closeTo(1000 - 120, 1e-6));

      peer.link.latency = _ms * 200;
      final shown = [
        ...steady,
        ...frames(harness, writer, reader, _second * 2),
      ];

      for (var i = 1; i < shown.length; i++) {
        expect(shown[i], greaterThanOrEqualTo(shown[i - 1]), reason: '$i');
      }
      expect(shown.last, closeTo(3000 - 300, 1e-6));
      expect(
        reader.shown!.state,
        InterpolationState.interpolating,
        reason: 'the delay covers the new latency once it is estimated',
      );
    });

    test('catches up after a stall without rewinding', () {
      final harness = _Harness();
      final (client, _) = harness.join();
      harness.settle();
      final [onHost, onClient] = harness.register(1);
      final writer = _Avatar(harness.host, onHost, harness.schema);
      final reader = _Avatar(client, onClient, harness.schema);

      // A sample sent during the host's frame arrives at the client's next
      // frame, 10 ms later, before the 100 ms delay.
      final before = frames(harness, writer, reader, _second);
      expect(before.last, closeTo(1000 - 110, 1e-6));
      final after = frames(
        harness,
        writer,
        reader,
        _ms * 600,
        clientStalled: (now) => now < _ms * 1500,
      );

      // The burst of samples that arrives at 1500 ms is placed by sample
      // time, so presentation catches up instead of slowing down.
      expect(after.first, closeTo(1500 - 110, 1e-6));
      expect(after.last, closeTo(1600 - 110, 1e-6));
    });
  });

  test('a late joiner presents its baseline, then blends', () {
    final harness = _Harness();
    final [onHost] = harness.register(1);
    final writer = _Avatar(harness.host, onHost, harness.schema);
    harness
      ..sample(writer, 5, at: Duration.zero)
      ..sample(writer, 7, at: _ms * 50);

    harness.clock.advance(_ms * 150);
    final (client, _) = harness.join();
    final onClient = client.registry.register(
      const EntityId(1),
      owner: PeerId.host,
      authority: PeerId.host,
    );
    harness.settle();
    final reader = _Avatar(client, onClient, harness.schema);
    expect(reader.shown, _shows(7, InterpolationState.holding));

    harness.sample(writer, 9, at: _ms * 250);
    expect(
      harness.showAt(reader, _ms * 250),
      _shows(7, InterpolationState.interpolating),
    );
    expect(
      harness.showAt(reader, _ms * 325),
      _shows(8, InterpolationState.interpolating),
    );

    // A replacement synchronizer starts from the retained value.
    reader.attachment.dispose();
    expect(reader.shown, isNull);
    final replacement = _Avatar(client, onClient, harness.schema);
    expect(replacement.shown, _shows(9, InterpolationState.holding));
  });

  test("relayed state follows its client authority's samples", () {
    final harness = _Harness();
    final (first, _) = harness.join();
    final (second, _) = harness.join();
    harness.settle();
    final [onHost, onFirst, onSecond] = harness.register(
      1,
      owner: _client1,
      authority: _client1,
    );
    final relay = _Avatar(harness.host, onHost, harness.schema);
    final writer = _Avatar(first, onFirst, harness.schema);
    final reader = _Avatar(second, onSecond, harness.schema);

    harness
      ..sample(writer, 0, at: Duration.zero)
      ..sample(writer, 10, at: _ms * 50)
      ..sample(writer, 20, at: _ms * 100);

    harness.clock.advance(_ms * 25);
    expect(relay.shown, _shows(5, InterpolationState.interpolating));
    expect(reader.shown, _shows(5, InterpolationState.interpolating));
    expect(writer.shown, isNull);
  });

  test('a custom delay and interpolator present fresh copies', () {
    final harness = _Harness();
    final (client, _) = harness.join();
    harness.settle();
    final [onHost, onClient] = harness.register(1);
    var point = _Point(0, 0);
    harness.host
        .attachEntity(onHost, isReady: () => true, isValid: () => true)
        .synchronize([harness.schema.point.property(get: () => point)]);
    final synchronizer = client
        .attachEntity(onClient, isReady: () => true, isValid: () => true)
        .synchronize(
          [
            harness.schema.point.property(
              get: () => _Point(0, 0),
              interpolator: const _PointInterpolator(),
            ),
          ],
          interval: _interval,
          interpolationDelay: _ms * 50,
        );

    harness.host.captureState();
    harness.settle();
    point = _Point(10, 20);
    harness.clock.advance(_interval);
    harness.host.captureState();
    harness.settle();
    harness.clock.advance(_ms * 25);

    final blended = synchronizer.interpolated(harness.schema.point)!;
    expect((blended.value.x, blended.value.y), (5.0, 10.0));
    blended.value.x = 99;
    harness.clock.advance(_ms * 25);
    final held = synchronizer.interpolated(harness.schema.point)!;
    expect((held.value.x, held.state), (10.0, InterpolationState.holding));
    held.value.x = 99;
    expect(synchronizer.interpolated(harness.schema.point)!.value.x, 10);
    expect(synchronizer.snapshot(harness.schema.point)!.value.x, 10);
  });

  test('rejects fields without interpolators and invalid delays', () {
    final harness = _Harness();
    final [entity] = harness.register(1);
    final avatar = _Avatar(harness.host, entity, harness.schema);
    final foreign =
        (ProtocolSchemaBuilder()
              ..addField(const FieldId('test.x'), const DoubleCodec()))
            .build()
            .fieldDefinition(const FieldId('test.x'))!;

    expect(
      () => avatar.synchronizer.interpolated(harness.schema.label),
      throwsArgumentError,
    );
    expect(
      () => avatar.synchronizer.interpolated(foreign),
      throwsArgumentError,
    );
    avatar.attachment.dispose();
    for (final delay in [Duration.zero, -_ms]) {
      final attachment = harness.host.attachEntity(
        entity,
        isReady: () => true,
        isValid: () => true,
      );
      expect(
        () => attachment.synchronize([
          harness.schema.x.property(get: () => 0),
        ], interpolationDelay: delay),
        throwsArgumentError,
      );
      attachment.dispose();
    }
  });
}

const _second = Duration(seconds: 1);
