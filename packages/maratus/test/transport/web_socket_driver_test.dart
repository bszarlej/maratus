@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:maratus/src/transport/web_socket_driver.dart';
import 'package:test/test.dart';

const _deadline = Duration(seconds: 5);

Future<WebSocketListener> _listen({int maxConnections = 4}) => bindWebSocket(
  address: '127.0.0.1',
  port: 0,
  path: '/game',
  maxConnections: maxConnections,
);

Uri _uri(int port, [String path = '/game']) =>
    Uri(scheme: 'ws', host: '127.0.0.1', port: port, path: path);

void main() {
  test(
    'native drivers deliver binary messages before normal closure',
    () async {
      final listener = await _listen();
      addTearDown(listener.close);
      final accepted = listener.connections.first;
      final client = await connectWebSocket(
        _uri(listener.port),
        timeout: _deadline,
      ).ready;
      addTearDown(client.close);
      final server = await accepted.timeout(_deadline);
      addTearDown(server.close);
      final received = server.messages.toList();

      client.send(Uint8List.fromList([1, 2, 3]));
      client.send(Uint8List(0));
      await client.close();
      expect(await received.timeout(_deadline), [
        [1, 2, 3],
        <int>[],
      ]);
      expect(server.closeCode, WebSocketStatus.normalClosure);
      await client.close();
    },
  );

  test('listener rejects wrong paths and missing subprotocols', () async {
    final listener = await _listen();
    addTearDown(listener.close);
    await expectLater(
      connectWebSocket(_uri(listener.port, '/wrong'), timeout: _deadline).ready,
      throwsA(isA<WebSocketException>()),
    );
    await expectLater(
      WebSocket.connect(_uri(listener.port).toString()),
      throwsA(isA<WebSocketException>()),
    );
  });

  test(
    'repeated native closes drain complete bursts in both directions',
    () async {
      final listener = await _listen();
      addTearDown(listener.close);
      final connections = StreamIterator(listener.connections);
      addTearDown(connections.cancel);
      for (var cycle = 0; cycle < 24; cycle++) {
        final accepted = connections.moveNext();
        final client = await connectWebSocket(
          _uri(listener.port),
          timeout: _deadline,
        ).ready;
        expect(await accepted.timeout(_deadline), isTrue);
        final server = connections.current;
        final sender = cycle.isEven ? client : server;
        final receiver = cycle.isEven ? server : client;
        final received = receiver.messages.toList();
        final messages = List.generate(64, (index) {
          final bytes = Uint8List(4096)..fillRange(0, 4096, index);
          bytes[0] = cycle;
          return bytes;
        });
        try {
          for (final message in messages) {
            sender.send(message);
          }
          await sender.close();
          expect(
            await received.timeout(_deadline),
            messages,
            reason: 'Cycle $cycle must drain every frame before closure.',
          );
          expect(receiver.closeCode, WebSocketStatus.normalClosure);
          expect(sender.isOpen, isFalse);
          expect(receiver.isOpen, isFalse);
        } finally {
          await Future.wait([client.close(), server.close()]);
        }
      }
    },
  );

  test('listener connection slots are released after driver closure', () async {
    final listener = await _listen(maxConnections: 1);
    addTearDown(listener.close);
    final accepted = StreamIterator(listener.connections);
    addTearDown(accepted.cancel);
    final next = accepted.moveNext();
    final client = await connectWebSocket(
      _uri(listener.port),
      timeout: _deadline,
    ).ready;
    addTearDown(client.close);
    expect(await next.timeout(_deadline), isTrue);
    final first = accepted.current;
    addTearDown(first.close);

    await expectLater(
      connectWebSocket(_uri(listener.port), timeout: _deadline).ready,
      throwsA(isA<WebSocketException>()),
    );
    await first.close();
    final replacementAccepted = accepted.moveNext();
    final replacement = await connectWebSocket(
      _uri(listener.port),
      timeout: _deadline,
    ).ready;
    addTearDown(replacement.close);
    expect(await replacementAccepted.timeout(_deadline), isTrue);
    addTearDown(accepted.current.close);
  });

  test('listener shutdown leaves accepted sockets usable', () async {
    final listener = await _listen();
    addTearDown(listener.close);
    final accepted = listener.connections.first;
    final client = await connectWebSocket(
      _uri(listener.port),
      timeout: _deadline,
    ).ready;
    addTearDown(client.close);
    final server = await accepted;
    addTearDown(server.close);
    final received = server.messages.first;
    final port = listener.port;

    await listener.close();
    client.send(Uint8List.fromList([4]));
    expect(await received.timeout(_deadline), [4]);
    await expectLater(
      connectWebSocket(_uri(port), timeout: _deadline).ready,
      throwsA(isA<SocketException>()),
    );
  });

  test('cancelling an in-progress handshake aborts its HTTP request', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    final request = server.first;
    final dial = connectWebSocket(_uri(server.port), timeout: _deadline);
    final rejected = expectLater(dial.ready, throwsA(isA<StateError>()));
    await request.timeout(_deadline);
    await dial.cancel();
    await rejected;
    await dial.cancel();
  });

  test('an unresponsive handshake reaches its opening deadline', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    final requests = server.listen((_) {});
    addTearDown(requests.cancel);
    final dial = connectWebSocket(
      _uri(server.port),
      timeout: const Duration(milliseconds: 100),
    );
    await expectLater(dial.ready, throwsA(isA<TimeoutException>()));
    await dial.cancel();
  });
}
