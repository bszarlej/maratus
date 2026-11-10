import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:maratus/maratus.dart';

import 'enet_driver.dart';

/// Creates an ENet host backed by the bundled native code asset.
EnetDriver createEnetDriver({
  required String? address,
  required int port,
  required int maxConnections,
  required int channelCount,
  required int maxPacketBytes,
  required int maxWaitingBytes,
}) {
  return using((arena) {
    final host = _create(
      address?.toNativeUtf8(allocator: arena) ?? nullptr,
      port,
      maxConnections,
      channelCount,
      maxPacketBytes,
      maxWaitingBytes,
    );
    if (host == nullptr) {
      throw StateError('ENet could not create the UDP host.');
    }
    return _NativeEnetDriver(host);
  });
}

final class _NativeEnetDriver implements EnetDriver, Finalizable {
  _NativeEnetDriver(this._host) {
    _finalizer.attach(this, _host, detach: this);
  }

  static final _finalizer = NativeFinalizer(Native.addressOf(_destroy));
  Pointer<Void> _host;

  void _checkOpen() {
    if (_host == nullptr) throw StateError('The ENet driver is closed.');
  }

  @override
  int get port {
    _checkOpen();
    return _port(_host);
  }

  @override
  int connect(String address, int port, int channelCount) {
    _checkOpen();
    return using((arena) {
      final id = _connect(
        _host,
        address.toNativeUtf8(allocator: arena),
        port,
        channelCount,
      );
      if (id == 0) throw StateError('ENet could not start the connection.');
      return id;
    });
  }

  @override
  EnetDriverEvent? poll() {
    if (_host == nullptr) return null;
    final event = _poll(_host).ref;
    switch (event.type) {
      case 0:
        return null;
      case 1:
        return EnetDriverConnected(event.peer, event.channel);
      case 2:
        try {
          return EnetDriverReceived(
            event.peer,
            event.channel,
            event.length == 0
                ? Uint8List(0)
                : Uint8List.fromList(event.data.asTypedList(event.length)),
          );
        } finally {
          _releasePacket(_host);
        }
      case 3:
        return EnetDriverDisconnected(event.peer, event.token != 0);
      case 4:
        return EnetDriverSent(event.peer, event.token);
      default:
        throw StateError('ENet failed while servicing the UDP host.');
    }
  }

  @override
  bool send(
    int peer,
    int channel,
    Uint8List bytes,
    DeliveryMode mode, {
    int? token,
  }) {
    if (_host == nullptr) return false;
    return using((arena) {
      // ENet copies these bytes into an owned packet before this arena closes.
      final data = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
      data.asTypedList(bytes.length).setAll(0, bytes);
      final result = _send(
        _host,
        peer,
        channel,
        data,
        bytes.length,
        mode.index,
        token == null ? 0 : 1,
        token ?? 0,
      );
      if (result < 0) throw StateError('ENet could not queue the packet.');
      return result == 1;
    });
  }

  @override
  void disconnect(int peer) {
    if (_host != nullptr) _disconnect(_host, peer);
  }

  @override
  void reset(int peer) {
    if (_host != nullptr) _reset(_host, peer);
  }

  @override
  void close() {
    if (_host == nullptr) return;
    _finalizer.detach(this);
    _destroy(_host);
    _host = nullptr;
  }
}

final class _NativeEvent extends Struct {
  @Int32()
  external int type;

  @Int32()
  external int channel;

  @Uint64()
  external int peer;

  @Int64()
  external int token;

  external Pointer<Uint8> data;

  @Size()
  external int length;
}

@Native<Pointer<Void> Function(Pointer<Utf8>, Uint16, Size, Size, Size, Size)>(
  symbol: 'maratus_enet_create',
)
external Pointer<Void> _create(
  Pointer<Utf8> address,
  int port,
  int maxConnections,
  int channelCount,
  int maxPacketBytes,
  int maxWaitingBytes,
);

@Native<Uint16 Function(Pointer<Void>)>(symbol: 'maratus_enet_port')
external int _port(Pointer<Void> host);

@Native<Uint64 Function(Pointer<Void>, Pointer<Utf8>, Uint16, Size)>(
  symbol: 'maratus_enet_connect',
)
external int _connect(
  Pointer<Void> host,
  Pointer<Utf8> address,
  int port,
  int channelCount,
);

@Native<Pointer<_NativeEvent> Function(Pointer<Void>)>(
  symbol: 'maratus_enet_poll',
)
external Pointer<_NativeEvent> _poll(Pointer<Void> host);

@Native<Void Function(Pointer<Void>)>(symbol: 'maratus_enet_release_packet')
external void _releasePacket(Pointer<Void> host);

@Native<
  Int32 Function(
    Pointer<Void>,
    Uint64,
    Uint8,
    Pointer<Uint8>,
    Size,
    Int32,
    Int32,
    Int64,
  )
>(symbol: 'maratus_enet_send')
external int _send(
  Pointer<Void> host,
  int peer,
  int channel,
  Pointer<Uint8> data,
  int length,
  int mode,
  int hasToken,
  int token,
);

@Native<Void Function(Pointer<Void>, Uint64)>(symbol: 'maratus_enet_disconnect')
external void _disconnect(Pointer<Void> host, int peer);

@Native<Void Function(Pointer<Void>, Uint64)>(symbol: 'maratus_enet_reset')
external void _reset(Pointer<Void> host, int peer);

@Native<Void Function(Pointer<Void>)>(symbol: 'maratus_enet_destroy')
external void _destroy(Pointer<Void> host);
