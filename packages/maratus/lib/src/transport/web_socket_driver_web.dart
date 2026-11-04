import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'web_socket_driver_base.dart';

/// Browsers only create outgoing WebSocket connections.
bool get supportsWebSocketHosting => false;

/// Starts a browser-managed connection and its cancellable opening deadline.
WebSocketDial connectWebSocket(Uri uri, {required Duration timeout}) =>
    _BrowserWebSocket(uri, timeout);

/// Reports that browsers cannot accept incoming WebSocket connections.
Future<WebSocketListener> bindWebSocket({
  required String address,
  required int port,
  required String path,
  required int maxConnections,
}) => Future.error(UnsupportedError('Browsers cannot host WebSockets.'));

final class _BrowserWebSocket implements WebSocketDriver, WebSocketDial {
  _BrowserWebSocket(Uri uri, Duration timeout) {
    try {
      final socket = _socket = web.WebSocket(
        uri.toString(),
        webSocketProtocol.toJS,
      )..binaryType = 'arraybuffer';
      socket.onopen = ((web.Event _) {
        if (_finished) return;
        _timer?.cancel();
        if (socket.protocol != webSocketProtocol) {
          _fail(StateError('The host did not select maratus-v1.'));
        } else if (!_ready.isCompleted) {
          _ready.complete(this);
        }
      }).toJS;
      socket.onmessage = ((web.MessageEvent event) {
        if (_finished) return;
        final data = event.data;
        if (data.isA<JSArrayBuffer>()) {
          _messages.add((data as JSArrayBuffer).toDart.asUint8List());
        } else if (data.isA<JSString>()) {
          _messages.add((data as JSString).toDart);
        } else {
          _fail(StateError('Unsupported WebSocket message type.'));
        }
      }).toJS;
      socket.onerror = ((web.Event _) {
        _fail(StateError('The browser could not communicate with the host.'));
      }).toJS;
      socket.onclose = ((web.CloseEvent event) {
        _closeCode = event.code;
        if (!_ready.isCompleted) {
          _ready.completeError(StateError('WebSocket connection failed.'));
        }
        _finish();
      }).toJS;
      _timer = Timer(timeout, () {
        _fail(
          TimeoutException('WebSocket opening handshake timed out.', timeout),
        );
      });
    } on Object catch (error, stack) {
      _ready.completeError(error, stack);
      _finish();
    }
  }

  final _ready = Completer<WebSocketDriver>();
  // Delivery may synchronously make the engine close this driver, so keep
  // stream notification outside the browser's event callback.
  final _messages = StreamController<Object>();
  web.WebSocket? _socket;
  Timer? _timer;
  int? _closeCode;
  var _finished = false;

  @override
  bool get isOpen => !_finished && _socket?.readyState == web.WebSocket.OPEN;

  @override
  Future<WebSocketDriver> get ready => _ready.future;

  @override
  Stream<Object> get messages => _messages.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  void send(Uint8List message) {
    final socket = _socket;
    if (_finished ||
        socket == null ||
        socket.readyState != web.WebSocket.OPEN) {
      throw StateError('WebSocket is not open.');
    }
    socket.send(message.toJS);
  }

  void _fail(Object error) {
    if (_finished) return;
    if (!_ready.isCompleted) {
      _ready.completeError(error);
    } else {
      _messages.addError(error);
    }
    unawaited(close());
  }

  @override
  Future<void> cancel() async {
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Connection cancelled.'));
      await close();
    }
  }

  @override
  Future<void> close() async {
    if (_finished) return;
    try {
      // Browsers continue draining already enqueued messages independently of
      // these event handlers. They expose no force-close or completion future.
      _socket?.close(1000);
    } on Object {
      // Closing a failed connection must still release our handlers and timer.
    }
    _finish();
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    final socket = _socket;
    if (socket != null) {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onclose = null;
    }
    _socket = null;
    unawaited(_messages.close());
  }
}
