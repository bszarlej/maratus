import 'dart:async';
import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus_enet/src/enet_driver.dart';
import 'package:maratus_enet/src/enet_peer_base.dart';
import 'package:test/test.dart';

import 'support/fake_enet_driver.dart';

const QueueDepth _empty = (messages: 0, bytes: 0);
const _interval = Duration(milliseconds: 2);

Uint8List _frame(
  int kind,
  int sequence, [
  List<int> payload = const [],
  DeliveryMode mode = DeliveryMode.reliable,
]) {
  final bytes = Uint8List(10 + payload.length);
  bytes.setRange(0, 6, [0x6d, 0x45, 0x4e, 1, kind, mode.index]);
  ByteData.sublistView(bytes).setUint32(6, sequence);
  bytes.setRange(10, bytes.length, payload);
  return bytes;
}

Matcher _opened(PeerConnection connection) => isA<ConnectionOpened>().having(
  (event) => event.connection,
  'connection',
  same(connection),
);

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

final class _Harness {
  _Harness({
    bool isHost = true,
    this.channelCount = 1,
    int maxConnections = 64,
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
  }) {
    peer = EnetPeerBase(
      driver: driver,
      isHost: isHost,
      channelCount: channelCount,
      maxConnections: maxConnections,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      clock: clock,
      serviceInterval: _interval,
      connectTimeout: const Duration(milliseconds: 20),
      closeTimeout: const Duration(milliseconds: 10),
    );
  }

  final driver = FakeEnetDriver();
  final clock = ManualClock();
  final int channelCount;
  late final EnetPeerBase peer;

  void step() => clock.advance(_interval);

  PeerConnection open([int id = 1]) {
    driver.events.add(EnetDriverConnected(id, channelCount * 3));
    step();
    final opened = peer.poll();
    expect(opened, isA<ConnectionOpened>());
    return opened!.connection;
  }

  void receive(Uint8List bytes, {int peer = 1, int channel = 0}) {
    driver.events.add(EnetDriverReceived(peer, channel, bytes));
    step();
  }
}

void main() {
  final harnesses = <_Harness>[];

  _Harness harness({
    bool isHost = true,
    int channelCount = 1,
    int maxConnections = 64,
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
  }) {
    final result = _Harness(
      isHost: isHost,
      channelCount: channelCount,
      maxConnections: maxConnections,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
    );
    harnesses.add(result);
    return result;
  }

  tearDown(() async {
    for (final h in harnesses) {
      h.peer.close();
      h.clock.advance(const Duration(milliseconds: 100));
      await h.peer.done;
      expect(h.driver.closeCalls, 1);
      expect(h.clock.pendingTimerCount, 0);
    }
    harnesses.clear();
  });

  test('native service progresses independently of application polling', () {
    final h = harness();
    h.driver.events.add(const EnetDriverConnected(1, 3));
    expect(h.peer.poll(), isNull);
    expect(h.driver.pollCalls, 0);

    h.step();
    final polls = h.driver.pollCalls;
    expect(polls, greaterThan(0));
    expect(h.peer.poll(), isA<ConnectionOpened>());
    expect(h.peer.poll(), isNull);
    expect(h.driver.pollCalls, polls);
    h.step();
    expect(h.driver.pollCalls, greaterThan(polls));
    expect(h.peer.port, h.driver.port);
  });

  test('queued events preserve opening and reliable payload order', () {
    final h = harness();
    h.driver.events.addAll([
      const EnetDriverConnected(1, 3),
      EnetDriverReceived(1, 0, _frame(0, 1, [10, 20])),
      EnetDriverReceived(1, 0, _frame(0, 2, [30])),
    ]);
    h.step();
    final opening = h.peer.poll()!;
    final connection = opening.connection;

    expect(opening, _opened(connection));
    expect(connection.incoming, (messages: 2, bytes: 3));
    expect(h.driver.sent, isEmpty);
    expect(h.peer.poll(), _message(connection, [10, 20]));
    expect(connection.incoming, (messages: 1, bytes: 1));
    expect(h.driver.sent.single.bytes, _frame(1, 1));
    expect(h.peer.poll(), _message(connection, [30]));
    expect(connection.incoming, _empty);
    expect(h.driver.sent.last.bytes, _frame(1, 2));
    expect(h.peer.poll(), isNull);
  });

  test('incoming data is copied before application polling', () {
    final h = harness();
    final connection = h.open();
    final bytes = _frame(0, 1, [10, 20]);
    h.receive(bytes);
    bytes.fillRange(0, bytes.length, 255);

    expect(h.peer.poll(), _message(connection, [10, 20]));
    expect(h.driver.sent.single.bytes, _frame(1, 1));
  });

  test('all delivery modes use independent native channels and copy data', () {
    final h = harness(channelCount: 2);
    final connection = h.open();
    var sequence = 0;
    for (var channel = 0; channel < 2; channel++) {
      for (final mode in DeliveryMode.values) {
        sequence++;
        final payload = Uint8List.fromList([sequence]);
        expect(connection.send(payload, mode: mode, channel: channel), isTrue);
        payload[0] = 255;
        final sent = h.driver.sent.last;
        expect(sent.peer, 1);
        expect(sent.channel, channel * 3 + mode.index);
        expect(sent.mode, mode);
        expect(sent.bytes, _frame(0, sequence, [sequence], mode));
        expect(sent.token, mode == DeliveryMode.reliable ? isNull : sequence);
      }
    }

    expect(connection.outgoing, (messages: 6, bytes: 6));
    expect(h.peer.capabilities.canHost, isTrue);
    expect(h.peer.capabilities.channelCount, 2);
    expect(h.peer.capabilities.deliveryModes, DeliveryMode.values.toSet());
    expect(h.peer.capabilities, same(h.peer.capabilities));
  });

  test(
    'received modes and channels survive framing and only reliable ACKs',
    () {
      final h = harness(channelCount: 2);
      final connection = h.open();
      for (final mode in DeliveryMode.values) {
        h.receive(
          _frame(0, mode.index + 1, [mode.index], mode),
          channel: 3 + mode.index,
        );
      }
      expect(h.driver.sent, isEmpty);
      for (final mode in DeliveryMode.values) {
        expect(
          h.peer.poll(),
          _message(connection, [mode.index], mode: mode, channel: 1),
        );
      }
      expect(connection.incoming, _empty);
      expect(h.driver.sent, hasLength(1));
      expect(h.driver.sent.single.channel, 3);
      expect(h.driver.sent.single.mode, DeliveryMode.reliable);
      expect(h.driver.sent.single.bytes, _frame(1, 1));
    },
  );

  test(
    'empty payloads consume message credit and receive acknowledgements',
    () {
      final h = harness();
      final connection = h.open();
      expect(connection.send(Uint8List(0)), isTrue);
      h.receive(_frame(0, 1));
      expect(connection.incoming, (messages: 1, bytes: 0));
      expect(connection.outgoing, (messages: 1, bytes: 0));
      expect(h.peer.poll(), _message(connection, []));
      expect(h.driver.sent.last.bytes, _frame(1, 1));
      h.receive(_frame(1, 1));
      expect(connection.outgoing, _empty);
    },
  );

  test(
    'unreleased ACK control packets are bounded independently of payloads',
    () {
      final h = harness(outgoingLimits: const QueueLimits(maxMessages: 1));
      final connection = h.open();
      h.receive(_frame(0, 1, [1]));
      h.receive(_frame(0, 2, [2]));
      h.receive(_frame(0, 3, [3]));

      expect(h.peer.poll(), _message(connection, [1]));
      expect(h.driver.sent.single.bytes, _frame(1, 1));
      expect(h.driver.sent.single.token, lessThan(0));
      expect(connection.outgoing, _empty);
      expect(h.peer.poll(), _message(connection, [2]));
      expect(connection.isOpen, isFalse);
      expect(connection.closeReason, CloseReason.overflow);
      expect(connection.incoming, _empty);
      expect(connection.outgoing, _empty);
      expect(h.driver.sent, hasLength(1));
      expect(h.peer.poll(), _closed(connection, CloseReason.overflow));
      expect(h.peer.poll(), isNull);
    },
  );

  test(
    'native ACK release restores control capacity without releasing data',
    () {
      final h = harness(outgoingLimits: const QueueLimits(maxMessages: 1));
      final connection = h.open();
      expect(connection.send(Uint8List.fromList([8, 9])), isTrue);
      h.receive(_frame(0, 1, [1]));
      expect(h.peer.poll(), _message(connection, [1]));
      final firstAck = h.driver.sent.last;
      expect(firstAck.bytes, _frame(1, 1));
      expect(firstAck.token, lessThan(0));
      expect(connection.outgoing, (messages: 1, bytes: 2));

      h.driver.events.add(EnetDriverSent(1, firstAck.token!));
      h.step();
      expect(connection.outgoing, (messages: 1, bytes: 2));
      h.receive(_frame(0, 2, [2]));
      expect(h.peer.poll(), _message(connection, [2]));
      expect(h.driver.sent.last.bytes, _frame(1, 2));
      expect(connection.isOpen, isTrue);
      expect(connection.outgoing, (messages: 1, bytes: 2));

      h.receive(_frame(1, 1));
      expect(connection.outgoing, _empty);
      expect(h.peer.poll(), isNull);
    },
  );

  test('stale negative release cannot free another queued control packet', () {
    final h = harness(outgoingLimits: const QueueLimits(maxMessages: 1));
    final connection = h.open();
    h.receive(_frame(0, 1, [1]));
    expect(h.peer.poll(), _message(connection, [1]));
    final releasedToken = h.driver.sent.single.token!;
    h.driver.events.add(EnetDriverSent(1, releasedToken));
    h.step();

    h.receive(_frame(0, 2, [2]));
    expect(h.peer.poll(), _message(connection, [2]));
    expect(h.driver.sent.last.token, isNot(releasedToken));
    h.driver.events.add(EnetDriverSent(1, releasedToken));
    h.step();
    h.receive(_frame(0, 3, [3]));
    expect(h.peer.poll(), _message(connection, [3]));
    expect(h.driver.sent, hasLength(2));
    expect(h.peer.poll(), _closed(connection, CloseReason.overflow));
    expect(h.peer.poll(), isNull);
  });

  test('a slow receiver retains reliable sender credit until it polls', () {
    final sender = harness(outgoingLimits: const QueueLimits(maxMessages: 1));
    final receiver = harness();
    final outgoing = sender.open();
    final incoming = receiver.open();
    expect(outgoing.send(Uint8List.fromList([1])), isTrue);
    receiver.receive(sender.driver.sent.single.bytes);

    expect(outgoing.outgoing, (messages: 1, bytes: 1));
    expect(incoming.incoming, (messages: 1, bytes: 1));
    expect(receiver.driver.sent, isEmpty);
    expect(receiver.peer.poll(), _message(incoming, [1]));
    sender.receive(receiver.driver.sent.single.bytes);
    expect(outgoing.outgoing, _empty);
    expect(outgoing.send(Uint8List.fromList([2])), isTrue);
    receiver.receive(sender.driver.sent.last.bytes);
    expect(outgoing.send(Uint8List.fromList([3])), isFalse);
    expect(outgoing.closeReason, CloseReason.overflow);
    expect(receiver.peer.poll(), _message(incoming, [2]));
  });

  for (final limits in [
    const QueueLimits(maxMessages: 1),
    const QueueLimits(maxBytes: 2),
  ]) {
    final budget = limits.maxMessages == 1 ? 'message count' : 'byte count';

    test('outgoing $budget overflow closes once and resets its credit', () {
      final h = harness(outgoingLimits: limits);
      final connection = h.open();
      expect(connection.send(Uint8List.fromList([1, 2])), isTrue);
      expect(connection.send(Uint8List.fromList([3])), isFalse);

      expect(connection.isOpen, isFalse);
      expect(connection.closeReason, CloseReason.overflow);
      expect(connection.outgoing, _empty);
      expect(h.driver.sent, hasLength(1));
      expect(h.peer.poll(), _closed(connection, CloseReason.overflow));
      expect(h.peer.poll(), isNull);
      expect(connection.send(Uint8List(0)), isFalse);
    });

    test('ACK releases outgoing $budget capacity', () {
      final h = harness(outgoingLimits: limits);
      final connection = h.open();
      expect(connection.send(Uint8List.fromList([1, 2])), isTrue);
      h.receive(_frame(1, 1));
      expect(connection.send(Uint8List.fromList([3])), isTrue);
      expect(connection.outgoing, (messages: 1, bytes: 1));
      expect(connection.isOpen, isTrue);
    });

    test('incoming $budget overflow discards pending payloads', () {
      final h = harness(incomingLimits: limits);
      final connection = h.open();
      h.receive(_frame(0, 1, [1, 2]));
      h.receive(_frame(0, 2, [3]));

      expect(connection.isOpen, isFalse);
      expect(connection.incoming, _empty);
      expect(connection.closeReason, CloseReason.overflow);
      expect(h.driver.sent, isEmpty);
      expect(h.peer.poll(), _closed(connection, CloseReason.overflow));
      expect(h.peer.poll(), isNull);
    });
  }

  for (final mode in [
    DeliveryMode.unreliable,
    DeliveryMode.unreliableOrdered,
  ]) {
    test('${mode.name} payloads that overflow the incoming queue are '
        'discarded', () {
      final h = harness(incomingLimits: const QueueLimits(maxMessages: 1));
      final connection = h.open();
      h.receive(_frame(0, 1, [1], mode), channel: mode.index);
      h.receive(_frame(0, 2, [2], mode), channel: mode.index);

      expect(connection.isOpen, isTrue);
      expect(connection.incoming, (messages: 1, bytes: 1));
      expect(h.peer.poll(), _message(connection, [1], mode: mode));
      h.receive(_frame(0, 3, [3], mode), channel: mode.index);
      expect(h.peer.poll(), _message(connection, [3], mode: mode));
      expect(h.peer.poll(), isNull);

      h.receive(_frame(0, 4, [4]));
      h.receive(_frame(0, 5, [5]));
      expect(connection.closeReason, CloseReason.overflow);
      expect(h.peer.poll(), _closed(connection, CloseReason.overflow));
    });
  }

  test('a single oversized payload fails without reaching native send', () {
    final h = harness(outgoingLimits: const QueueLimits(maxBytes: 2));
    final connection = h.open();
    expect(connection.send(Uint8List(3)), isFalse);
    expect(h.driver.sent, isEmpty);
    expect(connection.outgoing, _empty);
    expect(h.peer.poll(), _closed(connection, CloseReason.overflow));
  });

  test('unreliable payload limit prevents native reliability upgrades', () {
    final h = harness();
    final connection = h.open();
    for (final mode in [
      DeliveryMode.unreliable,
      DeliveryMode.unreliableOrdered,
    ]) {
      expect(
        () => connection.send(Uint8List(1001), mode: mode),
        throwsArgumentError,
      );
      expect(connection.outgoing, _empty);
      expect(h.driver.sent, isEmpty);
    }
    expect(connection.send(Uint8List(1001)), isTrue);
    expect(connection.isOpen, isTrue);
  });

  for (final mode in [
    DeliveryMode.unreliable,
    DeliveryMode.unreliableOrdered,
  ]) {
    test('${mode.name} release frees credit without any receiver ACK', () {
      final h = harness(outgoingLimits: const QueueLimits(maxMessages: 1));
      final connection = h.open();
      expect(connection.send(Uint8List.fromList([1, 2]), mode: mode), isTrue);
      expect(connection.outgoing, (messages: 1, bytes: 2));

      // No remote receipt exists: the native packet may have been dropped.
      h.driver.events.add(const EnetDriverSent(1, 1));
      h.step();
      expect(connection.outgoing, _empty);
      expect(connection.send(Uint8List.fromList([3]), mode: mode), isTrue);
      expect(connection.outgoing, (messages: 1, bytes: 1));
      expect(h.peer.poll(), isNull);
    });
  }

  test('native release cannot free reliable message credit', () {
    final h = harness();
    final connection = h.open();
    expect(connection.send(Uint8List.fromList([1, 2])), isTrue);
    h.driver.events.add(const EnetDriverSent(1, 1));
    h.step();
    expect(connection.outgoing, (messages: 1, bytes: 2));
    expect(connection.isOpen, isTrue);
    h.receive(_frame(1, 1));
    expect(connection.outgoing, _empty);
  });

  test('stale native releases cannot free a newer packet or another peer', () {
    final h = harness();
    final first = h.open();
    expect(
      first.send(Uint8List.fromList([1]), mode: DeliveryMode.unreliable),
      isTrue,
    );
    h.driver.events.add(const EnetDriverSent(1, 1));
    h.step();
    expect(
      first.send(Uint8List.fromList([2, 3]), mode: DeliveryMode.unreliable),
      isTrue,
    );
    h.driver.events.add(const EnetDriverSent(1, 1));
    h.step();
    expect(first.outgoing, (messages: 1, bytes: 2));
    first.close();

    final second = h.open(2);
    expect(
      second.send(Uint8List.fromList([4]), mode: DeliveryMode.unreliable),
      isTrue,
    );
    h.driver.events.addAll([
      const EnetDriverSent(1, 1),
      const EnetDriverSent(1, 2),
      const EnetDriverDisconnected(1, true),
      EnetDriverReceived(1, 0, _frame(0, 1, [9])),
    ]);
    h.step();
    expect(second.isOpen, isTrue);
    expect(second.outgoing, (messages: 1, bytes: 1));
    expect(h.peer.poll(), isNull);
    h.driver.events.add(const EnetDriverSent(2, 1));
    h.step();
    expect(second.outgoing, _empty);
  });

  test('ACKs can arrive in independent channel order', () {
    final h = harness(channelCount: 2);
    final connection = h.open();
    expect(connection.send(Uint8List.fromList([1, 2])), isTrue);
    expect(connection.send(Uint8List.fromList([3]), channel: 1), isTrue);
    h.receive(_frame(1, 2), channel: 3);
    expect(connection.outgoing, (messages: 1, bytes: 2));
    h.receive(_frame(1, 1));
    expect(connection.outgoing, _empty);
    expect(connection.isOpen, isTrue);
  });

  test(
    'quiet reliable channels accept global sequence gaps beyond half range',
    () {
      final h = harness(channelCount: 2);
      final connection = h.open();
      h.receive(_frame(0, 1, [1]));
      // A busy channel can consume more than half the global sequence space
      // between two packets on a quiet channel. ENet supplies channel ordering.
      h.receive(_frame(0, 0x80000001, [2]), channel: 3);
      h.receive(_frame(0, 0x80000002, [3]));

      expect(h.peer.poll(), _message(connection, [1]));
      expect(h.peer.poll(), _message(connection, [2], channel: 1));
      expect(h.peer.poll(), _message(connection, [3]));
      expect(h.driver.sent.map((packet) => packet.bytes), [
        _frame(1, 1),
        _frame(1, 0x80000001),
        _frame(1, 0x80000002),
      ]);
      expect(connection.isOpen, isTrue);
      expect(connection.incoming, _empty);
      expect(h.peer.poll(), isNull);
    },
  );

  test('reliable sequences can skip other lanes and wrap around', () {
    final h = harness(channelCount: 2);
    final connection = h.open();
    h.receive(_frame(0, 0xfffffffe, [1]));
    h.receive(_frame(0, 3, [2]), channel: 3);
    h.receive(_frame(0, 1, [3]));
    expect(h.peer.poll(), _message(connection, [1]));
    expect(h.peer.poll(), _message(connection, [2], channel: 1));
    expect(h.peer.poll(), _message(connection, [3]));
    expect(connection.isOpen, isTrue);
    expect(connection.incoming, _empty);
    expect(h.peer.poll(), isNull);
  });

  final malformed = <String, Uint8List>{
    'empty frame': Uint8List(0),
    'truncated header': Uint8List(9),
    'unknown magic': _frame(0, 1)..[0] = 255,
    'unknown version': _frame(0, 1)..[3] = 2,
    'unknown kind': _frame(2, 1),
    'unknown mode': _frame(0, 1)..[5] = 3,
    'zero sequence': _frame(0, 0),
    'ACK with payload': _frame(1, 1, [1]),
    'unexpected ACK': _frame(1, 1),
    'unreliable ACK': _frame(1, 1, [], DeliveryMode.unreliable),
    'mode and channel mismatch': _frame(0, 1, [], DeliveryMode.unreliable),
  };
  for (final entry in malformed.entries) {
    test('${entry.key} closes as lost and discards pending payloads', () {
      final h = harness();
      final connection = h.open();
      h.receive(_frame(0, 1, [7]));
      h.receive(entry.value);
      expect(connection.isOpen, isFalse);
      expect(connection.closeReason, CloseReason.lost);
      expect(connection.incoming, _empty);
      expect(h.peer.poll(), _closed(connection, CloseReason.lost));
      expect(h.peer.poll(), isNull);
    });
  }

  test('out of range native receive channel is rejected', () {
    final h = harness();
    final connection = h.open();
    h.receive(_frame(0, 1), channel: 3);
    expect(h.peer.poll(), _closed(connection, CloseReason.lost));
  });

  test('ACK on a different channel cannot release the message', () {
    final h = harness(channelCount: 2);
    final connection = h.open();
    expect(connection.send(Uint8List.fromList([1]), channel: 1), isTrue);
    h.receive(_frame(1, 1));
    expect(h.peer.poll(), _closed(connection, CloseReason.lost));
  });

  test('a repeated ACK cannot release a different outstanding message', () {
    final h = harness();
    final connection = h.open();
    expect(connection.send(Uint8List.fromList([1])), isTrue);
    expect(connection.send(Uint8List.fromList([2])), isTrue);
    h.receive(_frame(1, 1));
    expect(connection.outgoing, (messages: 1, bytes: 1));
    h.receive(_frame(1, 1));
    expect(h.peer.poll(), _closed(connection, CloseReason.lost));
  });

  test('native send failure reports lost and does not retain credit', () {
    final h = harness();
    final connection = h.open();
    h.driver.failSend = true;
    expect(connection.send(Uint8List.fromList([1])), isFalse);
    expect(connection.outgoing, _empty);
    expect(h.peer.poll(), _closed(connection, CloseReason.lost));
    expect(h.peer.poll(), isNull);
  });

  test('native send exceptions close only the affected connection', () {
    final h = harness();
    final first = h.open();
    final second = h.open(2);
    h.driver.throwSend = true;
    expect(first.send(Uint8List.fromList([1])), isFalse);
    expect(first.outgoing, _empty);
    expect(h.peer.poll(), _closed(first, CloseReason.lost));
    expect(second.isOpen, isTrue);
    h.driver.throwSend = false;
    expect(second.send(Uint8List.fromList([2])), isTrue);
    expect(h.peer.poll(), isNull);
  });

  for (final throws in [false, true]) {
    test('ACK write failure throws=$throws preserves buffered remote data', () {
      final h = harness();
      final connection = h.open();
      h.receive(_frame(0, 1, [1]));
      h.receive(_frame(0, 2, [2]));
      h.driver
        ..failSend = !throws
        ..throwSend = throws;

      // Native disconnect may already prevent writes before the corresponding
      // event has been delivered; accepted input must still reach the caller.
      expect(h.peer.poll(), _message(connection, [1]));
      expect(connection.incoming, (messages: 1, bytes: 1));
      expect(connection.isOpen, isTrue);
      expect(h.driver.sent, isEmpty);
      h.driver.events.add(const EnetDriverDisconnected(1, true));
      h.step();
      expect(h.peer.poll(), _message(connection, [2]));
      expect(connection.incoming, _empty);
      expect(h.peer.poll(), _closed(connection, CloseReason.remote));
      expect(h.peer.poll(), isNull);
    });

    test('failed ACK write throws=$throws returns its control capacity', () {
      final h = harness(outgoingLimits: const QueueLimits(maxMessages: 1));
      final connection = h.open();
      h.receive(_frame(0, 1, [1]));
      h.receive(_frame(0, 2, [2]));
      h.driver
        ..failSend = !throws
        ..throwSend = throws;
      expect(h.peer.poll(), _message(connection, [1]));
      expect(h.driver.sent, isEmpty);

      h.driver
        ..failSend = false
        ..throwSend = false;
      expect(h.peer.poll(), _message(connection, [2]));
      expect(h.driver.sent.single.bytes, _frame(1, 2));
      expect(h.driver.sent.single.token, lessThan(0));
      expect(connection.isOpen, isTrue);
      expect(connection.incoming, _empty);
      expect(connection.outgoing, _empty);
      expect(h.peer.poll(), isNull);
    });
  }

  test(
    'native service failure preserves received data then closes all peers',
    () async {
      final h = harness();
      final first = h.open();
      final second = h.open(2);
      h.receive(_frame(0, 1, [1]));
      h.receive(_frame(0, 1, [2]), peer: 2);
      h.driver.throwPoll = true;
      h.step();
      await h.peer.done;

      expect(first.closeReason, CloseReason.lost);
      expect(second.closeReason, CloseReason.lost);
      expect(h.peer.poll(), _message(first, [1]));
      expect(h.peer.poll(), _message(second, [2]));
      expect(h.peer.poll(), _closed(first, CloseReason.lost));
      expect(h.peer.poll(), _closed(second, CloseReason.lost));
      expect(h.peer.poll(), isNull);
      expect(h.driver.closeCalls, 1);
      expect(h.clock.pendingTimerCount, 0);
    },
  );

  test('cleanup exceptions cannot escape or prevent completion', () async {
    final h = harness();
    final connection = h.open();
    h.driver
      ..throwDisconnect = true
      ..throwReset = true
      ..throwClose = true;
    h.peer.close();
    await h.peer.done;
    expect(connection.closeReason, CloseReason.local);
    expect(h.driver.disconnected, [1]);
    expect(h.driver.resets, [1]);
    expect(h.driver.closeCalls, 1);
    expect(h.peer.poll(), isNull);
  });

  for (final graceful in [true, false]) {
    test('remote disconnect graceful=$graceful preserves pending events', () {
      final h = harness();
      h.driver.events.addAll([
        const EnetDriverConnected(1, 3),
        EnetDriverReceived(1, 0, _frame(0, 1, [1])),
        EnetDriverReceived(1, 0, _frame(0, 2, [2])),
        EnetDriverDisconnected(1, graceful),
      ]);
      h.step();
      final connection = h.peer.poll()!.connection;
      final reason = graceful ? CloseReason.remote : CloseReason.lost;

      expect(connection.isOpen, isFalse);
      expect(connection.closeReason, reason);
      expect(connection.outgoing, _empty);
      expect(h.peer.poll(), _message(connection, [1]));
      expect(h.peer.poll(), _message(connection, [2]));
      expect(connection.incoming, _empty);
      expect(h.peer.poll(), _closed(connection, reason));
      expect(h.peer.poll(), isNull);
      expect(h.driver.sent, isEmpty);
    });
  }

  test('local close discards input and drains accepted native sends once', () {
    final h = harness();
    final connection = h.open();
    h.receive(_frame(0, 1, [1]));
    expect(connection.send(Uint8List.fromList([2])), isTrue);
    connection.close();
    connection.close();

    expect(connection.closeReason, CloseReason.local);
    expect(connection.isOpen, isFalse);
    expect(connection.incoming, _empty);
    expect(connection.outgoing, _empty);
    expect(h.peer.poll(), isNull);
    expect(h.driver.disconnected, [1]);
    expect(h.driver.resets, isEmpty);
    expect(h.driver.sent.single.bytes, _frame(0, 1, [2]));
    expect(connection.send(Uint8List(0)), isFalse);
  });

  test('closing one connection leaves other connection events intact', () {
    final h = harness();
    final first = h.open();
    final second = h.open(2);
    h.receive(_frame(0, 1, [1]));
    h.receive(_frame(0, 1, [2]), peer: 2);
    first.close();

    expect(h.peer.poll(), _message(second, [2]));
    expect(h.peer.poll(), isNull);
    expect(second.isOpen, isTrue);
  });

  test('closed connections still validate unsupported channel choices', () {
    final h = harness();
    final connection = h.open();
    connection.close();
    for (final channel in [-1, 1]) {
      expect(
        () => connection.send(Uint8List(0), channel: channel),
        throwsUnsupportedError,
      );
    }
    expect(h.driver.sent, isEmpty);
  });

  test('peer close discards events and waits for native disconnect', () async {
    final h = harness();
    final connection = h.open();
    h.receive(_frame(0, 1, [1]));
    var finished = false;
    unawaited(h.peer.done.then((_) => finished = true));
    h.peer.close();
    h.peer.close();
    await Future<void>.value();

    expect(h.peer.isClosed, isTrue);
    expect(connection.closeReason, CloseReason.local);
    expect(connection.incoming, _empty);
    expect(h.peer.poll(), isNull);
    expect(h.driver.disconnected, [1]);
    expect(h.driver.closeCalls, 0);
    expect(finished, isFalse);
    h.driver.events.add(const EnetDriverDisconnected(1, true));
    h.step();
    await h.peer.done;
    expect(finished, isTrue);
    expect(h.driver.closeCalls, 1);
    expect(h.clock.pendingTimerCount, 0);
  });

  test('peer disposal includes a connection already closed locally', () async {
    final h = harness();
    final connection = h.open();
    connection.close();
    h.peer.close();
    expect(h.driver.closeCalls, 0);
    h.driver.events.add(const EnetDriverDisconnected(1, true));
    h.step();
    await h.peer.done;
    expect(h.driver.disconnected, [1]);
    expect(h.driver.closeCalls, 1);
  });

  test(
    'close timeout bounds native drain and clears all scheduled work',
    () async {
      final h = harness();
      h.open();
      h.peer.close();
      h.clock.advance(const Duration(milliseconds: 8));
      expect(h.driver.closeCalls, 0);
      h.clock.advance(const Duration(milliseconds: 2));
      await h.peer.done;
      expect(h.driver.resets, [1]);
      expect(h.driver.closeCalls, 1);
      expect(h.clock.pendingTimerCount, 0);
    },
  );

  test('peer close clears data retained after remote closure', () async {
    final h = harness();
    final connection = h.open();
    h.receive(_frame(0, 1, [1, 2]));
    h.driver.events.add(const EnetDriverDisconnected(1, true));
    h.step();
    expect(connection.incoming, (messages: 1, bytes: 2));
    h.peer.close();
    await h.peer.done;
    expect(connection.incoming, _empty);
    expect(h.peer.poll(), isNull);
  });

  test('admission stays bounded until terminal events have been polled', () {
    final h = harness(maxConnections: 1);
    h.driver.events.addAll([
      const EnetDriverConnected(1, 3),
      const EnetDriverConnected(2, 3),
      const EnetDriverDisconnected(1, true),
      const EnetDriverConnected(3, 3),
    ]);
    h.step();
    expect(h.driver.resets, containsAll([2, 3]));
    final connection = h.peer.poll()!.connection;
    expect(h.peer.poll(), _closed(connection, CloseReason.remote));
    expect(h.peer.poll(), isNull);
    final accepted = h.open(4);
    expect(accepted.isOpen, isTrue);
  });

  test('local close releases admission while native disconnect drains', () {
    final h = harness(maxConnections: 1);
    final first = h.open();
    first.close();
    final second = h.open(2);
    expect(first.closeReason, CloseReason.local);
    expect(second.isOpen, isTrue);
    expect(h.driver.resets, isEmpty);
    expect(h.driver.disconnected, [1]);
    expect(h.peer.poll(), isNull);
  });

  test('insufficient negotiated channels are rejected by the host', () {
    final h = harness(channelCount: 2);
    h.driver.events.add(const EnetDriverConnected(1, 3));
    h.step();
    expect(h.driver.resets, [1]);
    expect(h.peer.poll(), isNull);
  });

  test(
    'client requests channels and reports insufficient negotiation once',
    () {
      final h = harness(isHost: false, channelCount: 2);
      h.peer.startConnect('localhost', 1234);
      expect(h.driver.connections, [
        (address: 'localhost', port: 1234, channelCount: 6),
      ]);
      h.driver.events.add(const EnetDriverConnected(1, 3));
      h.step();
      final event = h.peer.poll();
      expect(event, isA<ConnectionClosed>());
      expect((event! as ConnectionClosed).reason, CloseReason.connectFailed);
      expect(event.connection.isOpen, isFalse);
      expect(event.connection.closeReason, CloseReason.connectFailed);
      h.clock.advance(const Duration(milliseconds: 30));
      expect(h.peer.poll(), isNull);
    },
  );

  test('client connection times out using the injected clock', () {
    final h = harness(isHost: false);
    h.peer.startConnect('localhost', 1234);
    h.clock.advance(const Duration(milliseconds: 18));
    expect(h.peer.poll(), isNull);
    h.clock.advance(const Duration(milliseconds: 2));
    final event = h.peer.poll();
    expect(event, isA<ConnectionClosed>());
    expect((event! as ConnectionClosed).reason, CloseReason.connectFailed);
    expect(h.driver.resets, contains(1));
    h.clock.advance(const Duration(milliseconds: 30));
    expect(h.peer.poll(), isNull);
  });

  test('native connect failure closes only with connectFailed', () async {
    final h = harness(isHost: false);
    h.driver.throwConnect = true;
    h.peer.startConnect('localhost', 1234);
    await h.peer.done;
    final event = h.peer.poll();
    expect(event, isA<ConnectionClosed>());
    expect((event! as ConnectionClosed).reason, CloseReason.connectFailed);
    expect(event.connection.isOpen, isFalse);
    expect(h.peer.poll(), isNull);
    expect(h.clock.pendingTimerCount, 0);
  });

  test(
    'native failure while connecting reports no established connection',
    () async {
      final h = harness(isHost: false);
      h.peer.startConnect('localhost', 1234);
      h.driver.throwPoll = true;
      h.step();
      await h.peer.done;
      final event = h.peer.poll();
      expect(event, isA<ConnectionClosed>());
      expect((event! as ConnectionClosed).reason, CloseReason.connectFailed);
      expect(h.peer.poll(), isNull);
      expect(h.clock.pendingTimerCount, 0);
    },
  );

  test('established client cancels its connection timeout', () {
    final h = harness(isHost: false);
    h.peer.startConnect('localhost', 1234);
    final connection = h.open();
    h.clock.advance(const Duration(milliseconds: 30));
    expect(connection.isOpen, isTrue);
    expect(h.peer.poll(), isNull);
  });

  test('client accepts only its requested host connection', () {
    final h = harness(isHost: false);
    h.peer.startConnect('localhost', 1234);
    final connection = h.open();
    h.driver.events.add(const EnetDriverConnected(2, 3));
    h.step();
    expect(h.driver.resets, contains(2));
    expect(connection.isOpen, isTrue);
    expect(h.peer.poll(), isNull);
  });

  test('explicit connection failure produces a single terminal event', () {
    final h = harness(isHost: false);
    h.peer.connectFailed();
    h.peer.connectFailed();
    final event = h.peer.poll();
    expect(event, isA<ConnectionClosed>());
    expect((event! as ConnectionClosed).reason, CloseReason.connectFailed);
    expect(h.peer.poll(), isNull);
  });

  test('closing a connecting client suppresses later failure events', () async {
    final h = harness(isHost: false);
    h.peer.startConnect('localhost', 1234);
    h.peer.close();
    h.peer.connectFailed();
    h.clock.advance(const Duration(milliseconds: 30));
    await h.peer.done;
    expect(h.peer.poll(), isNull);
    expect(h.driver.closeCalls, 1);
  });
}
