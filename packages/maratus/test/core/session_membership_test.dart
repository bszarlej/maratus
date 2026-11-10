import 'dart:async';

import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

const _first = PeerId(2);
const _second = PeerId(3);
const _third = PeerId(4);

final class _Schema {
  _Schema() {
    final builder = ProtocolSchemaBuilder();
    avatar = builder.addSpawnType(
      const SpawnTypeId('avatar'),
      const StringCodec(maxLength: 16),
    );
    whisper = builder.addRpc(
      const RpcId('avatar.whisper'),
      const StringCodec(maxLength: 16),
      target: RpcTarget.peer,
    );
    schema = builder.build();
  }

  late final SpawnType<String> avatar;
  late final Rpc<String> whisper;
  late final ProtocolSchema schema;
}

/// What a peer's spawn and despawn handlers saw.
final class _Observer {
  /// For each avatar spawned on the peer, its owner, and whether the peer
  /// listed the owner at that moment.
  final spawned = <(PeerId, bool)>[];

  /// The same for each avatar despawned on the peer.
  final despawned = <(PeerId, bool)>[];
}

/// A host and the clients that join it over an in-memory network.
final class _Harness {
  _Harness({this.timeouts = const SessionTimeouts()}) {
    network = InMemoryNetwork(clock: clock);
    host = _session()..host(network.host());
    _membership(host);
  }

  final clock = ManualClock();
  final definitions = _Schema();
  final SessionTimeouts timeouts;
  late final InMemoryNetwork network;
  late final MultiplayerSession host;
  final _sessions = <MultiplayerSession>[];
  final observers = <MultiplayerSession, _Observer>{};

  /// Sessions that stop updating, as if their game had frozen.
  final paused = <MultiplayerSession>{};

  /// Sessions that leave the entities of their baseline pending, so they
  /// keep synchronizing.
  final loading = <MultiplayerSession>{};

  MultiplayerSession _session() {
    final session = MultiplayerSession(
      schema: definitions.schema,
      clock: clock,
      timeouts: timeouts,
    );
    final observer = observers[session] = _Observer();
    session.bindSpawn(
      definitions.avatar,
      onSpawn: (context) {
        final owner = context.entity.owner;
        observer.spawned.add((owner, session.peers.contains(owner)));
        if (!loading.contains(session)) {
          session.registry.markReady(context.entity.id);
        }
      },
      onDespawn: (entity) => observer.despawned.add((
        entity.owner,
        session.peers.contains(entity.owner),
      )),
    );
    addTearDown(session.close);
    _sessions.add(session);
    return session;
  }

  /// Starts a client that joins the host.
  MultiplayerSession join() => _session()..join(network.connect());

  /// Advances the clock by [step] and updates every session that is not
  /// [paused], [rounds] times.
  void run({Duration step = Duration.zero, int rounds = 6}) {
    for (var i = 0; i < rounds; i++) {
      clock.advance(step);
      for (final session in _sessions) {
        if (!paused.contains(session)) session.update();
      }
    }
  }

  /// Runs until the host has admitted [client].
  void admit(PeerId client) {
    for (var i = 0; i < 6 && !host.peers.contains(client); i++) {
      run(rounds: 1);
    }
    expect(host.peers, contains(client));
  }
}

/// Takes every pending event from [session].
List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

/// Takes the pending membership events of [session], dropping the others.
List<SessionEvent> _membership(MultiplayerSession session) => [
  for (final event in _drain(session))
    if (event is PeerJoined || event is PeerReady || event is PeerLeft) event,
];

/// The clients of [session]'s session and whether each is ready, as
/// [session] sees them, including itself if it is a joined client.
Map<PeerId, bool> _roster(MultiplayerSession session) => {
  for (final peer in session.peers)
    if (peer != PeerId.host) peer: session.isReady(peer),
  if (!session.isHost && session.localPeer != null)
    session.localPeer!: session.state == SessionState.ready,
};

void main() {
  group('clients', () {
    test('list the other clients and their readiness as the host does', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      harness.run();

      expect(first.peers, [PeerId.host, _second]);
      expect(second.peers, [PeerId.host, _first]);
      expect(first.isReady(_second), isTrue);
      expect(second.isReady(_first), isTrue);
      expect(first.isReady(PeerId.host), isTrue);
      expect(_roster(first), {_first: true, _second: true});
      expect(_roster(second), _roster(harness.host));
      expect(_membership(first), const [
        PeerJoined(_second),
        PeerReady(_second),
      ]);
      // The second client's baseline already lists the first.
      expect(_membership(second), const [
        PeerJoined(_first),
        PeerReady(_first),
      ]);

      final third = harness.join();
      harness.run();

      expect(third.peers, [PeerId.host, _first, _second]);
      for (final session in [first, second, third]) {
        expect(_roster(session), _roster(harness.host));
      }
      expect(_membership(first), const [PeerJoined(_third), PeerReady(_third)]);
      expect(_membership(second), const [
        PeerJoined(_third),
        PeerReady(_third),
      ]);
      expect(_membership(third), const [
        PeerJoined(_first),
        PeerReady(_first),
        PeerJoined(_second),
        PeerReady(_second),
      ]);
      expect(_membership(harness.host), const [
        PeerJoined(_first),
        PeerJoined(_second),
        PeerReady(_first),
        PeerReady(_second),
        PeerJoined(_third),
        PeerReady(_third),
      ]);
    });

    test('a late joiner learns which clients are still synchronizing', () {
      final harness = _Harness();
      harness.host.spawn(harness.definitions.avatar, 'World');
      final slow = harness.join();
      harness.loading.add(slow);
      harness.run();
      expect(slow.state, SessionState.synchronizing);
      _membership(harness.host);

      final late = harness.join();
      harness.run();

      expect(late.state, SessionState.ready);
      expect(late.peers, [PeerId.host, _first]);
      expect(late.isReady(_first), isFalse);
      expect(_roster(late), _roster(harness.host));
      expect(_membership(slow), const [
        PeerJoined(_second),
        PeerReady(_second),
      ]);
      expect(_membership(late), const [PeerJoined(_first)]);

      slow.registry.markReady(slow.registry.entities.single.id);
      harness.run();

      expect(slow.state, SessionState.ready);
      expect(late.isReady(_first), isTrue);
      expect(_membership(late), const [PeerReady(_first)]);
      expect(_roster(late), _roster(harness.host));
      expect(_roster(slow), _roster(harness.host));
    });

    test('learn about a client before any entity that it owns', () {
      final harness = _Harness();
      final observer = harness.join();
      harness.run();

      // Like an application reacting to PeerJoined, the host spawns the new
      // client's avatar as soon as it admits the client.
      final player = harness.join();
      harness.admit(_second);
      harness.host.spawn(harness.definitions.avatar, 'Bob', owner: _second);
      harness.run();
      final late = harness.join();
      harness.run();

      expect(player.state, SessionState.ready);
      expect(harness.observers[observer]!.spawned, [(_second, true)]);
      expect(harness.observers[late]!.spawned, [(_second, true)]);
    });

    test('learn that a client left before the host reacts to it', () {
      final harness = _Harness();
      final observer = harness.join();
      final player = harness.join();
      harness.run();
      harness.host.spawn(
        harness.definitions.avatar,
        'Bob',
        owner: _second,
        onOwnerLeft: OwnerLeftPolicy.despawn,
      );
      harness.run();
      _membership(observer);

      player.close();
      harness.run();

      expect(observer.peers, [PeerId.host]);
      expect(observer.isReady(_second), isFalse);
      expect(_membership(observer), const [
        PeerLeft(_second, DisconnectReason.remoteClosed),
      ]);
      expect(harness.observers[observer]!.despawned, [(_second, false)]);
    });

    test('report why another client left', () {
      final harness = _Harness(
        timeouts: const SessionTimeouts(idle: Duration(seconds: 5)),
      );
      final observer = harness.join();
      final kicked = harness.join();
      final frozen = harness.join();
      harness.run();
      _membership(observer);

      harness.host.kick(_second);
      harness.run();
      harness.paused.add(frozen);
      harness.run(step: const Duration(seconds: 1), rounds: 6);

      expect(kicked.disconnectReason, DisconnectReason.kicked);
      expect(_membership(observer), const [
        PeerLeft(_second, DisconnectReason.kicked),
        PeerLeft(_third, DisconnectReason.timeout),
      ]);
      expect(observer.peers, [PeerId.host]);
      expect(_roster(observer), _roster(harness.host));
    });

    test('are not told about clients that the host has not admitted', () async {
      final harness = _Harness();
      final observer = harness.join();
      harness.run();
      _membership(observer);
      final decision = Completer<Admission>();
      harness.host.onJoinRequest = (request) =>
          request.peer == _second ? decision.future : Admission.reject('Full');

      final pending = harness.join();
      harness.run();
      final rejected = harness.join();
      harness.run();

      expect(rejected.disconnectReason, DisconnectReason.rejected);
      expect(pending.state, SessionState.handshaking);
      expect(observer.peers, [PeerId.host]);
      expect(_membership(observer), isEmpty);

      decision.complete(const Admission.admit());
      await Future<void>.delayed(Duration.zero);
      harness.run();

      expect(pending.state, SessionState.ready);
      expect(pending.peers, [PeerId.host, _first]);
      expect(observer.peers, [PeerId.host, _second]);
      expect(_membership(observer), const [
        PeerJoined(_second),
        PeerReady(_second),
      ]);
    });

    test('forget the other clients when they disconnect', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      harness.run();
      _membership(first);
      _membership(second);

      first.close();
      expect(first.peers, isEmpty);
      expect(first.isReady(_second), isFalse);
      expect(_membership(first), isEmpty);

      first.join(harness.network.connect());
      harness.run();
      expect(first.localPeer, _third);
      expect(first.peers, [PeerId.host, _second]);
      expect(_membership(second), const [
        PeerLeft(_first, DisconnectReason.remoteClosed),
        PeerJoined(_third),
        PeerReady(_third),
      ]);

      harness.host.close();
      harness.run();
      expect(second.disconnectReason, DisconnectReason.remoteClosed);
      expect(second.peers, isEmpty);
      expect(_membership(second), isEmpty);
    });

    test('reach the ready clients they list with peer-targeted RPCs', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      harness.run();
      final board = harness.host.spawn(harness.definitions.avatar, 'Board');
      harness.run();
      final whispers = <(PeerId, String)>[];
      second.bindRpc(
        second.registry[board.id]!,
        harness.definitions.whisper,
        (context, text) => whispers.add((context.sender, text)),
      );

      final reachable = first.peers.where(first.isReady).toList();
      for (final peer in reachable.where((peer) => peer != PeerId.host)) {
        expect(
          first.callRpc(
            first.registry[board.id]!,
            harness.definitions.whisper,
            'Hi',
            peer: peer,
          ),
          isTrue,
        );
      }
      harness.run();

      expect(reachable, [PeerId.host, _second]);
      expect(whispers, [(_first, 'Hi')]);
      for (final session in [harness.host, first, second]) {
        expect(_drain(session), isNot(contains(isA<RpcRejected>())));
      }
    });
  });

  group('a client', () {
    for (final (description, baseline, changes)
        in <(String, List<ProtocolMessage>, List<ProtocolMessage>)>[
          ('to itself', const [PeerJoinedMessage(peer: _first)], const []),
          (
            'a client twice',
            const [PeerJoinedMessage(peer: _second)],
            const [PeerJoinedMessage(peer: _second)],
          ),
          (
            'an unknown client ready',
            const [],
            const [PeerReadyMessage(peer: _second)],
          ),
          (
            'a client ready twice',
            const [
              PeerJoinedMessage(peer: _second),
              PeerReadyMessage(peer: _second),
            ],
            const [PeerReadyMessage(peer: _second)],
          ),
          (
            'an unknown client leaving',
            const [],
            const [
              PeerLeftMessage(peer: _second, reason: DepartureReason.left),
            ],
          ),
          (
            'a departure in the baseline',
            const [
              PeerJoinedMessage(peer: _second),
              PeerLeftMessage(peer: _second, reason: DepartureReason.left),
            ],
            const [],
          ),
        ]) {
      test('leaves a host that introduces $description', () {
        final harness = _RawHostHarness();
        harness.welcome(baseline);
        harness.change(changes);

        expect(
          harness.client.disconnectReason,
          DisconnectReason.protocolViolation,
        );
        expect(harness.client.peers, isEmpty);
      });
    }

    test('applies membership changes only in increasing revision order', () {
      final harness = _RawHostHarness();
      harness.welcome(const [PeerJoinedMessage(peer: _second)]);
      harness.change(const [
        PeerJoinedMessage(peer: _third),
        PeerReadyMessage(peer: _third),
      ]);
      // Obsolete: revisions 1 and 2 were applied already.
      harness.host
        ..send(const PeerReadyMessage(peer: _second), revision: 2)
        ..send(
          const PeerLeftMessage(peer: _third, reason: DepartureReason.kicked),
          revision: 1,
        );
      harness.run();

      expect(harness.client.state, SessionState.ready);
      expect(harness.client.obsoleteMessageCount, 2);
      expect(harness.client.peers, [PeerId.host, _second, _third]);
      expect(harness.client.isReady(_second), isFalse);
      expect(harness.client.isReady(_third), isTrue);

      harness.change(const [
        PeerLeftMessage(peer: _second, reason: DepartureReason.bootstrapFailed),
        PeerLeftMessage(peer: _third, reason: DepartureReason.transportError),
      ]);
      expect(harness.client.peers, [PeerId.host]);
      expect(_membership(harness.client), const [
        PeerJoined(_second),
        PeerJoined(_third),
        PeerReady(_third),
        PeerLeft(_second, DisconnectReason.bootstrapFailed),
        PeerLeft(_third, DisconnectReason.transportError),
      ]);
    });
  });
}

/// A client session joining a host that speaks the protocol directly, to
/// send what a session would not.
final class _RawHostHarness {
  _RawHostHarness() {
    network = InMemoryNetwork(clock: clock);
    host = _RawHost(network.host(), ProtocolCodec(definitions.schema));
    client = MultiplayerSession(schema: definitions.schema, clock: clock)
      ..join(network.connect());
    addTearDown(client.close);
    run();
  }

  final clock = ManualClock();
  final definitions = _Schema();
  late final InMemoryNetwork network;
  late final _RawHost host;
  late final MultiplayerSession client;

  void run() {
    for (var i = 0; i < 6; i++) {
      clock.advance(Duration.zero);
      host.update();
      client.update();
    }
  }

  /// Welcomes the client as [_first] at revision zero, with a baseline of
  /// [membership].
  void welcome(List<ProtocolMessage> membership) {
    host.send(const WelcomeMessage(peer: _first, epoch: 9));
    for (final message in membership) {
      host.send(message);
    }
    host.send(const SyncedMessage());
    run();
  }

  /// Sends [changes] with the revisions after the host's latest one.
  void change(List<ProtocolMessage> changes) {
    for (final message in changes) {
      host.send(message, revision: ++host.revision);
    }
    run();
  }
}

/// A host that speaks the protocol directly.
final class _RawHost {
  _RawHost(this.peer, this.codec);

  static const generation = 5;

  final InMemoryHost peer;
  final ProtocolCodec codec;
  PeerConnection? connection;
  var revision = 0;

  void update() {
    for (var event = peer.poll(); event != null; event = peer.poll()) {
      if (event case ConnectionOpened(:final connection)) {
        this.connection = connection;
      }
    }
  }

  void send(ProtocolMessage message, {int? revision}) => connection!.send(
    codec.encode(
      MessageEnvelope(
        message,
        generation: generation,
        revision: revision ?? this.revision,
      ),
    ),
  );
}
