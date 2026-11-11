import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ice_server.dart';
import 'webrtc_driver.dart';

/// Native platforms use the bundled libdatachannel code asset.
bool get supportsWebRtc => true;

/// Creates a driver backed by the bundled libdatachannel code asset.
///
/// Each connection may hold at most [maxQueuedBytes] of received data that
/// the transport has not polled yet.
WebRtcDriver createWebRtcDriver({required int maxQueuedBytes}) {
  final handle = _create(maxQueuedBytes);
  if (handle == nullptr) {
    throw StateError('libdatachannel could not create the WebRTC driver.');
  }
  return _NativeWebRtcDriver(handle);
}

final class _NativeWebRtcDriver implements WebRtcDriver, Finalizable {
  _NativeWebRtcDriver(this._handle) {
    _finalizer.attach(this, _handle, detach: this);
  }

  static final _finalizer = NativeFinalizer(Native.addressOf(_destroy));
  Pointer<Void> _handle;

  Pointer<Void> get _open {
    if (_handle == nullptr) throw StateError('The WebRTC driver is closed.');
    return _handle;
  }

  @override
  int open(int laneCount, List<IceServer> iceServers) {
    final handle = _open;
    final urls = [
      for (final server in iceServers)
        for (final url in server.urls)
          (url: url, username: server.username, credential: server.credential),
    ];
    return using((arena) {
      final count = urls.isEmpty ? 1 : urls.length;
      final addresses = arena<Pointer<Utf8>>(count);
      final usernames = arena<Pointer<Utf8>>(count);
      final credentials = arena<Pointer<Utf8>>(count);
      for (final (index, server) in urls.indexed) {
        addresses[index] = server.url.toNativeUtf8(allocator: arena);
        usernames[index] =
            server.username?.toNativeUtf8(allocator: arena) ?? nullptr;
        credentials[index] =
            server.credential?.toNativeUtf8(allocator: arena) ?? nullptr;
      }
      final connection = _openConnection(
        handle,
        laneCount,
        addresses,
        usernames,
        credentials,
        urls.length,
      );
      if (connection == 0) {
        throw StateError('libdatachannel could not create the connection.');
      }
      return connection;
    });
  }

  @override
  void createOffer(int connection) {
    if (_createOffer(_open, connection) != 0) {
      throw StateError('libdatachannel could not create the offer.');
    }
  }

  @override
  void acceptOffer(int connection, String sdp) {
    final handle = _open;
    using((arena) {
      if (_acceptOffer(
            handle,
            connection,
            sdp.toNativeUtf8(allocator: arena),
          ) !=
          0) {
        throw StateError('libdatachannel could not accept the offer.');
      }
    });
  }

  @override
  void acceptAnswer(int connection, String sdp) {
    final handle = _open;
    using((arena) {
      if (_acceptAnswer(
            handle,
            connection,
            sdp.toNativeUtf8(allocator: arena),
          ) !=
          0) {
        throw StateError('libdatachannel could not accept the answer.');
      }
    });
  }

  @override
  void addCandidate(int connection, String candidate, String? mid) {
    final handle = _open;
    using((arena) {
      // An unusable candidate leaves the other network paths to be tried.
      _addCandidate(
        handle,
        connection,
        candidate.toNativeUtf8(allocator: arena),
        mid?.toNativeUtf8(allocator: arena) ?? nullptr,
      );
    });
  }

  @override
  void send(int connection, int lane, Uint8List bytes) {
    final handle = _open;
    using((arena) {
      // libdatachannel copies the bytes before this arena is released.
      final data = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
      data.asTypedList(bytes.length).setAll(0, bytes);
      if (_send(handle, connection, lane, data, bytes.length) != 0) {
        throw StateError('libdatachannel could not send on lane $lane.');
      }
    });
  }

  @override
  int bufferedAmount(int connection, int lane) {
    final amount = _bufferedAmount(_open, connection, lane);
    if (amount < 0) {
      throw StateError('libdatachannel has no lane $lane on $connection.');
    }
    return amount;
  }

  @override
  void close(int connection) {
    if (_handle != nullptr) _close(_handle, connection);
  }

  @override
  WebRtcDriverEvent? poll() {
    if (_handle == nullptr) return null;
    final event = _poll(_handle).ref;
    final connection = event.connection;
    Uint8List bytes() => event.length == 0
        ? Uint8List(0)
        : Uint8List.fromList(event.data.asTypedList(event.length));
    return switch (event.type) {
      0 => null,
      1 => WebRtcDriverDescription(connection, utf8.decode(bytes())),
      2 => WebRtcDriverCandidate(
        connection,
        utf8.decode(bytes()),
        event.hasMid == 0 ? null : event.mid.toDartString(),
      ),
      3 => WebRtcDriverLaneOpened(connection, event.lane),
      4 => WebRtcDriverMessage(connection, event.lane, bytes()),
      5 => WebRtcDriverClosed(connection),
      _ => throw StateError('libdatachannel reported an unknown event.'),
    };
  }

  @override
  void dispose() {
    if (_handle == nullptr) return;
    _finalizer.detach(this);
    _destroy(_handle);
    _handle = nullptr;
  }
}

final class _NativeEvent extends Struct {
  @Int32()
  external int type;

  @Int32()
  external int connection;

  @Int32()
  external int lane;

  @Int32()
  external int hasMid;

  external Pointer<Uint8> data;

  @Size()
  external int length;

  external Pointer<Utf8> mid;
}

@Native<Pointer<Void> Function(Size)>(symbol: 'maratus_webrtc_create')
external Pointer<Void> _create(int maxQueuedBytes);

@Native<
  Int32 Function(
    Pointer<Void>,
    Int32,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    Int32,
  )
>(symbol: 'maratus_webrtc_open')
external int _openConnection(
  Pointer<Void> driver,
  int laneCount,
  Pointer<Pointer<Utf8>> urls,
  Pointer<Pointer<Utf8>> usernames,
  Pointer<Pointer<Utf8>> credentials,
  int serverCount,
);

@Native<Int32 Function(Pointer<Void>, Int32)>(
  symbol: 'maratus_webrtc_create_offer',
)
external int _createOffer(Pointer<Void> driver, int connection);

@Native<Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>)>(
  symbol: 'maratus_webrtc_accept_offer',
)
external int _acceptOffer(
  Pointer<Void> driver,
  int connection,
  Pointer<Utf8> sdp,
);

@Native<Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>)>(
  symbol: 'maratus_webrtc_accept_answer',
)
external int _acceptAnswer(
  Pointer<Void> driver,
  int connection,
  Pointer<Utf8> sdp,
);

@Native<Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'maratus_webrtc_add_candidate',
)
external int _addCandidate(
  Pointer<Void> driver,
  int connection,
  Pointer<Utf8> candidate,
  Pointer<Utf8> mid,
);

@Native<Int32 Function(Pointer<Void>, Int32, Int32, Pointer<Uint8>, Size)>(
  symbol: 'maratus_webrtc_send',
)
external int _send(
  Pointer<Void> driver,
  int connection,
  int lane,
  Pointer<Uint8> data,
  int length,
);

@Native<Int64 Function(Pointer<Void>, Int32, Int32)>(
  symbol: 'maratus_webrtc_buffered_amount',
)
external int _bufferedAmount(Pointer<Void> driver, int connection, int lane);

@Native<Void Function(Pointer<Void>, Int32)>(symbol: 'maratus_webrtc_close')
external void _close(Pointer<Void> driver, int connection);

@Native<Pointer<_NativeEvent> Function(Pointer<Void>)>(
  symbol: 'maratus_webrtc_poll',
)
external Pointer<_NativeEvent> _poll(Pointer<Void> driver);

@Native<Void Function(Pointer<Void>)>(symbol: 'maratus_webrtc_destroy')
external void _destroy(Pointer<Void> driver);
