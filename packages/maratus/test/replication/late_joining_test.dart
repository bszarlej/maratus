import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

const _interval = Duration(milliseconds: 50);
const _client1 = PeerId(2);
const _client2 = PeerId(3);

List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

/// The registrations shared by every session of a test.
final class _Schema {
  _Schema() {
    final builder = ProtocolSchemaBuilder();
    avatar = builder.addSpawnType(
      const SpawnTypeId('test.avatar'),
      const StringCodec(maxLength: 16),
    );
    health = builder.addField(
      const FieldId('test.health'),
      const IntCodec(min: 0, max: 100),
    );
    poke = builder.addRpc(
      const RpcId('test.poke'),
      const IntCodec(min: 0, max: 9),
      caller: RpcCaller.host,
      target: RpcTarget.all,
      local: RpcLocal.include,
    );
    nudge = builder.addRpc(
      const RpcId('test.nudge'),
      const IntCodec(min: 0, max: 9),
      caller: RpcCaller.host,
      target: RpcTarget.owner,
    );
    schema = builder.build();
  }

  late final SpawnType<String> avatar;
  late final SyncField<int> health;

  /// A transient effect played by every peer.
  late final Rpc<int> poke;

  /// A transient effect addressed to an avatar's owner.
  late final Rpc<int> nudge;
  late final ProtocolSchema schema;
}

/// The local representation of a spawned avatar, which becomes ready when
/// the test says it has loaded, like a component with assets to load.
final class _Avatar {
  _Avatar(this.session, SpawnContext<String> context, _Schema schema)
    : entity = context.entity,
      name = context.data {
    final attachment = session.attachEntity(
      entity,
      isReady: () => loaded,
      isValid: () => true,
    );
    synchronizer = attachment.synchronize([
      schema.health.property(
        get: () => health,
        set: (value) {
          health = value;
          applied.add((value, session.state));
        },
      ),
    ], interval: _interval);
    attachment
      ..bindRpc(schema.poke, (_, value) {
        pokes.add(value);
        // The authority keeps the lasting result of an effect as state.
        if (entity.authority == session.localPeer) health += value;
      })
      ..bindRpc(schema.nudge, (_, value) => pokes.add(value));
  }

  final MultiplayerSession session;
  final NetworkEntity entity;
  final String name;
  late final MultiplayerSynchronizer synchronizer;
  var loaded = false;
  var health = 0;

  /// Each received value applied, with the session state it was applied in.
  final applied = <(int, SessionState)>[];

  /// The effects this peer played for the avatar.
  final pokes = <int>[];
}

/// A session whose spawn handler represents each avatar with an [_Avatar].
final class _Peer {
  _Peer(this.session, this.schema, {required this.loads}) {
    session.bindSpawn(
      schema.avatar,
      onSpawn: (context) {
        spawned.add(context.data);
        if (failing.contains(context.data)) {
          throw StateError('Cannot create ${context.data}.');
        }
        avatars[context.entity] = _Avatar(session, context, schema)
          ..loaded = loads;
      },
      onDespawn: avatars.remove,
    );
  }

  final MultiplayerSession session;
  final _Schema schema;

  /// Whether new avatars are ready as soon as they are created.
  final bool loads;
  final avatars = <NetworkEntity, _Avatar>{};

  /// The names of the avatars whose spawn handler ran, in order.
  final spawned = <String>[];

  /// The names of the avatars whose spawn handler throws.
  final failing = <String>{};

  _Avatar operator [](String name) =>
      avatars.values.singleWhere((avatar) => avatar.name == name);

  /// The live avatars with their latest authoritative health, to compare
  /// peers.
  List<String> get world => [
    for (final avatar in avatars.values)
      '${avatar.entity.id.value} ${avatar.name} '
          'hp${avatar.synchronizer.snapshot(schema.health)?.value}',
  ];
}

/// A host and the clients that join it over an in-memory network whose links
/// have [latency].
final class _Harness {
  _Harness({
    this.timeouts = const SessionTimeouts(),
    this.latency = Duration.zero,
  }) {
    network = InMemoryNetwork(clock: clock, latency: latency);
    host = _Peer(_session(), schema, loads: true)..session.host(network.host());
  }

  final clock = ManualClock();
  final schema = _Schema();
  final SessionTimeouts timeouts;
  final Duration latency;
  late final InMemoryNetwork network;
  late final _Peer host;
  final _sessions = <MultiplayerSession>[];

  /// Sessions that neither update nor capture, like a paused game.
  final stalled = <MultiplayerSession>{};

  MultiplayerSession _session() {
    final session = MultiplayerSession(
      schema: schema.schema,
      clock: clock,
      timeouts: timeouts,
    );
    addTearDown(session.close);
    _sessions.add(session);
    return session;
  }

  /// Starts a client whose avatars wait to be loaded.
  _Peer join({QueueLimits incomingLimits = const QueueLimits()}) =>
      _Peer(_session(), schema, loads: false)
        ..session.join(network.connect(incomingLimits: incomingLimits));

  /// Advances the clock by one link latency, then updates every session,
  /// [rounds] times.
  void run({int rounds = 6}) {
    for (var i = 0; i < rounds; i++) {
      clock.advance(latency);
      for (final session in _sessions) {
        if (!stalled.contains(session)) session.update();
      }
    }
  }

  /// Lets a synchronizer interval pass, captures state everywhere, and
  /// delivers it.
  void tick() {
    clock.advance(_interval);
    for (final session in _sessions) {
      if (!stalled.contains(session)) session.captureState();
    }
    run();
  }
}

/// A client session joining a host that speaks the protocol directly, to
/// observe the revision that the client acknowledges.
final class _RawHostHarness {
  _RawHostHarness() {
    final network = InMemoryNetwork(clock: clock);
    final peer = network.host();
    client = _Peer(
      MultiplayerSession(schema: schema.schema, clock: clock),
      schema,
      loads: false,
    )..session.join(network.connect());
    addTearDown(client.session.close);
    _updates = [
      () {
        for (var event = peer.poll(); event != null; event = peer.poll()) {
          switch (event) {
            case ConnectionOpened(:final connection):
              this.connection = connection;
            case MessageReceived(:final message):
              received.add(codec.decode(message));
            case ConnectionClosed():
              break;
          }
        }
      },
      client.session.update,
    ];
    run();
  }

  final clock = ManualClock();
  final schema = _Schema();
  late final codec = ProtocolCodec(schema.schema);
  late final _Peer client;
  late final List<void Function()> _updates;
  PeerConnection? connection;

  /// The envelopes the client sent to this host.
  final received = <MessageEnvelope>[];

  void run() {
    for (var i = 0; i < 6; i++) {
      clock.advance(Duration.zero);
      for (final update in _updates) {
        update();
      }
    }
  }

  void send(ProtocolMessage message, {required int revision}) =>
      connection!.send(
        codec.encode(
          MessageEnvelope(message, generation: 5, revision: revision),
        ),
      );
}

SpawnMessage _avatar(int entity, String name) => SpawnMessage(
  entity: EntityId(entity),
  type: const SpawnTypeId('test.avatar'),
  data: name,
  owner: PeerId.host,
  authority: PeerId.host,
);

StateMessage _health(int entity, int value) => StateMessage(
  entity: EntityId(entity),
  values: {const FieldId('test.health'): value},
);

void main() {
  group('installation', () {
    test(
      'a joining client stays synchronizing until its baseline is ready',
      () {
        final harness = _Harness();
        final host = harness.host.session;
        host
          ..spawn(harness.schema.avatar, 'Ada')
          ..spawn(harness.schema.avatar, 'Bob');
        harness.host['Ada'].health = 7;
        harness.host['Bob'].health = 9;
        harness.tick();
        _drain(host);

        final client = harness.join();
        harness.run();

        expect(client.session.state, SessionState.synchronizing);
        expect(client.session.pendingBaselineCount, 2);
        expect(client.session.revision, host.revision);
        expect(client.world, harness.host.world);
        expect(client['Ada'].applied, isEmpty);
        expect(host.isReady(_client1), isFalse);
        expect(_drain(host), [const PeerJoined(_client1)]);

        client['Ada'].loaded = true;
        harness.run();
        expect(client.session.state, SessionState.synchronizing);
        expect(client.session.pendingBaselineCount, 1);
        expect(client['Ada'].applied, [(7, SessionState.synchronizing)]);

        client['Bob'].loaded = true;
        harness.run();
        expect(client.session.state, SessionState.ready);
        expect(client.session.pendingBaselineCount, 0);
        expect(client['Bob'].applied, [(9, SessionState.synchronizing)]);
        expect(host.isReady(_client1), isTrue);
        expect(_drain(host), [const PeerReady(_client1)]);
        expect(_drain(client.session), const [
          SessionStateChanged(SessionState.connecting),
          SessionStateChanged(SessionState.handshaking),
          SessionStateChanged(SessionState.synchronizing),
          SessionStateChanged(SessionState.ready),
        ]);
      },
    );

    test(
      'spawns, changes, and despawns during installation apply in order',
      () {
        final harness = _Harness();
        final host = harness.host.session;
        final schema = harness.schema;
        host.spawn(schema.avatar, 'Ada');
        final bob = host.spawn(schema.avatar, 'Bob');
        host.spawn(schema.avatar, 'Cy');
        harness.tick();
        final client = harness.join();
        harness.run();
        final baseline = client.session.revision;
        expect(client.session.pendingBaselineCount, 3);

        host
          ..despawn(bob)
          ..spawn(schema.avatar, 'Dee');
        harness.host['Ada'].health = 30;
        harness.tick();

        expect(client.session.state, SessionState.synchronizing);
        expect(client.session.revision, greaterThan(baseline));
        expect(client.session.revision, host.revision);
        expect(client.session.registry[bob.id]!.state, EntityState.removed);
        // Only the baseline entities that are still live delay readiness.
        expect(client.session.pendingBaselineCount, 2);
        expect(client.world, harness.host.world);

        client['Ada'].loaded = true;
        client['Cy'].loaded = true;
        harness.run();

        // The acknowledgement covers the later changes: both peers agree at
        // that revision, while Dee, spawned after the baseline, still loads.
        expect(client.session.state, SessionState.ready);
        expect(host.isReady(_client1), isTrue);
        expect(client.session.revision, host.revision);
        expect(client.world, harness.host.world);
        expect(client['Dee'].entity.state, EntityState.pending);
        expect(client['Ada'].applied, [(30, SessionState.synchronizing)]);
        expect(client['Cy'].applied, [(0, SessionState.synchronizing)]);

        harness.host['Cy'].health = 4;
        client['Dee'].loaded = true;
        harness.tick();
        expect(client.world, harness.host.world);
        expect(client['Cy'].applied.last, (4, SessionState.ready));
        expect(client['Dee'].applied, [(0, SessionState.ready)]);
        expect(client.session.obsoleteMessageCount, 0);
      },
    );

    test('despawning the last pending baseline entity completes it', () {
      final harness = _Harness();
      final host = harness.host.session;
      final ada = host.spawn(harness.schema.avatar, 'Ada');
      final client = harness.join();
      harness.run();
      expect(client.session.pendingBaselineCount, 1);

      host.despawn(ada);
      harness.run();

      expect(client.session.state, SessionState.ready);
      expect(client.avatars, isEmpty);
      expect(host.isReady(_client1), isTrue);
    });

    test('the ready report acknowledges the latest applied revision', () {
      final harness = _RawHostHarness();
      final client = harness.client;
      harness
        ..send(const WelcomeMessage(peer: _client1, epoch: 9), revision: 2)
        ..send(_avatar(1, 'Ada'), revision: 2)
        ..send(const SyncedMessage(), revision: 2)
        ..send(_avatar(2, 'Bob'), revision: 3)
        ..send(_health(1, 5), revision: 4)
        ..run();

      expect(client.session.state, SessionState.synchronizing);
      expect(client.session.revision, 4);
      expect(client.session.pendingBaselineCount, 1);
      expect(harness.received.map((envelope) => envelope.message), [
        isA<HelloMessage>(),
      ]);

      client['Ada'].loaded = true;
      harness.run();

      expect(client.session.state, SessionState.ready);
      expect(client['Ada'].applied, [(5, SessionState.synchronizing)]);
      expect(
        harness.received.last,
        isA<MessageEnvelope>()
            .having(
              (envelope) => envelope.message,
              'message',
              isA<ReadyMessage>(),
            )
            .having((envelope) => envelope.revision, 'revision', 4),
      );
    });

    test('finishing at the bootstrap deadline takes precedence', () {
      const bootstrap = Duration(milliseconds: 200);
      final harness = _Harness(
        timeouts: const SessionTimeouts(bootstrap: bootstrap),
      );
      harness.host.session.spawn(harness.schema.avatar, 'Ada');
      final client = harness.join();
      harness.run();
      expect(client.session.state, SessionState.synchronizing);

      client['Ada'].loaded = true;
      harness.clock.advance(bootstrap);
      client.session.update();
      harness.run();

      expect(client.session.state, SessionState.ready);
      expect(harness.host.session.isReady(_client1), isTrue);
    });
  });

  group('transient RPCs', () {
    test('reach a joining client only once the host sees it ready', () {
      final harness = _Harness();
      final host = harness.host.session;
      final schema = harness.schema;
      final ada = host.spawn(schema.avatar, 'Ada');
      expect(host.callRpc(ada, schema.poke, 1), isTrue);
      harness.run();
      final client = harness.join();
      harness.run();
      _drain(host);

      // While the client installs its baseline, a broadcast skips it and a
      // call addressed to it is rejected. It cannot call RPCs itself.
      expect(host.callRpc(ada, schema.poke, 2), isTrue);
      final bob = host.spawn(schema.avatar, 'Bob', owner: _client1);
      expect(host.callRpc(bob, schema.nudge, 3), isFalse);
      expect(
        () => client.session.callRpc(client['Ada'].entity, schema.poke, 4),
        throwsStateError,
      );
      harness
        ..run()
        ..tick();
      client['Ada'].loaded = true;
      harness.run();
      expect(client.session.state, SessionState.ready);

      expect(host.callRpc(ada, schema.poke, 5), isTrue);
      harness
        ..run()
        ..tick();

      // Earlier effects are not replayed: the client receives their lasting
      // result as synchronized state instead.
      expect(harness.host['Ada'].pokes, [1, 2, 5]);
      expect(client['Ada'].pokes, [5]);
      expect(client['Bob'].pokes, isEmpty);
      expect(client['Ada'].applied, [
        (3, SessionState.synchronizing),
        (8, SessionState.ready),
      ]);
      expect(
        _drain(host).whereType<RpcRejected>().map(
          (event) => (event.entity, event.rpc, event.reason, event.target),
        ),
        [(bob.id, schema.nudge.id, RpcRejection.invalidTarget, _client1)],
      );
      expect(_drain(client.session).whereType<RpcRejected>(), isEmpty);
    });

    test('a client leaves a host that delivers an RPC before it is ready', () {
      final harness = _RawHostHarness();
      final client = harness.client;
      harness
        ..send(const WelcomeMessage(peer: _client1, epoch: 9), revision: 1)
        ..send(_avatar(1, 'Ada'), revision: 1)
        ..send(const SyncedMessage(), revision: 1)
        ..run();
      final ada = client['Ada'];

      harness
        ..send(
          const RpcDeliveryMessage(
            entity: EntityId(1),
            rpc: RpcId('test.poke'),
            payload: 1,
            sender: PeerId.host,
            target: _client1,
          ),
          revision: 0,
        )
        ..run();

      expect(
        client.session.disconnectReason,
        DisconnectReason.protocolViolation,
      );
      expect(ada.pokes, isEmpty);
      expect(
        harness.received.last.message,
        isA<GoodbyeMessage>().having(
          (message) => message.reason,
          'reason',
          GoodbyeReason.protocolViolation,
        ),
      );
    });
  });

  group('failure and restart', () {
    test('a failing spawn handler ends the bootstrap with a clear reason', () {
      final harness = _Harness();
      final host = harness.host.session;
      final schema = harness.schema;
      final observer = harness.join();
      harness.run();
      host.spawn(schema.avatar, 'Ada');
      final bob = host.spawn(schema.avatar, 'Bob');
      harness.run();
      final client = harness.join()..failing.add('Bob');
      while (!host.peers.contains(_client2)) {
        harness.run(rounds: 1);
      }
      // Like an application reacting to PeerJoined, the host spawns the
      // joining client's avatar, which it releases when the client leaves.
      host.spawn(
        schema.avatar,
        'Cy',
        owner: _client2,
        onOwnerLeft: OwnerLeftPolicy.despawn,
      );
      _drain(host);
      harness.run();

      expect(client.session.disconnectReason, DisconnectReason.bootstrapFailed);
      expect(_drain(client.session).skip(3), [
        isA<SpawnHandlerFailed>()
            .having((event) => event.entity, 'entity', bob.id)
            .having((event) => event.error, 'error', isStateError),
        const SessionStateChanged(
          SessionState.disconnected,
          DisconnectReason.bootstrapFailed,
        ),
      ]);
      // No part of the incomplete world remains on the client.
      expect(client.avatars, isEmpty);
      expect(client.session.registry.entities, isEmpty);
      expect(client.session.pendingBaselineCount, 0);
      expect(_drain(host), [
        const PeerLeft(_client2, DisconnectReason.bootstrapFailed),
      ]);
      expect(observer.spawned, ['Ada', 'Bob', 'Cy']);
      expect(observer.world, harness.host.world);
      expect(harness.host.avatars.values.map((avatar) => avatar.name), [
        'Ada',
        'Bob',
      ]);
    });

    test('a baseline that never finishes loading times out on both sides', () {
      const bootstrap = Duration(milliseconds: 200);
      final harness = _Harness(
        timeouts: const SessionTimeouts(bootstrap: bootstrap),
      );
      final host = harness.host.session;
      host.spawn(harness.schema.avatar, 'Ada');
      final client = harness.join();
      harness.run();
      _drain(host);
      expect(client.session.state, SessionState.synchronizing);

      harness.clock.advance(bootstrap);
      harness.run();

      expect(client.session.disconnectReason, DisconnectReason.timeout);
      expect(client.avatars, isEmpty);
      expect(_drain(host), [
        const PeerLeft(_client1, DisconnectReason.timeout),
      ]);
    });

    test('a joining client that stops updating cannot queue without bound', () {
      final harness = _Harness();
      final host = harness.host.session;
      host.spawn(harness.schema.avatar, 'Ada');
      final client = harness.join(
        incomingLimits: const QueueLimits(maxMessages: 4),
      );
      harness.run();
      _drain(host);
      expect(client.session.state, SessionState.synchronizing);

      // Its game pauses while the host keeps changing state.
      harness.stalled.add(client.session);
      for (var health = 1; health <= 5; health++) {
        harness.host['Ada'].health = health;
        harness.tick();
      }

      expect(host.peers, isEmpty);
      expect(_drain(host), [
        const PeerLeft(_client1, DisconnectReason.remoteClosed),
      ]);
      harness.stalled.remove(client.session);
      harness.run();
      expect(client.session.disconnectReason, DisconnectReason.transportError);
      expect(client.avatars, isEmpty);
    });

    for (final (departure, depart, clientReason, hostReason, hostAvatars)
        in <
          (
            String,
            void Function(_Harness harness, _Peer client),
            DisconnectReason,
            DisconnectReason,
            List<String>,
          )
        >[
          (
            'the client closes',
            (_, client) => client.session.close(),
            DisconnectReason.closed,
            DisconnectReason.remoteClosed,
            ['Ada'],
          ),
          (
            'its connection is lost',
            (harness, _) => harness.network.links.single.disconnect(),
            DisconnectReason.transportError,
            DisconnectReason.transportError,
            ['Ada'],
          ),
          (
            'the host closes',
            (harness, _) => harness.host.session.close(),
            DisconnectReason.remoteClosed,
            DisconnectReason.closed,
            [],
          ),
        ]) {
      test('a bootstrap ends without a partial world when $departure', () {
        final harness = _Harness();
        final host = harness.host.session;
        host.spawn(harness.schema.avatar, 'Ada');
        final client = harness.join();
        harness.run();
        final avatar = host.spawn(
          harness.schema.avatar,
          'Bob',
          owner: _client1,
          onOwnerLeft: OwnerLeftPolicy.despawn,
        );
        harness.run();
        _drain(host);
        expect(client.session.state, SessionState.synchronizing);
        expect(client.spawned, ['Ada', 'Bob']);

        depart(harness, client);
        harness.run();

        expect(client.session.disconnectReason, clientReason);
        expect(client.avatars, isEmpty);
        expect(client.session.registry.entities, isEmpty);
        expect(client.session.pendingBaselineCount, 0);
        expect(_drain(host).first, PeerLeft(_client1, hostReason));
        expect(avatar.state, EntityState.removed);
        expect(
          harness.host.avatars.values.map((avatar) => avatar.name),
          hostAvatars,
        );
      });
    }

    test('rejoining after a failed bootstrap starts afresh', () {
      final harness = _Harness();
      final host = harness.host.session;
      host
        ..spawn(harness.schema.avatar, 'Ada')
        ..spawn(harness.schema.avatar, 'Bob');
      harness.host['Bob'].health = 3;
      harness.tick();
      final client = harness.join()..failing.add('Bob');
      harness.run();
      expect(client.session.disconnectReason, DisconnectReason.bootstrapFailed);

      client.failing.clear();
      client.session.join(harness.network.connect());
      harness.run();

      expect(client.session.state, SessionState.synchronizing);
      expect(client.session.localPeer, _client2);
      expect(client.session.epoch, host.epoch);
      expect(client.session.pendingBaselineCount, 2);
      for (final avatar in client.avatars.values) {
        avatar.loaded = true;
      }
      harness.run();

      expect(client.session.state, SessionState.ready);
      expect(client.world, harness.host.world);
      expect(client.spawned, ['Ada', 'Bob', 'Ada', 'Bob']);
      expect(
        _drain(host),
        containsAllInOrder([
          const PeerLeft(_client1, DisconnectReason.bootstrapFailed),
          const PeerJoined(_client2),
          const PeerReady(_client2),
        ]),
      );
    });

    test('reconnecting ignores messages left for the previous connection', () {
      final harness = _Harness(latency: const Duration(milliseconds: 10));
      final host = harness.host.session;
      host.spawn(harness.schema.avatar, 'Ada');
      final bob = host.spawn(harness.schema.avatar, 'Bob');
      harness.host['Ada'].health = 5;
      harness.tick();
      final client = harness.join();
      // The welcome and baseline are on their way when the client gives up.
      harness.run(rounds: 3);
      expect(host.peers, [_client1]);
      expect(client.session.state, SessionState.handshaking);

      client.session
        ..close()
        ..join(harness.network.connect());
      host.despawn(bob);
      harness.host['Ada'].health = 6;
      harness.tick();
      for (final avatar in client.avatars.values) {
        avatar.loaded = true;
      }
      harness.run();

      expect(client.session.state, SessionState.ready);
      expect(client.session.localPeer, _client2);
      expect(client.world, harness.host.world);
      expect(client.spawned, ['Ada']);
      expect(client.session.staleMessageCount, 0);
      expect(client.session.obsoleteMessageCount, 0);
      expect(
        _drain(host),
        containsAllInOrder([
          const PeerJoined(_client1),
          const PeerLeft(_client1, DisconnectReason.remoteClosed),
          const PeerJoined(_client2),
          const PeerReady(_client2),
        ]),
      );
    });
  });
}
