@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:maratus/maratus.dart';
import 'package:maratus_webrtc/maratus_webrtc.dart';
import 'package:maratus_webrtc/signaling_server.dart';
import 'package:maratus_webrtc/src/signaling_protocol.dart';
import 'package:maratus_webrtc/src/webrtc_driver.dart';
import 'package:maratus_webrtc/src/webrtc_peer_base.dart';
import 'package:test/test.dart';

import 'support/fake_webrtc_driver.dart';

Future<void> _until(
  bool Function() condition, {
  FutureOr<void> Function()? update,
}) async {
  final deadline = Stopwatch()..start();
  while (true) {
    await update?.call();
    if (condition()) return;
    if (deadline.elapsed > const Duration(seconds: 10)) {
      fail('Signaling condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Collects a channel's messages, errors, and end.
final class _Inbox {
  _Inbox(SignalingChannel channel) {
    channel.messages.listen(
      messages.add,
      onError: errors.add,
      onDone: () => ended = true,
    );
  }

  final messages = <String>[];
  final errors = <Object>[];
  var ended = false;
}

/// Collects the channels a host receives.
final class _Lobby {
  _Lobby(this.signaling) {
    signaling.clients.listen(
      (channel) => channels.add((channel, _Inbox(channel))),
      onDone: () => ended = true,
    );
  }

  final WebSocketHostSignaling signaling;
  final channels = <(SignalingChannel, _Inbox)>[];
  var ended = false;
}

Matcher _refused(String reason) => isA<SignalingException>().having(
  (error) => error.message,
  'message',
  reason,
);

void main() {
  Future<SignalingServer> bind({
    int maxRooms = 256,
    int maxClientsPerRoom = 64,
    int maxConnections = 1024,
    Duration requestTimeout = const Duration(seconds: 10),
  }) async {
    final server = await SignalingServer.bind(
      port: 0,
      maxRooms: maxRooms,
      maxClientsPerRoom: maxClientsPerRoom,
      maxConnections: maxConnections,
      requestTimeout: requestTimeout,
    );
    addTearDown(server.close);
    return server;
  }

  Uri url(SignalingServer server) =>
      Uri.parse('ws://127.0.0.1:${server.port}/signaling');

  Future<_Lobby> open(SignalingServer server, {String? room}) async {
    final signaling = await WebSocketHostSignaling.connect(
      url(server),
      room: room,
    );
    addTearDown(signaling.close);
    return _Lobby(signaling);
  }

  (SignalingChannel, _Inbox) join(SignalingServer server, String room) {
    final channel = WebSocketSignalingChannel.join(url(server), room: room);
    addTearDown(channel.close);
    return (channel, _Inbox(channel));
  }

  /// Connects a raw socket speaking the relay subprotocol.
  Future<(WebSocket, List<Object?>, Completer<void>)> raw(
    SignalingServer server,
  ) async {
    final socket = await WebSocket.connect(
      url(server).toString(),
      protocols: const ['maratus-signaling-v1'],
    );
    addTearDown(() => socket.close());
    final received = <Object?>[];
    final closed = Completer<void>();
    socket.listen(received.add, onDone: closed.complete);
    return (socket, received, closed);
  }

  test('a host opens a generated room', () async {
    final server = await bind();
    final lobby = await open(server);
    expect(lobby.signaling.room, matches(RegExp(r'^[A-HJ-NP-Z2-9]{6}$')));
    expect(server.roomCount, 1);
  });

  test('a host can request a room name that is not open', () async {
    final server = await bind();
    final lobby = await open(server, room: 'lobby');
    expect(lobby.signaling.room, 'lobby');
    await expectLater(
      WebSocketHostSignaling.connect(url(server), room: 'lobby'),
      throwsA(_refused('room-unavailable')),
    );
    expect(server.roomCount, 1);
  });

  test('signaling relays messages both ways in order', () async {
    final server = await bind();
    final lobby = await open(server);
    final (client, clientInbox) = join(server, lobby.signaling.room);
    client
      ..send('first')
      ..send('second');
    await _until(() => lobby.channels.isNotEmpty);
    final (channel, hostInbox) = lobby.channels.single;
    await _until(() => hostInbox.messages.length == 2);
    expect(hostInbox.messages, ['first', 'second']);
    channel
      ..send('third')
      ..send('fourth');
    await _until(() => clientInbox.messages.length == 2);
    expect(clientInbox.messages, ['third', 'fourth']);
    expect(clientInbox.errors, isEmpty);
    expect(hostInbox.errors, isEmpty);
  });

  test('closing either end of a client ends the other end', () async {
    final server = await bind();
    final lobby = await open(server);
    // Join one at a time, since the server numbers clients in arrival order.
    final (first, _) = join(server, lobby.signaling.room);
    await _until(() => lobby.channels.length == 1);
    final (_, secondInbox) = join(server, lobby.signaling.room);
    await _until(() => lobby.channels.length == 2);
    first.close();
    final firstHostInbox = lobby.channels.first.$2;
    await _until(() => firstHostInbox.ended);
    lobby.channels.last.$1.close();
    await _until(() => secondInbox.ended);
    expect(secondInbox.errors, isEmpty);
    await _until(() => server.connectionCount == 1);
  });

  test('joining an unknown room fails the channel', () async {
    final server = await bind();
    final (_, inbox) = join(server, 'nowhere');
    await _until(() => inbox.ended);
    expect(inbox.errors, [_refused('unknown-room')]);
  });

  test('a full room refuses clients until one leaves', () async {
    final server = await bind(maxClientsPerRoom: 1);
    final lobby = await open(server);
    final (first, _) = join(server, lobby.signaling.room);
    await _until(() => lobby.channels.length == 1);
    final (_, refused) = join(server, lobby.signaling.room);
    await _until(() => refused.ended);
    expect(refused.errors, [_refused('full')]);
    first.close();
    await _until(() => lobby.channels.single.$2.ended);
    join(server, lobby.signaling.room);
    await _until(() => lobby.channels.length == 2);
  });

  test('closing a room ends its clients and frees its name', () async {
    final server = await bind();
    final lobby = await open(server, room: 'party');
    final (_, inbox) = join(server, 'party');
    await _until(() => lobby.channels.isNotEmpty);
    lobby.signaling.close();
    await _until(() => inbox.ended && lobby.ended);
    expect(lobby.channels.single.$2.ended, isTrue);
    await _until(() => server.roomCount == 0);
    final (_, late) = join(server, 'party');
    await _until(() => late.ended);
    expect(late.errors, [_refused('unknown-room')]);
    expect((await open(server, room: 'party')).signaling.room, 'party');
  });

  test('the server refuses rooms beyond its limit', () async {
    final server = await bind(maxRooms: 1);
    await open(server);
    await expectLater(
      WebSocketHostSignaling.connect(url(server)),
      throwsA(_refused('full')),
    );
  });

  final violations = <String, List<Object>>{
    'invalid JSON': ['{'],
    'binary data': [
      [1, 2, 3],
    ],
    'a client message before a request': [
      jsonEncode({'type': 'signal', 'data': 'x'}),
    ],
    'a second request': [
      jsonEncode({'type': 'host'}),
      jsonEncode({'type': 'host'}),
    ],
    'a host signal without a client': [
      jsonEncode({'type': 'host'}),
      jsonEncode({'type': 'signal', 'data': 'x'}),
    ],
  };
  for (final MapEntry(key: name, value: messages) in violations.entries) {
    test('$name is refused as a protocol violation', () async {
      final server = await bind();
      final (socket, received, closed) = await raw(server);
      for (final message in messages) {
        socket.add(message);
      }
      await closed.future.timeout(const Duration(seconds: 5));
      expect(
        received.last,
        jsonEncode({'type': 'error', 'reason': 'protocol'}),
      );
      expect(socket.closeCode, WebSocketStatus.policyViolation);
      await _until(() => server.connectionCount == 0);
    });
  }

  test('a client cannot act as the host of its room', () async {
    final server = await bind();
    final lobby = await open(server);
    final (socket, received, closed) = await raw(server);
    socket
      ..add(jsonEncode({'type': 'join', 'room': lobby.signaling.room}))
      ..add(jsonEncode({'type': 'leave', 'client': 1}));
    await closed.future.timeout(const Duration(seconds: 5));
    expect(received.last, jsonEncode({'type': 'error', 'reason': 'protocol'}));
    await _until(() => lobby.channels.single.$2.ended);
  });

  test('a connection without a request is closed', () async {
    final server = await bind(
      requestTimeout: const Duration(milliseconds: 100),
    );
    final (_, received, closed) = await raw(server);
    await closed.future.timeout(const Duration(seconds: 5));
    expect(received, [
      jsonEncode({'type': 'error', 'reason': 'timeout'}),
    ]);
  });

  test('requests outside the endpoint are refused', () async {
    final server = await bind(maxConnections: 1);
    Future<WebSocket> connect(String path, {bool protocol = true}) =>
        WebSocket.connect(
          'ws://127.0.0.1:${server.port}$path',
          protocols: protocol ? const ['maratus-signaling-v1'] : null,
        );
    await expectLater(connect('/other'), throwsA(isA<WebSocketException>()));
    await expectLater(
      connect('/signaling', protocol: false),
      throwsA(isA<WebSocketException>()),
    );
    await raw(server);
    await expectLater(
      connect('/signaling'),
      throwsA(isA<WebSocketException>()),
    );
  });

  test('servers that do not speak the protocol are rejected', () async {
    final other = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => other.close(force: true));
    other.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(null, onDone: socket.close);
    });
    final uri = Uri.parse('ws://127.0.0.1:${other.port}/signaling');
    await expectLater(
      WebSocketHostSignaling.connect(uri),
      throwsA(isA<SignalingException>()),
    );
    final inbox = _Inbox(WebSocketSignalingChannel.join(uri, room: 'room'));
    await _until(() => inbox.ended);
    expect(inbox.errors.single, isA<SignalingException>());
  });

  test('connecting to an unresponsive server times out', () async {
    final silent = await ServerSocket.bind('127.0.0.1', 0);
    final accepted = <Socket>[];
    silent.listen(accepted.add);
    addTearDown(() async {
      for (final socket in accepted) {
        socket.destroy();
      }
      await silent.close();
    });
    final uri = Uri.parse('ws://127.0.0.1:${silent.port}/signaling');
    const timeout = Duration(milliseconds: 200);
    await expectLater(
      WebSocketHostSignaling.connect(uri, timeout: timeout),
      throwsA(isA<TimeoutException>()),
    );
    final inbox = _Inbox(
      WebSocketSignalingChannel.join(uri, room: 'room', timeout: timeout),
    );
    await _until(() => inbox.ended);
    expect(inbox.errors.single, isA<TimeoutException>());
  });

  test('invalid arguments are rejected before connecting', () {
    final uri = Uri.parse('ws://127.0.0.1:1/signaling');
    expect(
      () => WebSocketHostSignaling.connect(uri, room: 'a b'),
      throwsArgumentError,
    );
    expect(
      () => WebSocketHostSignaling.connect(uri, timeout: Duration.zero),
      throwsArgumentError,
    );
    expect(
      () => WebSocketSignalingChannel.join(uri, room: ''),
      throwsArgumentError,
    );
    expect(() => SignalingServer.bind(path: 'signaling'), throwsArgumentError);
    expect(() => SignalingServer.bind(maxRooms: 0), throwsArgumentError);
    expect(() => SignalingServer.bind(port: 65536), throwsArgumentError);
    expect(
      () => SignalingServer.bind(requestTimeout: Duration.zero),
      throwsArgumentError,
    );
  });

  test('oversized messages are rejected before sending', () async {
    final server = await bind();
    final lobby = await open(server);
    final (client, _) = join(server, lobby.signaling.room);
    await _until(() => lobby.channels.isNotEmpty);
    final oversized = 'x' * (maxSignalingMessageLength + 1);
    expect(() => client.send(oversized), throwsArgumentError);
    expect(() => lobby.channels.single.$1.send(oversized), throwsArgumentError);
    client.send('still connected');
    await _until(() => lobby.channels.single.$2.messages.isNotEmpty);
  });

  test('closing the server ends hosts and their clients', () async {
    final server = await bind();
    final lobby = await open(server);
    final (_, inbox) = join(server, lobby.signaling.room);
    await _until(() => lobby.channels.isNotEmpty);
    await server.close();
    await _until(() => lobby.ended && inbox.ended);
    expect(server.connectionCount, 0);
    expect(server.roomCount, 0);
  });

  test('transport engines negotiate through a signaling server', () async {
    final server = await bind();
    final lobby = await WebSocketHostSignaling.connect(url(server));
    final clock = ManualClock();
    final hostDriver = FakeWebRtcDriver();
    final clientDriver = FakeWebRtcDriver();
    final host = WebRtcPeerBase.host(
      driver: hostDriver,
      signaling: lobby,
      clock: clock,
    );
    final client = WebRtcPeerBase.client(
      driver: clientDriver,
      signaling: WebSocketSignalingChannel.join(url(server), room: lobby.room),
      clock: clock,
    );
    addTearDown(() async {
      host.close();
      client.close();
      clock.advance(const Duration(seconds: 3));
      await Future.wait([host.done, client.done]);
    });
    void step() => clock.advance(const Duration(milliseconds: 2));

    clientDriver.events
      ..add(const WebRtcDriverDescription(1, 'offer'))
      ..add(const WebRtcDriverCandidate(1, 'candidate:client', '0'));
    await _until(() => hostDriver.candidates.isNotEmpty, update: step);
    expect(hostDriver.offers.single.sdp, 'offer');
    hostDriver.events
      ..add(const WebRtcDriverDescription(1, 'answer'))
      ..add(const WebRtcDriverCandidate(1, 'candidate:host', '0'));
    await _until(() => clientDriver.candidates.isNotEmpty, update: step);
    expect(clientDriver.answers.single.sdp, 'answer');

    hostDriver.openLanes(1, 2);
    clientDriver.openLanes(1, 2);
    step();
    expect(host.poll(), isA<ConnectionOpened>());
    expect(client.poll(), isA<ConnectionOpened>());
    // Both ends close the client's signaling once connected.
    await _until(() => server.connectionCount == 1);
    expect(server.roomCount, 1);
  });

  test('a refused offer fails a client through the server', () async {
    final server = await bind();
    final lobby = await WebSocketHostSignaling.connect(url(server));
    final clock = ManualClock();
    final host = WebRtcPeerBase.host(
      driver: FakeWebRtcDriver(),
      signaling: lobby,
      clock: clock,
    );
    final client = WebRtcPeerBase.client(
      driver: FakeWebRtcDriver()
        ..events.add(const WebRtcDriverDescription(1, 'offer')),
      signaling: WebSocketSignalingChannel.join(url(server), room: lobby.room),
      channelCount: 2,
      clock: clock,
    );
    addTearDown(() async {
      host.close();
      client.close();
      await Future.wait([host.done, client.done]);
    });
    PeerEvent? event;
    await _until(
      () => (event ??= client.poll()) != null,
      update: () => clock.advance(const Duration(milliseconds: 2)),
    );
    expect(
      event,
      isA<ConnectionClosed>().having(
        (event) => event.reason,
        'reason',
        CloseReason.connectFailed,
      ),
    );
    expect(host.poll(), isNull);
  });
}
