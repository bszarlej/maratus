import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'web_socket_driver_base.dart';

const _shutdownTimeout = Duration(seconds: 5);

/// Native platforms can accept incoming connections.
bool get supportsWebSocketHosting => true;

/// Opens a native socket with a cancellable HTTP opening handshake.
WebSocketDial connectWebSocket(Uri uri, {required Duration timeout}) =>
    _IoDial(uri, timeout);

final class _IoDial implements WebSocketDial {
  _IoDial(Uri uri, Duration timeout) {
    _client.connectionTimeout = timeout;
    _timer = Timer(timeout, () {
      _abort(
        TimeoutException('WebSocket opening handshake timed out.', timeout),
      );
    });
    _connecting = _connect(uri);
    unawaited(_connecting);
  }

  final _client = HttpClient();
  final _ready = Completer<WebSocketDriver>();
  late final Timer _timer;
  late final Future<void> _connecting;

  @override
  Future<WebSocketDriver> get ready => _ready.future;

  Future<void> _connect(Uri uri) async {
    try {
      // Ownership transfers to _IoWebSocket, including rejected/late sockets.
      // ignore: close_sinks
      final socket = await WebSocket.connect(
        uri.toString(),
        protocols: [webSocketProtocol],
        compression: CompressionOptions.compressionOff,
        customClient: _client,
      );
      final driver = _IoWebSocket(socket);
      if (_ready.isCompleted) {
        await driver.close();
      } else if (socket.protocol != webSocketProtocol) {
        unawaited(driver.close());
        _ready.completeError(
          const WebSocketException('The host did not select maratus-v1.'),
        );
      } else {
        _ready.complete(driver);
      }
    } on Object catch (error, stack) {
      if (!_ready.isCompleted) _ready.completeError(error, stack);
    } finally {
      _timer.cancel();
      _client.close(force: true);
    }
  }

  void _abort(Object error) {
    if (_ready.isCompleted) return;
    _timer.cancel();
    _client.close(force: true);
    _ready.completeError(error);
  }

  @override
  Future<void> cancel() async {
    _abort(StateError('Connection cancelled.'));
    // HttpClient.close aborts the request. Also await any socket whose upgrade
    // raced that cancellation so its driver can finish closing.
    await _connecting.timeout(_shutdownTimeout, onTimeout: () {});
  }
}

/// Binds an HTTP listener that only accepts the transport's endpoint.
Future<WebSocketListener> bindWebSocket({
  required String address,
  required int port,
  required String path,
  required int maxConnections,
}) async => _IoListener(
  await HttpServer.bind(address, port),
  path: path,
  maxConnections: maxConnections,
);

final class _IoWebSocket implements WebSocketDriver {
  _IoWebSocket(this._socket, {void Function()? onDone}) : _onDone = onDone {
    _subscription = _socket.listen(
      (Object? message) {
        if (!_messages.isClosed && message != null) _messages.add(message);
      },
      onError: (Object error, StackTrace stack) {
        if (!_messages.isClosed) _messages.addError(error, stack);
      },
      onDone: _finish,
    );
    // The stream and sink can fail independently. Observe the sink's future
    // even when the caller has not explicitly closed it yet.
    unawaited(
      _socket.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  final WebSocket _socket;
  final void Function()? _onDone;
  final _messages = StreamController<Object>(sync: true);
  final _ended = Completer<void>();
  late final StreamSubscription<Object?> _subscription;
  Future<void>? _closing;
  var _finished = false;

  @override
  bool get isOpen =>
      !_finished && _closing == null && _socket.readyState == WebSocket.open;

  @override
  Stream<Object> get messages => _messages.stream;

  @override
  int? get closeCode => _socket.closeCode;

  @override
  void send(Uint8List message) => _socket.add(message);

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      // Closing the sink only finishes writing its frames. Keep reading until
      // the closing handshake ends too: cancelling the input subscription as
      // soon as the sink finishes can truncate the remote peer's final data.
      // Bound both operations with one deadline for stalled connections.
      await Future.wait<void>([
        _socket.close(WebSocketStatus.normalClosure).then<void>((_) {}),
        _ended.future,
      ]).timeout(_shutdownTimeout);
    } on Object {
      // Closure is best effort after a network failure or a stalled receiver.
    } finally {
      await _subscription.cancel();
      _finish();
    }
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    _ended.complete();
    _onDone?.call();
    unawaited(_messages.close());
  }
}

final class _IoListener implements WebSocketListener {
  _IoListener(
    this._server, {
    required this.path,
    required this.maxConnections,
  }) {
    _subscription = _server.listen(
      (request) {
        late final Future<void> accepting;
        accepting = _accept(
          request,
        ).whenComplete(() => _pending.remove(accepting));
        _pending.add(accepting);
        unawaited(accepting);
      },
      onError: (Object error, StackTrace stack) {
        if (!_connections.isClosed) _connections.addError(error, stack);
      },
      onDone: () {
        _closed = true;
        if (!_connections.isClosed) unawaited(_connections.close());
      },
    );
  }

  final HttpServer _server;
  final String path;
  final int maxConnections;
  final _connections = StreamController<WebSocketDriver>(sync: true);
  final _pending = <Future<void>>{};
  late final StreamSubscription<HttpRequest> _subscription;
  var _activeConnections = 0;
  var _closed = false;
  Future<void>? _closing;

  @override
  int get port => _server.port;

  @override
  Stream<WebSocketDriver> get connections => _connections.stream;

  Future<void> _accept(HttpRequest request) async {
    var reserved = false;
    try {
      final protocols = request.headers
          .value('sec-websocket-protocol')
          ?.split(',')
          .map((protocol) => protocol.trim());
      if (_closed || _activeConnections >= maxConnections) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      } else if (request.uri.path != path) {
        request.response.statusCode = HttpStatus.notFound;
      } else if (!WebSocketTransformer.isUpgradeRequest(request) ||
          protocols == null ||
          !protocols.contains(webSocketProtocol)) {
        request.response.statusCode = HttpStatus.badRequest;
      } else {
        _activeConnections++;
        reserved = true;
        // Ownership transfers to the driver, including late accepted sockets.
        // ignore: close_sinks
        final socket = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (protocols) =>
              protocols.contains(webSocketProtocol) ? webSocketProtocol : null,
          compression: CompressionOptions.compressionOff,
        );
        final driver = _IoWebSocket(socket, onDone: () => _activeConnections--);
        reserved = false;
        if (_closed) {
          await driver.close();
        } else {
          _connections.add(driver);
        }
        return;
      }
      await request.response.close().timeout(_shutdownTimeout);
    } on Object {
      if (reserved) _activeConnections--;
      // A client can disconnect during either the HTTP response or upgrade.
      // That failure belongs to this request, not to the listener.
      try {
        await request.response.close().timeout(_shutdownTimeout);
      } on Object {
        // The HTTP connection is already gone.
      }
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    await _server.close(force: true);
    await _subscription.cancel();
    // Closing the HTTP server aborts pending upgrades. A successfully detached
    // socket is instead closed by _accept after observing _closed.
    await Future.wait(
      _pending.toList(),
    ).timeout(_shutdownTimeout, onTimeout: () => <void>[]);
    if (!_connections.isClosed) unawaited(_connections.close());
  }
}
