import 'dart:async';
import 'dart:typed_data';

import 'package:maratus/src/transport/multiplayer_peer.dart';
import 'package:maratus/src/transport/web_socket_driver_base.dart';
import 'package:maratus/src/transport/web_socket_peer_base.dart';
import 'package:test/test.dart';

const QueueDepth _empty = (messages: 0, bytes: 0);

Uint8List _frame(int kind, int sequence, [List<int> payload = const []]) {
  final frame = Uint8List(5 + payload.length);
  frame[0] = kind;
  ByteData.sublistView(frame).setUint32(1, sequence);
  frame.setRange(5, frame.length, payload);
  return frame;
}

Matcher _opened(PeerConnection connection) => isA<ConnectionOpened>().having(
  (event) => event.connection,
  'connection',
  same(connection),
);

Matcher _message(PeerConnection connection, List<int> payload) =>
    isA<MessageReceived>()
        .having((event) => event.connection, 'connection', same(connection))
        .having((event) => event.message, 'message', payload);

Matcher _closed(PeerConnection connection, CloseReason reason) =>
    isA<ConnectionClosed>()
        .having((event) => event.connection, 'connection', same(connection))
        .having((event) => event.reason, 'reason', reason);

class _Driver implements WebSocketDriver {
  late final StreamController<Object> _incoming = StreamController<Object>(
    sync: true,
    onCancel: () => cancelCalls++,
  );

  final sent = <Uint8List>[];
  int closeCalls = 0;
  int cancelCalls = 0;
  bool failSend = false;
  bool failClose = false;
  bool isClosing = false;
  Completer<void>? closeGate;

  @override
  int? closeCode;

  @override
  Stream<Object> get messages => _incoming.stream;

  @override
  bool get isOpen =>
      !isClosing && closeCalls == 0 && closeCode == null && !_incoming.isClosed;

  void receive(Object frame) => _incoming.add(frame);

  void fail() => _incoming.addError(StateError('Socket failed'));

  Future<void> remoteClose([int? code = 1000]) {
    closeCode = code;
    return _incoming.close();
  }

  @override
  void send(Uint8List message) {
    if (failSend) throw StateError('Socket send failed');
    // Keep the original reference so the tests detect missing payload copies.
    sent.add(message);
  }

  @override
  Future<void> close() {
    closeCalls++;
    unawaited(_incoming.close());
    if (failClose) throw StateError('Socket close failed');
    return closeGate?.future ?? Future<void>.value();
  }
}

void main() {
  final peers = <WebSocketPeerBase>[];

  WebSocketPeerBase peer({
    bool isHost = true,
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
    int maxConnections = 64,
    Future<void> Function()? onClose,
  }) {
    final result = WebSocketPeerBase(
      isHost: isHost,
      incomingLimits: incomingLimits,
      outgoingLimits: outgoingLimits,
      maxConnections: maxConnections,
      onClose: onClose,
    );
    peers.add(result);
    return result;
  }

  tearDown(() async {
    for (final peer in peers) {
      peer.close();
      await peer.done;
    }
    peers.clear();
  });

  test('opening and messages are observed only through poll', () {
    final host = peer();
    final driver = _Driver();
    final connection = host.attach(driver)!;

    driver.receive(_frame(0, 1, [10, 20]));
    driver.receive(_frame(0, 2, [30]));

    expect(connection.isOpen, isTrue);
    expect(connection.closeReason, isNull);
    expect(connection.incoming, (messages: 2, bytes: 3));
    expect(driver.sent, isEmpty);
    expect(host.poll(), _opened(connection));
    expect(driver.sent, isEmpty);
    expect(host.poll(), _message(connection, [10, 20]));
    expect(connection.incoming, (messages: 1, bytes: 1));
    expect(driver.sent, [_frame(1, 1)]);
    expect(host.poll(), _message(connection, [30]));
    expect(connection.incoming, _empty);
    expect(driver.sent, [_frame(1, 1), _frame(1, 2)]);
    expect(host.poll(), isNull);
  });

  test('incoming data is copied before application polling', () {
    final host = peer();
    final driver = _Driver();
    final connection = host.attach(driver)!;
    final frame = _frame(0, 1, [10, 20]);

    driver.receive(frame);
    frame.fillRange(0, frame.length, 255);

    expect(host.poll(), _opened(connection));
    expect(host.poll(), _message(connection, [10, 20]));
    expect(driver.sent.single, _frame(1, 1));
  });

  test('plain byte lists from a platform driver are accepted and copied', () {
    final host = peer();
    final driver = _Driver();
    final connection = host.attach(driver)!;
    final frame = _frame(0, 1, [10, 20]).toList();

    driver.receive(frame);
    frame.fillRange(0, frame.length, 255);

    expect(host.poll(), _opened(connection));
    expect(host.poll(), _message(connection, [10, 20]));
    expect(driver.sent.single, _frame(1, 1));
  });

  test('send copies payload and retains depth until ordered ACKs', () {
    final host = peer();
    final driver = _Driver();
    final connection = host.attach(driver)!;
    final payload = Uint8List.fromList([10, 20]);

    expect(connection.send(payload), isTrue);
    payload.fillRange(0, payload.length, 99);
    expect(connection.send(Uint8List.fromList([30])), isTrue);

    expect(driver.sent, [
      _frame(0, 1, [10, 20]),
      _frame(0, 2, [30]),
    ]);
    expect(connection.outgoing, (messages: 2, bytes: 3));
    driver.receive(_frame(1, 1));
    expect(connection.outgoing, (messages: 1, bytes: 1));
    driver.receive(_frame(1, 2));
    expect(connection.outgoing, _empty);
    expect(host.poll(), _opened(connection));
    expect(host.poll(), isNull);
  });

  test('empty payloads count toward messages and receive ACKs', () {
    final host = peer();
    final driver = _Driver();
    final connection = host.attach(driver)!;

    expect(connection.send(Uint8List(0)), isTrue);
    driver.receive(_frame(0, 1));

    expect(connection.incoming, (messages: 1, bytes: 0));
    expect(connection.outgoing, (messages: 1, bytes: 0));
    expect(host.poll(), _opened(connection));
    expect(host.poll(), _message(connection, []));
    expect(driver.sent, [_frame(0, 1), _frame(1, 1)]);
    driver.receive(_frame(1, 1));
    expect(connection.outgoing, _empty);
  });

  test('supports only reliable delivery on channel zero', () {
    final host = peer();
    final driver = _Driver();
    final connection = host.attach(driver)!;

    for (final mode in [
      DeliveryMode.unreliable,
      DeliveryMode.unreliableOrdered,
    ]) {
      expect(
        () => connection.send(Uint8List(0), mode: mode),
        throwsUnsupportedError,
      );
    }
    for (final channel in [-1, 1]) {
      expect(
        () => connection.send(Uint8List(0), channel: channel),
        throwsUnsupportedError,
      );
    }
    expect(connection.isOpen, isTrue);
    expect(connection.outgoing, _empty);
    expect(driver.sent, isEmpty);
  });

  test('slow receiver keeps the sender bounded until it polls payloads', () {
    final sender = peer(outgoingLimits: const QueueLimits(maxMessages: 1));
    final receiver = peer();
    final senderDriver = _Driver();
    final receiverDriver = _Driver();
    final outgoing = sender.attach(senderDriver)!;
    final incoming = receiver.attach(receiverDriver)!;
    expect(sender.poll(), _opened(outgoing));
    expect(receiver.poll(), _opened(incoming));

    expect(outgoing.send(Uint8List.fromList([1])), isTrue);
    receiverDriver.receive(senderDriver.sent.single);
    expect(outgoing.outgoing, (messages: 1, bytes: 1));
    expect(incoming.incoming, (messages: 1, bytes: 1));
    expect(receiverDriver.sent, isEmpty);

    expect(receiver.poll(), _message(incoming, [1]));
    senderDriver.receive(receiverDriver.sent.single);
    expect(outgoing.outgoing, _empty);
    expect(outgoing.send(Uint8List.fromList([2])), isTrue);
    receiverDriver.receive(senderDriver.sent.last);
    expect(outgoing.send(Uint8List.fromList([3])), isFalse);
    expect(outgoing.closeReason, CloseReason.overflow);
    expect(receiver.poll(), _message(incoming, [2]));
  });

  for (final limits in [
    const QueueLimits(maxMessages: 1),
    const QueueLimits(maxBytes: 2),
  ]) {
    test('outgoing queue enforces $limits until remote application polls', () {
      final host = peer(outgoingLimits: limits);
      final driver = _Driver();
      final connection = host.attach(driver)!;
      expect(host.poll(), _opened(connection));

      expect(connection.send(Uint8List.fromList([1, 2])), isTrue);
      expect(connection.send(Uint8List.fromList([3])), isFalse);

      expect(connection.isOpen, isFalse);
      expect(connection.closeReason, CloseReason.overflow);
      expect(connection.outgoing, _empty);
      expect(driver.sent, [
        _frame(0, 1, [1, 2]),
      ]);
      expect(host.poll(), _closed(connection, CloseReason.overflow));
      expect(host.poll(), isNull);
      expect(connection.send(Uint8List(0)), isFalse);
    });

    test('ACK frees outgoing capacity for the next message with $limits', () {
      final host = peer(outgoingLimits: limits);
      final driver = _Driver();
      final connection = host.attach(driver)!;

      expect(connection.send(Uint8List.fromList([1, 2])), isTrue);
      driver.receive(_frame(1, 1));
      expect(connection.send(Uint8List.fromList([3])), isTrue);

      expect(connection.outgoing, (messages: 1, bytes: 1));
      expect(connection.isOpen, isTrue);
    });

    test(
      'incoming overflow discards locally pending messages with $limits',
      () {
        final host = peer(incomingLimits: limits);
        final driver = _Driver();
        final connection = host.attach(driver)!;
        expect(host.poll(), _opened(connection));

        driver.receive(_frame(0, 1, [1, 2]));
        driver.receive(_frame(0, 2, [3]));

        expect(connection.isOpen, isFalse);
        expect(connection.closeReason, CloseReason.overflow);
        expect(connection.incoming, _empty);
        expect(driver.sent, isEmpty);
        expect(host.poll(), _closed(connection, CloseReason.overflow));
        expect(host.poll(), isNull);
      },
    );
  }

  test('one oversized payload overflows the incoming byte budget', () {
    final host = peer(incomingLimits: const QueueLimits(maxBytes: 2));
    final driver = _Driver();
    final connection = host.attach(driver)!;
    expect(host.poll(), _opened(connection));

    driver.receive(_frame(0, 1, [1, 2, 3]));

    expect(connection.incoming, _empty);
    expect(host.poll(), _closed(connection, CloseReason.overflow));
  });

  test('one oversized outgoing payload is never passed to the socket', () {
    final host = peer(outgoingLimits: const QueueLimits(maxBytes: 2));
    final driver = _Driver();
    final connection = host.attach(driver)!;
    expect(host.poll(), _opened(connection));

    expect(connection.send(Uint8List.fromList([1, 2, 3])), isFalse);

    expect(connection.outgoing, _empty);
    expect(driver.sent, isEmpty);
    expect(host.poll(), _closed(connection, CloseReason.overflow));
  });

  final malformedFrames = <String, Object>{
    'text': 'hello',
    'empty': Uint8List(0),
    'short data': Uint8List.fromList([0, 0, 0, 1]),
    'short ACK': Uint8List.fromList([1, 0, 0, 1]),
    'unknown kind': _frame(2, 1),
    'ACK with payload': _frame(1, 1, [1]),
    'data sequence zero': _frame(0, 0),
    'skipped data sequence': _frame(0, 2),
    'unexpected ACK': _frame(1, 1),
  };
  for (final entry in malformedFrames.entries) {
    test('${entry.key} closes the connection as lost', () {
      final host = peer();
      final driver = _Driver();
      final connection = host.attach(driver)!;
      expect(host.poll(), _opened(connection));

      driver.receive(entry.value);

      expect(connection.isOpen, isFalse);
      expect(connection.closeReason, CloseReason.lost);
      expect(host.poll(), _closed(connection, CloseReason.lost));
      expect(host.poll(), isNull);
    });
  }

  test('repeated incoming sequence rejects pending messages', () {
    final host = peer();
    final driver = _Driver();
    final connection = host.attach(driver)!;
    expect(host.poll(), _opened(connection));

    driver.receive(_frame(0, 1, [1]));
    driver.receive(_frame(0, 1, [2]));

    expect(connection.incoming, _empty);
    expect(host.poll(), _closed(connection, CloseReason.lost));
    expect(host.poll(), isNull);
  });

  test('ACK cannot skip an outstanding message', () {
    final host = peer();
    final driver = _Driver();
    final connection = host.attach(driver)!;
    expect(host.poll(), _opened(connection));
    expect(connection.send(Uint8List.fromList([1])), isTrue);
    expect(connection.send(Uint8List.fromList([2])), isTrue);

    driver.receive(_frame(1, 2));

    expect(connection.outgoing, _empty);
    expect(host.poll(), _closed(connection, CloseReason.lost));
  });

  test('repeated ACK cannot release another message', () {
    final host = peer();
    final driver = _Driver();
    final connection = host.attach(driver)!;
    expect(host.poll(), _opened(connection));
    expect(connection.send(Uint8List.fromList([1])), isTrue);
    expect(connection.send(Uint8List.fromList([2])), isTrue);
    driver.receive(_frame(1, 1));

    driver.receive(_frame(1, 1));

    expect(connection.outgoing, _empty);
    expect(host.poll(), _closed(connection, CloseReason.lost));
  });

  for (final code in <int?>[1000, 1001, 1006, null]) {
    test(
      'remote closure $code preserves received events before closing',
      () async {
        final host = peer();
        final driver = _Driver();
        final connection = host.attach(driver)!;
        driver.receive(_frame(0, 1, [1]));
        driver.receive(_frame(0, 2, [2]));

        await driver.remoteClose(code);

        final reason = code == 1000 || code == 1001
            ? CloseReason.remote
            : CloseReason.lost;
        expect(connection.isOpen, isFalse);
        expect(connection.closeReason, reason);
        expect(host.poll(), _opened(connection));
        expect(host.poll(), _message(connection, [1]));
        expect(host.poll(), _message(connection, [2]));
        expect(connection.incoming, _empty);
        expect(host.poll(), _closed(connection, reason));
        expect(host.poll(), isNull);
        expect(driver.sent, isEmpty);
      },
    );
  }

  test(
    'socket error preserves received events and reports lost once',
    () async {
      final host = peer();
      final driver = _Driver();
      final connection = host.attach(driver)!;
      driver.receive(_frame(0, 1, [1]));

      driver.fail();
      await driver.remoteClose(1006);

      expect(host.poll(), _opened(connection));
      expect(host.poll(), _message(connection, [1]));
      expect(host.poll(), _closed(connection, CloseReason.lost));
      expect(host.poll(), isNull);
    },
  );

  test('send failure rejects the message and reports lost', () {
    final host = peer();
    final driver = _Driver();
    final connection = host.attach(driver)!;
    expect(host.poll(), _opened(connection));
    driver.failSend = true;

    expect(connection.send(Uint8List.fromList([1])), isFalse);

    expect(connection.isOpen, isFalse);
    expect(connection.outgoing, _empty);
    expect(host.poll(), _closed(connection, CloseReason.lost));
    expect(host.poll(), isNull);
  });

  test('ACK failure returns the message and waits for the socket error', () {
    final host = peer();
    final driver = _Driver();
    final connection = host.attach(driver)!;
    expect(host.poll(), _opened(connection));
    driver.receive(_frame(0, 1, [1]));
    driver.failSend = true;

    expect(host.poll(), _message(connection, [1]));

    expect(connection.incoming, _empty);
    expect(connection.isOpen, isTrue);
    expect(host.poll(), isNull);
    driver.fail();
    expect(connection.isOpen, isFalse);
    expect(host.poll(), _closed(connection, CloseReason.lost));
    expect(host.poll(), isNull);
  });

  test('ACK failure preserves subsequent data before normal closure', () async {
    final host = peer();
    final driver = _Driver();
    final connection = host.attach(driver)!;
    expect(host.poll(), _opened(connection));
    driver.receive(_frame(0, 1, [1]));
    driver.failSend = true;

    expect(host.poll(), _message(connection, [1]));
    expect(connection.isOpen, isTrue);
    expect(host.poll(), isNull);
    // The socket may still deliver buffered DATA after its write side closes.
    driver.receive(_frame(0, 2, [2]));
    await driver.remoteClose();

    expect(host.poll(), _message(connection, [2]));
    expect(host.poll(), _closed(connection, CloseReason.remote));
    expect(host.poll(), isNull);
    expect(connection.incoming, _empty);
  });

  test(
    'ACK during a normal remote close preserves remaining payloads',
    () async {
      final host = peer();
      final driver = _Driver();
      final connection = host.attach(driver)!;
      expect(host.poll(), _opened(connection));
      driver.receive(_frame(0, 1, [1]));
      driver.receive(_frame(0, 2, [2]));
      // A native socket can observe the close frame before its stream's done
      // notification reaches the engine. A polling ACK then fails to enqueue.
      driver.closeCode = 1000;
      driver.failSend = true;

      expect(host.poll(), _message(connection, [1]));

      expect(connection.isOpen, isTrue);
      expect(connection.incoming, (messages: 1, bytes: 1));
      await driver.remoteClose();
      expect(connection.closeReason, CloseReason.remote);
      expect(host.poll(), _message(connection, [2]));
      expect(connection.incoming, _empty);
      expect(host.poll(), _closed(connection, CloseReason.remote));
      expect(host.poll(), isNull);
    },
  );

  test(
    'poll suppresses ACKs during closing before a close code arrives',
    () async {
      final host = peer();
      final driver = _Driver();
      final connection = host.attach(driver)!;
      expect(host.poll(), _opened(connection));
      driver.receive(_frame(0, 1, [1]));
      driver.receive(_frame(0, 2, [2]));
      driver.isClosing = true;
      driver.failSend = true;

      expect(host.poll(), _message(connection, [1]));
      expect(connection.isOpen, isTrue);
      expect(driver.sent, isEmpty);
      await driver.remoteClose();

      expect(host.poll(), _message(connection, [2]));
      expect(host.poll(), _closed(connection, CloseReason.remote));
      expect(host.poll(), isNull);
    },
  );

  test(
    'peer close clears input retained after remote connection closure',
    () async {
      final host = peer();
      final driver = _Driver();
      final connection = host.attach(driver)!;
      expect(host.poll(), _opened(connection));
      driver.receive(_frame(0, 1, [1, 2]));
      await driver.remoteClose();
      expect(connection.incoming, (messages: 1, bytes: 2));

      host.close();
      await host.done;

      expect(connection.incoming, _empty);
      expect(host.poll(), isNull);
    },
  );

  test('local connection close discards queued messages without Closed', () {
    final host = peer();
    final driver = _Driver();
    final connection = host.attach(driver)!;
    driver.receive(_frame(0, 1, [1]));
    expect(connection.send(Uint8List.fromList([2])), isTrue);

    connection.close();
    connection.close();

    expect(connection.isOpen, isFalse);
    expect(connection.closeReason, CloseReason.local);
    expect(connection.incoming, _empty);
    expect(connection.outgoing, _empty);
    expect(host.poll(), _opened(connection));
    expect(host.poll(), isNull);
    expect(connection.send(Uint8List(0)), isFalse);
    expect(driver.sent, [
      _frame(0, 1, [2]),
    ]);
    expect(driver.closeCalls, 1);
  });

  test('closing one connection retains events for other connections', () {
    final host = peer();
    final firstDriver = _Driver();
    final secondDriver = _Driver();
    final first = host.attach(firstDriver)!;
    final second = host.attach(secondDriver)!;
    firstDriver.receive(_frame(0, 1, [1]));
    secondDriver.receive(_frame(0, 1, [2]));

    first.close();

    expect(host.poll(), _opened(first));
    expect(host.poll(), _opened(second));
    expect(host.poll(), _message(second, [2]));
    expect(host.poll(), isNull);
    expect(second.isOpen, isTrue);
  });

  test(
    'peer close discards events and awaits socket and listener disposal',
    () async {
      final listenerClosed = Completer<void>();
      var closeCalls = 0;
      final host = peer(
        onClose: () {
          closeCalls++;
          return listenerClosed.future;
        },
      );
      final firstDriver = _Driver()..closeGate = Completer<void>();
      final secondDriver = _Driver()..closeGate = Completer<void>();
      final first = host.attach(firstDriver)!;
      final second = host.attach(secondDriver)!;
      firstDriver.receive(_frame(0, 1, [1]));
      var finished = false;
      unawaited(host.done.then((_) => finished = true));

      host.close();
      host.close();

      expect(host.isClosed, isTrue);
      expect(first.closeReason, CloseReason.local);
      expect(second.closeReason, CloseReason.local);
      expect(host.poll(), isNull);
      expect(closeCalls, 1);
      expect(firstDriver.closeCalls, 1);
      expect(secondDriver.closeCalls, 1);
      expect(finished, isFalse);
      firstDriver.closeGate!.complete();
      secondDriver.closeGate!.complete();
      await Future<void>.value();
      expect(finished, isFalse);
      listenerClosed.complete();
      await host.done;
      expect(finished, isTrue);
    },
  );

  test(
    'closed peer rejects and disposes subsequently arriving sockets',
    () async {
      final host = peer();
      host.close();
      final driver = _Driver();

      expect(host.attach(driver), isNull);
      await host.done;

      expect(driver.closeCalls, 1);
      expect(host.poll(), isNull);
    },
  );

  test(
    'admission remains bounded until closed events have been polled',
    () async {
      final host = peer(maxConnections: 1);
      final firstDriver = _Driver();
      final first = host.attach(firstDriver)!;
      final refusedWhileOpen = _Driver();
      expect(host.attach(refusedWhileOpen), isNull);
      expect(refusedWhileOpen.closeCalls, 1);
      await firstDriver.remoteClose();

      final refusedWhilePending = _Driver();
      expect(host.attach(refusedWhilePending), isNull);
      expect(refusedWhilePending.closeCalls, 1);
      expect(host.poll(), _opened(first));
      expect(host.poll(), _closed(first, CloseReason.remote));

      final secondDriver = _Driver();
      final second = host.attach(secondDriver)!;
      expect(host.poll(), _opened(second));
      expect(host.poll(), isNull);
    },
  );

  test(
    'peer done includes cleanup for a connection already closed locally',
    () async {
      final host = peer();
      final driver = _Driver()..closeGate = Completer<void>();
      final connection = host.attach(driver)!;
      expect(host.poll(), _opened(connection));
      connection.close();
      var finished = false;
      unawaited(host.done.then((_) => finished = true));

      host.close();
      await Future<void>.value();
      expect(finished, isFalse);

      driver.closeGate!.complete();
      await host.done;
      expect(finished, isTrue);
      expect(driver.closeCalls, 1);
    },
  );

  test('cleanup errors do not escape close or prevent peer disposal', () async {
    final host = peer(onClose: () => throw StateError('Listener close failed'));
    final driver = _Driver()..failClose = true;
    final connection = host.attach(driver)!;

    host.close();
    await host.done;

    expect(connection.isOpen, isFalse);
    expect(driver.closeCalls, 1);
    expect(host.poll(), isNull);
  });

  test('rejecting a driver contains synchronous disposal errors', () async {
    final host = peer(maxConnections: 1);
    host.attach(_Driver());
    final rejected = _Driver()..failClose = true;

    expect(host.attach(rejected), isNull);
    host.close();
    await host.done;

    expect(rejected.closeCalls, 1);
  });

  test('explicit close frees its slot once Opened has been polled', () {
    final host = peer(maxConnections: 1);
    final first = host.attach(_Driver())!;

    first.close();

    final refusedWhilePending = _Driver();
    expect(host.attach(refusedWhilePending), isNull);
    expect(refusedWhilePending.closeCalls, 1);
    expect(host.poll(), _opened(first));
    final second = host.attach(_Driver())!;
    expect(host.poll(), _opened(second));
    expect(host.poll(), isNull);
  });

  test('client accepts only one host connection', () {
    final client = peer(isHost: false);
    final connection = client.attach(_Driver())!;
    final unexpected = _Driver();

    expect(client.attach(unexpected), isNull);

    expect(unexpected.closeCalls, 1);
    expect(client.poll(), _opened(connection));
    expect(client.poll(), isNull);
  });

  test('failed connection emits only one connectFailed event', () {
    final client = peer(isHost: false);

    client.connectFailed();
    client.connectFailed();

    final event = client.poll();
    expect(event, isA<ConnectionClosed>());
    expect((event! as ConnectionClosed).reason, CloseReason.connectFailed);
    expect(event.connection.isOpen, isFalse);
    expect(event.connection.closeReason, CloseReason.connectFailed);
    expect(client.poll(), isNull);
  });

  test('closing a connecting client suppresses a later failed connection', () {
    final client = peer(isHost: false);

    client.close();
    client.connectFailed();

    expect(client.poll(), isNull);
  });
}
