import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'relay_protocol.dart';

const _shutdownTimeout = Duration(seconds: 5);
const _pingInterval = Duration(seconds: 20);
const _roomAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const _roomLength = 6;

/// A WebSocket server that relays signaling between WebRTC hosts and clients.
///
/// A host opens a room, and clients that know the room's name join it. The
/// server relays signaling messages between the host and each of its clients
/// until they have connected directly, and it never carries game traffic.
/// Anyone who knows a room's name can ask its host to connect; the host's
/// session decides whom to admit.
///
/// Hosts connect with `WebSocketHostSignaling.connect` and clients with
/// `WebSocketSignalingChannel.join`, using `ws:` or `wss:` URLs for
/// [address], [port], and [path]. Browsers require `wss:` on pages served
/// over HTTPS; terminate TLS at a reverse proxy in front of this server.
final class SignalingServer {
  SignalingServer._(
    this._server, {
    required this.address,
    required this.path,
    required this.maxRooms,
    required this.maxClientsPerRoom,
    required this.maxConnections,
    required this.requestTimeout,
  }) {
    _subscription = _server.listen(
      _request,
      onError: (Object _, StackTrace _) {},
    );
  }

  /// Binds a signaling server, throwing if the address or port is
  /// unavailable.
  ///
  /// Port zero selects an available port; [port] reports the selected value.
  /// The default address accepts only local connections. Use `0.0.0.0` to
  /// accept connections on every IPv4 interface. Only WebSocket upgrades at
  /// [path] are accepted.
  ///
  /// The server holds at most [maxRooms] rooms, [maxClientsPerRoom]
  /// negotiating clients in each room, and [maxConnections] connections in
  /// total. A connection that sends no request within [requestTimeout] is
  /// closed.
  static Future<SignalingServer> bind({
    String address = '127.0.0.1',
    int port = 8080,
    String path = '/signaling',
    int maxRooms = 256,
    int maxClientsPerRoom = 64,
    int maxConnections = 1024,
    Duration requestTimeout = const Duration(seconds: 10),
  }) async {
    if (address.isEmpty) throw ArgumentError.value(address, 'address');
    if (port < 0 || port > 65535) throw ArgumentError.value(port, 'port');
    if (!path.startsWith('/') || path.contains('?') || path.contains('#')) {
      throw ArgumentError.value(path, 'path', 'must be an absolute URL path');
    }
    for (final entry in {
      'maxRooms': maxRooms,
      'maxClientsPerRoom': maxClientsPerRoom,
      'maxConnections': maxConnections,
    }.entries) {
      if (entry.value < 1) {
        throw ArgumentError.value(entry.value, entry.key, 'must be positive');
      }
    }
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'must be positive',
      );
    }
    return SignalingServer._(
      await HttpServer.bind(address, port),
      address: address,
      path: path,
      maxRooms: maxRooms,
      maxClientsPerRoom: maxClientsPerRoom,
      maxConnections: maxConnections,
      requestTimeout: requestTimeout,
    );
  }

  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _subscription;
  final _random = Random.secure();
  final _rooms = <String, _Room>{};
  final _connections = <_Connection>{};
  final _pending = <Future<void>>{};
  var _upgrading = 0;
  var _closed = false;
  Future<void>? _closing;

  /// The interface address supplied to [bind].
  final String address;

  /// The URL path at which connections are accepted.
  final String path;

  /// The largest number of open rooms.
  final int maxRooms;

  /// The largest number of clients negotiating in one room.
  final int maxClientsPerRoom;

  /// The largest number of connections, including ones still upgrading.
  final int maxConnections;

  /// How long a new connection may take to open or join a room.
  final Duration requestTimeout;

  /// The actual listening TCP port.
  int get port => _server.port;

  /// The number of open rooms.
  int get roomCount => _rooms.length;

  /// The number of open connections.
  int get connectionCount => _connections.length;

  void _request(HttpRequest request) {
    late final Future<void> accepting;
    accepting = _accept(request).whenComplete(() => _pending.remove(accepting));
    _pending.add(accepting);
  }

  Future<void> _accept(HttpRequest request) async {
    var reserved = false;
    try {
      final protocols = request.headers
          .value('sec-websocket-protocol')
          ?.split(',')
          .map((protocol) => protocol.trim());
      if (_closed || _connections.length + _upgrading >= maxConnections) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      } else if (request.uri.path != path) {
        request.response.statusCode = HttpStatus.notFound;
      } else if (!WebSocketTransformer.isUpgradeRequest(request) ||
          protocols == null ||
          !protocols.contains(relaySubprotocol)) {
        request.response.statusCode = HttpStatus.badRequest;
      } else {
        _upgrading++;
        reserved = true;
        // Ownership transfers to the connection, including late sockets.
        // ignore: close_sinks
        final socket = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (protocols) =>
              protocols.contains(relaySubprotocol) ? relaySubprotocol : null,
          compression: CompressionOptions.compressionOff,
        );
        _upgrading--;
        reserved = false;
        final connection = _Connection(this, socket);
        if (_closed) {
          await connection.close(WebSocketStatus.goingAway);
        } else {
          _connections.add(connection);
        }
        return;
      }
      await request.response.close().timeout(_shutdownTimeout);
    } on Object {
      if (reserved) _upgrading--;
      // A client can disconnect during either the HTTP response or upgrade.
      try {
        await request.response.close().timeout(_shutdownTimeout);
      } on Object {
        // The HTTP connection is already gone.
      }
    }
  }

  /// Opens a room for [host], returning its name, or the reason it was
  /// refused.
  ({String? room, String? refusal}) _open(String? requested, _Connection host) {
    if (_rooms.length >= maxRooms) {
      return (room: null, refusal: RelayError.full);
    }
    var name = requested;
    if (name == null) {
      do {
        name = String.fromCharCodes([
          for (var index = 0; index < _roomLength; index++)
            _roomAlphabet.codeUnitAt(_random.nextInt(_roomAlphabet.length)),
        ]);
      } while (_rooms.containsKey(name));
    } else if (_rooms.containsKey(name)) {
      return (room: null, refusal: RelayError.roomUnavailable);
    }
    _rooms[name] = _Room(name, host);
    return (room: name, refusal: null);
  }

  /// Stops accepting connections and closes every room and connection.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    await _server.close(force: true);
    await _subscription.cancel();
    await Future.wait(
      _pending.toList(),
    ).timeout(_shutdownTimeout, onTimeout: () => <void>[]);
    await Future.wait([
      for (final connection in _connections.toList())
        connection.close(WebSocketStatus.goingAway),
    ]);
  }
}

final class _Room {
  _Room(this.name, this.host);

  final String name;
  final _Connection host;
  final clients = <int, _Connection>{};
  var nextClient = 1;
}

final class _Connection {
  _Connection(this._server, this._socket) {
    _socket.pingInterval = _pingInterval;
    _timer = Timer(_server.requestTimeout, () => _refuse(RelayError.timeout));
    _subscription = _socket.listen(
      _message,
      onError: (Object _, StackTrace _) => _finish(),
      onDone: _finish,
    );
    // The sink can fail independently of the stream.
    unawaited(
      _socket.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  final SignalingServer _server;
  final WebSocket _socket;
  late final StreamSubscription<Object?> _subscription;
  Timer? _timer;
  _Room? _hosting;
  _Room? _joined;
  int? _client;
  Future<void>? _closing;
  var _closeRequested = false;
  var _finished = false;

  void _message(Object? data) {
    if (_finished) return;
    final RelayMessage message;
    try {
      if (data is! String) throw const FormatException('Binary data.');
      message = RelayMessage.decode(data);
    } on FormatException {
      _refuse(RelayError.protocol);
      return;
    }
    final hosting = _hosting;
    final joined = _joined;
    if (hosting != null) {
      _hostMessage(hosting, message);
    } else if (joined != null) {
      _clientMessage(joined, message);
    } else {
      _request(message);
    }
  }

  void _request(RelayMessage message) {
    _timer?.cancel();
    _timer = null;
    switch (message) {
      case RelayHost(:final room):
        final opened = _server._open(room, this);
        final name = opened.room;
        if (name == null) {
          _refuse(opened.refusal!);
          return;
        }
        _hosting = _server._rooms[name];
        _send(RelayRoom(name));
      case RelayJoin(:final room):
        final target = _server._rooms[room];
        if (target == null) {
          _refuse(RelayError.unknownRoom);
          return;
        }
        if (target.clients.length >= _server.maxClientsPerRoom ||
            target.nextClient > maxRelayClient) {
          _refuse(RelayError.full);
          return;
        }
        final client = target.nextClient++;
        target.clients[client] = this;
        _joined = target;
        _client = client;
        target.host._send(RelayJoined(client));
      default:
        _refuse(RelayError.protocol);
    }
  }

  void _hostMessage(_Room room, RelayMessage message) {
    switch (message) {
      case RelaySignal(:final data, client: final client?):
        // A client that already left receives nothing further.
        room.clients[client]?._send(RelaySignal(data));
      case RelayLeave(:final client):
        unawaited(
          room.clients.remove(client)?.close(WebSocketStatus.normalClosure),
        );
      default:
        _refuse(RelayError.protocol);
    }
  }

  void _clientMessage(_Room room, RelayMessage message) {
    switch (message) {
      case RelaySignal(:final data, client: null):
        room.host._send(RelaySignal(data, client: _client));
      default:
        _refuse(RelayError.protocol);
    }
  }

  void _send(RelayMessage message) {
    if (_finished) return;
    try {
      _socket.add(message.encode());
    } on Object {
      _finish();
    }
  }

  void _refuse(String reason) {
    _send(RelayError(reason));
    unawaited(close(WebSocketStatus.policyViolation));
  }

  Future<void> close(int code) {
    // Set before closing starts, so that finishing does not close again with
    // another code.
    _closeRequested = true;
    return _closing ??= _close(code);
  }

  Future<void> _close(int code) async {
    _finish();
    try {
      await _socket.close(code).timeout(_shutdownTimeout);
    } on Object {
      // Closure is best effort after a network failure.
    }
    await _subscription.cancel();
  }

  /// Leaves the server's bookkeeping once, notifying the other side.
  void _finish() {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    _timer = null;
    _server._connections.remove(this);
    final hosting = _hosting;
    if (hosting != null) {
      _server._rooms.remove(hosting.name);
      for (final client in hosting.clients.values.toList()) {
        unawaited(client.close(WebSocketStatus.goingAway));
      }
      hosting.clients.clear();
    }
    final joined = _joined;
    final client = _client;
    if (joined != null && client != null) {
      if (joined.clients.remove(client) != null) {
        joined.host._send(RelayLeave(client));
      }
    }
    if (!_closeRequested) unawaited(close(WebSocketStatus.normalClosure));
  }
}
