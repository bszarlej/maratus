import 'dart:async';
import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus_webrtc/maratus_webrtc.dart';
import 'package:maratus_webrtc/src/signaling_protocol.dart';
import 'package:maratus_webrtc/src/webrtc_driver.dart';
import 'package:maratus_webrtc/src/webrtc_peer_base.dart';
import 'package:test/test.dart';

import 'support/fake_webrtc_driver.dart';
import 'support/in_memory_signaling.dart';

const QueueDepth _empty = (messages: 0, bytes: 0);
const _interval = Duration(milliseconds: 2);
const _connectTimeout = Duration(milliseconds: 40);
const _closeTimeout = Duration(milliseconds: 10);

const _kindMessage = 0;
const _kindAck = 1;
const _kindClose = 2;
const _kindPart = 3;

Uint8List _frame(
  int kind,
  int sequence, [
  List<int> payload = const [],
  DeliveryMode mode = DeliveryMode.reliable,
]) {
  final bytes = Uint8List(6 + payload.length);
  bytes[0] = kind;
  bytes[1] = mode.index;
  ByteData.sublistView(bytes).setUint32(2, sequence);
  bytes.setRange(6, bytes.length, payload);
  return bytes;
}

Uint8List _closeMarker() => _frame(_kindClose, 0);

Matcher _message(
  PeerConnection connection,
  List<int> payload, {
  DeliveryMode mode = DeliveryMode.reliable,
  int channel = 0,
}) => isA<MessageReceived>()
    .having((event) => event.connection, 'connection', same(connection))
    .having((event) => event.message, 'message', payload)
    .having((event) => event.mode, 'mode', mode)
    .having((event) => event.channel, 'channel', channel);

Matcher _closed(PeerConnection connection, CloseReason reason) =>
    isA<ConnectionClosed>()
        .having((event) => event.connection, 'connection', same(connection))
        .having((event) => event.reason, 'reason', reason);

Matcher _sentFrame(
  int lane,
  int kind,
  int sequence, {
  List<int>? payload,
  DeliveryMode mode = DeliveryMode.reliable,
}) => isA<FakeFrame>()
    .having((frame) => frame.lane, 'lane', lane)
    .having((frame) => frame.kind, 'kind', kind)
    .having((frame) => frame.mode, 'mode', mode.index)
    .having((frame) => frame.sequence, 'sequence', sequence)
    .having((frame) => frame.payload, 'payload', payload ?? isA<Uint8List>());

Matcher get _closeMarkerFrame =>
    isA<FakeFrame>().having((frame) => frame.bytes, 'bytes', _closeMarker());

List<PeerEvent> _drain(MultiplayerPeer peer) => [
  for (var event = peer.poll(); event != null; event = peer.poll()) event,
];

/// The client side of a host's negotiation, scripted by a test.
final class _RemoteClient {
  _RemoteClient(this.channel) {
    channel.messages.listen(
      (text) => received.add(SignalingMessage.decode(text)),
      onDone: () => ended = true,
    );
  }

  final InMemorySignalingChannel channel;
  final received = <SignalingMessage>[];
  var ended = false;

  void send(SignalingMessage message) => channel.send(message.encode());
}

final class _Host {
  _Host({
    this.channelCount = 1,
    int maxConnections = 64,
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
    List<IceServer> iceServers = const [],
  }) {
    peer = WebRtcPeerBase.host(
      driver: driver,
      signaling: signaling,
      iceServers: iceServers,
      channelCount: channelCount,
      maxConnections: maxConnections,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      clock: clock,
      serviceInterval: _interval,
      connectTimeout: _connectTimeout,
      closeTimeout: _closeTimeout,
    );
  }

  final driver = FakeWebRtcDriver();
  final clock = ManualClock();
  final signaling = InMemorySignaling();
  final int channelCount;
  late final WebRtcPeerBase peer;

  int get laneCount => channelCount * 2;

  void step() => clock.advance(_interval);

  /// Joins through signaling and sends an offer, as a client would.
  Future<_RemoteClient> offer({int? channelCount, int? version}) async {
    final remote = _RemoteClient(signaling.join());
    remote.send(
      OfferMessage(
        sdp: 'client offer',
        channelCount: channelCount ?? this.channelCount,
        version: version ?? webRtcProtocolVersion,
      ),
    );
    await pumpEventQueue();
    return remote;
  }

  /// Negotiates a connection and polls its open event.
  Future<PeerConnection> connect() async {
    await offer();
    final id = driver.opened.last.connection;
    driver.events.add(WebRtcDriverDescription(id, 'host answer'));
    driver.openLanes(id, laneCount);
    step();
    await pumpEventQueue();
    final event = peer.poll();
    expect(event, isA<ConnectionOpened>());
    return event!.connection;
  }

  void receive(Uint8List bytes, {int connection = 1, int lane = 0}) {
    driver.events.add(WebRtcDriverMessage(connection, lane, bytes));
    step();
  }
}

final class _Client {
  _Client({
    this.channelCount = 1,
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
    bool throwOpen = false,
    bool throwCreateOffer = false,
  }) {
    final (local, host) = InMemorySignalingChannel.pair();
    signaling = local;
    remote = _RemoteClient(host);
    driver
      ..throwOpen = throwOpen
      ..throwCreateOffer = throwCreateOffer;
    peer = WebRtcPeerBase.client(
      driver: driver,
      signaling: local,
      channelCount: channelCount,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      clock: clock,
      serviceInterval: _interval,
      connectTimeout: _connectTimeout,
      closeTimeout: _closeTimeout,
    );
  }

  final driver = FakeWebRtcDriver();
  final clock = ManualClock();
  final int channelCount;
  late final InMemorySignalingChannel signaling;

  /// The host's end of signaling, scripted by the test.
  late final _RemoteClient remote;
  late final WebRtcPeerBase peer;

  int get laneCount => channelCount * 2;

  void step() => clock.advance(_interval);

  /// Reports the local offer, which the client sends through signaling.
  Future<void> describe() async {
    driver.events.add(const WebRtcDriverDescription(1, 'client offer'));
    step();
    await pumpEventQueue();
  }

  Future<void> answer() async {
    remote.send(const AnswerMessage('host answer'));
    await pumpEventQueue();
  }

  Future<PeerConnection> connect() async {
    await describe();
    await answer();
    driver.openLanes(1, laneCount);
    step();
    final event = peer.poll();
    expect(event, isA<ConnectionOpened>());
    return event!.connection;
  }
}

/// A host and a client whose drivers are wired to each other.
final class _Pair {
  _Pair({int channelCount = 1}) {
    host = WebRtcPeerBase.host(
      driver: hostDriver,
      signaling: signaling,
      channelCount: channelCount,
      clock: clock,
      serviceInterval: _interval,
      connectTimeout: _connectTimeout,
      closeTimeout: _closeTimeout,
    );
    client = WebRtcPeerBase.client(
      driver: clientDriver,
      signaling: signaling.join(),
      channelCount: channelCount,
      clock: clock,
      serviceInterval: _interval,
      connectTimeout: _connectTimeout,
      closeTimeout: _closeTimeout,
    );
    laneCount = channelCount * 2;
  }

  final clock = ManualClock();
  final signaling = InMemorySignaling();
  final hostDriver = FakeWebRtcDriver();
  final clientDriver = FakeWebRtcDriver();
  late final int laneCount;
  late final WebRtcPeerBase host;
  late final WebRtcPeerBase client;

  void step() => clock.advance(_interval);

  Future<(PeerConnection, PeerConnection)> connect() async {
    clientDriver.events.add(const WebRtcDriverDescription(1, 'offer'));
    step();
    await pumpEventQueue();
    expect(hostDriver.offers.single.sdp, 'offer');
    hostDriver.events
      ..add(const WebRtcDriverDescription(1, 'answer'))
      ..add(const WebRtcDriverCandidate(1, 'candidate:host', '0'));
    clientDriver.events.add(
      const WebRtcDriverCandidate(1, 'candidate:client', '0'),
    );
    step();
    await pumpEventQueue();
    expect(clientDriver.answers.single.sdp, 'answer');
    expect(clientDriver.candidates.single.candidate, 'candidate:host');
    expect(hostDriver.candidates.single.candidate, 'candidate:client');
    hostDriver.openLanes(1, laneCount);
    clientDriver.openLanes(1, laneCount);
    step();
    final hostEvent = host.poll();
    final clientEvent = client.poll();
    expect(hostEvent, isA<ConnectionOpened>());
    expect(clientEvent, isA<ConnectionOpened>());
    return (hostEvent!.connection, clientEvent!.connection);
  }

  /// Moves sent data between the drivers, losing unordered data for which
  /// [lose] returns true.
  void flush({bool Function(FakeFrame frame)? lose}) {
    void move(FakeWebRtcDriver from, FakeWebRtcDriver to) {
      for (final frame in from.take()) {
        if (frame.lane.isOdd && (lose?.call(frame) ?? false)) continue;
        to.events.add(WebRtcDriverMessage(1, frame.lane, frame.bytes));
      }
    }

    move(hostDriver, clientDriver);
    move(clientDriver, hostDriver);
    step();
  }
}

void main() {
  final cleanups = <Future<void> Function()>[];

  Future<void> finish(WebRtcPeerBase peer, ManualClock clock) async {
    peer.close();
    clock.advance(const Duration(milliseconds: 100));
    await peer.done;
    expect(clock.pendingTimerCount, 0);
  }

  _Host host({
    int channelCount = 1,
    int maxConnections = 64,
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
    List<IceServer> iceServers = const [],
  }) {
    final result = _Host(
      channelCount: channelCount,
      maxConnections: maxConnections,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      iceServers: iceServers,
    );
    cleanups.add(() async {
      await finish(result.peer, result.clock);
      expect(result.driver.disposeCalls, 1);
      expect(result.signaling.isClosed, isTrue);
    });
    return result;
  }

  _Client client({
    int channelCount = 1,
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
    bool throwOpen = false,
    bool throwCreateOffer = false,
  }) {
    final result = _Client(
      channelCount: channelCount,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      throwOpen: throwOpen,
      throwCreateOffer: throwCreateOffer,
    );
    cleanups.add(() async {
      await finish(result.peer, result.clock);
      expect(result.driver.disposeCalls, 1);
      expect(result.signaling.isClosed, isTrue);
    });
    return result;
  }

  _Pair pair({int channelCount = 1}) {
    final result = _Pair(channelCount: channelCount);
    cleanups.add(() async {
      result.host.close();
      result.client.close();
      result.clock.advance(const Duration(milliseconds: 100));
      await Future.wait([result.host.done, result.client.done]);
      expect(result.clock.pendingTimerCount, 0);
    });
    return result;
  }

  tearDown(() async {
    for (final cleanup in cleanups) {
      await cleanup();
    }
    cleanups.clear();
  });

  group('options', () {
    final invalid = <String, void Function()>{
      'no channels': () => _Host(channelCount: 0),
      'too many channels': () => _Host(channelCount: maxWebRtcChannels + 1),
      'no connections': () => _Host(maxConnections: 0),
      'too many connections': () =>
          _Host(maxConnections: maxWebRtcConnections + 1),
      'an invalid ICE server': () => _Host(
        iceServers: const [
          IceServer(['turn:turn.example.com']),
        ],
      ),
    };
    for (final MapEntry(key: name, value: create) in invalid.entries) {
      test('$name are rejected before any resources are used', () {
        expect(create, throwsArgumentError);
      });
    }

    test('capabilities include every delivery mode on each channel', () {
      final h = host(channelCount: 3);
      final capabilities = h.peer.capabilities;
      expect(capabilities.canHost, isTrue);
      expect(capabilities.channelCount, 3);
      expect(capabilities.maxUnreliableMessageBytes, maxUnreliableBytes);
      expect(capabilities.deliveryModes, DeliveryMode.values.toSet());
      expect(h.peer.isHost, isTrue);
      expect(client().peer.isHost, isFalse);
    });
  });

  group('host negotiation', () {
    test(
      'applies an offer, answers, and opens once every lane opens',
      () async {
        final h = host(
          channelCount: 2,
          iceServers: const [
            IceServer(['stun:stun.example.com']),
          ],
        );
        final remote = await h.offer();
        final opened = h.driver.opened.single;
        expect(opened.laneCount, 4);
        expect(opened.servers.single.urls, ['stun:stun.example.com']);
        expect(h.driver.offers.single, (connection: 1, sdp: 'client offer'));

        h.driver.events
          ..add(const WebRtcDriverDescription(1, 'host answer'))
          ..add(const WebRtcDriverCandidate(1, 'candidate:host', '0'));
        h.step();
        await pumpEventQueue();
        expect(remote.received, [
          isA<AnswerMessage>().having((m) => m.sdp, 'sdp', 'host answer'),
          isA<CandidateMessage>()
              .having((m) => m.candidate, 'candidate', 'candidate:host')
              .having((m) => m.mid, 'mid', '0'),
        ]);

        remote.send(const CandidateMessage('candidate:client', '0'));
        await pumpEventQueue();
        expect(h.driver.candidates.single, (
          connection: 1,
          candidate: 'candidate:client',
          mid: '0',
        ));

        for (var lane = 0; lane < 3; lane++) {
          h.driver.events.add(WebRtcDriverLaneOpened(1, lane));
        }
        h.driver.events.add(const WebRtcDriverLaneOpened(1, 0));
        h.step();
        expect(h.peer.poll(), isNull);
        h.driver.events.add(const WebRtcDriverLaneOpened(1, 3));
        h.step();
        final event = h.peer.poll();
        expect(event, isA<ConnectionOpened>());
        expect(event!.connection.isOpen, isTrue);
        await pumpEventQueue();
        expect(remote.ended, isTrue, reason: 'signaling closes once open');
      },
    );

    for (final (name, channels, version) in [
      ('channel count', 2, webRtcProtocolVersion),
      ('protocol version', 1, webRtcProtocolVersion + 1),
    ]) {
      test('rejects a different $name without creating a connection', () async {
        final h = host(maxConnections: 1);
        final remote = await h.offer(channelCount: channels, version: version);
        expect(remote.received.single, isA<RejectMessage>());
        expect(
          (remote.received.single as RejectMessage).reason,
          RejectMessage.incompatible,
        );
        expect(remote.ended, isTrue);
        expect(h.driver.opened, isEmpty);
        // The refused negotiation does not keep the only admission slot.
        await h.connect();
      });
    }

    test('refuses clients beyond maxConnections, counting negotiations and '
        'unpolled closures', () async {
      final h = host(maxConnections: 1);
      final first = await h.offer();
      final refused = await h.offer();
      expect(refused.received.single, isA<RejectMessage>());
      expect(
        (refused.received.single as RejectMessage).reason,
        RejectMessage.full,
      );
      expect(refused.ended, isTrue);
      expect(h.driver.opened, hasLength(1));

      h.driver.events.add(const WebRtcDriverDescription(1, 'host answer'));
      h.driver.openLanes(1, h.laneCount);
      h.step();
      await pumpEventQueue();
      final connection = h.peer.poll()!.connection;
      expect(first.received.first, isA<AnswerMessage>());

      h.driver.events.add(const WebRtcDriverClosed(1));
      h.step();
      expect((await h.offer()).received.single, isA<RejectMessage>());

      expect(h.peer.poll(), _closed(connection, CloseReason.lost));
      final accepted = await h.offer();
      expect(accepted.received, isEmpty);
      expect(h.driver.opened, hasLength(2));
    });

    test('drops a negotiation that does not finish in time', () async {
      final h = host();
      final remote = await h.offer();
      h.clock.advance(_connectTimeout);
      await pumpEventQueue();
      expect(h.driver.closed, [1]);
      expect(remote.ended, isTrue);
      h.driver.openLanes(1, h.laneCount);
      h.step();
      expect(h.peer.poll(), isNull);
    });

    final violations = <String, Future<void> Function(_Host, _RemoteClient)>{
      'malformed signaling': (h, remote) async {
        remote.channel.send('{');
      },
      'a second offer': (h, remote) async {
        remote.send(const OfferMessage(sdp: 'again', channelCount: 1));
      },
      'an answer': (h, remote) async {
        remote.send(const AnswerMessage('answer'));
      },
      'too many candidates': (h, remote) async {
        for (var index = 0; index <= 128; index++) {
          remote.send(CandidateMessage('candidate:$index'));
        }
      },
      'a driver closure': (h, remote) async {
        h.driver.events.add(const WebRtcDriverClosed(1));
        h.step();
      },
      'an unknown lane': (h, remote) async {
        h.driver.events.add(WebRtcDriverLaneOpened(1, h.laneCount));
        h.step();
      },
      'too much data before the lanes open': (h, remote) async {
        h.driver.events.add(const WebRtcDriverLaneOpened(1, 0));
        for (var index = 0; index <= 64; index++) {
          h.driver.events.add(
            WebRtcDriverMessage(1, 0, _frame(_kindMessage, index + 1)),
          );
        }
        h.step();
      },
    };
    for (final MapEntry(key: name, value: violate) in violations.entries) {
      test('$name drops the negotiation', () async {
        final h = host();
        final remote = await h.offer();
        await violate(h, remote);
        await pumpEventQueue();
        expect(h.driver.closed, [1]);
        expect(remote.ended, isTrue);
        h.driver.openLanes(1, h.laneCount);
        h.step();
        expect(h.peer.poll(), isNull);
      });
    }

    test('drops clients whose signaling ends before an offer', () async {
      final h = host();
      final ended = h.signaling.join();
      final (failing, failed) = InMemorySignalingChannel.pair();
      h.signaling.accept(failed);
      final failedClient = _RemoteClient(failing);
      final candidate = _RemoteClient(h.signaling.join())
        ..send(const CandidateMessage('candidate:1'));
      await pumpEventQueue();
      ended.close();
      failed.fail();
      await pumpEventQueue();
      expect(failed.isClosed, isTrue, reason: 'the host closes a failed end');
      expect(failedClient.ended, isTrue);
      expect(candidate.ended, isTrue);
      expect(h.driver.opened, isEmpty);
      // None of the dropped clients holds an admission slot.
      await h.connect();
    });

    test('driver failures while applying the offer drop the client', () async {
      final h = host();
      h.driver.throwOpen = true;
      final refused = await h.offer();
      expect(refused.ended, isTrue);
      h.driver
        ..throwOpen = false
        ..throwAccept = true;
      final failed = await h.offer();
      expect(failed.ended, isTrue);
      expect(h.driver.closed, [1]);
    });

    test('an answer that cannot be delivered drops the client', () async {
      final h = host();
      final remote = await h.offer();
      remote.channel.close();
      await pumpEventQueue();
      expect(h.driver.closed, isEmpty, reason: 'the offer was applied');
      h.driver.events.add(const WebRtcDriverDescription(1, 'host answer'));
      h.step();
      expect(h.driver.closed, [1]);
    });

    test('negotiation can finish after signaling ends', () async {
      final h = host();
      final remote = await h.offer();
      h.driver.events.add(const WebRtcDriverDescription(1, 'host answer'));
      h.step();
      await pumpEventQueue();
      remote.channel.close();
      await pumpEventQueue();
      h.driver
        ..events.add(const WebRtcDriverCandidate(1, 'candidate:late', '0'))
        ..openLanes(1, h.laneCount);
      h.step();
      expect(h.peer.poll(), isA<ConnectionOpened>());
    });

    test('unusable remote candidates are ignored', () async {
      final h = host();
      final remote = await h.offer();
      h.driver.throwCandidate = true;
      remote.send(const CandidateMessage('candidate:bad'));
      await pumpEventQueue();
      expect(remote.ended, isFalse);
      h.driver.events.add(const WebRtcDriverDescription(1, 'host answer'));
      h.driver.openLanes(1, h.laneCount);
      h.step();
      expect(h.peer.poll(), isA<ConnectionOpened>());
    });

    test(
      'data that arrives before every lane opens follows the open event',
      () async {
        final h = host(channelCount: 2);
        await h.offer();
        h.driver.events
          ..add(const WebRtcDriverDescription(1, 'host answer'))
          ..add(const WebRtcDriverLaneOpened(1, 0))
          ..add(WebRtcDriverMessage(1, 0, _frame(_kindMessage, 1, [7])));
        h.step();
        expect(h.peer.poll(), isNull);
        h.driver.openLanes(1, h.laneCount);
        h.step();
        final opened = h.peer.poll()!;
        expect(opened, isA<ConnectionOpened>());
        expect(h.peer.poll(), _message(opened.connection, [7]));
      },
    );

    test(
      'closing stops signaling and abandons negotiations silently',
      () async {
        final h = host();
        final remote = await h.offer();
        h.peer.close();
        await pumpEventQueue();
        expect(h.signaling.isClosed, isTrue);
        expect(remote.ended, isTrue);
        expect(h.driver.closed, [1]);
        await h.peer.done;
        expect(h.driver.disposeCalls, 1);
        expect(h.peer.poll(), isNull);
        expect(h.signaling.join().isClosed, isTrue);
      },
    );

    test('failures of a refused client signaling cannot escape', () async {
      final h = host(maxConnections: 1);
      await h.offer();
      final (_, throwing) = InMemorySignalingChannel.pair();
      throwing
        ..throwOnSend = true
        ..throwOnClose = true;
      h.signaling.accept(throwing);
      await pumpEventQueue();
      expect(throwing.sent, isEmpty);
      expect(h.driver.opened, hasLength(1));
    });

    test(
      'a client signaling that cannot send drops only that client',
      () async {
        final h = host();
        final connection = await h.connect();
        final (client, hostEnd) = InMemorySignalingChannel.pair();
        h.signaling.accept(hostEnd);
        _RemoteClient(
          client,
        ).send(const OfferMessage(sdp: 'client offer', channelCount: 1));
        await pumpEventQueue();
        hostEnd.throwOnSend = true;
        h.driver.events.add(const WebRtcDriverDescription(2, 'host answer'));
        h.step();
        expect(h.driver.closed, [2]);
        expect(connection.isOpen, isTrue);
        expect(h.peer.poll(), isNull);
        expect(h.driver.disposeCalls, 0);
      },
    );

    test('failures closing a client signaling cannot escape', () async {
      final h = host();
      final (client, hostEnd) = InMemorySignalingChannel.pair();
      hostEnd.throwOnClose = true;
      h.signaling.accept(hostEnd);
      final remote = _RemoteClient(client)
        ..send(const OfferMessage(sdp: 'client offer', channelCount: 1));
      await pumpEventQueue();
      h.driver.events.add(const WebRtcDriverDescription(1, 'host answer'));
      h.driver.openLanes(1, h.laneCount);
      h.step();
      await pumpEventQueue();
      expect(h.peer.poll(), isA<ConnectionOpened>());
      expect(hostEnd.isClosed, isTrue);
      expect(remote.received.single, isA<AnswerMessage>());
    });
  });

  group('client negotiation', () {
    test('offers its channels, applies the answer, and opens', () async {
      final c = client(channelCount: 2);
      expect(c.driver.opened.single.laneCount, 4);
      expect(c.driver.offersCreated, [1]);
      c.driver.events
        ..add(const WebRtcDriverDescription(1, 'client offer'))
        ..add(const WebRtcDriverCandidate(1, 'candidate:client', null));
      c.step();
      await pumpEventQueue();
      expect(c.remote.received, [
        isA<OfferMessage>()
            .having((m) => m.sdp, 'sdp', 'client offer')
            .having((m) => m.channelCount, 'channels', 2)
            .having((m) => m.version, 'version', webRtcProtocolVersion),
        isA<CandidateMessage>()
            .having((m) => m.candidate, 'candidate', 'candidate:client')
            .having((m) => m.mid, 'mid', isNull),
      ]);

      await c.answer();
      expect(c.driver.answers.single, (connection: 1, sdp: 'host answer'));
      c.remote.send(const CandidateMessage('candidate:host', '0'));
      await pumpEventQueue();
      expect(c.driver.candidates.single.candidate, 'candidate:host');

      c.driver.openLanes(1, c.laneCount);
      c.step();
      final event = c.peer.poll();
      expect(event, isA<ConnectionOpened>());
      await pumpEventQueue();
      expect(c.remote.ended, isTrue, reason: 'signaling closes once open');
    });

    final failures = <String, Future<void> Function(_Client)>{
      'a refusal': (c) async {
        await c.describe();
        c.remote.send(const RejectMessage(RejectMessage.full));
      },
      'malformed signaling': (c) async {
        await c.describe();
        c.remote.channel.send('[]');
      },
      'an answer before the offer': (c) => c.answer(),
      'a candidate before the answer': (c) async {
        await c.describe();
        c.remote.send(const CandidateMessage('candidate:1'));
      },
      'a second answer': (c) async {
        await c.describe();
        await c.answer();
        await c.answer();
      },
      'signaling ending before the answer': (c) async {
        await c.describe();
        c.remote.channel.close();
      },
      'a signaling failure before the answer': (c) async {
        await c.describe();
        c.signaling.fail();
      },
      'a timeout': (c) async {
        await c.describe();
        await c.answer();
        c.clock.advance(_connectTimeout);
      },
      'a driver closure': (c) async {
        await c.describe();
        c.driver.events.add(const WebRtcDriverClosed(1));
        c.step();
      },
      'a failure applying the answer': (c) async {
        await c.describe();
        c.driver.throwAccept = true;
        await c.answer();
      },
      'signaling closed before the offer': (c) async {
        c.signaling.close();
        await c.describe();
      },
      'an offer that cannot be sent': (c) async {
        c.signaling.throwOnSend = true;
        await c.describe();
      },
    };
    for (final MapEntry(key: name, value: fail) in failures.entries) {
      test('$name fails the connection once and releases it', () async {
        final c = client();
        await fail(c);
        await pumpEventQueue();
        final events = _drain(c.peer);
        expect(events, [isA<ConnectionClosed>()]);
        final connection = events.single.connection;
        expect(events.single, _closed(connection, CloseReason.connectFailed));
        expect(connection.isOpen, isFalse);
        expect(connection.closeReason, CloseReason.connectFailed);
        expect(connection.send(Uint8List(1)), isFalse);
        expect(c.driver.closed, [1]);
        expect(c.signaling.isClosed, isTrue);
        await c.peer.done;
        expect(c.driver.disposeCalls, 1);
        c.clock.advance(_connectTimeout);
        expect(c.peer.poll(), isNull);
      });
    }

    for (final (name, throwOpen) in [
      ('creating the connection', true),
      ('creating the offer', false),
    ]) {
      test('a failure $name is reported as connectFailed', () async {
        final c = client(throwOpen: throwOpen, throwCreateOffer: !throwOpen);
        expect(c.peer.poll(), isA<ConnectionClosed>());
        expect(c.driver.closed, throwOpen ? isEmpty : [1]);
        await c.peer.done;
      });
    }

    test('negotiation can finish after signaling ends once answered', () async {
      final c = client();
      await c.describe();
      await c.answer();
      c.remote.channel.close();
      await pumpEventQueue();
      c.driver.openLanes(1, c.laneCount);
      c.step();
      expect(c.peer.poll(), isA<ConnectionOpened>());
    });

    test('closing a connecting client reports nothing', () async {
      final c = client();
      await c.describe();
      c.peer.close();
      expect(c.peer.isClosed, isTrue);
      expect(c.peer.poll(), isNull);
      expect(c.driver.closed, [1]);
      expect(c.signaling.isClosed, isTrue);
      await c.peer.done;
      c.clock.advance(_connectTimeout);
      expect(c.peer.poll(), isNull);
    });
  });

  group('data', () {
    test('reliable payloads use the reliable lane of their channel', () async {
      final h = host(channelCount: 2);
      final connection = await h.connect();
      expect(
        connection.send(Uint8List.fromList([1, 2, 3]), channel: 1),
        isTrue,
      );
      expect(h.driver.take(), [
        _sentFrame(2, _kindMessage, 1, payload: [1, 2, 3]),
      ]);
      expect(connection.outgoing, (messages: 1, bytes: 3));

      h.receive(_frame(_kindMessage, 7, [9]), lane: 2);
      expect(connection.incoming, (messages: 1, bytes: 1));
      expect(h.peer.poll(), _message(connection, [9], channel: 1));
      expect(connection.incoming, _empty);
      expect(h.driver.take(), [_sentFrame(2, _kindAck, 7, payload: [])]);

      h.receive(_frame(_kindAck, 1), lane: 2);
      expect(connection.outgoing, _empty);
      expect(connection.isOpen, isTrue);
    });

    test('received data is copied before the application polls', () async {
      final h = host();
      final connection = await h.connect();
      final bytes = _frame(_kindMessage, 1, [1, 2]);
      h.receive(bytes);
      bytes.fillRange(0, bytes.length, 0);
      expect(h.peer.poll(), _message(connection, [1, 2]));
    });

    test(
      'unreliable payloads use the unordered lane of their channel',
      () async {
        final h = host(channelCount: 2);
        final connection = await h.connect();
        connection
          ..send(Uint8List.fromList([1]), mode: DeliveryMode.unreliable)
          ..send(
            Uint8List.fromList([2]),
            mode: DeliveryMode.unreliableOrdered,
            channel: 1,
          );
        expect(h.driver.take(), [
          _sentFrame(
            1,
            _kindMessage,
            1,
            payload: [1],
            mode: DeliveryMode.unreliable,
          ),
          _sentFrame(
            3,
            _kindMessage,
            2,
            payload: [2],
            mode: DeliveryMode.unreliableOrdered,
          ),
        ]);
      },
    );

    test(
      'unreliable credit lasts until the driver has sent the bytes',
      () async {
        final h = host();
        final connection = await h.connect();
        connection
          ..send(Uint8List(10), mode: DeliveryMode.unreliable)
          ..send(Uint8List(20), mode: DeliveryMode.unreliableOrdered);
        expect(connection.outgoing, (messages: 2, bytes: 30));
        h.driver.buffered[(1, 1)] = 42;
        h.step();
        expect(connection.outgoing, (messages: 2, bytes: 30));
        h.driver.buffered[(1, 1)] = 26;
        h.step();
        expect(connection.outgoing, (messages: 1, bytes: 20));
        h.driver.buffered[(1, 1)] = 0;
        h.step();
        expect(connection.outgoing, _empty);
      },
    );

    test(
      'unreliable credit cannot be released by remote acknowledgements',
      () async {
        final h = host();
        final connection = await h.connect();
        connection.send(Uint8List(1), mode: DeliveryMode.unreliable);
        h.driver.buffered[(1, 1)] = 7;
        h.receive(_frame(_kindAck, 1));
        expect(connection.isOpen, isFalse);
        expect(h.peer.poll(), _closed(connection, CloseReason.lost));
      },
    );

    test(
      'ordered unreliable payloads discard stale arrivals per channel',
      () async {
        final h = host(channelCount: 2);
        final connection = await h.connect();
        const ordered = DeliveryMode.unreliableOrdered;
        const unordered = DeliveryMode.unreliable;
        h
          ..receive(_frame(_kindMessage, 5, [5], ordered), lane: 1)
          ..receive(_frame(_kindMessage, 4, [4], ordered), lane: 1)
          ..receive(_frame(_kindMessage, 5, [5], ordered), lane: 1)
          ..receive(_frame(_kindMessage, 3, [3], ordered), lane: 3)
          ..receive(_frame(_kindMessage, 2, [2], unordered), lane: 1)
          ..receive(_frame(_kindMessage, 6, [6], ordered), lane: 1);
        expect(_drain(h.peer), [
          _message(connection, [5], mode: ordered),
          _message(connection, [3], mode: ordered, channel: 1),
          _message(connection, [2], mode: unordered),
          _message(connection, [6], mode: ordered),
        ]);
      },
    );

    test('ordered unreliable sequences compare across wrap-around', () async {
      final h = host();
      final connection = await h.connect();
      const ordered = DeliveryMode.unreliableOrdered;
      h
        ..receive(_frame(_kindMessage, 0xfffffffe, [1], ordered), lane: 1)
        ..receive(_frame(_kindMessage, 1, [2], ordered), lane: 1)
        ..receive(_frame(_kindMessage, 0xffffffff, [3], ordered), lane: 1);
      expect(_drain(h.peer), [
        _message(connection, [1], mode: ordered),
        _message(connection, [2], mode: ordered),
      ]);
    });

    test(
      'reliable sequences can skip other channels and wrap around',
      () async {
        final h = host(channelCount: 2);
        final connection = await h.connect();
        h
          ..receive(_frame(_kindMessage, 0xfffffffe, [1]))
          ..receive(_frame(_kindMessage, 3, [2]), lane: 2)
          ..receive(_frame(_kindMessage, 1, [3]));
        expect(_drain(h.peer), [
          _message(connection, [1]),
          _message(connection, [2], channel: 1),
          _message(connection, [3]),
        ]);
        expect(connection.isOpen, isTrue);
      },
    );

    for (final size in [
      reliableChunkBytes + 1,
      2 * reliableChunkBytes,
      2 * reliableChunkBytes + 7,
    ]) {
      test(
        'a $size-byte reliable payload is chunked and reassembled',
        () async {
          final h = host();
          final connection = await h.connect();
          final payload = Uint8List.fromList([
            for (var index = 0; index < size; index++) index % 251,
          ]);
          expect(connection.send(payload), isTrue);
          final frames = h.driver.take();
          final chunks = (size + reliableChunkBytes - 1) ~/ reliableChunkBytes;
          expect(frames, hasLength(chunks));
          for (final (index, frame) in frames.indexed) {
            final last = index == chunks - 1;
            expect(frame.lane, 0);
            expect(frame.kind, last ? _kindMessage : _kindPart);
            expect(frame.sequence, 1);
            expect(
              frame.payload.length,
              last
                  ? size - (chunks - 1) * reliableChunkBytes
                  : reliableChunkBytes,
            );
          }
          expect(connection.outgoing, (messages: 1, bytes: size));

          for (final frame in frames) {
            h.driver.events.add(WebRtcDriverMessage(1, 0, frame.bytes));
          }
          h.step();
          expect(connection.incoming, (messages: 1, bytes: size));
          expect(h.peer.poll(), _message(connection, payload));
          expect(h.driver.take(), [_sentFrame(0, _kindAck, 1, payload: [])]);
        },
      );
    }

    final chunkViolations = <String, List<Uint8List>>{
      'a short part': [
        _frame(_kindPart, 1, [1]),
      ],
      'an oversized message': [
        _frame(_kindMessage, 1, Uint8List(reliableChunkBytes + 1)),
      ],
      'a part of another message': [
        _frame(_kindPart, 1, Uint8List(reliableChunkBytes)),
        _frame(_kindMessage, 2, [1]),
      ],
      'an empty final chunk': [
        _frame(_kindPart, 1, Uint8List(reliableChunkBytes)),
        _frame(_kindMessage, 1),
      ],
      'a close marker inside a message': [
        _frame(_kindPart, 1, Uint8List(reliableChunkBytes)),
        _closeMarker(),
      ],
    };
    for (final MapEntry(key: name, value: frames) in chunkViolations.entries) {
      test('$name closes as lost', () async {
        final h = host();
        final connection = await h.connect();
        h.receive(_frame(_kindMessage, 9, [9]));
        for (final frame in frames) {
          h.receive(frame);
        }
        expect(_drain(h.peer), [_closed(connection, CloseReason.lost)]);
        expect(h.driver.closed, [1]);
      });
    }

    test(
      'reassembly stops once a message cannot fit the incoming queue',
      () async {
        final h = host(incomingLimits: const QueueLimits(maxBytes: 20000));
        final connection = await h.connect();
        h.receive(_frame(_kindPart, 1, Uint8List(reliableChunkBytes)));
        expect(connection.isOpen, isTrue);
        h.receive(_frame(_kindMessage, 1, Uint8List(5000)));
        expect(_drain(h.peer), [_closed(connection, CloseReason.overflow)]);
        expect(h.driver.take(), [_closeMarkerFrame]);
      },
    );

    test('a slow receiver retains reliable credit until it polls', () async {
      final p = pair();
      final (hostConnection, clientConnection) = await p.connect();
      clientConnection.send(Uint8List.fromList([1, 2]));
      p.flush();
      expect(clientConnection.outgoing, (messages: 1, bytes: 2));
      p.flush();
      expect(clientConnection.outgoing, (messages: 1, bytes: 2));
      expect(p.host.poll(), _message(hostConnection, [1, 2]));
      p.flush();
      expect(clientConnection.outgoing, _empty);
    });

    for (final (budget, limits, size) in [
      ('message', const QueueLimits(maxMessages: 1), 1),
      ('byte', const QueueLimits(maxBytes: 4), 3),
    ]) {
      test('outgoing $budget overflow closes once and drains', () async {
        final h = host(outgoingLimits: limits);
        final connection = await h.connect();
        h.receive(_frame(_kindMessage, 1, [9]));
        expect(connection.send(Uint8List(size)), isTrue);
        expect(connection.send(Uint8List(size)), isFalse);
        expect(connection.closeReason, CloseReason.overflow);
        expect(connection.outgoing, _empty);
        expect(connection.send(Uint8List(size)), isFalse);
        expect(_drain(h.peer), [_closed(connection, CloseReason.overflow)]);
        expect(h.driver.take().last, _closeMarkerFrame);
        expect(h.driver.closed, isEmpty, reason: 'drains before release');
      });

      test(
        'incoming reliable $budget overflow discards pending payloads',
        () async {
          final h = host(incomingLimits: limits);
          final connection = await h.connect();
          h
            ..receive(_frame(_kindMessage, 1, Uint8List(size)))
            ..receive(_frame(_kindMessage, 2, Uint8List(size)));
          expect(_drain(h.peer), [_closed(connection, CloseReason.overflow)]);
          expect(connection.incoming, _empty);
        },
      );

      for (final mode in [
        DeliveryMode.unreliable,
        DeliveryMode.unreliableOrdered,
      ]) {
        test('${mode.name} $budget overflow drops only that payload', () async {
          final h = host(incomingLimits: limits);
          final connection = await h.connect();
          h
            ..receive(_frame(_kindMessage, 1, Uint8List(size), mode), lane: 1)
            ..receive(_frame(_kindMessage, 2, Uint8List(size), mode), lane: 1);
          expect(connection.isOpen, isTrue);
          expect(_drain(h.peer), [
            _message(connection, Uint8List(size), mode: mode),
          ]);
          h.receive(_frame(_kindMessage, 3, [3], mode), lane: 1);
          expect(h.peer.poll(), _message(connection, [3], mode: mode));
        });
      }
    }

    test('oversized unreliable payloads fail without being sent', () async {
      final h = host();
      final connection = await h.connect();
      for (final mode in [
        DeliveryMode.unreliable,
        DeliveryMode.unreliableOrdered,
      ]) {
        expect(
          () => connection.send(Uint8List(maxUnreliableBytes + 1), mode: mode),
          throwsArgumentError,
        );
      }
      expect(
        connection.send(
          Uint8List(maxUnreliableBytes),
          mode: DeliveryMode.unreliable,
        ),
        isTrue,
      );
      expect(h.driver.take(), hasLength(1));
      expect(connection.isOpen, isTrue);
    });

    test('unsupported channels are rejected even after closing', () async {
      final h = host(channelCount: 2);
      final connection = await h.connect();
      expect(
        () => connection.send(Uint8List(1), channel: 2),
        throwsUnsupportedError,
      );
      expect(
        () => connection.send(Uint8List(1), channel: -1),
        throwsUnsupportedError,
      );
      connection.close();
      expect(
        () => connection.send(Uint8List(1), channel: 2),
        throwsUnsupportedError,
      );
      expect(connection.send(Uint8List(1)), isFalse);
    });

    final malformed = <String, (int, Uint8List)>{
      'an empty frame': (0, Uint8List(0)),
      'a truncated header': (0, Uint8List(5)),
      'an unknown kind': (0, _frame(9, 1)),
      'a zero sequence': (0, _frame(_kindMessage, 0)),
      'an unreliable mode on the reliable lane': (
        0,
        _frame(_kindMessage, 1, [], DeliveryMode.unreliable),
      ),
      'a reliable mode on the unordered lane': (1, _frame(_kindMessage, 1)),
      'an unknown mode on the unordered lane': (
        1,
        _frame(_kindMessage, 1)..[1] = 3,
      ),
      'a part on the unordered lane': (
        1,
        _frame(_kindPart, 1, [], DeliveryMode.unreliable),
      ),
      'an oversized datagram': (
        1,
        _frame(
          _kindMessage,
          1,
          Uint8List(maxUnreliableBytes + 1),
          DeliveryMode.unreliable,
        ),
      ),
      'an unexpected acknowledgement': (0, _frame(_kindAck, 1)),
      'an acknowledgement with a payload': (0, _frame(_kindAck, 1, [1])),
      'a close marker with a sequence': (0, _frame(_kindClose, 1)),
      'a lane beyond the channels': (2, _frame(_kindMessage, 1)),
    };
    for (final MapEntry(key: name, value: (lane, bytes)) in malformed.entries) {
      test('$name closes as lost and discards pending payloads', () async {
        final h = host();
        final connection = await h.connect();
        h.receive(_frame(_kindMessage, 9, [9]));
        h.receive(bytes, lane: lane);
        expect(connection.closeReason, CloseReason.lost);
        expect(connection.incoming, _empty);
        expect(_drain(h.peer), [_closed(connection, CloseReason.lost)]);
        expect(h.driver.closed, [1]);
      });
    }

    test(
      'an acknowledgement on another channel cannot release a payload',
      () async {
        final h = host(channelCount: 2);
        final connection = await h.connect();
        connection.send(Uint8List(1));
        h.receive(_frame(_kindAck, 1), lane: 2);
        expect(h.peer.poll(), _closed(connection, CloseReason.lost));
      },
    );

    test('a repeated acknowledgement closes as lost', () async {
      final h = host();
      final connection = await h.connect();
      connection
        ..send(Uint8List(1))
        ..send(Uint8List(1));
      h.receive(_frame(_kindAck, 1));
      expect(connection.outgoing, (messages: 1, bytes: 1));
      h.receive(_frame(_kindAck, 1));
      expect(h.peer.poll(), _closed(connection, CloseReason.lost));
    });

    test('a failed send closes as lost without retaining credit', () async {
      final h = host();
      final connection = await h.connect();
      h.receive(_frame(_kindMessage, 1, [1]));
      h.driver.throwSend = true;
      expect(connection.send(Uint8List(1)), isFalse);
      expect(connection.outgoing, _empty);
      expect(_drain(h.peer), [_closed(connection, CloseReason.lost)]);
      expect(h.driver.closed, [1]);
    });

    test('a failed acknowledgement waits for the driver to report', () async {
      final h = host();
      final connection = await h.connect();
      h
        ..receive(_frame(_kindMessage, 1, [1]))
        ..receive(_frame(_kindMessage, 2, [2]));
      h.driver.throwSend = true;
      expect(h.peer.poll(), _message(connection, [1]));
      expect(connection.isOpen, isTrue);
      h.driver.events.add(const WebRtcDriverClosed(1));
      h.step();
      expect(_drain(h.peer), [
        _message(connection, [2]),
        _closed(connection, CloseReason.lost),
      ]);
    });

    test('a lane full of unread acknowledgements overflows', () async {
      final h = host(
        outgoingLimits: const QueueLimits(maxMessages: 2, maxBytes: 8),
      );
      final connection = await h.connect();
      h.receive(_frame(_kindMessage, 1, [1]));
      h.driver.buffered[(1, 0)] = 8 + (2 * 2 + 0 + 1) * 6;
      expect(h.peer.poll(), _message(connection, [1]));
      expect(connection.isOpen, isTrue);
      h.receive(_frame(_kindMessage, 2, [2]));
      h.driver.buffered[(1, 0)] = h.driver.buffered[(1, 0)]! + 1;
      expect(h.peer.poll(), _message(connection, [2]));
      expect(connection.closeReason, CloseReason.overflow);
    });

    test('a failure reading the unsent amount closes as lost', () async {
      final h = host();
      final connection = await h.connect();
      connection.send(Uint8List(1), mode: DeliveryMode.unreliable);
      h.driver.throwBuffered = true;
      h.step();
      expect(h.peer.poll(), _closed(connection, CloseReason.lost));
    });
  });

  group('closing', () {
    test('local close drains close markers on every reliable lane', () async {
      final h = host(channelCount: 2);
      final connection = await h.connect();
      h.receive(_frame(_kindMessage, 1, [1]));
      connection.send(Uint8List.fromList([5]));
      h.driver.take();
      connection.close();
      expect(connection.isOpen, isFalse);
      expect(connection.closeReason, CloseReason.local);
      expect(connection.incoming, _empty);
      expect(connection.outgoing, _empty);
      expect(h.peer.poll(), isNull);
      expect(h.driver.take(), [
        isA<FakeFrame>()
            .having((f) => f.lane, 'lane', 0)
            .having((f) => f.bytes, 'bytes', _closeMarker()),
        isA<FakeFrame>()
            .having((f) => f.lane, 'lane', 2)
            .having((f) => f.bytes, 'bytes', _closeMarker()),
      ]);
      connection.close();
      expect(h.driver.take(), isEmpty);
      h.receive(_frame(_kindMessage, 2, [2]));
      expect(h.peer.poll(), isNull);
      expect(h.driver.closed, isEmpty);
      h.clock.advance(_closeTimeout);
      expect(h.driver.closed, [1]);
    });

    test(
      'a drained connection is released once the remote closes it',
      () async {
        final h = host();
        final connection = await h.connect();
        connection.close();
        h.driver.events.add(const WebRtcDriverClosed(1));
        h.step();
        expect(h.driver.closed, [1]);
        expect(h.peer.poll(), isNull);
        h.clock.advance(_closeTimeout);
        expect(h.driver.closed, [1]);
      },
    );

    test('a failure sending close markers releases at once', () async {
      final h = host();
      final connection = await h.connect();
      h.driver.throwSend = true;
      connection.close();
      expect(h.driver.closed, [1]);
    });

    test('remote close follows earlier payloads on every channel', () async {
      final h = host(channelCount: 2);
      final connection = await h.connect();
      h
        ..receive(_frame(_kindMessage, 1, [1]))
        ..receive(_closeMarker())
        ..receive(
          _frame(_kindMessage, 2, [2], DeliveryMode.unreliable),
          lane: 1,
        )
        ..receive(_frame(_kindMessage, 3, [3]), lane: 2);
      expect(connection.isOpen, isTrue);
      h.receive(_closeMarker(), lane: 2);
      expect(connection.isOpen, isFalse);
      expect(connection.closeReason, CloseReason.remote);
      expect(h.driver.closed, [1]);
      expect(_drain(h.peer), [
        _message(connection, [1]),
        _message(connection, [3], channel: 1),
        _closed(connection, CloseReason.remote),
      ]);
      expect(
        h.driver.take(),
        isEmpty,
        reason: 'no acknowledgement is sent once closed',
      );
    });

    test(
      'data after a close marker on its reliable lane closes as lost',
      () async {
        final h = host(channelCount: 2);
        final connection = await h.connect();
        h
          ..receive(_closeMarker())
          ..receive(_frame(_kindMessage, 1, [1]));
        expect(h.peer.poll(), _closed(connection, CloseReason.lost));
      },
    );

    test('a driver closure reports lost and keeps pending payloads', () async {
      final h = host();
      final connection = await h.connect();
      h.receive(_frame(_kindMessage, 1, [1]));
      h.driver.events.add(const WebRtcDriverClosed(1));
      h.step();
      expect(connection.isOpen, isFalse);
      expect(h.driver.closed, [1]);
      expect(_drain(h.peer), [
        _message(connection, [1]),
        _closed(connection, CloseReason.lost),
      ]);
      expect(h.driver.take(), isEmpty);
    });

    test('closing one connection leaves the others intact', () async {
      final h = host();
      final first = await h.connect();
      final second = await h.connect();
      h.receive(_frame(_kindMessage, 1, [1]), connection: 2);
      first.close();
      expect(second.isOpen, isTrue);
      expect(h.peer.poll(), _message(second, [1]));
    });

    test('closing the peer discards events and drains connections', () async {
      final h = host();
      final connection = await h.connect();
      h.receive(_frame(_kindMessage, 1, [1]));
      h.peer.close();
      expect(h.peer.isClosed, isTrue);
      expect(connection.isOpen, isFalse);
      expect(connection.closeReason, CloseReason.local);
      expect(h.peer.poll(), isNull);
      expect(h.driver.take(), [_closeMarkerFrame]);
      var done = false;
      unawaited(h.peer.done.then((_) => done = true));
      await pumpEventQueue();
      expect(done, isFalse);
      h.clock.advance(_closeTimeout + _interval);
      await pumpEventQueue();
      expect(done, isTrue);
      expect(h.driver.closed, [1]);
      expect(h.driver.disposeCalls, 1);
      h.peer.close();
      expect(h.driver.disposeCalls, 1);
    });

    test('a driver failure ends every connection and releases it', () async {
      final h = host();
      final first = await h.connect();
      final second = await h.connect();
      await h.offer();
      h.receive(_frame(_kindMessage, 1, [1]));
      h.driver.throwPoll = true;
      h.step();
      expect(_drain(h.peer), [
        _message(first, [1]),
        _closed(first, CloseReason.lost),
        _closed(second, CloseReason.lost),
      ]);
      expect(h.driver.closed, unorderedEquals([1, 2, 3]));
      await h.peer.done;
      expect(h.driver.disposeCalls, 1);
      expect(h.signaling.isClosed, isTrue);
    });

    test('cleanup failures cannot escape or prevent completion', () async {
      final h = host();
      await h.connect();
      h.driver
        ..throwClose = true
        ..throwDispose = true
        ..throwSend = true;
      h.peer.close();
      await h.peer.done;
      expect(h.driver.closed, [1]);
      expect(h.driver.disposeCalls, 1);
    });

    test('closing both ends at once releases without a timeout', () async {
      final p = pair(channelCount: 2);
      final (hostConnection, clientConnection) = await p.connect();
      hostConnection.close();
      clientConnection.close();
      expect(p.hostDriver.closed, isEmpty);
      expect(p.clientDriver.closed, isEmpty);
      p.flush();
      expect(p.hostDriver.closed, [1]);
      expect(p.clientDriver.closed, [1]);
      expect(p.host.poll(), isNull);
      expect(p.client.poll(), isNull);
      await p.client.done;
    });

    test(
      'a draining connection waits for close markers on every channel',
      () async {
        final h = host(channelCount: 2);
        final connection = await h.connect();
        connection.close();
        h
          ..receive(_frame(_kindMessage, 1, [1]))
          ..receive(_frame(_kindClose, 0), lane: 1)
          ..receive(_closeMarker());
        expect(h.driver.closed, isEmpty);
        h.receive(_closeMarker(), lane: 2);
        expect(h.driver.closed, [1]);
        expect(h.peer.poll(), isNull);
      },
    );

    test('a client releases the driver once its connection ends', () async {
      final c = client();
      final connection = await c.connect();
      c.driver.events.add(WebRtcDriverMessage(1, 0, _closeMarker()));
      c.step();
      expect(connection.closeReason, CloseReason.remote);
      expect(c.driver.closed, [1]);
      await c.peer.done;
      expect(c.driver.disposeCalls, 1);
      expect(c.peer.poll(), _closed(connection, CloseReason.remote));
    });

    test('a local close releases admission at once', () async {
      final h = host(maxConnections: 1);
      final connection = await h.connect();
      connection.close();
      expect((await h.offer()).received, isEmpty);
    });
  });

  test('a host and a client exchange every delivery mode and close', () async {
    final p = pair(channelCount: 2);
    final (hostConnection, clientConnection) = await p.connect();
    final large = Uint8List.fromList([
      for (var index = 0; index < 3 * reliableChunkBytes; index++) index % 256,
    ]);
    clientConnection
      ..send(Uint8List.fromList([1]))
      ..send(large, channel: 1)
      ..send(Uint8List.fromList([2]), mode: DeliveryMode.unreliableOrdered)
      ..send(Uint8List.fromList([3]), mode: DeliveryMode.unreliable, channel: 1)
      ..send(Uint8List.fromList([4]), mode: DeliveryMode.unreliable);
    p.flush(lose: (frame) => frame.payload.single == 3);
    expect(_drain(p.host), [
      _message(hostConnection, [1]),
      _message(hostConnection, large, channel: 1),
      _message(hostConnection, [2], mode: DeliveryMode.unreliableOrdered),
      _message(hostConnection, [4], mode: DeliveryMode.unreliable),
    ]);
    p.flush();
    expect(clientConnection.outgoing, _empty);

    hostConnection.send(Uint8List.fromList([5]), channel: 1);
    p.flush();
    clientConnection.close();
    p.flush();
    expect(_drain(p.host), [
      _closed(hostConnection, CloseReason.remote),
    ], reason: 'the close follows the payload sent before it');
    expect(p.hostDriver.closed, [1]);
    expect(p.client.poll(), isNull, reason: 'a local close reports nothing');
    p.clientDriver.events.add(const WebRtcDriverClosed(1));
    p.step();
    expect(p.clientDriver.closed, [1]);
    await p.client.done;
    expect(p.clientDriver.disposeCalls, 1);
  });
}
