import 'webrtc_driver.dart';
import 'webrtc_driver_stub.dart'
    if (dart.library.js_interop) 'webrtc_driver_web.dart'
    as platform;

/// Whether this platform supports WebRTC connections.
bool get supportsWebRtc => platform.supportsWebRtc;

/// Creates the driver for this platform's WebRTC implementation, throwing an
/// [UnsupportedError] where there is none.
WebRtcDriver createWebRtcDriver() => platform.createWebRtcDriver();
