import 'webrtc_driver.dart';

/// Whether this platform supports WebRTC.
bool get supportsWebRtc => false;

/// Reports that WebRTC is unavailable on this platform.
WebRtcDriver createWebRtcDriver({required int maxQueuedBytes}) =>
    throw UnsupportedError('WebRTC is not supported on this platform.');
