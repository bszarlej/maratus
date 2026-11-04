@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

Future<void> _until(
  bool Function() condition, {
  void Function()? update,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    update?.call();
    if (condition()) return;
    if (DateTime.now().isAfter(deadline)) fail('Socket condition timed out.');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

List<PeerEvent> _drain(MultiplayerPeer peer) => [
  for (var event = peer.poll(); event != null; event = peer.poll()) event,
];

Uri _uri(WebSocketHost host, {String? path}) => Uri(
  scheme: 'ws',
  host: '127.0.0.1',
  port: host.port,
  path: path ?? host.path,
);

void main() {
  Future<WebSocketHost> host({
    QueueLimits outgoing = const QueueLimits(),
  }) async {
    final peer = await WebSocketHost.bind(port: 0, outgoingLimits: outgoing);
    addTearDown(() async {
      peer.close();
      await peer.done;
    });
    return peer;
  }

  WebSocketClient client(Uri uri) {
    final peer = WebSocketClient.connect(uri);
    addTearDown(() async {
      peer.close();
      await peer.done;
    });
    return peer;
  }

  test(
    'native peers preserve copied payload order and close after sends',
    () async {
      final server = await host();
      final joiner = client(_uri(server));
      final serverEvents = <PeerEvent>[];
      final clientEvents = <PeerEvent>[];
      void poll() {
        serverEvents.addAll(_drain(server));
        clientEvents.addAll(_drain(joiner));
      }

      await _until(
        () => serverEvents.isNotEmpty && clientEvents.isNotEmpty,
        update: poll,
      );
      final connection = serverEvents.single.connection;
      expect(serverEvents.single, isA<ConnectionOpened>());
      expect(clientEvents.single, isA<ConnectionOpened>());
      final bytes = Uint8List.fromList([10, 20]);
      expect(connection.send(bytes), isTrue);
      bytes[0] = 99;
      expect(connection.send(Uint8List.fromList([30])), isTrue);
      connection.close();
      await _until(() => clientEvents.last is ConnectionClosed, update: poll);
      expect(clientEvents.whereType<MessageReceived>().map((e) => e.message), [
        [10, 20],
        [30],
      ]);
      expect(
        (clientEvents.last as ConnectionClosed).reason,
        CloseReason.remote,
      );
      expect(serverEvents.whereType<ConnectionClosed>(), isEmpty);
      expect(connection.send(bytes), isFalse);
    },
  );

  test(
    'slow receiver retains outgoing credit until poll and overflow closes',
    () async {
      final server = await host(outgoing: const QueueLimits(maxMessages: 1));
      final joiner = client(_uri(server));
      PeerConnection? sending;
      PeerConnection? receiving;
      await _until(
        () => sending != null && receiving != null,
        update: () {
          sending ??= server.poll()?.connection;
          receiving ??= joiner.poll()?.connection;
        },
      );
      expect(sending!.send(Uint8List.fromList([1, 2])), isTrue);
      await _until(() => receiving!.incoming.messages == 1);
      expect(sending!.outgoing, (messages: 1, bytes: 2));
      expect(sending!.send(Uint8List.fromList([3])), isFalse);
      expect(sending!.closeReason, CloseReason.overflow);
      expect((server.poll()! as ConnectionClosed).reason, CloseReason.overflow);
      final received = <PeerEvent>[];
      await _until(
        () => received.any((e) => e is ConnectionClosed),
        update: () {
          received.addAll(_drain(joiner));
        },
      );
      expect(received.first, isA<MessageReceived>());
      expect(receiving!.incoming, (messages: 0, bytes: 0));
    },
  );

  test(
    'bad endpoint fails without opening and close releases listener port',
    () async {
      final server = await host();
      final joiner = client(_uri(server, path: '/missing'));
      PeerEvent? failure;
      await _until(
        () => failure != null,
        update: () => failure = joiner.poll(),
      );
      expect(failure, isA<ConnectionClosed>());
      expect((failure! as ConnectionClosed).reason, CloseReason.connectFailed);
      expect(joiner.poll(), isNull);
      final port = server.port;
      server.close();
      await server.done;
      final rebound = await WebSocketHost.bind(port: port);
      rebound.close();
      await rebound.done;
    },
  );

  test(
    'malformed WebSocket framing is rejected before payload dispatch',
    () async {
      final server = await host();
      final raw = await WebSocket.connect(
        _uri(server).toString(),
        protocols: ['maratus-v1'],
      );
      addTearDown(() async {
        await raw.close();
      });
      final events = <PeerEvent>[];
      await _until(
        () => events.isNotEmpty,
        update: () => events.addAll(_drain(server)),
      );
      raw.add('text is not a binary transport frame');
      await _until(
        () => events.last is ConnectionClosed,
        update: () => events.addAll(_drain(server)),
      );
      expect(events.whereType<MessageReceived>(), isEmpty);
      expect((events.last as ConnectionClosed).reason, CloseReason.lost);
    },
  );

  test(
    'same sessions exchange typed RPCs with two native clients and shut down',
    () async {
      final builder = ProtocolSchemaBuilder();
      final chat = builder.addRpc(
        const RpcId('chat'),
        const StringCodec(maxLength: 100),
        target: RpcTarget.all,
        local: RpcLocal.include,
      );
      final schema = builder.build();
      final server = await host();
      final firstPeer = client(_uri(server));
      final secondPeer = client(_uri(server));
      final sessions = [
        MultiplayerSession(schema: schema)..host(server),
        MultiplayerSession(schema: schema)..join(firstPeer),
        MultiplayerSession(schema: schema)..join(secondPeer),
      ];
      addTearDown(() {
        for (final session in sessions) {
          session.close();
        }
      });
      final received = List.generate(3, (_) => <(PeerId, String)>[]);
      final entities = <NetworkEntity>[];
      for (var i = 0; i < sessions.length; i++) {
        final session = sessions[i];
        final entity = session.registry.register(
          const EntityId(1),
          owner: PeerId.host,
          authority: PeerId.host,
        );
        entities.add(entity);
        session.registry.markReady(entity.id);
        session.bindRpc(
          entity,
          chat,
          (context, value) => received[i].add((context.sender, value)),
        );
      }
      void update() {
        for (final session in sessions) {
          session.update();
        }
      }

      await _until(
        () =>
            sessions.skip(1).every((s) => s.state == SessionState.ready) &&
            sessions.first.peers.every(sessions.first.isReady),
        update: update,
      );
      expect(sessions[1].localPeer, isNot(sessions[2].localPeer));
      expect(
        sessions[1].callRpc(entities[1], chat, 'hello over sockets'),
        isTrue,
      );
      await _until(
        () => received.every((messages) => messages.isNotEmpty),
        update: update,
      );
      for (final messages in received) {
        expect(messages, [(sessions[1].localPeer!, 'hello over sockets')]);
      }
      sessions.first.close();
      await _until(
        () =>
            sessions.skip(1).every((s) => s.state == SessionState.disconnected),
        update: update,
      );
      expect(sessions[1].disconnectReason, DisconnectReason.remoteClosed);
      expect(sessions[2].disconnectReason, DisconnectReason.remoteClosed);
    },
  );

  test(
    'malformed session payload disconnects only the offending socket',
    () async {
      final server = await host();
      final schema = ProtocolSchemaBuilder().build();
      final session = MultiplayerSession(schema: schema)..host(server);
      addTearDown(session.close);
      final raw = await WebSocket.connect(
        _uri(server).toString(),
        protocols: ['maratus-v1'],
      );
      addTearDown(() async {
        await raw.close();
      });
      final responses = <ProtocolMessage>[];
      final subscription = raw.listen((Object? value) {
        if (value is List<int> && value.first == 0) {
          responses.add(
            ProtocolCodec(
              schema,
            ).decode(Uint8List.fromList(value.sublist(5))).message,
          );
        }
      });
      addTearDown(subscription.cancel);
      raw.add([0, 0, 0, 0, 1, 0xff]);
      await _until(() => responses.isNotEmpty, update: session.update);
      expect(
        (responses.single as GoodbyeMessage).reason,
        GoodbyeReason.protocolViolation,
      );
      expect(session.state, SessionState.hosting);
    },
  );

  test('client rejects invalid options synchronously', () {
    for (final url in [
      'http://localhost',
      'ws:///missing',
      'ws://user:secret@host',
      'ws://host/#fragment',
    ]) {
      expect(
        () => WebSocketClient.connect(Uri.parse(url)),
        throwsArgumentError,
      );
    }
    expect(
      () => WebSocketClient.connect(
        Uri.parse('ws://localhost'),
        connectTimeout: Duration.zero,
      ),
      throwsArgumentError,
    );
  });

  test(
    'standard ws and wss ports can be omitted and dials cancelled',
    () async {
      for (final scheme in ['ws', 'wss']) {
        final peer = client(Uri.parse('$scheme://localhost/netcode'));
        peer.close();
        await peer.done;
        expect(peer.isClosed, isTrue);
        expect(peer.poll(), isNull);
      }
    },
  );
}
