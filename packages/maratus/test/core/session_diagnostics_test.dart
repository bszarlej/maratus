import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

import '../protocol/protocol_test_utils.dart';

const _ms = Duration(milliseconds: 1);
const _second = Duration(seconds: 1);

List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

Matcher _goodbye(GoodbyeReason reason) =>
    isA<GoodbyeMessage>().having((m) => m.reason, 'reason', reason);

/// A host and the participants that join it over an in-memory network.
final class _Harness {
  _Harness({
    Duration latency = Duration.zero,
    SessionTimeouts timeouts = const SessionTimeouts(),
    Duration? pingInterval = _second,
  }) {
    network = InMemoryNetwork(clock: clock, latency: latency);
    host = session(timeouts: timeouts, pingInterval: pingInterval)
      ..host(network.host());
  }

  final clock = ManualClock();
  final schema = buildTestSchema();
  late final InMemoryNetwork network;
  late final MultiplayerSession host;
  final _updates = <Object, void Function()>{};

  MultiplayerSession session({
    SessionTimeouts timeouts = const SessionTimeouts(),
    Duration? pingInterval = _second,
  }) {
    final session = MultiplayerSession(
      schema: schema,
      clock: clock,
      timeouts: timeouts,
      pingInterval: pingInterval,
    );
    addTearDown(session.close);
    _updates[session] = session.update;
    return session;
  }

  /// Starts a client session, returning it with its transport peer.
  (MultiplayerSession, InMemoryClient) join({
    SessionTimeouts timeouts = const SessionTimeouts(),
  }) {
    final peer = network.connect();
    return (session(timeouts: timeouts)..join(peer), peer);
  }

  _RawClient rawClient() {
    final client = _RawClient(network.connect(), schema);
    _updates[client] = client.update;
    return client;
  }

  /// Delivers everything in transit and updates every participant except
  /// the [stalled] ones.
  void settle({Set<Object> stalled = const {}}) {
    for (var i = 0; i < 6; i++) {
      clock.advance(Duration.zero);
      _update(stalled);
    }
  }

  /// Advances the clock by [duration] in steps of [step], updating every
  /// participant except the [stalled] ones after each step.
  void advance(
    Duration duration, {
    Duration step = const Duration(milliseconds: 10),
    Set<Object> stalled = const {},
  }) {
    for (var elapsed = Duration.zero; elapsed < duration; elapsed += step) {
      clock.advance(step);
      _update(stalled);
    }
  }

  void _update(Set<Object> stalled) {
    for (final MapEntry(key: participant, value: update)
        in _updates.entries.toList()) {
      if (!stalled.contains(participant)) update();
    }
  }
}

/// A client that speaks the protocol directly, to send what a session would
/// not.
final class _RawClient {
  _RawClient(this.peer, ProtocolSchema schema)
    : codec = ProtocolCodec(schema),
      fingerprint = schema.fingerprint;

  final InMemoryClient peer;
  final ProtocolCodec codec;
  final String fingerprint;
  PeerConnection? connection;
  var generation = 0;
  final received = <ProtocolMessage>[];

  void update() {
    for (var event = peer.poll(); event != null; event = peer.poll()) {
      switch (event) {
        case ConnectionOpened(:final connection):
          this.connection = connection;
        case MessageReceived(:final message):
          final envelope = codec.decode(message);
          if (envelope.message is WelcomeMessage) {
            generation = envelope.generation;
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

  void sendBytes(List<int> bytes) =>
      connection!.send(Uint8List.fromList(bytes));

  void hello() => send(HelloMessage(fingerprint: fingerprint));
}

/// A client session joining a host that speaks the protocol directly.
final class _RawHostHarness {
  _RawHostHarness() {
    final network = InMemoryNetwork(clock: clock);
    peer = network.host();
    codec = ProtocolCodec(schema);
    client = MultiplayerSession(schema: schema, clock: clock)
      ..join(network.connect());
    addTearDown(client.close);
    settle();
  }

  final clock = ManualClock();
  final schema = buildTestSchema();
  late final InMemoryHost peer;
  late final ProtocolCodec codec;
  late final MultiplayerSession client;
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

  void settle() {
    for (var i = 0; i < 6; i++) {
      clock.advance(Duration.zero);
      update();
      client.update();
    }
  }

  void send(ProtocolMessage message, {int generation = 5}) => connection!.send(
    codec.encode(MessageEnvelope(message, generation: generation)),
  );

  /// Accepts the client with an empty baseline.
  void welcome() {
    send(const WelcomeMessage(peer: PeerId(2), epoch: 9));
    send(const SyncedMessage());
    settle();
    expect(client.state, SessionState.ready);
  }
}

void main() {
  group('round trips', () {
    test('pings measure the round trip once a peer is accepted', () {
      final harness = _Harness(latency: _ms * 20);
      final (client, _) = harness.join();
      harness.advance(_ms * 200);
      expect(client.state, SessionState.ready);

      // The first ping follows one interval after the welcome.
      expect(harness.host.diagnostics.peers.single.roundTripTime, isNull);
      expect(harness.host.diagnostics.sent[MessageKind.ping].messages, 0);
      expect(client.diagnostics.sent[MessageKind.ping].messages, 0);

      harness.advance(_second);
      final atHost = harness.host.diagnostics.peers.single;
      final atClient = client.diagnostics.peers.single;
      expect(atHost.peer, client.localPeer);
      expect(atHost.roundTripTime, _ms * 40);
      expect(atHost.smoothedRoundTripTime, _ms * 40);
      expect(atClient.peer, PeerId.host);
      expect(atClient.roundTripTime, _ms * 40);
      expect(harness.host.diagnostics.sent[MessageKind.ping].messages, 1);
      expect(harness.host.diagnostics.received[MessageKind.pong].messages, 1);
      expect(client.diagnostics.sent[MessageKind.pong].messages, 1);
      expect(atClient.lastReceivedAt, harness.clock.now - _ms * 80);
    });

    test('round trips follow latency changes', () {
      final harness = _Harness(latency: _ms * 20);
      final (client, peer) = harness.join();
      harness.advance(_ms * 1200);
      expect(harness.host.diagnostics.peers.single.roundTripTime, _ms * 40);

      peer.link.latency = _ms * 50;
      harness.advance(_second);
      final atHost = harness.host.diagnostics.peers.single;
      expect(atHost.roundTripTime, _ms * 100);
      // Each round trip weighs one eighth of the smoothed value.
      expect(atHost.smoothedRoundTripTime, const Duration(microseconds: 47500));
      expect(client.diagnostics.peers.single.roundTripTime, _ms * 100);
    });

    test('a session waits for an answer before pinging again', () {
      final harness = _Harness();
      final (client, _) = harness.join();
      harness.settle();

      harness.advance(_second * 5, step: _ms * 100, stalled: {client});
      expect(harness.host.diagnostics.sent[MessageKind.ping].messages, 1);
      expect(harness.host.diagnostics.peers.single.roundTripTime, isNull);

      // The client answers the ping it missed, 4 s late.
      client.update();
      harness.clock.advance(Duration.zero);
      harness.host.update();
      final atHost = harness.host.diagnostics;
      expect(atHost.peers.single.roundTripTime, _ms * 4000);
      // The next ping was due long ago, so it follows the answer at once.
      expect(atHost.sent[MessageKind.ping].messages, 2);
    });

    test('a session without pings still answers them', () {
      final harness = _Harness(pingInterval: null);
      final raw = harness.rawClient();
      harness.settle();
      raw.hello();
      harness
        ..settle()
        ..advance(_second * 5, step: _ms * 500);
      expect(raw.received.whereType<PingMessage>(), isEmpty);

      raw.send(const PingMessage(7));
      harness.settle();

      expect(
        raw.received.last,
        isA<PongMessage>().having((m) => m.sequence, 'sequence', 7),
      );
      expect(harness.host.diagnostics.peers.single.roundTripTime, isNull);
    });
  });

  group('ping validation', () {
    test('drops a client that answers a ping it was not sent', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      harness.settle();
      raw.hello();
      harness.settle();
      final peer = harness.host.peers.single;

      raw.send(const PongMessage(0));
      harness.settle();

      expect(raw.received.last, _goodbye(GoodbyeReason.protocolViolation));
      expect(
        _drain(harness.host),
        contains(PeerLeft(peer, DisconnectReason.protocolViolation)),
      );
    });

    test('drops a client that answers with another sequence', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      harness.settle();
      raw.hello();
      harness
        ..settle()
        ..advance(_second, step: _ms * 100)
        ..settle();
      final ping = raw.received.whereType<PingMessage>().single;

      raw.send(PongMessage(ping.sequence + 1));
      harness.settle();

      expect(raw.received.last, _goodbye(GoodbyeReason.protocolViolation));
      expect(harness.host.peers, isEmpty);
    });

    test('drops a client that pings before it is accepted', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      harness.settle();

      raw.send(const PingMessage(0));
      harness.settle();

      expect(raw.received, [_goodbye(GoodbyeReason.protocolViolation)]);
      expect(harness.host.diagnostics.pendingConnections, 0);
    });

    test('a client answers its host and measures the round trip', () {
      final harness = _RawHostHarness()..welcome();

      harness.send(const PingMessage(9));
      harness.settle();
      expect(
        harness.received.last,
        isA<PongMessage>().having((m) => m.sequence, 'sequence', 9),
      );

      harness.clock.advance(_second);
      harness.client.update();
      harness.clock.advance(_ms * 30);
      harness.update();
      final ping = harness.received.last as PingMessage;
      harness.send(PongMessage(ping.sequence));
      harness.settle();

      expect(harness.client.state, SessionState.ready);
      expect(harness.client.diagnostics.peers.single.roundTripTime, _ms * 30);
    });

    test('a client leaves a host that sends an unsolicited pong', () {
      final harness = _RawHostHarness()..welcome();

      harness.send(const PongMessage(0));
      harness.settle();

      expect(
        harness.client.disconnectReason,
        DisconnectReason.protocolViolation,
      );
      expect(harness.received.last, _goodbye(GoodbyeReason.protocolViolation));
    });

    test('a client leaves a host that pings before welcoming it', () {
      final harness = _RawHostHarness();

      harness.send(const PingMessage(0), generation: 0);
      harness.settle();

      expect(
        harness.client.disconnectReason,
        DisconnectReason.protocolViolation,
      );
    });
  });

  group('traffic', () {
    test('counts the messages and bytes of each kind', () {
      final harness = _Harness();
      final (client, _) = harness.join();
      harness.settle();

      final atHost = harness.host.diagnostics;
      final atClient = client.diagnostics;
      expect(atHost.sent[MessageKind.welcome].messages, 1);
      expect(atHost.sent[MessageKind.synced].messages, 1);
      expect(atHost.sent.messages, 2);
      expect(
        atHost.sent[MessageKind.welcome].bytes +
            atHost.sent[MessageKind.synced].bytes,
        atHost.sent.bytes,
      );
      expect(atHost.received[MessageKind.hello].messages, 1);
      expect(atHost.received[MessageKind.ready].messages, 1);
      expect(atClient.sent.messages, 2);
      expect(atClient.received.messages, 2);
      // The in-memory transport delivers exactly what was sent.
      expect(atClient.received.bytes, atHost.sent.bytes);
      expect(atHost.received.bytes, atClient.sent.bytes);
      expect(atHost.peers.single.sent.bytes, atHost.sent.bytes);
      expect(atHost.peers.single.received.bytes, atHost.received.bytes);
      expect(atHost.sent[MessageKind.state].messages, 0);
    });

    test('session totals keep malformed and departed traffic', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      harness.settle();
      expect(harness.host.diagnostics.pendingConnections, 1);

      raw.sendBytes([1, 2, 3]);
      harness.settle();

      final diagnostics = harness.host.diagnostics;
      expect(diagnostics.received.messages, 1);
      expect(diagnostics.received.bytes, 3);
      expect([
        for (final kind in MessageKind.values)
          diagnostics.received[kind].messages,
      ], everyElement(0));
      expect(diagnostics.sent[MessageKind.goodbye].messages, 1);
      expect(diagnostics.peers, isEmpty);
      expect(diagnostics.pendingConnections, 0);
    });

    test('reports the queues of each connection', () {
      final harness = _Harness(latency: _ms * 20);
      final (client, _) = harness.join();
      harness.advance(_ms * 200);
      final move =
          harness.schema.rpcDefinition(const RpcId('player.move'))!
              as Rpc<MoveInput>;
      final atHost = harness.host.registry.register(
        const EntityId(7),
        owner: PeerId.host,
        authority: PeerId.host,
      );
      final atClient = client.registry.register(
        const EntityId(7),
        owner: PeerId.host,
        authority: PeerId.host,
      );
      harness.host.bindRpc(atHost, move, (_, _) {});
      harness.host.registry.markReady(atHost.id);
      client.registry.markReady(atClient.id);

      expect(client.callRpc(atClient, move, const MoveInput(0, 0)), isTrue);
      final size = client.diagnostics.sent[MessageKind.rpc].bytes;
      expect(client.diagnostics.peers.single.outgoing.messages, 1);

      harness.clock.advance(_ms * 20);
      expect(harness.host.diagnostics.peers.single.incoming, (
        messages: 1,
        bytes: size,
      ));
      harness.host.update();
      expect(harness.host.diagnostics.peers.single.incoming, (
        messages: 0,
        bytes: 0,
      ));

      harness.advance(_ms * 100);
      expect(client.diagnostics.peers.single.outgoing, (messages: 0, bytes: 0));
    });
  });

  test('resource counts return to their baseline after each session', () {
    final harness = _Harness();
    final player =
        harness.schema.spawnTypeDefinition(const SpawnTypeId('player'))!
            as SpawnType<String>;
    final health =
        harness.schema.fieldDefinition(const FieldId('player.health'))!
            as SyncField<int>;
    final move =
        harness.schema.rpcDefinition(const RpcId('player.move'))!
            as Rpc<MoveInput>;
    void bind(MultiplayerSession session) => session.bindSpawn(
      player,
      onSpawn: (context) {
        session.attachEntity(
            context.entity,
            isReady: () => true,
            isValid: () => true,
          )
          ..bindRpc(move, (_, _) {})
          ..synchronize([health.property(get: () => 1, set: (_) {})]);
      },
    );
    bind(harness.host);
    final client = harness.session();
    bind(client);

    void expectIdle(SessionDiagnostics diagnostics) {
      expect(diagnostics.entities, 0);
      expect(diagnostics.replicatedEntities, 0);
      expect(diagnostics.attachments, 0);
      expect(diagnostics.synchronizers, 0);
      expect(diagnostics.rpcBindings, 0);
      expect(diagnostics.spawnBindings, 1);
      expect(diagnostics.pendingRpcs, (messages: 0, bytes: 0));
      expect(diagnostics.peers, isEmpty);
    }

    expectIdle(harness.host.diagnostics);
    for (var cycle = 0; cycle < 3; cycle++) {
      client.join(harness.network.connect());
      harness.settle();
      harness.host.spawn(
        player,
        'Ada',
        owner: client.localPeer!,
        onOwnerLeft: OwnerLeftPolicy.despawn,
      );
      harness.host.captureState();
      harness.settle();

      for (final session in [harness.host, client]) {
        final diagnostics = session.diagnostics;
        expect(diagnostics.entities, 1);
        expect(diagnostics.replicatedEntities, 1);
        expect(diagnostics.attachments, 1);
        expect(diagnostics.synchronizers, 1);
        expect(diagnostics.rpcBindings, 1);
        expect(diagnostics.peers, hasLength(1));
      }
      // Counts start over with each session.
      expect(client.diagnostics.sent[MessageKind.hello].messages, 1);

      client.close();
      harness.settle();
      expectIdle(harness.host.diagnostics);
      expectIdle(client.diagnostics);
      expect(harness.network.links, isEmpty);
      expect(harness.clock.pendingTimerCount, 0);
    }
  });

  group('idle timeout', () {
    const timeouts = SessionTimeouts(idle: Duration(seconds: 3));

    test('a host drops a client that stops sending', () {
      final harness = _Harness(timeouts: timeouts);
      final (client, _) = harness.join();
      harness.settle();
      final peer = client.localPeer!;
      _drain(harness.host);

      harness.advance(_ms * 2900, step: _ms * 100, stalled: {client});
      expect(harness.host.peers, [peer]);
      harness.advance(_ms * 100, step: _ms * 100, stalled: {client});

      expect(harness.host.peers, isEmpty);
      expect(_drain(harness.host), [PeerLeft(peer, DisconnectReason.timeout)]);
      harness.settle();
      expect(client.disconnectReason, DisconnectReason.timeout);
    });

    test('a client leaves a host that stops sending', () {
      final harness = _Harness();
      final (client, _) = harness.join(timeouts: timeouts);
      harness.settle();
      final peer = client.localPeer!;

      harness.advance(_second * 3, step: _ms * 100, stalled: {harness.host});

      expect(client.disconnectReason, DisconnectReason.timeout);
      _drain(harness.host);
      harness.settle();
      expect(_drain(harness.host), [PeerLeft(peer, DisconnectReason.timeout)]);
    });

    test('pings keep updating peers connected', () {
      final harness = _Harness(timeouts: timeouts);
      final (client, _) = harness.join(timeouts: timeouts);
      harness.settle();

      harness.advance(_second * 10, step: _ms * 100);

      expect(client.state, SessionState.ready);
      expect(harness.host.isReady(client.localPeer!), isTrue);
      expect(harness.host.diagnostics.peers.single.roundTripTime, _ms * 200);
    });

    test('is disabled by default', () {
      final harness = _Harness();
      final (client, _) = harness.join();
      harness.settle();

      harness.advance(_second * 60, step: _second, stalled: {client});

      expect(harness.host.peers, [client.localPeer]);
    });

    test('requires a positive timeout and a shorter ping interval', () {
      final schema = buildTestSchema();
      for (final (timeouts, pingInterval) in [
        (const SessionTimeouts(idle: Duration.zero), _second),
        (SessionTimeouts(idle: -_ms), _second),
        (timeouts, null),
        (timeouts, _second * 3),
        (timeouts, _second * 4),
        (const SessionTimeouts(), Duration.zero),
        (const SessionTimeouts(), -_ms),
      ]) {
        expect(
          () => MultiplayerSession(
            schema: schema,
            timeouts: timeouts,
            pingInterval: pingInterval,
          ),
          throwsArgumentError,
          reason: '${timeouts.idle} with pings every $pingInterval',
        );
      }
      expect(
        MultiplayerSession(schema: schema, pingInterval: null).pingInterval,
        isNull,
      );
    });
  });
}
