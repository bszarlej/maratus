import 'dart:async';

import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

const _interval = Duration(milliseconds: 50);

List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

/// The registrations shared by every session of a test.
final class _Schema {
  _Schema() {
    final builder = ProtocolSchemaBuilder();
    ball = builder.addSpawnType(
      const SpawnTypeId('test.ball'),
      const BoolCodec(),
    );
    x = builder.addField(
      const FieldId('test.x'),
      const IntCodec(min: 0, max: 100000),
    );
    label = builder.addField(
      const FieldId('test.label'),
      const StringCodec(maxLength: 16),
    );
    position = builder.addField(
      const FieldId('test.position'),
      const DoubleCodec(min: -1000, max: 1000),
    );
    kick = builder.addRpc(
      const RpcId('test.kick'),
      const IntCodec(min: 0, max: 9),
      target: RpcTarget.authority,
      local: RpcLocal.include,
    );
    board = builder.addStaticEntity(const StaticEntityId('test.board'));
    schema = builder.build();
  }

  late final SpawnType<bool> ball;
  late final SyncField<int> x;
  late final SyncField<String> label;
  late final SyncField<double> position;
  late final Rpc<int> kick;
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

/// One peer's copy of an entity, whose synchronizer writes [x], [label],
/// and [position] on the entity's authority and applies [x] and [label]
/// elsewhere. Other peers present [position] only through interpolation.
final class _Model {
  _Model(MultiplayerSession session, NetworkEntity entity, _Schema schema) {
    attachment = session.attachEntity(
      entity,
      isReady: () => ready,
      isValid: () => true,
    );
    synchronizer = attachment.synchronize([
      schema.x.property(
        get: () => x,
        set: (value) {
          x = value;
          applied.add(value);
        },
      ),
      schema.label.property(get: () => label, set: (value) => label = value),
      schema.position.property(
        get: () => position,
        interpolator: const DoubleInterpolator(),
      ),
    ], interval: _interval);
    attachment.bindRpc(schema.kick, (_, value) => kicks.add(value));
  }

  late final EntityAttachment attachment;
  late final MultiplayerSynchronizer synchronizer;
  var ready = true;
  var x = 0;
  var label = '';
  var position = 0.0;

  /// The values of [x] that the synchronizer applied.
  final applied = <int>[];
  final kicks = <int>[];
}

/// A host and the clients that join it over an in-memory network, each
/// with a model of every ball.
final class _Harness {
  /// Creates a host whose clock runs [hostClockOffset] ahead of its
  /// clients', with [backpressure] for every session.
  _Harness({
    Duration hostClockOffset = Duration.zero,
    this.backpressure = const QueueLimits(
      maxMessages: 256,
      maxBytes: 1024 * 1024,
    ),
  }) {
    network = InMemoryNetwork(clock: clock);
    host = _session(clockOffset: hostClockOffset)..host(network.host());
  }

  final QueueLimits backpressure;
  final clock = ManualClock();
  final schema = _Schema();
  late final InMemoryNetwork network;
  late final MultiplayerSession host;
  final sessions = <MultiplayerSession>[];

  /// The update of each session and raw client, in creation order.
  final _updates = <(MultiplayerSession?, void Function())>[];
  final _models = <MultiplayerSession, Map<EntityId, _Model>>{};

  /// The authority that each session's spawn handler saw, by entity.
  final spawnedWith = <MultiplayerSession, Map<EntityId, PeerId>>{};

  MultiplayerSession _session({Duration clockOffset = Duration.zero}) {
    final session = MultiplayerSession(
      schema: schema.schema,
      clock: clockOffset == Duration.zero
          ? clock
          : _OffsetClock(clock, clockOffset),
      stateBackpressure: backpressure,
    );
    addTearDown(session.close);
    sessions.add(session);
    _updates.add((session, session.update));
    session.bindSpawn(
      schema.ball,
      onSpawn: (context) {
        final entity = context.entity;
        (spawnedWith[session] ??= {})[entity.id] = entity.authority;
        (_models[session] ??= {})[entity.id] = _Model(session, entity, schema);
      },
    );
    return session;
  }

  /// Joins a new client and waits until it is ready.
  MultiplayerSession join() {
    final session = _session()..join(network.connect());
    run();
    return session;
  }

  _RawClient rawClient() {
    final client = _RawClient(network.connect(), schema.schema);
    _updates.add((null, client.update));
    run();
    client.send(HelloMessage(fingerprint: schema.schema.fingerprint));
    run();
    client.send(const ReadyMessage());
    run();
    return client;
  }

  /// Attaches a model of the static board on every session.
  Map<MultiplayerSession, _Model> attachBoard() => {
    for (final session in sessions)
      session: _Model(session, session.staticEntity(schema.board), schema),
  };

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

  /// [session]'s model of [entity].
  _Model model(MultiplayerSession session, NetworkEntity entity) =>
      _models[session]![entity.id]!;

  /// [session]'s copy of [entity].
  NetworkEntity on(MultiplayerSession session, NetworkEntity entity) =>
      session.registry[entity.id]!;

  /// Expects every session to agree on [entity]'s authority and on its
  /// replicated values of `x` and `label`, and to hold [x] locally.
  void expectAgreement(NetworkEntity entity, {required int x}) {
    final authority = entity.authority;
    for (final session in sessions) {
      final model = this.model(session, entity);
      final reason = 'on peer ${session.localPeer?.value}';
      expect(on(session, entity).authority, authority, reason: reason);
      expect(model.x, x, reason: reason);
      expect(model.synchronizer.snapshot(schema.x)?.value, x, reason: reason);
      expect(
        model.synchronizer.snapshot(schema.label)?.value,
        this.model(host, entity).synchronizer.snapshot(schema.label)?.value,
        reason: reason,
      );
    }
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
  final received = <MessageEnvelope>[];

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
          }
          received.add(envelope);
        case ConnectionClosed():
          break;
      }
    }
  }

  /// The revision of the latest transfer that this client received.
  int get transferRevision => received
      .lastWhere((envelope) => envelope.message is AuthorityMessage)
      .revision;

  void send(ProtocolMessage message, {int revision = 0}) => connection!.send(
    codec.encode(
      MessageEnvelope(message, generation: generation, revision: revision),
    ),
  );

  void sendX(NetworkEntity entity, int x) => send(
    StateMessage(
      entity: entity.id,
      values: {const FieldId('test.x'): x},
      sampledAt: Duration.zero,
    ),
  );
}

void main() {
  group('transferAuthority', () {
    test('moves an entity\'s authority on every peer', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      final ball = harness.host.spawn(harness.schema.ball, true);
      harness.run();
      final peer = first.localPeer!;
      harness.sessions.forEach(_drain);

      expect(harness.host.transferAuthority(ball, peer), isTrue);
      harness.run();

      for (final session in harness.sessions) {
        expect(harness.on(session, ball).authority, peer);
        expect(_drain(session), [
          AuthorityChanged(
            entity: ball.id,
            previous: PeerId.host,
            authority: peer,
          ),
        ]);
      }
      expect(second.revision, harness.host.revision);
      expect(harness.host.transferAuthority(ball, peer), isFalse);
      harness.run();
      for (final session in harness.sessions) {
        expect(_drain(session), isEmpty);
      }
    });

    test('lets the new authority write the entity\'s state', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      final ball = harness.host.spawn(harness.schema.ball, true);
      harness.run();
      harness.model(harness.host, ball).x = 1;
      harness.tick();

      harness.host.transferAuthority(ball, first.localPeer!);
      harness.run();
      harness.model(first, ball)
        ..x = 2
        ..label = 'first';
      harness.model(harness.host, ball).x = 3;
      harness.tick();

      for (final session in harness.sessions) {
        expect(harness.model(session, ball).x, 2, reason: '$session');
        expect(harness.model(session, ball).label, 'first');
      }
      expect(harness.model(first, ball).applied, [1]);
      expect(harness.model(second, ball).applied, [1, 2]);
      // The previous authority applies the replicated values, starting with
      // the last one it sent.
      expect(harness.model(harness.host, ball).applied, [1, 2]);
      for (final session in harness.sessions) {
        expect(_drain(session).whereType<StateRejected>(), isEmpty);
      }
    });

    test('transfers static entities', () {
      final harness = _Harness();
      final client = harness.join();
      final models = harness.attachBoard();
      final board = harness.host.staticEntity(harness.schema.board);

      expect(harness.host.transferAuthority(board, client.localPeer!), isTrue);
      harness.run();
      models[client]!.x = 4;
      harness.tick();

      expect(
        client.staticEntity(harness.schema.board).authority,
        client.localPeer,
      );
      expect(models[harness.host]!.x, 4);
    });

    test('accepts only the host or a ready client as the new authority', () {
      final harness = _Harness();
      final client = harness.join();
      final ball = harness.host.spawn(harness.schema.ball, true);
      harness.run();
      final departed = harness.join().localPeer!;
      harness.sessions.last.close();
      harness.run();

      for (final authority in [const PeerId(99), departed]) {
        expect(
          () => harness.host.transferAuthority(ball, authority),
          throwsArgumentError,
        );
      }
      expect(
        () => client.transferAuthority(harness.on(client, ball), PeerId.host),
        throwsStateError,
      );
      expect(ball.authority, PeerId.host);
    });

    test('accepts only live replicated and static entities', () {
      final harness = _Harness();
      final client = harness.join();
      final registered = harness.host.registry.create(
        owner: PeerId.host,
        authority: PeerId.host,
      );
      final despawned = harness.host.spawn(harness.schema.ball, true);
      harness.host.despawn(despawned);
      final foreign = client.staticEntity(harness.schema.board);

      for (final entity in [registered, despawned, foreign]) {
        expect(
          () => harness.host.transferAuthority(entity, client.localPeer!),
          throwsArgumentError,
        );
      }
    });

    test('routes RPCs to the new authority', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      final ball = harness.host.spawn(harness.schema.ball, true);
      harness.run();

      harness.host.transferAuthority(ball, first.localPeer!);
      expect(
        second.callRpc(harness.on(second, ball), harness.schema.kick, 7),
        isTrue,
      );
      harness.run();

      expect(harness.model(first, ball).kicks, [7]);
      expect(harness.model(harness.host, ball).kicks, isEmpty);
      expect(harness.model(second, ball).kicks, isEmpty);
    });
  });

  group('acknowledgement', () {
    test(
      'drops state that the previous authority sent before the transfer',
      () {
        final harness = _Harness();
        final first = harness.join();
        harness.join();
        final peer = first.localPeer!;
        final ball = harness.host.spawn(
          harness.schema.ball,
          true,
          owner: peer,
          authority: peer,
        );
        harness.run();
        harness.model(first, ball).x = 1;
        harness.tick();
        harness.sessions.forEach(_drain);

        // The client samples before the transfer reaches it.
        harness.model(first, ball).x = 2;
        harness.clock.advance(_interval);
        first.captureState();
        harness.host.transferAuthority(ball, PeerId.host);
        harness.run();

        // The previous authority takes back the value the host accepted.
        harness.expectAgreement(ball, x: 1);
        expect(harness.model(first, ball).applied, [1]);
        expect(_drain(harness.host), [
          AuthorityChanged(
            entity: ball.id,
            previous: peer,
            authority: PeerId.host,
          ),
        ]);
      },
    );

    test('rejects state that the previous authority sends afterward', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      final ball = harness.host.spawn(
        harness.schema.ball,
        true,
        owner: raw.id!,
        authority: raw.id!,
      );
      harness.run();
      final model = harness.model(harness.host, ball);
      raw.sendX(ball, 1);
      harness.run();
      expect(model.x, 1);

      harness.host.transferAuthority(ball, PeerId.host);
      harness.run();
      raw.sendX(ball, 2);
      harness.run();
      expect(model.x, 1);
      _drain(harness.host);

      raw
        ..send(
          AuthorityAckMessage(entity: ball.id),
          revision: raw.transferRevision,
        )
        ..sendX(ball, 3);
      harness.run();

      expect(model.x, 1);
      expect(_drain(harness.host), [
        isA<StateRejected>()
            .having((event) => event.entity, 'entity', ball.id)
            .having((event) => event.sender, 'sender', raw.id)
            .having(
              (event) => event.reason,
              'reason',
              StateRejection.notAuthority,
            ),
      ]);
    });

    test(
      'accepts the new authority\'s state only after its acknowledgement',
      () {
        final harness = _Harness();
        final reader = harness.join();
        final raw = harness.rawClient();
        final ball = harness.host.spawn(harness.schema.ball, true);
        harness.run();

        harness.host.transferAuthority(ball, raw.id!);
        harness.run();
        raw.sendX(ball, 5);
        harness.run();
        expect(harness.model(harness.host, ball).x, 0);
        expect(harness.model(reader, ball).x, 0);

        raw
          ..send(
            AuthorityAckMessage(entity: ball.id),
            revision: raw.transferRevision,
          )
          ..sendX(ball, 6);
        harness.run();

        expect(harness.model(harness.host, ball).x, 6);
        expect(harness.model(reader, ball).x, 6);
        expect(_drain(harness.host).whereType<StateRejected>(), isEmpty);
      },
    );

    test('ignores acknowledgements of earlier transfers', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      final ball = harness.host.spawn(harness.schema.ball, true);
      harness.run();
      harness.host.transferAuthority(ball, raw.id!);
      harness.run();
      final earlier = raw.transferRevision;
      harness.host
        ..transferAuthority(ball, PeerId.host)
        ..transferAuthority(ball, raw.id!);
      harness.run();

      raw
        ..send(AuthorityAckMessage(entity: ball.id), revision: earlier)
        ..sendX(ball, 5);
      harness.run();
      expect(harness.model(harness.host, ball).x, 0);

      raw
        ..send(
          AuthorityAckMessage(entity: ball.id),
          revision: raw.transferRevision,
        )
        ..sendX(ball, 6);
      harness.run();
      expect(harness.model(harness.host, ball).x, 6);
      expect(harness.host.isReady(raw.id!), isTrue);
    });

    test('drops a client that acknowledges a revision not assigned yet', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      final peer = raw.id!;
      final ball = harness.host.spawn(harness.schema.ball, true);
      harness.run();
      _drain(harness.host);

      raw.send(
        AuthorityAckMessage(entity: ball.id),
        revision: harness.host.revision + 1,
      );
      harness.run();

      expect(_drain(harness.host), [
        PeerLeft(peer, DisconnectReason.protocolViolation),
      ]);
    });

    test('a session acknowledges a transfer before sending state', () {
      final harness = _Harness();
      final client = harness.join();
      final ball = harness.host.spawn(harness.schema.ball, true);
      harness.run();
      final before = client.diagnostics.sent;

      harness.host.transferAuthority(ball, client.localPeer!);
      harness.run();
      harness.model(client, ball).x = 1;
      harness.tick();

      final sent = client.diagnostics.sent;
      expect(
        sent[MessageKind.authorityAck].messages -
            before[MessageKind.authorityAck].messages,
        1,
      );
      expect(harness.model(harness.host, ball).x, 1);
    });
  });

  group('a joining client', () {
    test('receives the current authority of spawned entities', () {
      final harness = _Harness();
      final first = harness.join();
      final ball = harness.host.spawn(harness.schema.ball, true);
      harness.run();
      harness.host.transferAuthority(ball, first.localPeer!);
      harness.run();

      final late = harness.join();

      expect(late.isReady(PeerId.host), isTrue);
      expect(harness.on(late, ball).authority, first.localPeer);
      expect(harness.spawnedWith[late]![ball.id], first.localPeer);
      expect(_drain(late).whereType<AuthorityChanged>(), isEmpty);
    });

    test('receives the current authority of static entities', () {
      final harness = _Harness();
      final first = harness.join();
      final board = harness.host.staticEntity(harness.schema.board);
      harness.host.transferAuthority(board, first.localPeer!);
      harness.run();

      final late = harness.join();

      final onLate = late.staticEntity(harness.schema.board);
      expect(onLate.authority, first.localPeer);
      expect(_drain(late).whereType<AuthorityChanged>(), [
        AuthorityChanged(
          entity: board.id,
          previous: PeerId.host,
          authority: first.localPeer!,
        ),
      ]);
    });

    test('presents values of a previous authority without blending them', () {
      // The host's samples carry times far ahead of its clients'.
      final harness = _Harness(hostClockOffset: const Duration(minutes: 1));
      final first = harness.join();
      final ball = harness.host.spawn(harness.schema.ball, true);
      harness.run();
      harness.model(harness.host, ball)
        ..x = 1
        ..position = 10;
      harness.tick();
      harness.host.transferAuthority(ball, first.localPeer!);
      harness.run();
      harness.model(first, ball)
        ..x = 2
        ..position = 10;
      harness.tick();

      final late = harness.join();
      final synchronizer = harness.model(late, ball).synchronizer;

      harness.expectAgreement(ball, x: 2);
      expect(
        synchronizer.interpolated(harness.schema.position),
        isA<InterpolatedValue<double>>()
            .having((value) => value.value, 'value', 10)
            .having(
              (value) => value.state,
              'state',
              InterpolationState.holding,
            ),
      );

      harness.model(first, ball).position = 20;
      harness.tick();

      expect(synchronizer.interpolated(harness.schema.position)?.value, 20);
    });
  });

  group('synchronizers', () {
    test('keep the host\'s values across a transfer away and back', () {
      final harness = _Harness();
      final first = harness.join();
      harness.join();
      final peer = first.localPeer!;
      final ball = harness.host.spawn(
        harness.schema.ball,
        true,
        owner: peer,
        authority: peer,
      );
      harness.run();
      harness.model(first, ball).x = 1;
      harness.tick();

      harness.model(first, ball).x = 2;
      harness.clock.advance(_interval);
      first.captureState();
      harness.host
        ..transferAuthority(ball, PeerId.host)
        ..transferAuthority(ball, peer);
      harness.run();
      harness.tick();

      harness.expectAgreement(ball, x: 1);

      harness.model(first, ball).x = 4;
      harness.tick();
      harness.expectAgreement(ball, x: 4);
    });

    test('let a new authority continue from the values it received', () {
      final harness = _Harness();
      final client = harness.join();
      final ball = harness.host.spawn(harness.schema.ball, true);
      harness.run();
      final model = harness.model(client, ball)..ready = false;
      harness.model(harness.host, ball)
        ..x = 5
        ..label = 'host';
      harness.tick();
      expect(model.x, 0);

      harness.host.transferAuthority(ball, client.localPeer!);
      harness.run();
      model.ready = true;
      harness.tick();

      harness.expectAgreement(ball, x: 5);
      expect(model.applied, [5]);
      expect(model.label, 'host');
    });

    test('apply values that arrive in the update that transfers them', () {
      final harness = _Harness();
      final client = harness.join();
      final ball = harness.host.spawn(harness.schema.ball, true);
      harness.run();

      harness.model(harness.host, ball).x = 6;
      harness.clock.advance(_interval);
      harness.host
        ..captureState()
        ..transferAuthority(ball, client.localPeer!);
      harness.run();
      harness.tick();

      harness.expectAgreement(ball, x: 6);
      expect(harness.model(client, ball).applied, [6]);
    });

    test('deliver held state before a transfer to a congested client', () {
      final harness = _Harness(backpressure: const QueueLimits(maxMessages: 2));
      final writer = harness.join();
      final stalled = harness.join();
      final peer = writer.localPeer!;
      final ball = harness.host.spawn(
        harness.schema.ball,
        true,
        owner: peer,
        authority: peer,
      );
      harness.run();
      for (var x = 1; x <= 6; x++) {
        harness.model(writer, ball).x = x;
        harness.tick(stalled: {stalled});
      }
      PeerDiagnostics atHost() => harness.host.diagnostics.peers.singleWhere(
        (diagnostics) => diagnostics.peer == stalled.localPeer,
      );
      expect(atHost().heldState.messages, 1);

      harness.host.transferAuthority(ball, PeerId.host);
      expect(atHost().heldState.messages, 0);
      harness.run();
      harness.model(harness.host, ball).x = 9;
      harness.tick();

      harness.expectAgreement(ball, x: 9);
      expect(harness.model(stalled, ball).applied, containsAllInOrder([6, 9]));
      expect(stalled.obsoleteMessageCount, 0);
      expect(stalled.revision, harness.host.revision);
    });

    test('restart interpolation with the new authority\'s samples', () {
      // The host's samples carry times far ahead of its clients'.
      final harness = _Harness(hostClockOffset: const Duration(minutes: 1));
      final first = harness.join();
      final observer = harness.join();
      final ball = harness.host.spawn(harness.schema.ball, true);
      harness.run();
      for (final position in [0.0, 10.0]) {
        harness.model(harness.host, ball).position = position;
        harness.tick();
      }
      InterpolatedValue<double>? shown(MultiplayerSession session) => harness
          .model(session, ball)
          .synchronizer
          .interpolated(harness.schema.position);

      harness.host.transferAuthority(ball, first.localPeer!);
      harness.run();

      for (final session in [harness.host, observer]) {
        expect(
          shown(session),
          isA<InterpolatedValue<double>>()
              .having((value) => value.value, 'value', 10)
              .having(
                (value) => value.state,
                'state',
                InterpolationState.holding,
              ),
        );
      }
      expect(shown(first), isNull);

      // Presentation trails the newest sample by two intervals.
      for (final position in [20.0, 30.0, 40.0, 50.0]) {
        harness.model(first, ball).position = position;
        harness.tick();
      }
      for (final session in [harness.host, observer]) {
        expect(shown(session)!.value, 30);
      }
    });
  });
}
