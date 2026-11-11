import 'webrtc_driver.dart';
import 'webrtc_driver_stub.dart'
    if (dart.library.js_interop) 'webrtc_driver_web.dart'
    if (dart.library.ffi) 'webrtc_driver_native.dart'
    as platform;

/// Whether this platform supports WebRTC connections.
bool get supportsWebRtc => platform.supportsWebRtc;

/// Creates the driver for this platform's WebRTC implementation, throwing an
/// [UnsupportedError] where there is none.
///
/// A connection's received data that the transport has not polled yet is
/// bounded by [maxQueuedBytes] where the platform allows it.
WebRtcDriver createWebRtcDriver({required int maxQueuedBytes}) =>
    platform.createWebRtcDriver(maxQueuedBytes: maxQueuedBytes);
