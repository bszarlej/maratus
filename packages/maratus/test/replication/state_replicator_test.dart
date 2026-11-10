import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

const _ms = Duration(milliseconds: 1);
const _interval = Duration(milliseconds: 50);
const _client1 = PeerId(2);
const _fields = ['test.health', 'test.name', 'test.position'];

List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

Matcher _stateFrom(PeerId sender, List<String> fields) =>
    isA<(PeerId, List<String>)>()
        .having((message) => message.$1, 'sender', sender)
        .having((message) => message.$2, 'fields', fields);

final class _BrokenRoundTripCodec extends ValueCodec<int> {
  const _BrokenRoundTripCodec({this.rejectDecodedValue = false});

  final bool rejectDecodedValue;

  @override
  String get descriptor => 'test.broken@1';

  @override
  Object? encode(int value) {
    if (value < 0) throw StateError('cannot re-encode the decoded value');
    return value;
  }

  @override
  int decode(Object? wire) {
    if (rejectDecodedValue) return -(wire! as int);
    throw StateError('cannot decode the encoded value');
  }
}

/// A mutable two-dimensional point, like a vector.
final class _Point {
  _Point(this.x, this.y);

  double x;
  double y;

  @override
  String toString() => '$x,$y';
}

final class _PointCodec extends ValueCodec<_Point> {
  const _PointCodec();

  static const _axis = DoubleCodec(min: -1000, max: 1000);

  @override
  String get descriptor => 'test.point@1';

  @override
  Object? encode(_Point value) => {
    'x': _axis.encode(value.x),
    'y': _axis.encode(value.y),
  };

  @override
  _Point decode(Object? wire) {
    final object = WireObject(wire, const {'x', 'y'});
    return _Point(object.read('x', _axis), object.read('y', _axis));
  }
}

/// The registrations shared by every session of a test.
final class _Schema {
  _Schema({ValueCodec<int> healthCodec = const IntCodec(min: 0, max: 100)}) {
    final builder = ProtocolSchemaBuilder();
    avatar = builder.addSpawnType(
      const SpawnTypeId('test.avatar'),
      const StringCodec(maxLength: 16),
    );
    health = builder.addField(const FieldId('test.health'), healthCodec);
    name = builder.addField(
      const FieldId('test.name'),
      const StringCodec(maxLength: 16),
    );
    position = builder.addField(
      const FieldId('test.position'),
      const _PointCodec(),
    );
    large = builder.addField(
      const FieldId('test.large'),
      const StringCodec(maxLength: 40000),
    );
    larger = builder.addField(
      const FieldId('test.larger'),
      const StringCodec(maxLength: 40000),
    );
    huge = builder.addField(
      const FieldId('test.huge'),
      const StringCodec(maxLength: 70000),
    );
    schema = builder.build();
  }

  late final SpawnType<String> avatar;
  late final SyncField<int> health;
  late final SyncField<String> name;
  late final SyncField<_Point> position;
  late final SyncField<String> large;
  late final SyncField<String> larger;
  late final SyncField<String> huge;
  late final ProtocolSchema schema;
}

/// One peer's local values for one entity, kept in step by a synchronizer.
final class _Model {
  _Model(
    MultiplayerSession session,
    NetworkEntity entity,
    _Schema schema, {
    SyncMode healthMode = SyncMode.onChange,
    Duration interval = _interval,
  }) {
    attachment = session.attachEntity(
      entity,
      isReady: () => ready,
      isValid: () => true,
    );
    synchronizer = attachment.synchronize([
      schema.health.property(
        get: () {
          duringGet?.call();
          return health;
        },
        set: (value) {
          health = value;
          applied.add('health=$value');
          duringSet?.call();
        },
        mode: healthMode,
      ),
      schema.name.property(
        get: () {
          if (getError case final error?) throw error;
          return name;
        },
        set: (value) {
          if (setError case final error?) throw error;
          name = value;
          applied.add('name=$value');
        },
      ),
      schema.position.property(
        get: () => position,
        set: (value) {
          position = value;
          applied.add('position=$value');
        },
      ),
    ], interval: interval);
  }

  late final EntityAttachment attachment;
  late final MultiplayerSynchronizer synchronizer;
  var ready = true;
  var health = 0;
  var name = '';
  var position = _Point(0, 0);
  final applied = <String>[];
  Error? getError;
  Error? setError;
  void Function()? duringGet;
  void Function()? duringSet;

  String get values => 'health=$health name=$name position=$position';
}

/// A host and the clients that join it over an in-memory network.
final class _Harness {
  _Harness({_Schema? schema}) : schema = schema ?? _Schema() {
    network = InMemoryNetwork(clock: clock);
    host = _session()..host(network.host());
  }

  final clock = ManualClock();
  final _Schema schema;
  late final InMemoryNetwork network;
  late final MultiplayerSession host;
  final sessions = <MultiplayerSession>[];
  final _updates = <void Function()>[];

  /// The state messages each session accepted: senders and field IDs.
  final observed = <MultiplayerSession, List<(PeerId, List<String>)>>{};

  /// The sample times of the state messages each session accepted.
  final stamps = <MultiplayerSession, List<Duration>>{};

  MultiplayerSession _session() {
    late final MultiplayerSession session;
    session = MultiplayerSession(
      schema: schema.schema,
      clock: clock,
      onMessage: (sender, envelope) {
        final message = envelope.message as StateMessage;
        observed.putIfAbsent(session, () => []).add((
          sender,
          [for (final field in message.values.keys) field.value],
        ));
        stamps.putIfAbsent(session, () => []).add(message.sampledAt!);
      },
    );
    addTearDown(session.close);
    sessions.add(session);
    _updates.add(session.update);
    return session;
  }

  MultiplayerSession join() => _session()..join(network.connect());

  _RawClient rawClient() {
    final client = _RawClient(network.connect(), schema.schema);
    _updates.add(client.update);
    return client;
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

  /// Delivers everything in transit and updates every session.
  void run() {
    for (var i = 0; i < 6; i++) {
      clock.advance(Duration.zero);
      for (final update in _updates) {
        update();
      }
    }
  }

  /// Advances the clock by [step], captures state everywhere, and delivers it.
  void tick([Duration step = _interval]) {
    clock.advance(step);
    for (final session in sessions) {
      session.captureState();
    }
    run();
  }

  int observedBy(MultiplayerSession session) => observed[session]?.length ?? 0;
}

/// A client that speaks the protocol directly, to send what a session would
/// not.
final class _RawClient {
  _RawClient(this.peer, this.schema) : codec = ProtocolCodec(schema);

  final InMemoryClient peer;
  final ProtocolSchema schema;
  final ProtocolCodec codec;
  PeerConnection? connection;
  PeerId? id;
  var generation = 0;

  /// The revision of the baseline that the host welcomed this client with.
  var baseline = 0;
  final received = <ProtocolMessage>[];

  void update() {
    for (var event = peer.poll(); event != null; event = peer.poll()) {
      switch (event) {
        case ConnectionOpened(:final connection):
          this.connection = connection;
        case MessageReceived(:final message):
          final envelope = codec.decode(message);
          if (envelope.message case WelcomeMessage(:final peer)) {
            id = peer;
            generation = envelope.generation;
            baseline = envelope.revision;
          }
          received.add(envelope.message);
        case ConnectionClosed():
          break;
      }
    }
  }

  void send(ProtocolMessage message) => connection!.send(
    codec.encode(MessageEnvelope(message, generation: generation)),
  );

  /// Reports ready, acknowledging the baseline.
  void ready() => connection!.send(
    codec.encode(
      MessageEnvelope(
        const ReadyMessage(),
        generation: generation,
        revision: baseline,
      ),
    ),
  );
}

/// A client session joining a host that speaks the protocol directly.
final class _RawHostHarness {
  _RawHostHarness() {
    final network = InMemoryNetwork(clock: clock);
    final peer = network.host();
    codec = ProtocolCodec(schema.schema);
    client = MultiplayerSession(schema: schema.schema, clock: clock)
      ..join(network.connect());
    addTearDown(client.close);
    _updates = [
      () {
        for (var event = peer.poll(); event != null; event = peer.poll()) {
          if (event case ConnectionOpened(:final connection)) {
            this.connection = connection;
          }
        }
      },
      client.update,
    ];
    run();
    send(const WelcomeMessage(peer: _client1, epoch: 9));
    send(const SyncedMessage());
    run();
  }

  final clock = ManualClock();
  final schema = _Schema();
  late final ProtocolCodec codec;
  late final MultiplayerSession client;
  late final List<void Function()> _updates;
  PeerConnection? connection;

  void run() {
    for (var i = 0; i < 6; i++) {
      clock.advance(Duration.zero);
      for (final update in _updates) {
        update();
      }
    }
  }

  void send(ProtocolMessage message, {int revision = 0}) => connection!.send(
    codec.encode(MessageEnvelope(message, generation: 5, revision: revision)),
  );
}

StateMessage _health(int entity, int value) => StateMessage(
  entity: EntityId(entity),
  values: {const FieldId('test.health'): value},
  sampledAt: Duration.zero,
);

void main() {
  group('sampling', () {
    test('the authority sends initial values, then changed fields', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final [onHost, onClient] = harness.register(1);
      final writer = _Model(harness.host, onHost, harness.schema)
        ..health = 5
        ..name = 'Ada'
        ..position = _Point(1, 2);
      final reader = _Model(client, onClient, harness.schema);

      harness.host.captureState();
      harness.run();
      expect(reader.applied, ['health=5', 'name=Ada', 'position=1.0,2.0']);
      expect(harness.observed[client], [_stateFrom(PeerId.host, _fields)]);
      expect(client.revision, harness.host.revision);

      writer.health = 6;
      harness.tick();
      expect(reader.applied.last, 'health=6');
      expect(
        harness.observed[client]!.last,
        _stateFrom(PeerId.host, ['test.health']),
      );

      final revision = harness.host.revision;
      harness
        ..tick()
        ..tick();
      expect(harness.host.revision, revision);
      expect(harness.observedBy(client), 2);
      expect(reader.values, writer.values);
      expect(writer.applied, isEmpty);
    });

    test('always fields are sent every interval, changed or not', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final [onHost, onClient] = harness.register(1);
      _Model(
        harness.host,
        onHost,
        harness.schema,
        healthMode: SyncMode.always,
      ).health = 3;
      final reader = _Model(client, onClient, harness.schema);
      harness.host.captureState();
      harness.run();

      harness
        ..tick()
        ..tick();

      expect(harness.observed[client]!.skip(1), [
        _stateFrom(PeerId.host, ['test.health']),
        _stateFrom(PeerId.host, ['test.health']),
      ]);
      // An identical value is applied only once.
      expect(reader.applied, ['health=3', 'name=', 'position=0.0,0.0']);
    });

    test('cadence follows the session clock, not the call rate', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final [onHost, onClient] = harness.register(1);
      _Model(harness.host, onHost, harness.schema, healthMode: SyncMode.always);
      _Model(client, onClient, harness.schema);

      for (final (step, sent) in [
        (0, 1),
        (10, 1),
        (39, 1),
        (1, 2),
        (49, 2),
        (1, 3),
        // A late call samples once, then resumes the cadence from there.
        (1000, 4),
        (49, 4),
        (1, 5),
      ]) {
        harness.clock.advance(_ms * step);
        for (var frame = 0; frame < 3; frame++) {
          harness.host.captureState();
        }
        harness.run();
        expect(
          harness.observedBy(client),
          sent,
          reason: '${harness.clock.now}',
        );
      }
    });

    test('sampling copies mutable values', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final [onHost, onClient] = harness.register(1);
      final writer = _Model(harness.host, onHost, harness.schema)
        ..position = _Point(1, 2);
      final reader = _Model(client, onClient, harness.schema);
      harness.host.captureState();
      harness.run();

      writer.position.x = 5;
      reader.position.x = 9;

      final position = harness.schema.position;
      expect(writer.synchronizer.snapshot(position)!.value.x, 1);
      expect(reader.synchronizer.snapshot(position)!.value.x, 1);
      writer.synchronizer.snapshot(position)!.value.x = 7;
      expect(writer.synchronizer.snapshot(position)!.value.x, 1);
      harness.tick();
      expect(reader.applied.last, 'position=5.0,2.0');
      expect(reader.synchronizer.snapshot(position)!.time, harness.clock.now);
    });

    test('irregular capture calls remain at least one interval apart', () {
      final harness = _Harness();
      final [entity] = harness.register(1);
      _Model(harness.host, entity, harness.schema, healthMode: SyncMode.always);

      for (final (step, samples) in [
        (0, 1),
        (99, 2),
        (1, 2),
        (48, 2),
        (1, 3),
      ]) {
        harness.clock.advance(_ms * step);
        harness.host.captureState();
        expect(harness.host.revision, samples, reason: '${harness.clock.now}');
      }
    });
  });

  group('sample times', () {
    test('state carries the time its authority sampled it', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final [onHost, onClient] = harness.register(1);
      final writer = _Model(harness.host, onHost, harness.schema)..health = 1;
      _Model(client, onClient, harness.schema);

      harness.clock.advance(_ms * 70);
      harness.host.captureState();
      // Delivering a sample later does not change its time.
      harness.clock.advance(_ms * 15);
      harness.run();
      writer.health = 2;
      harness.tick();

      expect(harness.stamps[client], [_ms * 70, _ms * 135]);
    });

    test("relayed state keeps its client authority's time", () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      harness.run();
      final [onHost, onFirst, onSecond] = harness.register(
        1,
        owner: _client1,
        authority: _client1,
      );
      _Model(harness.host, onHost, harness.schema);
      _Model(first, onFirst, harness.schema).health = 4;
      _Model(second, onSecond, harness.schema);

      harness.clock.advance(_ms * 20);
      first.captureState();
      harness.clock.advance(_ms * 30);
      harness.run();

      expect(harness.stamps[harness.host], [_ms * 20]);
      expect(harness.stamps[second], [_ms * 20]);
    });

    test("a baseline carries its entity's latest sample time", () {
      final harness = _Harness();
      final [entity] = harness.register(1);
      final writer = _Model(harness.host, entity, harness.schema)..health = 1;
      harness.host.captureState();
      writer.name = 'Ada';
      harness.clock.advance(_ms * 80);
      harness.host.captureState();

      final joiner = harness.join();
      joiner.registry.register(
        const EntityId(1),
        owner: PeerId.host,
        authority: PeerId.host,
      );
      harness.run();

      expect(joiner.state, SessionState.ready);
      expect(harness.observed[joiner], [_stateFrom(PeerId.host, _fields)]);
      expect(harness.stamps[joiner], [_ms * 80]);
    });
  });

  group('authority', () {
    test('a client authority writes through the host to other clients', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      harness.run();
      final [onHost, onFirst, onSecond] = harness.register(
        1,
        owner: _client1,
        authority: _client1,
      );
      final relay = _Model(harness.host, onHost, harness.schema);
      final writer = _Model(first, onFirst, harness.schema)
        ..health = 42
        ..name = 'Bob';
      final reader = _Model(second, onSecond, harness.schema);
      final revision = harness.host.revision;

      harness.host.captureState();
      second.captureState();
      expect(harness.host.revision, revision);
      first.captureState();
      harness.run();

      expect(relay.values, writer.values);
      expect(reader.values, writer.values);
      expect(harness.observed[harness.host], [_stateFrom(_client1, _fields)]);
      expect(harness.observed[second], [_stateFrom(PeerId.host, _fields)]);
      expect(harness.observed[first], isNull);
      expect(writer.applied, isEmpty);
      expect(first.revision, revision);
      expect(second.revision, harness.host.revision);
    });

    test('a host ignores state from clients that do not write it', () {
      final harness = _Harness();
      final reader = harness.join();
      final raw = harness.rawClient();
      harness.run();
      raw.send(HelloMessage(fingerprint: harness.schema.schema.fingerprint));
      harness.run();
      raw.ready();
      harness.run();
      final [hostEntity, readerEntity] = harness.register(1);
      final [removed, _] = harness.register(
        2,
        owner: raw.id!,
        authority: raw.id!,
      );
      harness.host.registry.remove(removed.id);
      final owned = _Model(harness.host, hostEntity, harness.schema)
        ..health = 1;
      final replica = _Model(reader, readerEntity, harness.schema);
      harness.host.captureState();
      harness.run();
      _drain(harness.host);

      raw
        ..send(_health(1, 99))
        ..send(_health(3, 99))
        ..send(_health(2, 99));
      harness.run();

      expect(_drain(harness.host), [
        isA<StateRejected>()
            .having((event) => event.entity, 'entity', const EntityId(1))
            .having((event) => event.sender, 'sender', raw.id)
            .having(
              (event) => event.reason,
              'reason',
              StateRejection.notAuthority,
            ),
        isA<StateRejected>()
            .having((event) => event.entity, 'entity', const EntityId(3))
            .having(
              (event) => event.reason,
              'reason',
              StateRejection.unknownEntity,
            ),
      ]);
      expect(owned.synchronizer.snapshot(harness.schema.health)!.value, 1);
      expect(replica.health, 1);
      expect(harness.observed[harness.host], isNull);
      expect(harness.host.isReady(raw.id!), isTrue);
    });

    test('a host drops a client that sends state without a sample time', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      harness.run();
      raw.send(HelloMessage(fingerprint: harness.schema.schema.fingerprint));
      harness.run();
      raw.ready();
      harness.run();
      final [entity] = harness.register(1, owner: raw.id!, authority: raw.id!);
      final model = _Model(harness.host, entity, harness.schema);
      final peer = raw.id!;
      _drain(harness.host);

      raw.send(
        StateMessage(
          entity: const EntityId(1),
          values: {const FieldId('test.health'): 99},
        ),
      );
      harness.run();

      expect(_drain(harness.host), [
        PeerLeft(peer, DisconnectReason.protocolViolation),
      ]);
      expect(model.health, 0);
      expect(harness.observed[harness.host], isNull);
    });

    test('a client ignores host state for entities it writes', () {
      final harness = _RawHostHarness();
      final client = harness.client;
      final entity = client.registry.register(
        const EntityId(1),
        owner: _client1,
        authority: _client1,
      );
      final writer = _Model(client, entity, harness.schema)..health = 4;
      _drain(client);

      harness
        ..send(_health(1, 99), revision: 1)
        ..send(_health(5, 99), revision: 2)
        ..run();

      expect(
        _drain(client).whereType<StateRejected>().map(
          (event) => (event.entity, event.sender, event.reason),
        ),
        [
          (const EntityId(1), PeerId.host, StateRejection.notAuthority),
          (const EntityId(5), PeerId.host, StateRejection.unknownEntity),
        ],
      );
      expect(writer.health, 4);
      expect(writer.applied, isEmpty);
      expect(writer.synchronizer.snapshot(harness.schema.health), isNull);
    });

    test('obsolete revisions do not alter state', () {
      final harness = _RawHostHarness();
      final client = harness.client;
      final entity = client.registry.register(
        const EntityId(1),
        owner: PeerId.host,
        authority: PeerId.host,
      );
      final reader = _Model(client, entity, harness.schema);

      harness
        ..send(_health(1, 5), revision: 2)
        ..send(_health(1, 9), revision: 1)
        ..send(_health(1, 8), revision: 2)
        ..run();

      expect(reader.applied, ['health=5']);
      expect(client.obsoleteMessageCount, 2);
    });

    test('applying received values never sends them back', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      harness.run();
      final [onHost, onFirst, onSecond] = harness.register(1);
      final writer = _Model(harness.host, onHost, harness.schema)..health = 1;
      final readers = [
        _Model(first, onFirst, harness.schema),
        _Model(second, onSecond, harness.schema),
      ];
      for (final reader in readers) {
        // Even setters that write further values cannot echo them.
        reader.duringSet = () => reader
          ..health += 10
          ..name = 'changed';
      }
      harness.host.captureState();
      harness.run();
      final revision = harness.host.revision;

      for (var i = 0; i < 5; i++) {
        harness.tick();
      }

      expect(harness.host.revision, revision);
      expect(harness.observed[harness.host], isNull);
      expect(harness.observedBy(first), 1);
      expect(harness.observedBy(second), 1);
      expect(readers.map((reader) => reader.health), [11, 11]);
      expect(writer.applied, isEmpty);
    });
  });

  group('delivery', () {
    test('a synchronizer receives the latest values once ready', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final [onHost, onClient] = harness.register(1);
      final writer = _Model(harness.host, onHost, harness.schema)..health = 1;
      final reader = _Model(client, onClient, harness.schema)..ready = false;
      harness.host.captureState();
      harness.run();
      for (final value in [2, 3]) {
        writer.health = value;
        harness.tick();
      }
      expect(reader.applied, isEmpty);
      expect(reader.synchronizer.snapshot(harness.schema.health)!.value, 3);

      reader.ready = true;
      client.update();

      expect(reader.applied, ['health=3', 'name=', 'position=0.0,0.0']);
    });

    test('a replacement synchronizer receives the entity values again', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final [onHost, onClient] = harness.register(1);
      _Model(harness.host, onHost, harness.schema).health = 8;
      final first = _Model(client, onClient, harness.schema);
      harness.host.captureState();
      harness.run();

      first.attachment.dispose();
      expect(first.synchronizer.isDisposed, isTrue);
      final replacement = _Model(client, onClient, harness.schema);
      client.update();

      expect(replacement.applied, ['health=8', 'name=', 'position=0.0,0.0']);
      expect(first.applied, hasLength(3));
    });

    test(
      'setters pause when an earlier setter makes the attachment unready',
      () {
        final harness = _Harness();
        final client = harness.join();
        harness.run();
        final [onHost, onClient] = harness.register(1);
        _Model(harness.host, onHost, harness.schema)
          ..health = 8
          ..name = 'Ada';
        final reader = _Model(client, onClient, harness.schema);
        reader.duringSet = () => reader.ready = false;

        harness.host.captureState();
        harness.run();

        expect(reader.applied, ['health=8']);
        reader.ready = true;
        client.update();
        expect(reader.applied, ['health=8', 'name=Ada', 'position=0.0,0.0']);
      },
    );

    test('a setter may dispose its attachment before the remaining fields', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final [onHost, onClient] = harness.register(1);
      _Model(harness.host, onHost, harness.schema).health = 8;
      final reader = _Model(client, onClient, harness.schema);
      reader.duringSet = reader.attachment.dispose;

      harness.host.captureState();
      harness.run();

      expect(reader.applied, ['health=8']);
      expect(reader.synchronizer.isDisposed, isTrue);
      final replacement = _Model(client, onClient, harness.schema);
      client.update();
      expect(replacement.applied, ['health=8', 'name=', 'position=0.0,0.0']);
    });

    test('properties without setters retain authoritative snapshots', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final [onHost, onClient] = harness.register(1);
      _Model(harness.host, onHost, harness.schema).health = 8;
      final synchronizer = client
          .attachEntity(onClient, isReady: () => true, isValid: () => true)
          .synchronize([
            harness.schema.health.property(
              get: () => throw StateError('only the authority reads values'),
            ),
          ]);

      harness.host.captureState();
      harness.run();

      expect(synchronizer.snapshot(harness.schema.health)!.value, 8);
      expect(_drain(client).whereType<PropertySyncFailed>(), isEmpty);
    });

    test('registry removal and clearing cannot expose old snapshots', () {
      final harness = _Harness();
      final [entity] = harness.register(1);
      final first = _Model(harness.host, entity, harness.schema)..health = 8;
      harness.host.captureState();

      harness.host.registry.remove(entity.id);
      expect(first.synchronizer.snapshot(harness.schema.health), isNull);
      harness.host.registry.clear();
      final [replacementEntity] = harness.register(1);
      final replacement = _Model(
        harness.host,
        replacementEntity,
        harness.schema,
      )..health = 8;
      expect(replacement.synchronizer.snapshot(harness.schema.health), isNull);

      harness.host.captureState();

      expect(
        replacement.synchronizer.snapshot(harness.schema.health)!.value,
        8,
      );
      expect(first.synchronizer.snapshot(harness.schema.health), isNull);
      expect(harness.host.revision, 2);
    });

    test('a joining client receives the latest values in its baseline', () {
      final harness = _Harness();
      final writer = harness.join();
      harness.run();
      final [onHost, onWriter] = harness.register(
        5,
        owner: _client1,
        authority: _client1,
      );
      _Model(harness.host, onHost, harness.schema);
      _Model(writer, onWriter, harness.schema).health = 30;
      final spawned = <MultiplayerSession, _Model>{};
      void bind(MultiplayerSession session) => session.bindSpawn(
        harness.schema.avatar,
        onSpawn: (context) =>
            spawned[session] = _Model(session, context.entity, harness.schema),
      );
      bind(harness.host);
      harness.host.spawn(harness.schema.avatar, 'Ada');
      spawned[harness.host]!
        ..health = 9
        ..name = 'Ada';
      harness.host.captureState();
      writer.captureState();
      harness.run();

      final joiner = harness.join();
      bind(joiner);
      final [joinerStatic] = [
        joiner.registry.register(
          const EntityId(5),
          owner: _client1,
          authority: _client1,
        ),
      ];
      final relayed = _Model(joiner, joinerStatic, harness.schema);
      harness.run();

      expect(joiner.state, SessionState.ready);
      expect(spawned[joiner]!.values, spawned[harness.host]!.values);
      expect(relayed.health, 30);
      expect(harness.observedBy(joiner), 2);
      // Only the host's report that the joiner is ready, which goes to the
      // other clients, follows the baseline.
      expect(joiner.revision, harness.host.revision - 1);
    });

    test('despawning forgets the values of an entity', () {
      final harness = _Harness();
      final models = <_Model>[];
      harness.host.bindSpawn(
        harness.schema.avatar,
        onSpawn: (context) =>
            models.add(_Model(harness.host, context.entity, harness.schema)),
      );
      final entity = harness.host.spawn(harness.schema.avatar, 'Ada');
      models.single.health = 9;
      harness.host.captureState();
      expect(
        models.single.synchronizer.snapshot(harness.schema.health),
        isNotNull,
      );

      harness.host.despawn(entity);
      final joiner = harness.join();
      harness.run();

      expect(models.single.synchronizer.isDisposed, isTrue);
      expect(
        models.single.synchronizer.snapshot(harness.schema.health),
        isNull,
      );
      expect(joiner.state, SessionState.ready);
      expect(harness.observed[joiner], isNull);
      expect(_drain(joiner).whereType<StateRejected>(), isEmpty);
    });

    test('updates too large to combine are split, larger ones reported', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final [onHost, onClient] = harness.register(1);
      final schema = harness.schema;
      final large = 'a' * 40000;
      harness.host
          .attachEntity(onHost, isReady: () => true, isValid: () => true)
          .synchronize([
            schema.large.property(get: () => large),
            schema.larger.property(get: () => large),
            schema.huge.property(get: () => 'h' * 70000),
          ]);
      final received = <String>[];
      client
          .attachEntity(onClient, isReady: () => true, isValid: () => true)
          .synchronize([
            schema.large.property(
              get: () => '',
              set: (value) => received.add('large:${value.length}'),
            ),
            schema.larger.property(
              get: () => '',
              set: (value) => received.add('larger:${value.length}'),
            ),
          ]);
      _drain(harness.host);

      harness.host.captureState();
      harness.run();

      expect(
        _drain(harness.host).whereType<PropertySyncFailed>().single.field,
        schema.huge.id,
      );
      expect(harness.observed[client], [
        _stateFrom(PeerId.host, ['test.large']),
        _stateFrom(PeerId.host, ['test.larger']),
      ]);
      expect(received, ['large:40000', 'larger:40000']);
    });
  });

  group('failures', () {
    test(
      'a single oversized field is reported without retaining or sending it',
      () {
        final harness = _Harness();
        final client = harness.join();
        harness.run();
        final [entity, _] = harness.register(1);
        final synchronizer = harness.host
            .attachEntity(entity, isReady: () => true, isValid: () => true)
            .synchronize([
              harness.schema.huge.property(get: () => 'h' * 70000),
            ]);
        _drain(harness.host);
        final revision = harness.host.revision;

        harness.host.captureState();
        harness.run();

        final failure = _drain(
          harness.host,
        ).whereType<PropertySyncFailed>().single;
        expect(failure.field, harness.schema.huge.id);
        expect(failure.error, isA<ArgumentError>());
        expect(synchronizer.snapshot(harness.schema.huge), isNull);
        expect(harness.host.revision, revision);
        expect(harness.observedBy(client), 0);
        expect(client.state, SessionState.ready);
      },
    );

    for (final rejectDecodedValue in [false, true]) {
      test('broken codec round trips isolate the affected field '
          '(re-encode failure: $rejectDecodedValue)', () {
        final harness = _Harness(
          schema: _Schema(
            healthCodec: _BrokenRoundTripCodec(
              rejectDecodedValue: rejectDecodedValue,
            ),
          ),
        );
        final client = harness.join();
        harness.run();
        final [onHost, onClient] = harness.register(1);
        final writer = _Model(harness.host, onHost, harness.schema)..health = 5;
        final reader = _Model(client, onClient, harness.schema);
        _drain(harness.host);

        harness.host.captureState();
        harness.run();

        final failure = _drain(
          harness.host,
        ).whereType<PropertySyncFailed>().single;
        expect(failure.field, harness.schema.health.id);
        expect(
          failure.error,
          rejectDecodedValue ? isA<ArgumentError>() : isA<ProtocolException>(),
        );
        expect(writer.synchronizer.snapshot(harness.schema.health), isNull);
        expect(reader.applied, ['name=', 'position=0.0,0.0']);
        expect(client.state, SessionState.ready);
      });
    }

    for (final action in ['dispose', 'remove', 'close', 'restart']) {
      test(
        'a getter that causes $action stops sampling its old attachment',
        () {
          final harness = _Harness();
          final [entity] = harness.register(1);
          final writer = _Model(harness.host, entity, harness.schema)
            ..getError = StateError('the next getter must not run');
          writer.duringGet = () {
            switch (action) {
              case 'dispose':
                writer.attachment.dispose();
              case 'remove':
                harness.host.registry.remove(entity.id);
              case 'close':
                harness.host.close();
              case 'restart':
                harness.host.close();
                harness.host.host(InMemoryNetwork(clock: harness.clock).host());
            }
          };
          _drain(harness.host);

          harness.host.captureState();

          expect(writer.synchronizer.isDisposed, isTrue);
          expect(writer.synchronizer.snapshot(harness.schema.health), isNull);
          expect(harness.host.revision, 0);
          expect(_drain(harness.host).whereType<PropertySyncFailed>(), isEmpty);
        },
      );
    }

    test('getter, codec, and setter failures affect only their field', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final [onHost, onClient] = harness.register(1);
      final getError = StateError('getter failed');
      final setError = StateError('setter failed');
      final writer = _Model(harness.host, onHost, harness.schema)
        ..health = 101
        ..getError = getError;
      final reader = _Model(client, onClient, harness.schema)
        ..setError = setError;
      _drain(harness.host);
      _drain(client);

      harness.host.captureState();
      harness.run();
      final hostFailures = _drain(
        harness.host,
      ).whereType<PropertySyncFailed>().toList();
      expect(hostFailures.map((event) => event.field.value), [
        'test.health',
        'test.name',
      ]);
      expect(hostFailures.first.error, isA<ArgumentError>());
      expect(hostFailures.last.error, same(getError));
      expect(hostFailures.last.stackTrace, isA<StackTrace>());
      expect(reader.applied, ['position=0.0,0.0']);

      writer
        ..health = 50
        ..getError = null
        ..name = 'Ada';
      harness.tick();
      final clientFailure = _drain(
        client,
      ).whereType<PropertySyncFailed>().single;
      expect(clientFailure.field, harness.schema.name.id);
      expect(clientFailure.error, same(setError));
      expect(reader.applied.last, 'health=50');
      expect(reader.synchronizer.snapshot(harness.schema.name)!.value, 'Ada');
    });

    test('getters and setters cannot update or capture the session', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final [onHost, onClient] = harness.register(1);
      final writer = _Model(harness.host, onHost, harness.schema)..health = 5;
      final reader = _Model(client, onClient, harness.schema)
        ..duringSet = client.captureState;
      _drain(harness.host);
      _drain(client);

      harness.host.captureState();
      harness.run();
      writer.duringGet = harness.host.update;
      harness.tick();

      for (final session in [harness.host, client]) {
        final failure = _drain(session).whereType<PropertySyncFailed>().single;
        expect(failure.field, harness.schema.health.id);
        expect(failure.error, isA<StateError>());
      }
      expect(reader.applied, ['health=5', 'name=', 'position=0.0,0.0']);
      expect(writer.applied, isEmpty);
      final idle = MultiplayerSession(schema: harness.schema.schema)
        ..captureState();
      expect(idle.state, SessionState.disconnected);
    });

    test('synchronize validates its properties and lifetime', () {
      final harness = _Harness();
      final [entity] = harness.register(1);
      final schema = harness.schema;
      final attachment = harness.host.attachEntity(
        entity,
        isReady: () => true,
        isValid: () => true,
      );
      final health = schema.health.property(get: () => 0);
      const foreign = SyncField<int>(
        id: FieldId('test.health'),
        codec: IntCodec(min: 0, max: 100),
      );

      for (final (properties, interval) in [
        (<SyncProperty<Object?>>[], _interval),
        ([health, health], _interval),
        ([foreign.property(get: () => 0)], _interval),
        ([health], Duration.zero),
      ]) {
        expect(
          () => attachment.synchronize(properties, interval: interval),
          throwsArgumentError,
        );
      }
      final synchronizer = attachment.synchronize([health]);
      expect(() => attachment.synchronize([health]), throwsStateError);
      expect(() => synchronizer.snapshot(foreign), throwsArgumentError);
      synchronizer.dispose();
      synchronizer.dispose();
      expect(synchronizer.isDisposed, isTrue);
      expect(attachment.synchronize([health]).isDisposed, isFalse);
      attachment.dispose();
      expect(() => attachment.synchronize([health]), throwsStateError);
    });
  });

  test('connected peers converge on every field without echoes', () {
    final harness = _Harness();
    final first = harness.join();
    final second = harness.join();
    harness.run();
    final hostOwned = harness.register(1);
    final clientOwned = harness.register(
      2,
      owner: _client1,
      authority: _client1,
    );
    final sessions = [harness.host, first, second];
    final models = [
      for (var i = 0; i < sessions.length; i++)
        (
          _Model(sessions[i], hostOwned[i], harness.schema),
          _Model(sessions[i], clientOwned[i], harness.schema),
        ),
    ];
    final (hostWriter, _) = models[0];
    final (_, clientWriter) = models[1];

    for (var round = 1; round <= 4; round++) {
      hostWriter
        ..health = round
        ..position.x = round * 10.0;
      clientWriter
        ..name = 'r$round'
        ..position.y = -round.toDouble();
      harness.tick();
    }
    harness.tick();
    final revision = harness.host.revision;
    final counts = [
      for (final session in sessions) harness.observedBy(session),
    ];
    for (var i = 0; i < 5; i++) {
      harness.tick();
    }

    for (final (hostEntity, clientEntity) in models) {
      expect(hostEntity.values, hostWriter.values);
      expect(clientEntity.values, clientWriter.values);
    }
    expect(harness.host.revision, revision);
    expect([
      for (final session in sessions) harness.observedBy(session),
    ], counts);
  });
}
