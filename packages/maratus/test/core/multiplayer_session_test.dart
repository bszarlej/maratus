import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

import '../protocol/protocol_test_utils.dart';

const _ms = Duration(milliseconds: 1);
const _client1 = PeerId(2);
const _client2 = PeerId(3);
const _client3 = PeerId(4);

final _name = StateMessage(
  entity: const EntityId(7),
  values: const {FieldId('player.name'): 'Ada'},
  sampledAt: Duration.zero,
);
final _health = StateMessage(
  entity: const EntityId(7),
  values: const {FieldId('player.health'): 50},
  sampledAt: Duration.zero,
);

/// A random source whose [nextInt] returns scripted values in order.
final class _ScriptedRandom implements Random {
  _ScriptedRandom(this._values);

  final List<int> _values;
  var _next = 0;

  @override
  int nextInt(int max) => _values[_next++];

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

/// A schema with two static entities, a spawn type, and a field and an RPC
/// for the board, optionally declaring an `extra` static entity.
final class _StaticProtocol {
  factory _StaticProtocol({String? extra}) {
    final builder = ProtocolSchemaBuilder();
    // Declared out of identifier order, which assigns the entity IDs.
    final level = builder.addStaticEntity(const StaticEntityId('arena.level'));
    final board = builder.addStaticEntity(const StaticEntityId('arena.board'));
    if (extra != null) builder.addStaticEntity(StaticEntityId(extra));
    final player = builder.addSpawnType(
      const SpawnTypeId('player'),
      const StringCodec(maxLength: 16),
    );
    final score = builder.addField(
      const FieldId('arena.board.score'),
      const IntCodec(min: 0),
    );
    final vote = builder.addRpc(
      const RpcId('arena.board.vote'),
      const IntCodec(min: 0, max: 3),
    );
    return _StaticProtocol._(
      builder.build(),
      board,
      level,
      player,
      score,
      vote,
    );
  }

  _StaticProtocol._(
    this.schema,
    this.board,
    this.level,
    this.player,
    this.score,
    this.vote,
  );

  final ProtocolSchema schema;
  final StaticEntity board;
  final StaticEntity level;
  final SpawnType<String> player;
  final SyncField<int> score;
  final Rpc<int> vote;
}

/// Takes every pending event from [session].
List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

/// The spawn type registered by [buildTestSchema].
SpawnType<String> _player(ProtocolSchema schema) =>
    schema.spawnTypeDefinition(const SpawnTypeId('player'))!
        as SpawnType<String>;

/// The movement RPC registered by [buildTestSchema].
Rpc<MoveInput> _move(ProtocolSchema schema) =>
    schema.rpcDefinition(const RpcId('player.move'))! as Rpc<MoveInput>;

/// Advances [clock] by [step], then runs [updates], [rounds] times.
void _run(
  ManualClock clock,
  List<void Function()> updates, {
  Duration step = Duration.zero,
  int rounds = 6,
}) {
  for (var i = 0; i < rounds; i++) {
    clock.advance(step);
    for (final update in updates) {
      update();
    }
  }
}

/// A host session and the clients that join it over an in-memory network.
final class _Harness {
  _Harness({
    Duration latency = Duration.zero,
    this.timeouts = const SessionTimeouts(),
    QueueLimits hostOutgoingLimits = const QueueLimits(),
    ProtocolSchema? schema,
  }) : schema = schema ?? buildTestSchema() {
    network = InMemoryNetwork(clock: clock, latency: latency);
    host = session()..host(network.host(outgoingLimits: hostOutgoingLimits));
  }

  final clock = ManualClock();
  final SessionTimeouts timeouts;
  final ProtocolSchema schema;
  late final InMemoryNetwork network;
  late final MultiplayerSession host;

  /// The state messages that [host] accepted, with their senders.
  final received = <(PeerId, MessageEnvelope)>[];
  final _updates = <void Function()>[];

  /// Creates a session; the first one is [host].
  MultiplayerSession session({ProtocolSchema? schema, int seed = 1}) {
    final first = _updates.isEmpty;
    final session = MultiplayerSession(
      schema: schema ?? this.schema,
      clock: clock,
      timeouts: timeouts,
      random: Random(seed),
      onMessage: first
          ? (sender, envelope) => received.add((sender, envelope))
          : null,
    );
    _updates.add(session.update);
    return session;
  }

  /// Starts a client session joining the host.
  MultiplayerSession join({ProtocolSchema? schema}) =>
      session(schema: schema)..join(network.connect());

  /// Starts a client that speaks the protocol directly.
  _RawClient rawClient() {
    final client = _RawClient(network.connect());
    _updates.add(client.update);
    return client;
  }

  /// Advances the clock by [step] and updates everything, [rounds] times.
  void run({Duration step = Duration.zero, int rounds = 6}) =>
      _run(clock, _updates, step: step, rounds: rounds);
}

/// A client that speaks the protocol directly, to send what a session would
/// not.
final class _RawClient {
  _RawClient(this.peer);

  final InMemoryClient peer;
  final codec = ProtocolCodec(buildTestSchema());
  PeerConnection? connection;
  PeerId? id;
  var generation = 0;

  /// The revision of the baseline that the host welcomed this client with.
  var baseline = 0;
  final received = <ProtocolMessage>[];
  CloseReason? closeReason;

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
        case ConnectionClosed(:final reason):
          closeReason = reason;
      }
    }
  }

  void send(ProtocolMessage message, {int? generation, int revision = 0}) =>
      sendBytes(
        codec.encode(
          MessageEnvelope(
            message,
            generation: generation ?? this.generation,
            revision: revision,
          ),
        ),
      );

  void sendBytes(List<int> bytes) =>
      connection!.send(Uint8List.fromList(bytes));

  void hello([ProtocolSchema? schema]) => send(
    HelloMessage(fingerprint: (schema ?? buildTestSchema()).fingerprint),
  );

  /// Reports ready, acknowledging the baseline.
  void ready() => send(const ReadyMessage(), revision: baseline);
}

/// A host that speaks the protocol directly, to send what a session would
/// not.
final class _RawHost {
  _RawHost(this.peer);

  final InMemoryHost peer;
  final codec = ProtocolCodec(buildTestSchema());
  PeerConnection? connection;
  final received = <ProtocolMessage>[];

  void update() {
    for (var event = peer.poll(); event != null; event = peer.poll()) {
      switch (event) {
        case ConnectionOpened(:final connection):
          this.connection = connection;
        case MessageReceived(:final message):
          received.add(codec.decode(message).message);
        case ConnectionClosed():
          break;
      }
    }
  }

  void send(ProtocolMessage message, {int generation = 0, int revision = 0}) =>
      sendBytes(
        codec.encode(
          MessageEnvelope(message, generation: generation, revision: revision),
        ),
      );

  void sendBytes(List<int> bytes) =>
      connection!.send(Uint8List.fromList(bytes));
}

/// A client session joining a [_RawHost].
final class _RawHostHarness {
  _RawHostHarness({
    this.timeouts = const SessionTimeouts(),
    SessionMessageHandler? onMessage,
  }) {
    network = InMemoryNetwork(clock: clock);
    host = _RawHost(network.host());
    client = MultiplayerSession(
      schema: buildTestSchema(),
      clock: clock,
      timeouts: timeouts,
      onMessage: (sender, envelope) {
        received.add((sender, envelope));
        onMessage?.call(sender, envelope);
      },
    )..join(network.connect());
    // The entity that the host's state messages describe.
    client.registry.register(
      const EntityId(7),
      owner: PeerId.host,
      authority: PeerId.host,
    );
  }

  final clock = ManualClock();
  final SessionTimeouts timeouts;
  late final InMemoryNetwork network;
  late final _RawHost host;
  late final MultiplayerSession client;

  /// The state messages that [client] accepted, with their senders.
  final received = <(PeerId, MessageEnvelope)>[];

  void run({Duration step = Duration.zero, int rounds = 6}) =>
      _run(clock, [host.update, client.update], step: step, rounds: rounds);

  /// Welcomes the client with [generation], at [revision].
  void welcome({int generation = 5, int revision = 0}) {
    host
      ..send(
        const WelcomeMessage(peer: _client1, epoch: 9),
        generation: generation,
        revision: revision,
      )
      ..send(const SyncedMessage(), generation: generation, revision: revision);
    run();
  }
}

void main() {
  group('hosting', () {
    test('starts with a new epoch as the host peer', () {
      final harness = _Harness();

      expect(harness.host.state, SessionState.hosting);
      expect(harness.host.isHost, isTrue);
      expect(harness.host.localPeer, PeerId.host);
      expect(harness.host.epoch, isNotNull);
      expect(harness.host.peers, isEmpty);
      expect(_drain(harness.host), [
        const SessionStateChanged(SessionState.hosting),
      ]);
    });

    test('chooses a new epoch each time it starts', () {
      final harness = _Harness();
      final first = harness.host.epoch;

      harness.host
        ..close()
        ..host(harness.network.host());

      expect(harness.host.epoch, isNot(first));
    });

    test('never repeats the epoch of its previous session', () {
      final clock = ManualClock();
      final session = MultiplayerSession(
        schema: buildTestSchema(),
        clock: clock,
        random: _ScriptedRandom([6, 6, 6, 8]),
      )..host(InMemoryNetwork(clock: clock).host());
      expect(session.epoch, 7);

      session
        ..close()
        ..host(InMemoryNetwork(clock: clock).host());

      expect(session.epoch, 9);
    });

    test('requires a disconnected session and the right kind of peer', () {
      final harness = _Harness();
      final idle = harness.session();
      final otherHost = InMemoryNetwork(clock: harness.clock).host();

      expect(() => harness.host.host(otherHost), throwsStateError);
      expect(() => idle.host(harness.network.connect()), throwsArgumentError);
      expect(() => idle.join(otherHost), throwsArgumentError);
      expect(idle.state, SessionState.disconnected);
    });
  });

  group('joining', () {
    test('admits a client through the handshake', () {
      final harness = _Harness(latency: _ms * 10);
      final client = harness.join();

      harness.run(step: _ms * 10, rounds: 2);
      expect(client.state, SessionState.handshaking);
      harness.run(step: _ms * 10, rounds: 3);

      expect(_drain(client), [
        const SessionStateChanged(SessionState.connecting),
        const SessionStateChanged(SessionState.handshaking),
        const SessionStateChanged(SessionState.synchronizing),
        const SessionStateChanged(SessionState.ready),
      ]);
      expect(_drain(harness.host), [
        const SessionStateChanged(SessionState.hosting),
        const PeerJoined(_client1),
        const PeerReady(_client1),
      ]);
      expect(client.localPeer, _client1);
      expect(client.epoch, harness.host.epoch);
      expect(client.generation, isNotNull);
      expect(client.peers, [PeerId.host]);
      expect(client.isReady(PeerId.host), isTrue);
      expect(harness.host.peers, [_client1]);
      expect(harness.host.isReady(_client1), isTrue);
    });

    test('gives each client its own identity and generation', () {
      final harness = _Harness();
      final a = harness.join();
      final b = harness.join();

      harness.run();

      expect(a.localPeer, _client1);
      expect(b.localPeer, _client2);
      expect(a.generation, isNot(b.generation));
      expect(harness.host.peers, [_client1, _client2]);
    });

    test('never reuses the peer ID of a client that left', () {
      final harness = _Harness();
      final a = harness.join();
      harness.run();
      a.close();
      harness.run();

      final b = harness.join();
      harness.run();

      expect(b.localPeer, _client2);
      expect(harness.host.peers, [_client2]);
    });

    test('rejects a client whose schema differs', () {
      final harness = _Harness();
      final other =
          (ProtocolSchemaBuilder()
                ..addRpc(const RpcId('player.jump'), const BoolCodec()))
              .build();
      final client = harness.join(schema: other);

      harness.run();

      expect(client.state, SessionState.disconnected);
      expect(client.disconnectReason, DisconnectReason.schemaMismatch);
      expect(harness.host.peers, isEmpty);
      expect(_drain(harness.host), [
        const SessionStateChanged(SessionState.hosting),
      ]);
    });

    test('rejects a client that uses another protocol version', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      harness.run();

      raw.sendBytes(Uint8List.fromList([77, 2, 2]));
      harness.run();

      expect(raw.received, [
        isA<GoodbyeMessage>().having(
          (m) => m.reason,
          'reason',
          GoodbyeReason.versionMismatch,
        ),
      ]);
      expect(raw.closeReason, CloseReason.remote);
      expect(harness.host.peers, isEmpty);
    });

    test('leaves a host that uses another protocol version', () {
      final harness = _RawHostHarness();
      harness.run();

      harness.host.sendBytes(Uint8List.fromList([77, 2, 2]));
      harness.run();

      expect(harness.client.disconnectReason, DisconnectReason.versionMismatch);
      expect(harness.host.received.last, isA<GoodbyeMessage>());
    });

    test('fails when no host is accepting connections', () {
      final clock = ManualClock();
      final network = InMemoryNetwork(clock: clock);
      final client = MultiplayerSession(schema: buildTestSchema(), clock: clock)
        ..join(network.connect());

      _run(clock, [client.update]);

      expect(client.disconnectReason, DisconnectReason.transportError);
      expect(network.links, isEmpty);
    });
  });

  group('identity', () {
    test('attributes messages to the connection they arrived on', () {
      final harness = _Harness();
      final a = harness.rawClient();
      final b = harness.rawClient();
      harness.run();
      a.hello();
      b.hello();
      harness.run();
      a.ready();
      b.ready();
      harness.run();
      harness.host.registry.register(
        const EntityId(7),
        owner: a.id!,
        authority: a.id!,
      );
      _drain(harness.host);

      // Identical messages: only the connection tells their senders apart.
      b.send(_health);
      a.send(_health);
      harness.run();

      expect(harness.received.map((received) => received.$1), [a.id]);
      expect(_drain(harness.host), [
        isA<StateRejected>()
            .having((event) => event.sender, 'sender', b.id)
            .having(
              (event) => event.reason,
              'reason',
              StateRejection.notAuthority,
            ),
      ]);
    });

    test('drops messages that carry another connection generation', () {
      final harness = _Harness();
      final victim = harness.join();
      final raw = harness.rawClient();
      harness.run();
      raw.hello();
      harness.run();
      raw.ready();
      harness.run();
      expect(raw.id, _client2);
      harness.host.registry.register(
        const EntityId(7),
        owner: _client2,
        authority: _client2,
      );

      raw
        ..send(_name, generation: victim.generation)
        ..send(_name, generation: 0)
        ..send(_name);
      harness.run();

      expect(harness.host.staleMessageCount, 2);
      expect(harness.received, hasLength(1));
      expect(harness.received.single.$1, _client2);
      expect(raw.closeReason, isNull);
    });

    test('drops host messages that carry another generation', () {
      final harness = _RawHostHarness();
      harness.run();
      harness.welcome(generation: 5);
      expect(harness.client.generation, 5);

      harness.host
        ..send(_health, generation: 4, revision: 1)
        ..send(_health, generation: 5, revision: 2);
      harness.run();

      expect(harness.client.staleMessageCount, 1);
      expect(harness.received.map((received) => received.$2.revision), [2]);
      expect(harness.client.state, SessionState.ready);
    });

    test(
      'gives a client that joins again a new identity in the same epoch',
      () {
        final harness = _Harness();
        final client = harness.join();
        harness.run();
        final first = (
          peer: client.localPeer,
          generation: client.generation,
          epoch: client.epoch,
        );
        client.registry.create(owner: _client1, authority: PeerId.host);

        client
          ..close()
          ..join(harness.network.connect());
        harness.run();

        expect(client.localPeer, isNot(first.peer));
        expect(client.generation, isNot(first.generation));
        expect(client.epoch, first.epoch);
        expect(client.registry.entities, isEmpty);
      },
    );

    test('learns a new epoch when the host starts a new session', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final first = client.epoch;

      harness.host
        ..close()
        ..host(harness.network.host());
      harness.run();
      expect(client.disconnectReason, DisconnectReason.remoteClosed);
      client.join(harness.network.connect());
      harness.run();

      expect(client.state, SessionState.ready);
      expect(client.epoch, harness.host.epoch);
      expect(client.epoch, isNot(first));
      expect(client.localPeer, _client1);
    });
  });

  group('readiness', () {
    test('welcomes clients with the revision of the baseline', () {
      final harness = _Harness();
      final player = _player(harness.schema);
      for (var i = 0; i < 3; i++) {
        harness.host.spawn(player, 'Ada');
      }
      final client = harness.join();
      harness.run();

      // The client's own join takes the revision after the spawns.
      expect(client.revision, 4);
      harness.host.spawn(player, 'Bob');
      harness.run();
      expect(client.revision, 5);
      expect(client.obsoleteMessageCount, 0);
    });

    test('applies replicated changes only in increasing revision order', () {
      final harness = _RawHostHarness();
      harness.run();
      harness.welcome(revision: 5);

      for (final revision in [5, 6, 6, 4, 8]) {
        harness.host.send(_health, generation: 5, revision: revision);
      }
      harness.run();

      expect(harness.received.map((received) => received.$2.revision), [6, 8]);
      expect(harness.client.obsoleteMessageCount, 3);
      expect(harness.client.revision, 8);
    });

    test('accepts no game messages from a client that is not ready', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      harness.run();
      raw.hello();
      harness.run();

      raw.send(_name);
      harness.run();

      expect(harness.received, isEmpty);
      expect(
        _drain(harness.host).last,
        const PeerLeft(_client1, DisconnectReason.protocolViolation),
      );
      expect(
        raw.received.last,
        isA<GoodbyeMessage>().having(
          (m) => m.reason,
          'reason',
          GoodbyeReason.protocolViolation,
        ),
      );
    });

    test('rejects a ready report for a revision it has not sent', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      harness.run();
      raw.hello();
      harness.run();

      raw.send(const ReadyMessage(), revision: 99);
      harness.run();

      expect(harness.host.isReady(_client1), isFalse);
      expect(
        _drain(harness.host).last,
        const PeerLeft(_client1, DisconnectReason.protocolViolation),
      );
    });

    test('accepts a ready report for any revision sent since the baseline', () {
      final harness = _Harness();
      final player = _player(harness.schema);
      harness.host.spawn(player, 'Ada');
      final early = harness.rawClient();
      final current = harness.rawClient();
      final ahead = harness.rawClient();
      harness.run();
      early.hello();
      current.hello();
      ahead.hello();
      harness.run();
      _drain(harness.host);

      // Each join takes a revision, so the baselines are revisions 2 to 4;
      // the spawn of Bob reaches all three.
      expect([early.baseline, current.baseline, ahead.baseline], [2, 3, 4]);
      harness.host.spawn(player, 'Bob');
      final latest = harness.host.revision;
      early.send(const ReadyMessage(), revision: early.baseline - 1);
      current.send(const ReadyMessage(), revision: latest);
      // Not assigned yet, even after the departure and readiness that the
      // other reports replicate.
      ahead.send(const ReadyMessage(), revision: latest + 10);
      harness.run();

      expect(harness.host.peers, [_client2]);
      expect(harness.host.isReady(_client2), isTrue);
      expect(_drain(harness.host), [
        const PeerLeft(_client1, DisconnectReason.protocolViolation),
        const PeerReady(_client2),
        const PeerLeft(_client3, DisconnectReason.protocolViolation),
      ]);
    });
  });

  test('rejects recursive updates without consuming later messages', () {
    final handled = <int>[];
    late final _RawHostHarness harness;
    harness = _RawHostHarness(
      onMessage: (_, envelope) {
        handled.add(envelope.revision);
        if (envelope.revision == 1) harness.client.update();
      },
    );
    harness.run();
    harness.welcome();
    harness.host
      ..send(_health, generation: 5, revision: 1)
      ..send(_health, generation: 5, revision: 2);
    harness.clock.advance(Duration.zero);

    expect(harness.client.update, throwsStateError);
    expect(handled, [1]);
    expect(harness.client.revision, 1);
    harness.client.update();
    expect(handled, [1, 2]);
    harness.host.send(_health, generation: 5, revision: 3);
    harness.run();

    expect(handled, [1, 2, 3]);
    expect(harness.client.revision, 3);
    expect(harness.client.state, SessionState.ready);
  });

  group('send failures', () {
    test('a host removes a peer immediately when its outgoing queue fills', () {
      final harness = _Harness(
        hostOutgoingLimits: const QueueLimits(maxMessages: 2),
      );
      harness.join();
      harness.run();
      _drain(harness.host);
      final player = _player(harness.schema);

      harness.host
        ..spawn(player, 'Ada')
        ..spawn(player, 'Bob');
      expect(harness.host.peers, [_client1]);
      harness.host.spawn(player, 'Cy');

      expect(harness.host.peers, isEmpty);
      expect(harness.host.isReady(_client1), isFalse);
      expect(_drain(harness.host), [
        const PeerLeft(_client1, DisconnectReason.transportError),
      ]);
      harness.run();
      expect(_drain(harness.host), isEmpty);
    });

    test('a client disconnects immediately when its outgoing queue fills', () {
      final harness = _Harness();
      final client = harness.session()
        ..join(
          harness.network.connect(
            outgoingLimits: const QueueLimits(maxMessages: 1),
          ),
        );
      harness.run();
      _drain(client);
      final entity = client.registry.register(
        const EntityId(7),
        owner: _client1,
        authority: PeerId.host,
      );
      client.registry.markReady(entity.id);
      final move = _move(harness.schema);

      expect(client.callRpc(entity, move, const MoveInput(0, 0)), isTrue);
      expect(client.callRpc(entity, move, const MoveInput(0, 0)), isFalse);

      expect(client.state, SessionState.disconnected);
      expect(client.disconnectReason, DisconnectReason.transportError);
      expect(client.peers, isEmpty);
      expect(_drain(client), [
        const SessionStateChanged(
          SessionState.disconnected,
          DisconnectReason.transportError,
        ),
      ]);
      harness.run();
      expect(_drain(client), isEmpty);
    });

    test('a failed hello never enters handshaking', () {
      final harness = _Harness();
      final client = harness.session()
        ..join(
          harness.network.connect(
            outgoingLimits: const QueueLimits(maxBytes: 1),
          ),
        );
      harness.run();

      expect(client.state, SessionState.disconnected);
      expect(client.disconnectReason, DisconnectReason.transportError);
      expect(_drain(client), [
        const SessionStateChanged(SessionState.connecting),
        const SessionStateChanged(
          SessionState.disconnected,
          DisconnectReason.transportError,
        ),
      ]);
      expect(harness.host.peers, isEmpty);
    });

    test('failed welcome or synced removes the admitted client once', () {
      for (final limits in [
        const QueueLimits(maxBytes: 1),
        const QueueLimits(maxMessages: 1),
      ]) {
        final harness = _Harness(hostOutgoingLimits: limits);
        final raw = harness.rawClient();
        harness.run();
        _drain(harness.host);
        raw.hello();
        harness.run();

        expect(harness.host.peers, isEmpty);
        expect(harness.host.state, SessionState.hosting);
        expect(_drain(harness.host), [
          const PeerJoined(_client1),
          const PeerLeft(_client1, DisconnectReason.transportError),
        ]);
        expect(raw.received.whereType<SyncedMessage>(), isEmpty);
        expect(raw.closeReason, CloseReason.remote);
        harness.run();
        expect(_drain(harness.host), isEmpty);
      }
    });

    test('a failed ready acknowledgement never enters gameplay', () {
      final clock = ManualClock();
      final network = InMemoryNetwork(clock: clock);
      final host = _RawHost(network.host());
      final client = MultiplayerSession(schema: buildTestSchema(), clock: clock)
        ..join(
          network.connect(outgoingLimits: const QueueLimits(maxMessages: 1)),
        );
      clock.advance(Duration.zero);
      host.update();
      host
        ..send(const WelcomeMessage(peer: _client1, epoch: 9), generation: 5)
        ..send(const SyncedMessage(), generation: 5);
      clock.advance(Duration.zero);

      // Hello and Ready are enqueued in the same client update. Only Hello fits.
      client.update();

      expect(client.state, SessionState.disconnected);
      expect(client.disconnectReason, DisconnectReason.transportError);
      expect(client.isReady(PeerId.host), isFalse);
      expect(_drain(client), [
        const SessionStateChanged(SessionState.connecting),
        const SessionStateChanged(SessionState.handshaking),
        const SessionStateChanged(SessionState.synchronizing),
        const SessionStateChanged(
          SessionState.disconnected,
          DisconnectReason.transportError,
        ),
      ]);
      _run(clock, [host.update, client.update]);
      expect(host.received.whereType<ReadyMessage>(), isEmpty);
      expect(_drain(client), isEmpty);
    });

    test('a goodbye that overflows emits a single peer departure', () {
      final harness = _Harness(
        hostOutgoingLimits: const QueueLimits(maxMessages: 2),
      );
      harness.join();
      harness.run();
      _drain(harness.host);
      final player = _player(harness.schema);
      harness.host
        ..spawn(player, 'Ada')
        ..spawn(player, 'Bob');

      expect(harness.host.kick(_client1), isTrue);

      expect(harness.host.peers, isEmpty);
      expect(_drain(harness.host), [
        const PeerLeft(_client1, DisconnectReason.transportError),
      ]);
      expect(harness.host.kick(_client1), isFalse);
      harness.run();
      expect(_drain(harness.host), isEmpty);
    });
  });

  group('timeouts', () {
    const timeouts = SessionTimeouts(
      handshake: Duration(milliseconds: 100),
      bootstrap: Duration(milliseconds: 200),
    );

    test('reject zero or negative durations when constructing a session', () {
      for (final duration in [
        Duration.zero,
        const Duration(microseconds: -1),
      ]) {
        for (final timeouts in [
          SessionTimeouts(handshake: duration),
          SessionTimeouts(bootstrap: duration),
        ]) {
          expect(
            () => MultiplayerSession(
              schema: buildTestSchema(),
              timeouts: timeouts,
            ),
            throwsArgumentError,
          );
        }
      }
    });

    test('close a connection that never says hello', () {
      final harness = _Harness(timeouts: timeouts);
      final raw = harness.rawClient();
      harness.run(rounds: 1);

      harness.run(step: _ms * 99, rounds: 1);
      expect(raw.closeReason, isNull);
      harness.run(step: _ms, rounds: 1);
      harness.run();

      expect(
        raw.received.single,
        isA<GoodbyeMessage>().having(
          (m) => m.reason,
          'reason',
          GoodbyeReason.timeout,
        ),
      );
      expect(raw.closeReason, CloseReason.remote);
      expect(_drain(harness.host), [
        const SessionStateChanged(SessionState.hosting),
      ]);
    });

    test('remove a client that never becomes ready', () {
      final harness = _Harness(timeouts: timeouts);
      final raw = harness.rawClient();
      harness.run();
      raw.hello();
      harness.run();

      harness.run(step: _ms * 200, rounds: 1);

      expect(_drain(harness.host), [
        const SessionStateChanged(SessionState.hosting),
        const PeerJoined(_client1),
        const PeerLeft(_client1, DisconnectReason.timeout),
      ]);
      harness.run();
      expect(
        raw.received.last,
        isA<GoodbyeMessage>().having(
          (m) => m.reason,
          'reason',
          GoodbyeReason.timeout,
        ),
      );
    });

    test('end joining a host that never answers', () {
      final harness = _RawHostHarness(timeouts: timeouts);
      harness.run();

      harness.run(step: _ms * 99, rounds: 1);
      expect(harness.client.state, SessionState.handshaking);
      harness.run(step: _ms, rounds: 1);
      harness.run();

      expect(harness.client.disconnectReason, DisconnectReason.timeout);
      expect(harness.host.received, [
        isA<HelloMessage>(),
        isA<GoodbyeMessage>().having(
          (m) => m.reason,
          'reason',
          GoodbyeReason.timeout,
        ),
      ]);
    });

    test('end joining while the connection is still opening', () {
      final clock = ManualClock();
      final network = InMemoryNetwork(
        clock: clock,
        latency: const Duration(seconds: 1),
      );
      network.host();
      final client = MultiplayerSession(
        schema: buildTestSchema(),
        clock: clock,
        timeouts: timeouts,
      )..join(network.connect());

      _run(clock, [client.update], step: _ms * 50, rounds: 2);

      expect(client.disconnectReason, DisconnectReason.timeout);
      expect(network.links, isEmpty);
    });

    test('count messages that arrived before the deadline', () {
      final harness = _RawHostHarness(timeouts: timeouts);
      harness.run();
      harness.host
        ..send(const WelcomeMessage(peer: _client1, epoch: 9), generation: 5)
        ..send(const SyncedMessage(), generation: 5);
      harness.clock.advance(_ms * 500);

      harness.client.update();

      expect(harness.client.state, SessionState.ready);
    });
  });

  group('closing', () {
    test('invalidates entity handles on local and remote disconnection', () {
      for (final reason in [
        DisconnectReason.closed,
        DisconnectReason.remoteClosed,
        DisconnectReason.transportError,
      ]) {
        final harness = _Harness();
        final client = harness.join();
        harness.run();
        final entity = client.registry.create(
          owner: _client1,
          authority: PeerId.host,
        );
        client.registry.markReady(entity.id);

        switch (reason) {
          case DisconnectReason.closed:
            client.close();
          case DisconnectReason.remoteClosed:
            harness.host.close();
          case DisconnectReason.transportError:
            harness.network.links.single.disconnect();
          default:
            fail('Unexpected test disconnection reason.');
        }
        harness.run();

        expect(client.disconnectReason, reason);
        expect(entity.state, EntityState.removed);
        expect(client.registry.entities, isEmpty);
        expect(client.registry[entity.id], isNull);
      }
    });

    test('old queued messages cannot reach a rejoined client or new epoch', () {
      for (final restartHost in [false, true]) {
        final builder = ProtocolSchemaBuilder();
        final ping = builder.addRpc(
          const RpcId('test.ping'),
          const IntCodec(min: 0, max: 9),
          target: RpcTarget.all,
        );
        final schema = builder.build();
        final clock = ManualClock();
        final network = InMemoryNetwork(clock: clock);
        final received = <(String, PeerId, int)>[];
        final host = MultiplayerSession(schema: schema, clock: clock)
          ..host(network.host());
        final client = MultiplayerSession(schema: schema, clock: clock)
          ..join(network.connect());

        NetworkEntity bind(MultiplayerSession session, String name) {
          final entity = session.registry.register(
            const EntityId(1),
            owner: PeerId.host,
            authority: PeerId.host,
          );
          session
            ..registry.markReady(entity.id)
            ..bindRpc(entity, ping, (context, value) {
              received.add((name, context.sender, value));
            });
          return entity;
        }

        _run(clock, [host.update, client.update]);
        final oldEpoch = client.epoch;
        final oldGeneration = client.generation;
        var hostEntity = bind(host, 'host');
        final oldEntity = bind(client, 'client');

        expect(host.callRpc(hostEntity, ping, 1), isTrue);
        if (restartHost) expect(client.callRpc(oldEntity, ping, 2), isTrue);
        // Deliver bytes into the old sessions' incoming queues without dispatch.
        clock.advance(Duration.zero);
        client.close();
        if (restartHost) {
          host
            ..close()
            ..host(network.host());
          hostEntity = bind(host, 'host');
        }
        client.join(network.connect());
        // Bind the same IDs again before any update, so that a message from
        // an old lifetime would reach a handler.
        final current = bind(client, 'client');
        _run(clock, [host.update, client.update]);

        expect(received, isEmpty);
        expect(client.state, SessionState.ready);
        expect(oldEntity.state, EntityState.removed);
        expect(current.id, oldEntity.id);
        expect(client.epoch, restartHost ? isNot(oldEpoch) : oldEpoch);
        if (!restartHost) expect(client.generation, isNot(oldGeneration));

        expect(host.callRpc(hostEntity, ping, 3), isTrue);
        _run(clock, [host.update, client.update]);
        expect(received, [('client', PeerId.host, 3)]);
      }
    });

    test('a host removes every client', () {
      final harness = _Harness();
      final a = harness.join();
      final b = harness.join();
      harness.run();
      _drain(harness.host);

      harness.host.close();
      harness.run();

      expect(_drain(harness.host), [
        const PeerLeft(_client1, DisconnectReason.closed),
        const PeerLeft(_client2, DisconnectReason.closed),
        const SessionStateChanged(
          SessionState.disconnected,
          DisconnectReason.closed,
        ),
      ]);
      expect(a.disconnectReason, DisconnectReason.remoteClosed);
      expect(b.disconnectReason, DisconnectReason.remoteClosed);
      expect(harness.host.peers, isEmpty);
      expect(harness.host.localPeer, isNull);
      expect(harness.host.epoch, isNull);
      expect(a.localPeer, isNull);
      expect(a.generation, isNull);
    });

    test('a client leaves the host', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      _drain(client);
      _drain(harness.host);

      client.close();
      harness.run();

      expect(_drain(client), [
        const SessionStateChanged(
          SessionState.disconnected,
          DisconnectReason.closed,
        ),
      ]);
      expect(_drain(harness.host), [
        const PeerLeft(_client1, DisconnectReason.remoteClosed),
      ]);
    });

    test('closing again has no effect', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      harness.host.close();
      _drain(harness.host);

      harness.host
        ..close()
        ..update();
      harness.run();
      client.close();

      expect(_drain(harness.host), isEmpty);
      expect(harness.host.state, SessionState.disconnected);
      expect(client.disconnectReason, DisconnectReason.remoteClosed);
    });

    test('a host kicks a client', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      _drain(harness.host);

      expect(harness.host.kick(_client1), isTrue);
      expect(harness.host.kick(_client1), isFalse);
      expect(client.kick(PeerId.host), isFalse);
      harness.run();

      expect(_drain(harness.host), [
        const PeerLeft(_client1, DisconnectReason.kicked),
      ]);
      expect(client.disconnectReason, DisconnectReason.kicked);
    });

    test('a lost connection disconnects both sides', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      _drain(harness.host);

      harness.network.links.single.disconnect();
      harness.run();

      expect(_drain(harness.host), [
        const PeerLeft(_client1, DisconnectReason.transportError),
      ]);
      expect(client.disconnectReason, DisconnectReason.transportError);
    });
  });

  group('protocol violations', () {
    test('remove a client that sends malformed data', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      harness.run();
      raw.hello();
      harness.run();
      raw.ready();
      harness.run();

      raw.sendBytes(utf8.encode('{"v":1,'));
      harness.run();

      expect(
        _drain(harness.host).last,
        const PeerLeft(_client1, DisconnectReason.protocolViolation),
      );
      expect(
        raw.received.last,
        isA<GoodbyeMessage>().having(
          (m) => m.reason,
          'reason',
          GoodbyeReason.protocolViolation,
        ),
      );
      expect(raw.closeReason, CloseReason.remote);
    });

    test('remove a client that spawns entities', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      harness.run();
      raw.hello();
      harness.run();
      raw.ready();
      harness.run();

      raw.send(
        SpawnMessage(
          entity: const EntityId(1),
          type: const SpawnTypeId('player'),
          data: 'Ada',
          owner: raw.id!,
          authority: raw.id!,
        ),
      );
      harness.run();

      expect(
        _drain(harness.host).last,
        const PeerLeft(_client1, DisconnectReason.protocolViolation),
      );
    });

    test('remove a client that says hello twice', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      harness.run();
      raw.hello();
      harness.run();

      raw.hello();
      harness.run();

      expect(
        _drain(harness.host).last,
        const PeerLeft(_client1, DisconnectReason.protocolViolation),
      );
    });

    test('leave a host whose welcome assigns no generation', () {
      final harness = _RawHostHarness();
      harness.run();

      harness.welcome(generation: 0);

      expect(
        harness.client.disconnectReason,
        DisconnectReason.protocolViolation,
      );
    });

    test('leave a host whose baseline ends at a different revision', () {
      for (final revision in [3, 5]) {
        final harness = _RawHostHarness();
        harness.run();

        harness.host
          ..send(
            const WelcomeMessage(peer: _client1, epoch: 9),
            generation: 5,
            revision: 4,
          )
          ..send(const SyncedMessage(), generation: 5, revision: revision);
        harness.run();

        expect(
          harness.client.disconnectReason,
          DisconnectReason.protocolViolation,
        );
      }
    });

    test('leave a host that sends game messages before welcoming', () {
      final harness = _RawHostHarness();
      harness.run();

      harness.host.send(_name);
      harness.run();

      expect(
        harness.client.disconnectReason,
        DisconnectReason.protocolViolation,
      );
      expect(harness.received, isEmpty);
      expect(
        harness.host.received.last,
        isA<GoodbyeMessage>().having(
          (m) => m.reason,
          'reason',
          GoodbyeReason.protocolViolation,
        ),
      );
    });
  });

  group('static entities', () {
    test('exist on every peer with the same IDs as soon as it starts', () {
      final protocol = _StaticProtocol();
      final harness = _Harness(schema: protocol.schema);
      final client = harness.join();

      expect(protocol.schema.staticEntities, [protocol.board, protocol.level]);
      for (final session in [harness.host, client]) {
        final board = session.staticEntity(protocol.board);
        final level = session.staticEntity(protocol.level);
        expect(board.id, const EntityId(1));
        expect(level.id, const EntityId(2));
        for (final entity in [board, level]) {
          expect(entity.owner, PeerId.host);
          expect(entity.authority, PeerId.host);
          expect(entity.state, EntityState.pending);
          expect(session.registry[entity.id], same(entity));
        }
      }
    });

    test('are followed by the IDs of spawned entities', () {
      final protocol = _StaticProtocol();
      final harness = _Harness(schema: protocol.schema);
      final client = harness.join();
      harness.run();

      final spawned = harness.host.spawn(protocol.player, 'Ada');
      harness.run();

      expect(spawned.id, const EntityId(3));
      expect(client.registry[spawned.id]?.state, EntityState.pending);
      expect(client.state, SessionState.ready);
    });

    test('carry state and RPCs, including in a late baseline', () {
      final protocol = _StaticProtocol();
      final harness = _Harness(schema: protocol.schema);
      final hostBoard = harness.host.staticEntity(protocol.board);
      final votes = <(PeerId, int)>[];
      harness.host.attachEntity(
          hostBoard,
          isReady: () => true,
          isValid: () => true,
        )
        ..bindRpc(
          protocol.vote,
          (context, vote) => votes.add((context.sender, vote)),
        )
        ..synchronize([protocol.score.property(get: () => 7)]);
      harness.run();
      harness.host.captureState();

      final client = harness.join();
      var score = 0;
      final clientBoard = client.staticEntity(protocol.board);
      client
          .attachEntity(clientBoard, isReady: () => true, isValid: () => true)
          .synchronize([
            protocol.score.property(
              get: () => score,
              set: (value) => score = value,
            ),
          ]);
      harness.run();

      expect(client.state, SessionState.ready);
      expect(score, 7);
      expect(client.callRpc(clientBoard, protocol.vote, 2), isTrue);
      harness.run();
      expect(votes, [(client.localPeer!, 2)]);
    });

    test('must match for a client to join', () {
      final protocol = _StaticProtocol();
      final harness = _Harness(schema: protocol.schema);
      final client = harness.join(
        schema: _StaticProtocol(extra: 'arena.lobby').schema,
      );
      harness.run();

      expect(client.disconnectReason, DisconnectReason.schemaMismatch);
      expect(harness.host.peers, isEmpty);
    });

    test('are registered again by each new session', () {
      final protocol = _StaticProtocol();
      final harness = _Harness(schema: protocol.schema);
      final first = harness.host.staticEntity(protocol.board);

      harness.host.close();
      expect(first.state, EntityState.removed);
      expect(() => harness.host.staticEntity(protocol.board), throwsStateError);
      harness.host.host(harness.network.host());
      final second = harness.host.staticEntity(protocol.board);

      expect(second, isNot(same(first)));
      expect(second.id, first.id);
      expect(second.state, EntityState.pending);
    });

    test('are unavailable before the session starts', () {
      final protocol = _StaticProtocol();
      final session = MultiplayerSession(schema: protocol.schema);

      expect(() => session.staticEntity(protocol.board), throwsStateError);
    });

    test('accept only the handles of the session schema', () {
      final protocol = _StaticProtocol();
      final harness = _Harness(schema: protocol.schema);

      expect(
        () => harness.host.staticEntity(
          const StaticEntity(id: StaticEntityId('arena.board')),
        ),
        throwsArgumentError,
      );
      expect(
        () => harness.host.staticEntity(_StaticProtocol().board),
        throwsArgumentError,
      );
    });

    test('cannot be despawned', () {
      final protocol = _StaticProtocol();
      final harness = _Harness(schema: protocol.schema);
      final board = harness.host.staticEntity(protocol.board);

      expect(() => harness.host.despawn(board), throwsArgumentError);
      expect(board.state, EntityState.pending);
    });
  });

  test('starts each session with an empty registry', () {
    final harness = _Harness();
    final entity = harness.host.registry.create(
      owner: PeerId.host,
      authority: PeerId.host,
    );

    harness.host.close();
    expect(entity.state, EntityState.removed);
    expect(harness.host.registry.entities, isEmpty);
    harness.host.host(harness.network.host());

    expect(harness.host.registry.entities, isEmpty);
  });
}
