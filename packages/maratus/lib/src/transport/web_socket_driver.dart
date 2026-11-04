import 'web_socket_driver_base.dart';
import 'web_socket_driver_stub.dart'
    if (dart.library.io) 'web_socket_driver_io.dart'
    if (dart.library.js_interop) 'web_socket_driver_web.dart'
    as platform;

export 'web_socket_driver_base.dart';

/// Whether this platform can accept incoming WebSocket connections.
bool get supportsWebSocketHosting => platform.supportsWebSocketHosting;

/// Opens a socket, failing if the opening handshake exceeds [timeout].
WebSocketDial connectWebSocket(Uri uri, {required Duration timeout}) =>
    platform.connectWebSocket(uri, timeout: timeout);

/// Starts a native listener for the specified path and subprotocol.
Future<WebSocketListener> bindWebSocket({
  required String address,
  required int port,
  required String path,
  required int maxConnections,
}) => platform.bindWebSocket(
  address: address,
  port: port,
  path: path,
  maxConnections: maxConnections,
);
