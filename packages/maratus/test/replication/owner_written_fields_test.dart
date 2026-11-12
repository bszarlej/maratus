import 'dart:async';

import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

const _interval = Duration(milliseconds: 50);

List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

/// The registrations shared by every session of a test: an avatar whose
/// owner writes its input and aim, and whose authority writes its position.
final class _Schema {
  _Schema() {
    final builder = ProtocolSchemaBuilder();
    avatar = builder.addSpawnType(
      const SpawnTypeId('test.avatar'),
      const BoolCodec(),
    );
    input = builder.addField(
      const FieldId('test.input'),
      const IntCodec(min: -1000, max: 1000),
      writer: FieldWriter.owner,
    );
    x = builder.addField(
      const FieldId('test.x'),
      const IntCodec(min: -1000, max: 1000),
    );
    aim = builder.addField(
      const FieldId('test.aim'),
      const DoubleCodec(min: -1000, max: 1000),
      deliveryMode: DeliveryMode.unreliableOrdered,
      channel: 1,
      writer: FieldWriter.owner,
    );
    y = builder.addField(
      const FieldId('test.y'),
      const DoubleCodec(min: -1000, max: 1000),
      deliveryMode: DeliveryMode.unreliableOrdered,
      channel: 1,
    );
    board = builder.addStaticEntity(const StaticEntityId('test.board'));
    schema = builder.build();
  }

  late final SpawnType<bool> avatar;
  late final SyncField<int> input;
  late final SyncField<int> x;
  late final SyncField<double> aim;
  late final SyncField<double> y;
  late final StaticEntity board;
  late final ProtocolSchema schema;
}

/// A clock that runs [offset] ahead of [base], as another device's might.
final class _OffsetClock implements MonotonicClock {
  _OffsetClock(this.base, this.offset);

  final MonotonicClock base;
  final Duration offset;

  @override
  Duration get now => base.now + offset;

  @override
  Timer schedule(Duration delay, void Function() callback) =>
      base.schedule(delay, callback);
}

/// One peer's copy of an avatar. Its synchronizer combines the owner's
/// [input] with the authority's [x] and, with lanes, the owner's [aim] and
/// the authority's [y] on another channel, which other peers present only
/// through interpolation.
final class _Avatar {
  _Avatar(
    MultiplayerSession session,
    NetworkEntity entity,
    _Schema schema, {
    required bool lanes,
  }) {
    attachment = session.attachEntity(
      entity,
      isReady: () => true,
      isValid: () => true,
    );
    synchronizer = attachment.synchronize([
      schema.input.property(
        get: () => input,
        set: (value) {
          input = value;
          applied.add('input=$value');
        },
      ),
      schema.x.property(
        get: () => x,
        set: (value) {
          x = value;
          applied.add('x=$value');
        },
      ),
      if (lanes) ...[
        schema.aim.property(
          get: () => aim,
          mode: SyncMode.always,
          interpolator: const DoubleInterpolator(),
        ),
        schema.y.property(
          get: () => y,
          mode: SyncMode.always,
          interpolator: const DoubleInterpolator(),
        ),
      ],
    ], interval: _interval);
  }

  late final EntityAttachment attachment;
  late final MultiplayerSynchronizer synchronizer;
  var input = 0;
  var x = 0;
  var aim = 0.0;
  var y = 0.0;

  /// The values that the synchronizer applied, in order.
  final applied = <String>[];
}

/// A host and the clients that join it over an in-memory network with two
/// channels, each with an avatar for every spawned entity.
final class _Harness {
  /// Creates a host whose clock runs [hostClockOffset] ahead of its
  /// clients', with [backpressure] for every session. With [lanes], the
  /// avatars also synchronize the fields on channel one.
  _Harness({
    Duration hostClockOffset = Duration.zero,
    this.backpressure = const QueueLimits(
      maxMessages: 256,
      maxBytes: 1024 * 1024,
    ),
    this.lanes = false,
  }) {
    network = InMemoryNetwork(
      clock: clock,
      deliveryModes: DeliveryMode.values.toSet(),
      channelCount: 2,
    );
    host = _session(clockOffset: hostClockOffset)..host(network.host());
  }

  final QueueLimits backpressure;
  final bool lanes;
  final clock = ManualClock();
  final schema = _Schema();
  late final InMemoryNetwork network;
  late final MultiplayerSession host;
  final sessions = <MultiplayerSession>[];

  /// The update of each session and raw client, in creation order.
  final _updates = <(MultiplayerSession?, void Function())>[];
  final _avatars = <MultiplayerSession, Map<EntityId, _Avatar>>{};

  /// The state messages each session accepted, as `sender:fields`.
  final observed = <MultiplayerSession, List<String>>{};

  /// The fields and sample times of the state messages each session
  /// accepted.
  final stamps = <MultiplayerSession, List<(String, Duration?)>>{};

  MultiplayerSession _session({Duration clockOffset = Duration.zero}) {
    late final MultiplayerSession session;
    session = MultiplayerSession(
      schema: schema.schema,
      clock: clockOffset == Duration.zero
          ? clock
          : _OffsetClock(clock, clockOffset),
      stateBackpressure: backpressure,
      onMessage: (sender, envelope) {
        final message = envelope.message as StateMessage;
        final fields = [
          for (final field in message.values.keys) field.value,
        ].join(',');
        (observed[session] ??= []).add('${sender.value}:$fields');
        (stamps[session] ??= []).add((fields, message.sampledAt));
      },
    );
    addTearDown(session.close);
    sessions.add(session);
    _updates.add((session, session.update));
    session.bindSpawn(
      schema.avatar,
      onSpawn: (context) => (_avatars[session] ??= {})[context.entity.id] =
          _Avatar(session, context.entity, schema, lanes: lanes),
    );
    return session;
  }

  /// Joins a new client and waits until it is ready.
  MultiplayerSession join() {
    final session = _session()..join(network.connect());
    run();
    return session;
  }

  /// Joins a client that speaks the protocol directly and reports ready.
  _RawClient rawClient() {
    final client = _RawClient(network.connect(), schema.schema);
    _updates.add((null, client.update));
    run();
    client.send(HelloMessage(fingerprint: schema.schema.fingerprint));
    run();
    client.ready();
    run();
    return client;
  }

  /// Spawns an avatar owned by [owner], whose authority is the host unless
  /// [authority] is given.
  NetworkEntity spawn(
    PeerId owner, {
    PeerId authority = PeerId.host,
    OwnerLeftPolicy onOwnerLeft = OwnerLeftPolicy.keep,
  }) {
    final entity = host.spawn(
      schema.avatar,
      true,
      owner: owner,
      authority: authority,
      onOwnerLeft: onOwnerLeft,
    );
    run();
    return entity;
  }

  /// [session]'s avatar of [entity].
  _Avatar avatar(MultiplayerSession session, NetworkEntity entity) =>
      _avatars[session]![entity.id]!;

  /// Delivers everything in transit and updates every session except the
  /// [stalled] ones.
  void run({Set<MultiplayerSession> stalled = const {}}) {
    for (var i = 0; i < 6; i++) {
      clock.advance(Duration.zero);
      for (final (session, update) in _updates) {
        if (!stalled.contains(session)) update();
      }
    }
  }

  /// After an interval, captures state on every session that is not
  /// [stalled], and delivers it.
  void tick({Set<MultiplayerSession> stalled = const {}}) {
    clock.advance(_interval);
    for (final session in sessions) {
      if (!stalled.contains(session)) session.captureState();
    }
    run(stalled: stalled);
  }
}

/// A client that speaks the protocol directly, to send what a session would
/// not.
final class _RawClient {
  _RawClient(this.peer, ProtocolSchema schema) : codec = ProtocolCodec(schema);

  final InMemoryClient peer;
  final ProtocolCodec codec;
  PeerConnection? connection;
  PeerId? id;
  var generation = 0;

  /// The revision of the baseline that the host welcomed this client with.
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

  /// The revision of the latest transfer that this client received.
  int get transferRevision => received
      .lastWhere((envelope) => envelope.message is AuthorityMessage)
      .revision;

  void send(
    ProtocolMessage message, {
    int revision = 0,
    DeliveryMode mode = DeliveryMode.reliable,
    int channel = 0,
  }) => connection!.send(
    codec.encode(
      MessageEnvelope(message, generation: generation, revision: revision),
    ),
    mode: mode,
    channel: channel,
  );

  /// Sends [values] of [entity]'s fields on the control channel.
  void sendState(NetworkEntity entity, Map<String, Object?> values) => send(
    StateMessage(
      entity: entity.id,
      values: {
        for (final MapEntry(key: field, :value) in values.entries)
          FieldId(field): value,
      },
      sampledAt: Duration.zero,
    ),
  );

  /// Sends a [value] of [entity]'s [field] on channel one, with [sequence].
  void sendLane(
    NetworkEntity entity,
    String field,
    Object? value, {
    required int sequence,
  }) => send(
    StateMessage(
      entity: entity.id,
      values: {FieldId(field): value},
      sampledAt: Duration.zero,
      sequence: sequence,
    ),
    mode: DeliveryMode.unreliableOrdered,
    channel: 1,
  );

  /// Reports ready, acknowledging the baseline.
  void ready() => send(const ReadyMessage(), revision: baseline);

  /// Acknowledges the latest transfer of [entity]'s authority.
  void acknowledge(NetworkEntity entity) =>
      send(AuthorityAckMessage(entity: entity.id), revision: transferRevision);
}

/// A client session joining a host that speaks the protocol directly.
final class _RawHost {
  _RawHost() {
    final network = InMemoryNetwork(
      clock: clock,
      deliveryModes: DeliveryMode.values.toSet(),
      channelCount: 2,
    );
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
    send(const WelcomeMessage(peer: local, epoch: 9));
    send(const SyncedMessage());
    run();
  }

  /// The peer ID that the host gives its client.
  static const local = PeerId(2);

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

  void send(
    ProtocolMessage message, {
    int revision = 0,
    DeliveryMode mode = DeliveryMode.reliable,
    int channel = 0,
  }) => connection!.send(
    codec.encode(MessageEnvelope(message, generation: 5, revision: revision)),
    mode: mode,
    channel: channel,
  );

  /// Sends a [value] of [entity]'s [field] on channel one, with [sequence],
  /// as a dependency of [revision].
  void sendLane(
    NetworkEntity entity,
    String field,
    Object? value, {
    required int sequence,
    required int revision,
  }) => send(
    StateMessage(
      entity: entity.id,
      values: {FieldId(field): value},
      sampledAt: Duration.zero,
      sequence: sequence,
    ),
    revision: revision,
    mode: DeliveryMode.unreliableOrdered,
    channel: 1,
  );
}

void main() {
  group('the host', () {
    test('relays the values an owner writes to the other clients', () {
      final harness = _Harness();
      final owner = harness.join();
      final other = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final onHost = harness.avatar(harness.host, entity)..x = 5;
      final onOwner = harness.avatar(owner, entity)..input = 1;
      final onOther = harness.avatar(other, entity);

      harness.tick();

      expect(onHost.input, 1);
      expect(onOther.input, 1);
      expect(onOwner.x, 5);
      expect(onOther.x, 5);
      expect(onHost.applied, ['input=1']);
      expect(onOwner.applied, ['x=5']);
      expect(onOther.applied, unorderedEquals(['input=1', 'x=5']));
      expect(harness.observed[harness.host], [
        '${owner.localPeer!.value}:test.input',
      ]);
      expect(harness.observed[owner], ['1:test.x']);
      expect(
        harness.observed[other],
        unorderedEquals(['1:test.input', '1:test.x']),
      );
      for (final session in harness.sessions) {
        final synchronizer = harness.avatar(session, entity).synchronizer;
        expect(synchronizer.snapshot(harness.schema.input)?.value, 1);
        expect(synchronizer.snapshot(harness.schema.x)?.value, 5);
      }
      expect(_drain(harness.host).whereType<StateRejected>(), isEmpty);
    });

    test('accepts each field of an entity only from its writer', () {
      final harness = _Harness();
      final owner = harness.rawClient();
      final stranger = harness.rawClient();
      final reader = harness.join();
      final entity = harness.spawn(owner.id!);
      final onHost = harness.avatar(harness.host, entity);
      _drain(harness.host);

      owner
        ..sendState(entity, {'test.input': 1})
        ..sendState(entity, {'test.x': 7});
      stranger
        ..sendState(entity, {'test.input': -1})
        ..sendState(entity, {'test.x': 9});
      harness.run();

      expect(onHost.input, 1);
      expect(onHost.x, 0);
      expect(harness.avatar(reader, entity).input, 1);
      expect(harness.avatar(reader, entity).x, 0);
      expect(harness.observed[harness.host], ['${owner.id!.value}:test.input']);
      expect(
        _drain(harness.host).whereType<StateRejected>().map(
          (event) => (event.entity, event.sender, event.reason),
        ),
        unorderedEquals([
          (entity.id, owner.id, StateRejection.notAuthority),
          (entity.id, stranger.id, StateRejection.notOwner),
          (entity.id, stranger.id, StateRejection.notAuthority),
        ]),
      );
      expect(harness.host.isReady(owner.id!), isTrue);
      expect(harness.host.isReady(stranger.id!), isTrue);
    });

    test('rejects a message that sets a field its sender does not write', () {
      final harness = _Harness();
      final owner = harness.rawClient();
      final entity = harness.spawn(owner.id!);
      final onHost = harness.avatar(harness.host, entity);
      _drain(harness.host);

      owner.sendState(entity, {'test.input': 1, 'test.x': 7});
      harness.run();

      expect(onHost.input, 0);
      expect(onHost.x, 0);
      expect(
        _drain(
          harness.host,
        ).whereType<StateRejected>().map((event) => event.reason),
        [StateRejection.notAuthority],
      );
    });

    test('lets a client that owns and writes an entity write both kinds', () {
      final harness = _Harness();
      final writer = harness.join();
      final other = harness.join();
      final peer = writer.localPeer!;
      final entity = harness.spawn(peer, authority: peer);
      final onWriter = harness.avatar(writer, entity)
        ..input = 1
        ..x = 5;

      harness.tick();

      for (final session in [harness.host, other]) {
        expect(harness.avatar(session, entity).input, 1);
        expect(harness.avatar(session, entity).x, 5);
      }
      expect(onWriter.applied, isEmpty);
      // Each writer's fields travel in their own message.
      expect(harness.observed[harness.host], [
        '${peer.value}:test.input',
        '${peer.value}:test.x',
      ]);
      expect(_drain(harness.host).whereType<StateRejected>(), isEmpty);
    });

    test('writes the owner fields of its entities while a client is their '
        'authority', () {
      final harness = _Harness();
      final authority = harness.join();
      final other = harness.join();
      final entity = harness.spawn(PeerId.host);
      harness.host.transferAuthority(entity, authority.localPeer!);
      harness.run();
      final onHost = harness.avatar(harness.host, entity)..input = 1;
      final onAuthority = harness.avatar(authority, entity)..x = 5;

      harness.tick();

      expect(onAuthority.input, 1);
      expect(onAuthority.applied, ['input=1']);
      expect(onHost.x, 5);
      expect(onHost.applied, ['x=5']);
      expect(harness.avatar(other, entity).input, 1);
      expect(harness.avatar(other, entity).x, 5);
    });

    test('keeps the values of an owner that left for later clients', () {
      final harness = _Harness();
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      harness.avatar(owner, entity).input = 7;
      harness.tick();

      owner.close();
      harness.run();
      final late = harness.join();

      expect(harness.host.registry[entity.id]!.state, EntityState.ready);
      expect(harness.avatar(harness.host, entity).input, 7);
      expect(harness.avatar(late, entity).input, 7);
    });
  });

  group('a client', () {
    test('never applies received values of the fields it owns', () {
      final harness = _RawHost();
      final client = harness.client;
      final entity = client.registry.register(
        const EntityId(2),
        owner: _RawHost.local,
        authority: PeerId.host,
      );
      final avatar = _Avatar(client, entity, harness.schema, lanes: false)
        ..input = 4;
      _drain(client);

      harness
        ..send(
          StateMessage(
            entity: entity.id,
            values: {harness.schema.input.id: 9},
            sampledAt: Duration.zero,
          ),
          revision: 1,
        )
        ..send(
          StateMessage(
            entity: entity.id,
            values: {harness.schema.x.id: 3},
            sampledAt: Duration.zero,
          ),
          revision: 2,
        )
        ..run();

      expect(
        _drain(client).whereType<StateRejected>().map(
          (event) => (event.entity, event.sender, event.reason),
        ),
        [(entity.id, PeerId.host, StateRejection.notOwner)],
      );
      expect(avatar.input, 4);
      expect(avatar.x, 3);
      expect(avatar.applied, ['x=3']);
      expect(avatar.synchronizer.snapshot(harness.schema.input), isNull);
    });

    test('keeps owner values that a transfer of authority made stale', () {
      final harness = _RawHost();
      final client = harness.client;
      final board = client.staticEntity(harness.schema.board);
      final avatar = _Avatar(client, board, harness.schema, lanes: true);

      harness
        ..send(
          AuthorityMessage(entity: board.id, authority: const PeerId(3)),
          revision: 1,
        )
        ..run();
      // Both samples depend on a revision before the transfer.
      harness
        ..sendLane(board, 'test.aim', 4.0, sequence: 1, revision: 0)
        ..sendLane(board, 'test.y', 4.0, sequence: 2, revision: 0)
        ..run();

      expect(board.authority, const PeerId(3));
      expect(avatar.synchronizer.snapshot(harness.schema.aim)?.value, 4.0);
      expect(avatar.synchronizer.snapshot(harness.schema.y), isNull);
    });

    test('keeps writing its fields across transfers of the authority', () {
      final harness = _Harness();
      final owner = harness.join();
      final other = harness.join();
      final peer = owner.localPeer!;
      final entity = harness.spawn(peer, authority: peer);
      final onOwner = harness.avatar(owner, entity)
        ..input = 1
        ..x = 5;
      harness.tick();

      harness.host.transferAuthority(entity, PeerId.host);
      // The owner samples before it learns of the transfer.
      onOwner
        ..input = 2
        ..x = 6;
      harness.tick();

      final onHost = harness.avatar(harness.host, entity);
      final onOther = harness.avatar(other, entity);
      expect(onHost.input, 2);
      expect(onHost.x, 5);
      expect(onOther.input, 2);
      expect(onOther.x, 5);
      // The host's values replace the owner's, apart from its input.
      expect(onOwner.x, 5);
      expect(onOwner.input, 2);
      expect(onOwner.applied, ['x=5']);
      expect(onOwner.synchronizer.snapshot(harness.schema.input)?.value, 2);
      expect(_drain(harness.host).whereType<StateRejected>(), isEmpty);

      onOwner.input = 3;
      onHost.x = 8;
      harness.tick();

      expect(onHost.input, 3);
      expect(onOther.input, 3);
      expect(onOwner.x, 8);
      expect(onOther.x, 8);
      expect(onOwner.applied, ['x=5', 'x=8']);
      expect(_drain(harness.host).whereType<StateRejected>(), isEmpty);
    });

    test('keeps its input when it becomes the authority', () {
      final harness = _Harness();
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final onOwner = harness.avatar(owner, entity)..input = 1;
      harness.avatar(harness.host, entity).x = 5;
      harness.tick();

      // A local change that the owner has not sampled yet.
      onOwner.input = 2;
      harness.host.transferAuthority(entity, owner.localPeer!);
      harness.run();

      expect(onOwner.input, 2);
      expect(onOwner.x, 5);
      expect(onOwner.applied, ['x=5']);

      onOwner.x = 6;
      harness.tick();

      expect(harness.avatar(harness.host, entity).input, 2);
      expect(harness.avatar(harness.host, entity).x, 6);
    });
  });

  group('during a transfer of the authority, the host', () {
    test('accepts the owner fields of its previous authority', () {
      final harness = _Harness(lanes: true);
      final raw = harness.rawClient();
      final entity = harness.spawn(raw.id!, authority: raw.id!);
      final onHost = harness.avatar(harness.host, entity);

      harness.host.transferAuthority(entity, PeerId.host);
      harness.run();
      // The client has not acknowledged the transfer.
      raw
        ..sendState(entity, {'test.input': 1})
        ..sendState(entity, {'test.x': 7})
        ..sendLane(entity, 'test.aim', 4.0, sequence: 1)
        ..sendLane(entity, 'test.y', 4.0, sequence: 2);
      harness.run();

      expect(onHost.input, 1);
      expect(onHost.x, 0);
      expect(onHost.synchronizer.snapshot(harness.schema.aim)?.value, 4.0);
      expect(onHost.synchronizer.snapshot(harness.schema.y), isNull);
      expect(_drain(harness.host).whereType<StateRejected>(), isEmpty);
      expect(harness.host.isReady(raw.id!), isTrue);

      raw
        ..acknowledge(entity)
        ..sendState(entity, {'test.input': 2})
        ..sendState(entity, {'test.x': 8});
      harness.run();

      expect(onHost.input, 2);
      expect(onHost.x, 0);
      expect(
        _drain(
          harness.host,
        ).whereType<StateRejected>().map((event) => event.reason),
        [StateRejection.notAuthority],
      );
    });

    test('keeps the order of the owner\'s samples on their own channel', () {
      final harness = _Harness(lanes: true);
      final raw = harness.rawClient();
      final entity = harness.spawn(raw.id!);
      final onHost = harness.avatar(harness.host, entity);
      raw.sendLane(entity, 'test.aim', 5.0, sequence: 5);
      harness.run();

      harness.host.transferAuthority(entity, raw.id!);
      harness.run();
      raw.sendLane(entity, 'test.aim', 3.0, sequence: 3);
      harness.run();

      expect(onHost.synchronizer.snapshot(harness.schema.aim)?.value, 5.0);
    });
  });

  group('congestion', () {
    const backpressure = QueueLimits(maxMessages: 2);

    test('newer owner values replace unsent ones', () {
      final harness = _Harness(backpressure: backpressure);
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final onOwner = harness.avatar(owner, entity);
      final onHost = harness.avatar(harness.host, entity);
      harness.tick();

      for (var input = 1; input <= 10; input++) {
        onOwner.input = input;
        harness.tick(stalled: {harness.host});
      }

      final peer = owner.diagnostics.peers.single;
      expect(peer.outgoing.messages, 2);
      expect(peer.heldState.messages, 1);
      expect(peer.coalescedStates, 7);
      harness.run();
      expect(onHost.applied, ['input=0', 'input=2', 'input=10']);
      expect(owner.diagnostics.peers.single.heldState.messages, 0);
    });

    test('holds owner and authority values of an entity apart', () {
      final harness = _Harness(backpressure: backpressure);
      final owner = harness.join();
      final other = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final onOwner = harness.avatar(owner, entity);
      final onHost = harness.avatar(harness.host, entity);
      final onOther = harness.avatar(other, entity);
      harness.tick();

      for (var value = 1; value <= 10; value++) {
        onOwner.input = value;
        onHost.x = -value;
        harness.tick(stalled: {other});
      }

      final peer = harness.host.diagnostics.peers.singleWhere(
        (peer) => peer.peer == other.localPeer,
      );
      expect(peer.heldState.messages, 2);
      harness.run();
      expect(onOther.input, 10);
      expect(onOther.x, -10);
      expect(other.obsoleteMessageCount, 0);
      expect(other.revision, harness.host.revision);
    });
  });

  group('late joining', () {
    test('a client receives owner values in its baseline', () {
      final harness = _Harness();
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      harness.avatar(owner, entity).input = 3;
      harness.avatar(harness.host, entity).x = 5;
      harness.tick();

      final late = harness.join();
      final onLate = harness.avatar(late, entity);

      expect(late.state, SessionState.ready);
      expect(onLate.input, 3);
      expect(onLate.x, 5);
      expect(onLate.applied, unorderedEquals(['input=3', 'x=5']));
      expect(onLate.synchronizer.snapshot(harness.schema.input)?.value, 3);
    });

    test("a baseline keeps each writer's sample time", () {
      const offset = Duration(hours: 1);
      final harness = _Harness(hostClockOffset: offset);
      final owner = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      harness.avatar(owner, entity).input = 3;
      harness.avatar(harness.host, entity).x = 5;
      harness.tick();
      final sampledAt = harness.clock.now;

      final late = harness.join();

      expect(
        harness.stamps[late],
        unorderedEquals([
          ('test.input', sampledAt),
          ('test.x', sampledAt + offset),
        ]),
      );
    });
  });

  group('interpolation', () {
    test("follows each writer's clock", () {
      const offset = Duration(hours: 1);
      final harness = _Harness(hostClockOffset: offset, lanes: true);
      final owner = harness.join();
      final other = harness.join();
      final entity = harness.spawn(owner.localPeer!);
      final onOwner = harness.avatar(owner, entity);
      final onHost = harness.avatar(harness.host, entity);
      final synchronizer = harness.avatar(other, entity).synchronizer;

      for (var i = 1; i <= 5; i++) {
        onOwner.aim = i * 10.0;
        onHost.y = i * 10.0;
        harness.tick();
      }
      harness.clock.advance(_interval ~/ 2);

      // Presentation trails the newest samples by two intervals, so it is
      // halfway between the third and fourth samples of each writer.
      final aim = synchronizer.interpolated(harness.schema.aim)!;
      final y = synchronizer.interpolated(harness.schema.y)!;
      expect(aim.state, InterpolationState.interpolating);
      expect(aim.value, closeTo(35, 1e-9));
      expect(y.state, InterpolationState.interpolating);
      expect(y.value, closeTo(35, 1e-9));
      expect(onOwner.synchronizer.interpolated(harness.schema.aim), isNull);
      expect(onHost.synchronizer.interpolated(harness.schema.y), isNull);
      expect(onHost.synchronizer.interpolated(harness.schema.aim), isNotNull);

      // A transfer restarts only the timeline of authority-written fields.
      harness.host.transferAuthority(entity, owner.localPeer!);
      harness.run();

      final held = synchronizer.interpolated(harness.schema.y)!;
      expect(held.state, InterpolationState.holding);
      expect(held.value, 50);
      final continued = synchronizer.interpolated(harness.schema.aim)!;
      expect(continued.state, InterpolationState.interpolating);
      expect(continued.value, closeTo(35, 1e-9));
    });
  });
}
