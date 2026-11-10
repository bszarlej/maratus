@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus_enet/src/enet_driver.dart';
import 'package:maratus_enet/src/enet_driver_native.dart';
import 'package:test/test.dart';

final class _Endpoint {
  _Endpoint({bool bound = false})
    : driver = createEnetDriver(
        address: bound ? '127.0.0.1' : null,
        port: 0,
        maxConnections: 1,
        channelCount: 3,
        maxPacketBytes: 4096,
        maxWaitingBytes: 16384,
      );

  final EnetDriver driver;
  final events = <EnetDriverEvent>[];

  void service() {
    for (var count = 0; count < 256; count++) {
      final event = driver.poll();
      if (event == null) return;
      events.add(event);
    }
  }
}

Future<void> _until(
  bool Function() condition,
  List<_Endpoint> endpoints,
) async {
  final watch = Stopwatch()..start();
  while (true) {
    for (final endpoint in endpoints) {
      endpoint.service();
    }
    if (condition()) return;
    if (watch.elapsed > const Duration(seconds: 10)) {
      fail('Native ENet driver condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<(int, int)> _connect(_Endpoint host, _Endpoint client) async {
  final clientId = client.driver.connect('127.0.0.1', host.driver.port, 3);
  await _until(
    () =>
        host.events.whereType<EnetDriverConnected>().isNotEmpty &&
        client.events.whereType<EnetDriverConnected>().isNotEmpty,
    [host, client],
  );
  return (host.events.whereType<EnetDriverConnected>().last.peer, clientId);
}

void main() {
  _Endpoint endpoint({bool bound = false}) {
    final result = _Endpoint(bound: bound);
    addTearDown(result.driver.close);
    return result;
  }

  test(
    'packet release callbacks preserve signed tokens for every mode',
    () async {
      final host = endpoint(bound: true);
      final client = endpoint();
      final (_, clientId) = await _connect(host, client);
      final tokens = [-17, 23, 42];

      for (final mode in DeliveryMode.values) {
        expect(
          client.driver.send(
            clientId,
            mode.index,
            Uint8List.fromList([mode.index]),
            mode,
            token: tokens[mode.index],
          ),
          isTrue,
        );
        await _until(
          () => client.events.whereType<EnetDriverSent>().any(
            (event) => event.token == tokens[mode.index],
          ),
          [host, client],
        );
      }

      expect(
        client.events.whereType<EnetDriverSent>().map((event) => event.token),
        tokens,
      );
      expect(
        client.events.whereType<EnetDriverSent>().map((event) => event.peer),
        everyElement(clientId),
      );
      final packets = host.events.whereType<EnetDriverReceived>().toList();
      expect(packets.map((event) => event.bytes), [
        [0],
        [1],
        [2],
      ]);
      expect(packets.map((event) => event.channel), [0, 1, 2]);

      // Rejected sends must not produce a spurious release callback.
      expect(
        client.driver.send(
          clientId + 1,
          0,
          Uint8List(0),
          DeliveryMode.reliable,
          token: -18,
        ),
        isFalse,
      );
      expect(
        client.driver.send(
          clientId,
          0,
          Uint8List(4097),
          DeliveryMode.reliable,
          token: -19,
        ),
        isFalse,
      );
      client.service();
      expect(client.events.whereType<EnetDriverSent>(), hasLength(3));
    },
  );

  test('unreliable release does not wait for remote native service', () async {
    final host = endpoint(bound: true);
    final client = endpoint();
    final (_, clientId) = await _connect(host, client);
    for (final mode in [
      DeliveryMode.unreliableOrdered,
      DeliveryMode.unreliable,
    ]) {
      expect(
        client.driver.send(
          clientId,
          mode.index,
          Uint8List(0),
          mode,
          token: mode.index,
        ),
        isTrue,
      );
    }
    await _until(() => client.events.whereType<EnetDriverSent>().length == 2, [
      client,
    ]);
    expect(host.events.whereType<EnetDriverReceived>(), isEmpty);

    // Negative tokens track the transport's reliable consumption ACKs. They
    // remain native-owned until the remote ENet host acknowledges delivery.
    expect(
      client.driver.send(
        clientId,
        0,
        Uint8List(0),
        DeliveryMode.reliable,
        token: -1,
      ),
      isTrue,
    );
    client.service();
    expect(
      client.events.whereType<EnetDriverSent>().map((event) => event.token),
      unorderedEquals([1, 2]),
    );
    await _until(
      () => client.events.whereType<EnetDriverSent>().any(
        (event) => event.token == -1,
      ),
      [host, client],
    );
  });

  test(
    'reset releases queued callbacks without leaking them into reused slots',
    () async {
      final host = endpoint(bound: true);
      final client = endpoint();
      final (hostId, clientId) = await _connect(host, client);
      for (final mode in DeliveryMode.values) {
        expect(
          client.driver.send(
            clientId,
            mode.index,
            Uint8List(128),
            mode,
            token: mode == DeliveryMode.reliable ? -7 : mode.index,
          ),
          isTrue,
        );
      }
      client.driver.reset(clientId);
      host.driver.reset(hostId);
      host.events.clear();
      client.events.clear();

      final (nextHostId, nextClientId) = await _connect(host, client);
      expect(nextHostId, greaterThan(hostId));
      expect(nextClientId, greaterThan(clientId));
      expect(client.events.whereType<EnetDriverSent>(), isEmpty);
      expect(
        client.driver.send(clientId, 0, Uint8List(0), DeliveryMode.reliable),
        isFalse,
      );
      expect(
        client.driver.send(
          nextClientId,
          0,
          Uint8List(128),
          DeliveryMode.reliable,
          token: -8,
        ),
        isTrue,
      );
      expect(
        client.driver.send(
          nextClientId,
          2,
          Uint8List(128),
          DeliveryMode.unreliable,
          token: 8,
        ),
        isTrue,
      );
      // Destroying a host invokes packet callbacks during ENet cleanup. Their
      // owner must remain alive, and no completion may outlive the destroyed host.
      client.driver.close();
      client.driver.close();
      expect(client.driver.poll(), isNull);
    },
  );

  test(
    'disconnect before connect cannot reuse its identity for an inbound peer',
    () async {
      final host = endpoint(bound: true);
      final unusedRemote = endpoint(bound: true);
      final client = endpoint();
      final cancelled = host.driver.connect(
        '127.0.0.1',
        unusedRemote.driver.port,
        3,
      );
      // ENet resets a still-connecting peer without producing a terminal event.
      host.driver.disconnect(cancelled);

      final (accepted, _) = await _connect(host, client);
      expect(accepted, greaterThan(cancelled));
      expect(
        host.driver.send(cancelled, 0, Uint8List(0), DeliveryMode.reliable),
        isFalse,
      );
      host.driver.reset(cancelled);
      expect(
        host.driver.send(
          accepted,
          0,
          Uint8List(0),
          DeliveryMode.reliable,
          token: -1,
        ),
        isTrue,
      );
      await _until(() => host.events.whereType<EnetDriverSent>().isNotEmpty, [
        host,
        client,
      ]);
      expect(host.events.whereType<EnetDriverSent>().single.peer, accepted);
    },
  );
}
