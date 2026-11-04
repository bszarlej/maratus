import 'dart:math';
import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

const _ms = Duration(milliseconds: 1);
const QueueDepth _empty = (messages: 0, bytes: 0);

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

/// Takes every pending event from [peer].
List<PeerEvent> _drain(MultiplayerPeer peer) => [
  for (var event = peer.poll(); event != null; event = peer.poll()) event,
];

Matcher _isOpened(Object? connection) => isA<ConnectionOpened>().having(
  (event) => event.connection,
  'connection',
  connection,
);

Matcher _isMessage(Object? connection, List<int> message) =>
    isA<MessageReceived>()
        .having((event) => event.connection, 'connection', connection)
        .having((event) => event.message, 'message', message);

Matcher _isClosed(Object? connection, CloseReason reason) =>
    isA<ConnectionClosed>()
        .having((event) => event.connection, 'connection', connection)
        .having((event) => event.reason, 'reason', reason);

/// A client connected to a host, with the connection as each side sees it.
typedef _Pair = ({
  InMemoryClient client,
  PeerConnection atHost,
  PeerConnection atClient,
});

/// Connects a client to [host] and advances [clock] by a round trip, after
/// which both ends of the connection are open.
_Pair _connect(
  ManualClock clock,
  InMemoryNetwork network,
  InMemoryHost host, {
  Duration latency = Duration.zero,
  QueueLimits incomingLimits = const QueueLimits(),
  QueueLimits outgoingLimits = const QueueLimits(),
}) {
  final client = network.connect(
    latency: latency,
    incomingLimits: incomingLimits,
    outgoingLimits: outgoingLimits,
  );
  clock.advance(latency * 2);
  final atHost = host.poll();
  final atClient = client.poll();
  expect(atHost, _isOpened(anything));
  expect(atClient, _isOpened(anything));
  return (
    client: client,
    atHost: atHost!.connection,
    atClient: atClient!.connection,
  );
}

/// The events observed by [_runRandomOperations], and the close reasons
/// among them.
typedef _RandomRun = ({List<String> trace, Set<CloseReason> reasons});

/// Performs random sends, polls, clock advances, latency changes, closes,
/// disconnects, and connections on a network.
///
/// Checks that the events of each connection follow the order that
/// [MultiplayerPeer.poll] describes, and that messages arrive exactly once
/// and in order on links whose ends both stay open. Each message carries its
/// sequence number on the sending connection.
_RandomRun _runRandomOperations(int seed) {
  final random = Random(seed);
  final clock = ManualClock();
  final network = InMemoryNetwork(clock: clock);
  const incomingLimits = QueueLimits(maxMessages: 16);
  const outgoingLimits = QueueLimits(maxMessages: 4);
  final host = network.host(
    incomingLimits: incomingLimits,
    outgoingLimits: outgoingLimits,
  );
  final peers = <InMemoryPeer>[host];
  final trace = <String>[];
  final reasons = <CloseReason>{};
  final opened = <PeerConnection>[];
  final closedHere = <PeerConnection>{};
  final reportedClosed = <PeerConnection>{};
  final sent = <PeerConnection, int>{};
  final received = <PeerConnection, int>{};

  void connect() => peers.add(
    network.connect(
      latency: _ms * random.nextInt(20),
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
    ),
  );

  void poll(int peerIndex, int count) {
    final peer = peers[peerIndex];
    for (var i = 0; i < count; i++) {
      final event = peer.poll();
      if (event == null) return;
      final connection = event.connection;
      expect(closedHere, isNot(contains(connection)), reason: '$event');
      expect(reportedClosed, isNot(contains(connection)), reason: '$event');
      var entry = 'peer $peerIndex: $event';
      switch (event) {
        case ConnectionOpened():
          expect(opened, isNot(contains(connection)), reason: '$event');
          opened.add(connection);
        case MessageReceived(:final message):
          expect(opened, contains(connection), reason: '$event');
          final sequence = ByteData.sublistView(message).getUint32(0);
          expect(sequence, received[connection] ?? 0, reason: '$event');
          received[connection] = sequence + 1;
          entry += ' #$sequence';
        case ConnectionClosed(:final reason):
          expect(
            opened.contains(connection),
            reason != CloseReason.connectFailed,
            reason: '$event',
          );
          reportedClosed.add(connection);
          reasons.add(reason);
      }
      trace.add(entry);
    }
  }

  void send(PeerConnection connection) {
    final sequence = sent[connection] ?? 0;
    final message = Uint8List(4 + random.nextInt(8));
    ByteData.sublistView(message).setUint32(0, sequence);
    final accepted = connection.send(message);
    if (accepted) {
      sent[connection] = sequence + 1;
    } else {
      expect(connection.isOpen, isFalse);
    }
    trace.add('send #$sequence on $connection: $accepted');
  }

  T pick<T>(List<T> items) => items[random.nextInt(items.length)];

  for (var step = 0; step < 2000; step++) {
    final live = [
      for (final connection in opened)
        if (connection.isOpen) connection,
    ];
    final links = network.links;
    switch (random.nextInt(100)) {
      case < 40 when opened.isNotEmpty:
        // Mostly on open connections, sometimes on any.
        send(
          live.isNotEmpty && random.nextInt(10) > 0 ? pick(live) : pick(opened),
        );
      case < 65:
        clock.advance(_ms * random.nextInt(10));
      case < 88:
        // The host, or a client whose link can still deliver something.
        final active = [
          0,
          for (var i = 1; i < peers.length; i++)
            if (links.contains((peers[i] as InMemoryClient).link)) i,
        ];
        poll(pick(active), 1 + random.nextInt(8));
      case < 93 when links.isNotEmpty:
        pick(links).latency = _ms * random.nextInt(20);
      case < 94 when live.isNotEmpty:
        final connection = pick(live);
        closedHere.add(connection);
        connection.close();
      case < 95 when links.isNotEmpty:
        pick(links).disconnect();
      case _ when links.length < 6:
        connect();
    }
  }

  // Let everything in transit arrive, and take every event.
  clock.advance(const Duration(seconds: 1));
  for (var i = 0; i < peers.length; i++) {
    poll(i, 1 << 20);
  }
  final ends = <InMemoryLink, List<PeerConnection>>{};
  for (final connection in opened) {
    (ends[(connection as InMemoryConnection).link] ??= []).add(connection);
  }
  for (final pair in ends.values.where((pair) => pair.length == 2)) {
    for (final (from, to) in [(pair[0], pair[1]), (pair[1], pair[0])]) {
      final delivered = received[to] ?? 0;
      final accepted = sent[from] ?? 0;
      if (from.isOpen && to.isOpen) {
        expect(delivered, accepted, reason: '$from to $to');
      } else {
        expect(delivered, lessThanOrEqualTo(accepted), reason: '$from to $to');
      }
    }
  }

  for (final peer in peers) {
    peer.close();
  }
  expect(clock.pendingTimerCount, 0);
  expect(network.links, isEmpty);
  return (trace: trace, reasons: reasons);
}

void main() {
  late ManualClock clock;

  setUp(() => clock = ManualClock());

  group('connecting', () {
    test('opens on the host after the latency, and on the client after a '
        'round trip', () {
      final network = InMemoryNetwork(clock: clock, latency: _ms * 10);
      final host = network.host();
      final client = network.connect();

      clock.advance(_ms * 9);
      expect(host.poll(), isNull);
      clock.advance(_ms);
      final atHost = host.poll();
      expect(atHost, _isOpened(anything));
      expect(atHost!.connection.isOpen, isTrue);
      expect(client.poll(), isNull);

      clock.advance(_ms * 9);
      expect(client.poll(), isNull);
      clock.advance(_ms);
      final atClient = client.poll();
      expect(atClient, _isOpened(anything));
      expect(atClient!.connection.isOpen, isTrue);
      expect(atClient.connection.closeReason, isNull);
    });

    test('uses the latency given for a client', () {
      final network = InMemoryNetwork(clock: clock, latency: _ms * 10);
      final host = network.host();
      final client = network.connect(latency: _ms * 2);

      clock.advance(_ms * 4);

      expect(host.poll(), _isOpened(anything));
      expect(client.poll(), _isOpened(anything));
      expect(client.link.latency, _ms * 2);
    });

    test('gives each client its own connection', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final a = _connect(clock, network, host);
      final b = _connect(clock, network, host);

      a.atClient.send(_bytes([1]));
      b.atClient.send(_bytes([2]));
      a.atHost.send(_bytes([3]));
      clock.advance(Duration.zero);

      expect(a.atHost, isNot(same(b.atHost)));
      expect(_drain(host), [
        _isMessage(a.atHost, [1]),
        _isMessage(b.atHost, [2]),
      ]);
      expect(_drain(a.client), [
        _isMessage(a.atClient, [3]),
      ]);
      expect(_drain(b.client), isEmpty);
    });

    test('fails when no host is accepting connections', () {
      final network = InMemoryNetwork(clock: clock, latency: _ms * 5);
      final client = network.connect();

      clock.advance(_ms * 9);
      expect(client.poll(), isNull);
      clock.advance(_ms);
      final event = client.poll();

      expect(event, _isClosed(anything, CloseReason.connectFailed));
      expect(event!.connection.isOpen, isFalse);
      expect(event.connection.closeReason, CloseReason.connectFailed);
      expect(client.poll(), isNull);
      expect(network.links, isEmpty);
      expect(clock.pendingTimerCount, 0);
    });

    test('accepts connections only while a host is open', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      expect(network.host, throwsStateError);

      host.close();
      final refused = network.connect();
      clock.advance(Duration.zero);
      expect(refused.poll(), _isClosed(anything, CloseReason.connectFailed));

      final pair = _connect(clock, network, network.host());
      expect(pair.atClient.isOpen, isTrue);
    });

    test('withdraws an attempt that the host has not received', () {
      final network = InMemoryNetwork(clock: clock, latency: _ms * 10);
      final host = network.host();
      final client = network.connect();
      clock.advance(_ms * 5);

      client.close();
      expect(network.links, isEmpty);
      expect(clock.pendingTimerCount, 0);

      clock.advance(_ms * 100);
      expect(host.poll(), isNull);
      expect(client.poll(), isNull);
    });

    test('closes an attempt that the host has already accepted', () {
      final network = InMemoryNetwork(clock: clock, latency: _ms * 10);
      final host = network.host();
      final client = network.connect();
      clock.advance(_ms * 15);
      final atHost = host.poll()!.connection;

      client.close();
      clock.advance(_ms * 10);

      expect(_drain(host), [_isClosed(atHost, CloseReason.remote)]);
      expect(_drain(client), isEmpty);
      expect(network.links, isEmpty);
      expect(clock.pendingTimerCount, 0);
    });

    test('rejects negative latencies', () {
      final network = InMemoryNetwork(clock: clock);
      final client = network.connect();

      expect(
        () => InMemoryNetwork(clock: clock, latency: -_ms),
        throwsArgumentError,
      );
      expect(() => network.connect(latency: -_ms), throwsArgumentError);
      expect(() => client.link.latency = -_ms, throwsArgumentError);
      expect(network.links, [client.link]);
    });
  });

  group('delivery', () {
    test('delivers messages in order once the latency has elapsed', () {
      final network = InMemoryNetwork(clock: clock, latency: _ms * 10);
      final host = network.host();
      final pair = _connect(clock, network, host, latency: _ms * 10);

      pair.atClient.send(_bytes([1]));
      clock.advance(_ms * 3);
      pair.atClient
        ..send(_bytes([2, 2]))
        ..send(_bytes([3]));

      clock.advance(_ms * 6);
      expect(host.poll(), isNull);
      clock.advance(_ms);
      expect(_drain(host), [
        _isMessage(pair.atHost, [1]),
      ]);
      clock.advance(_ms * 3);
      expect(_drain(host), [
        _isMessage(pair.atHost, [2, 2]),
        _isMessage(pair.atHost, [3]),
      ]);
    });

    test('delivers nothing until the clock advances', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host);

      pair.atHost.send(_bytes([1]));
      expect(pair.client.poll(), isNull);

      clock.advance(Duration.zero);
      expect(_drain(pair.client), [
        _isMessage(pair.atClient, [1]),
      ]);
    });

    test('keeps messages in order when the latency drops', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host, latency: _ms * 50);

      pair.atClient.send(_bytes([1]));
      pair.client.link.latency = _ms * 10;
      pair.atClient.send(_bytes([2]));

      clock.advance(_ms * 49);
      expect(host.poll(), isNull);
      clock.advance(_ms);
      expect(_drain(host), [
        _isMessage(pair.atHost, [1]),
        _isMessage(pair.atHost, [2]),
      ]);
    });

    test('delays later messages when the latency rises', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host, latency: _ms * 10);

      pair.atClient.send(_bytes([1]));
      pair.client.link.latency = _ms * 30;
      pair.atClient.send(_bytes([2]));

      clock.advance(_ms * 10);
      expect(_drain(host), [
        _isMessage(pair.atHost, [1]),
      ]);
      clock.advance(_ms * 19);
      expect(host.poll(), isNull);
      clock.advance(_ms);
      expect(_drain(host), [
        _isMessage(pair.atHost, [2]),
      ]);
    });

    test('reports messages from different clients in arrival order', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final slow = _connect(clock, network, host, latency: _ms * 20);
      final fast = _connect(clock, network, host, latency: _ms * 5);

      slow.atClient.send(_bytes([1]));
      clock.advance(_ms * 10);
      fast.atClient.send(_bytes([2]));
      clock.advance(_ms * 10);

      expect(_drain(host), [
        _isMessage(fast.atHost, [2]),
        _isMessage(slow.atHost, [1]),
      ]);
    });

    test('copies sent messages', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host);
      final message = _bytes([1, 2, 3]);

      pair.atClient.send(message);
      message[0] = 9;
      clock.advance(Duration.zero);

      expect(_drain(host), [
        _isMessage(pair.atHost, [1, 2, 3]),
      ]);
    });

    test('supports only reliable delivery on one channel', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host);

      expect(host.isHost, isTrue);
      expect(pair.client.isHost, isFalse);
      expect(host.capabilities, same(InMemoryNetwork.capabilities));
      expect(pair.client.capabilities, same(InMemoryNetwork.capabilities));
      expect(InMemoryNetwork.capabilities.canHost, isTrue);
      for (final mode in [
        DeliveryMode.unreliableOrdered,
        DeliveryMode.unreliable,
      ]) {
        expect(
          () => pair.atClient.send(_bytes([1]), mode: mode),
          throwsUnsupportedError,
        );
      }
      expect(
        () => pair.atClient.send(_bytes([1]), channel: 1),
        throwsUnsupportedError,
      );
      expect(pair.atClient.outgoing, _empty);
      expect(pair.atClient.send(_bytes([1])), isTrue);
    });
  });

  group('closing', () {
    test('delivers what was sent before a close, then the close', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host, latency: _ms * 10);

      pair.atClient
        ..send(_bytes([1]))
        ..send(_bytes([2]))
        ..close();
      expect(pair.atClient.isOpen, isFalse);
      expect(pair.atClient.closeReason, CloseReason.local);
      expect(pair.atClient.outgoing, (messages: 2, bytes: 2));
      expect(pair.atHost.isOpen, isTrue);

      clock.advance(_ms * 10);
      expect(pair.atHost.isOpen, isFalse);
      expect(pair.atHost.closeReason, CloseReason.remote);
      expect(_drain(host), [
        _isMessage(pair.atHost, [1]),
        _isMessage(pair.atHost, [2]),
        _isClosed(pair.atHost, CloseReason.remote),
      ]);
      expect(_drain(pair.client), isEmpty);
    });

    test('discards unpolled messages on the side that closes', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host);
      pair.atClient
        ..send(_bytes([1]))
        ..send(_bytes([2]));
      clock.advance(Duration.zero);
      expect(pair.atHost.incoming, (messages: 2, bytes: 2));

      pair.atHost.close();

      expect(pair.atHost.incoming, _empty);
      expect(host.poll(), isNull);
      clock.advance(Duration.zero);
      expect(_drain(pair.client), [
        _isClosed(pair.atClient, CloseReason.remote),
      ]);
    });

    test('rejects sends once the connection has closed', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host);

      pair.atClient.close();
      expect(pair.atClient.send(_bytes([1])), isFalse);
      expect(pair.atClient.outgoing, _empty);

      // The host's end closes when the close arrives, before it is polled.
      clock.advance(Duration.zero);
      expect(pair.atHost.isOpen, isFalse);
      expect(pair.atHost.send(_bytes([1])), isFalse);
      expect(pair.atHost.outgoing, _empty);
    });

    test('ignores repeated closes', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host);

      pair.atClient
        ..close()
        ..close();
      pair.client
        ..close()
        ..close();
      clock.advance(Duration.zero);
      host
        ..close()
        ..close();

      expect(pair.client.isClosed, isTrue);
      expect(host.isClosed, isTrue);
      expect(pair.atClient.closeReason, CloseReason.local);
      expect(pair.atHost.closeReason, CloseReason.remote);
      expect(network.links, isEmpty);
    });

    test('discards messages that arrive after a close', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host, latency: _ms * 10);

      pair.atClient.send(_bytes([1]));
      pair.atHost.close();
      clock.advance(_ms * 10);

      expect(_drain(host), isEmpty);
      expect(pair.atClient.outgoing, _empty);
      expect(_drain(pair.client), [
        _isClosed(pair.atClient, CloseReason.remote),
      ]);
    });

    test('keeps messages that arrived before the other side closed', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host);

      pair.atHost
        ..send(_bytes([1]))
        ..close();
      clock.advance(Duration.zero);

      expect(pair.atClient.isOpen, isFalse);
      expect(pair.atClient.incoming, (messages: 1, bytes: 1));
      expect(_drain(pair.client), [
        _isMessage(pair.atClient, [1]),
        _isClosed(pair.atClient, CloseReason.remote),
      ]);
      expect(pair.atClient.incoming, _empty);
    });

    test('closes every connection when the host closes', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final a = _connect(clock, network, host, latency: _ms * 10);
      final b = _connect(clock, network, host, latency: _ms * 10);

      a.atHost.send(_bytes([1]));
      host.close();

      expect(host.isClosed, isTrue);
      expect(a.atHost.closeReason, CloseReason.local);
      expect(b.atHost.closeReason, CloseReason.local);
      expect(host.poll(), isNull);
      clock.advance(_ms * 10);
      expect(_drain(a.client), [
        _isMessage(a.atClient, [1]),
        _isClosed(a.atClient, CloseReason.remote),
      ]);
      expect(_drain(b.client), [_isClosed(b.atClient, CloseReason.remote)]);
    });

    test('discards pending events when a peer closes', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host);
      pair.atHost
        ..send(_bytes([1]))
        ..send(_bytes([2]))
        ..close();
      clock.advance(Duration.zero);
      expect(pair.atClient.incoming, (messages: 2, bytes: 2));

      pair.client.close();

      expect(pair.client.poll(), isNull);
      expect(pair.atClient.incoming, _empty);
      expect(pair.atClient.closeReason, CloseReason.remote);
    });
  });

  group('disconnecting', () {
    test('loses what is in transit and reports the loss to both ends', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host, latency: _ms * 10);
      pair.atClient.send(_bytes([1]));
      clock.advance(_ms * 10);
      pair.atClient.send(_bytes([2]));
      pair.atHost.send(_bytes([3]));

      pair.client.link.disconnect();

      expect(pair.atClient.outgoing, _empty);
      expect(pair.atHost.outgoing, _empty);
      expect(_drain(host), [
        _isMessage(pair.atHost, [1]),
        _isClosed(pair.atHost, CloseReason.lost),
      ]);
      expect(_drain(pair.client), [_isClosed(pair.atClient, CloseReason.lost)]);
      clock.advance(_ms * 100);
      expect(host.poll(), isNull);
      expect(pair.client.poll(), isNull);
      expect(network.links, isEmpty);
      expect(clock.pendingTimerCount, 0);
    });

    test('fails a connection that is still being established', () {
      final network = InMemoryNetwork(clock: clock, latency: _ms * 10);
      final host = network.host();
      final client = network.connect();
      clock.advance(_ms * 15);
      final atHost = host.poll()!.connection;

      client.link.disconnect();

      expect(_drain(host), [_isClosed(atHost, CloseReason.lost)]);
      expect(_drain(client), [_isClosed(anything, CloseReason.connectFailed)]);
    });

    test('has no effect on a link that has been released', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host);
      pair.client.link.disconnect();
      _drain(host);
      _drain(pair.client);

      pair.client.link.disconnect();

      expect(host.poll(), isNull);
      expect(pair.client.poll(), isNull);
      expect(pair.atHost.closeReason, CloseReason.lost);
    });
  });

  group('queue limits', () {
    test('count the messages and bytes queued in each direction', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host, latency: _ms * 10);

      pair.atClient
        ..send(_bytes([1, 2]))
        ..send(_bytes([3]));
      expect(pair.atClient.outgoing, (messages: 2, bytes: 3));
      expect(pair.atHost.incoming, _empty);

      clock.advance(_ms * 10);
      expect(pair.atClient.outgoing, _empty);
      expect(pair.atHost.incoming, (messages: 2, bytes: 3));

      host.poll();
      expect(pair.atHost.incoming, (messages: 1, bytes: 1));
      host.poll();
      expect(pair.atHost.incoming, _empty);
    });

    test('close a connection whose outgoing queue is full', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(
        clock,
        network,
        host,
        latency: _ms * 10,
        outgoingLimits: const QueueLimits(maxMessages: 2),
      );

      expect(pair.atClient.send(_bytes([1])), isTrue);
      expect(pair.atClient.send(_bytes([2])), isTrue);
      expect(pair.atClient.send(_bytes([3])), isFalse);

      expect(pair.atClient.closeReason, CloseReason.overflow);
      expect(_drain(pair.client), [
        _isClosed(pair.atClient, CloseReason.overflow),
      ]);
      clock.advance(_ms * 10);
      expect(_drain(host), [
        _isMessage(pair.atHost, [1]),
        _isMessage(pair.atHost, [2]),
        _isClosed(pair.atHost, CloseReason.remote),
      ]);
    });

    test('bound the size of the outgoing queue', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(
        clock,
        network,
        host,
        outgoingLimits: const QueueLimits(maxBytes: 4),
      );

      expect(pair.atClient.send(_bytes([1, 2, 3])), isTrue);
      expect(pair.atClient.send(_bytes([4, 5])), isFalse);
      expect(pair.atClient.closeReason, CloseReason.overflow);
    });

    test('close a connection whose incoming queue is full', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host(
        incomingLimits: const QueueLimits(maxMessages: 2),
      );
      final pair = _connect(clock, network, host, latency: _ms * 10);

      pair.atClient
        ..send(_bytes([1]))
        ..send(_bytes([2]))
        ..send(_bytes([3]));
      clock.advance(_ms * 10);

      expect(pair.atHost.closeReason, CloseReason.overflow);
      expect(pair.atHost.incoming, _empty);
      expect(_drain(host), [_isClosed(pair.atHost, CloseReason.overflow)]);
      clock.advance(_ms * 10);
      expect(_drain(pair.client), [
        _isClosed(pair.atClient, CloseReason.remote),
      ]);
    });

    test('bound the size of the incoming queue', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host(incomingLimits: const QueueLimits(maxBytes: 4));
      final pair = _connect(clock, network, host);

      pair.atClient
        ..send(_bytes([1, 2, 3]))
        ..send(_bytes([4, 5]));
      clock.advance(Duration.zero);

      expect(pair.atHost.closeReason, CloseReason.overflow);
    });

    test('free space as messages are delivered and polled', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host(
        incomingLimits: const QueueLimits(maxMessages: 1),
      );
      final pair = _connect(
        clock,
        network,
        host,
        outgoingLimits: const QueueLimits(maxMessages: 1),
      );

      for (var i = 0; i < 3; i++) {
        expect(pair.atClient.send(_bytes([i])), isTrue);
        clock.advance(Duration.zero);
        expect(_drain(host), [
          _isMessage(pair.atHost, [i]),
        ]);
      }
      expect(pair.atHost.isOpen, isTrue);
      expect(pair.atClient.isOpen, isTrue);
    });
  });

  group('releasing resources', () {
    test('closing every peer releases timers, links, and messages', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final a = _connect(clock, network, host, latency: _ms * 10);
      final b = _connect(clock, network, host, latency: _ms * 10);
      a.atClient.send(_bytes([1]));
      b.atHost.send(_bytes([2]));
      clock.advance(_ms * 10);
      a.atClient.send(_bytes([3]));
      b.atHost.send(_bytes([4]));

      host.close();
      a.client.close();
      b.client.close();

      expect(clock.pendingTimerCount, 0);
      expect(network.links, isEmpty);
      for (final connection in [a.atHost, a.atClient, b.atHost, b.atClient]) {
        expect(connection.incoming, _empty);
        expect(connection.outgoing, _empty);
      }
      clock.advance(_ms * 100);
      for (final peer in [host, a.client, b.client]) {
        expect(peer.poll(), isNull);
      }
    });

    test('a closed host releases a link once its client learns of it', () {
      final network = InMemoryNetwork(clock: clock);
      final host = network.host();
      final pair = _connect(clock, network, host, latency: _ms * 10);

      host.close();
      expect(network.links, [pair.client.link]);
      expect(clock.pendingTimerCount, 1);

      clock.advance(_ms * 10);
      expect(network.links, isEmpty);
      expect(clock.pendingTimerCount, 0);
      expect(_drain(pair.client), [
        _isClosed(pair.atClient, CloseReason.remote),
      ]);
    });
  });

  group('random operations', () {
    test('deliver each message once and in order unless its connection '
        'closes', () {
      final reasons = <CloseReason>{};
      for (var seed = 0; seed < 25; seed++) {
        reasons.addAll(_runRandomOperations(seed).reasons);
      }

      // Every way a connection can close for the other side was exercised.
      expect(
        reasons,
        containsAll([
          CloseReason.remote,
          CloseReason.connectFailed,
          CloseReason.lost,
          CloseReason.overflow,
        ]),
      );
    });

    test('produce the same events on every run', () {
      for (var seed = 0; seed < 5; seed++) {
        final first = _runRandomOperations(seed).trace;
        expect(first, hasLength(greaterThan(1000)));
        expect(_runRandomOperations(seed).trace, first);
      }
    });
  });
}
