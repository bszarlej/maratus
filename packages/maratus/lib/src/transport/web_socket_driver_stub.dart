import 'web_socket_driver_base.dart';

/// Whether this platform can host WebSocket connections.
bool get supportsWebSocketHosting => false;

/// Reports that WebSocket connections are unavailable on this platform.
WebSocketDial connectWebSocket(Uri uri, {required Duration timeout}) =>
    _UnsupportedDial();

final class _UnsupportedDial implements WebSocketDial {
  @override
  Future<WebSocketDriver> get ready =>
      Future.error(UnsupportedError('WebSockets are not supported.'));

  @override
  Future<void> cancel() async {}
}

/// Reports that WebSocket hosting is unavailable on this platform.
Future<WebSocketListener> bindWebSocket({
  required String address,
  required int port,
  required String path,
  required int maxConnections,
}) => Future.error(UnsupportedError('WebSocket hosting is not supported.'));
