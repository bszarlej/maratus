import 'package:maratus/maratus.dart';
import 'package:maratus_webrtc/maratus_webrtc.dart';
import 'package:test/test.dart';

import 'support/in_memory_signaling.dart';

void main() {
  final invalid = <String, void Function(InMemorySignaling)>{
    'a host without channels': (signaling) =>
        WebRtcHost(signaling: signaling, channelCount: 0),
    'a host with too many channels': (signaling) =>
        WebRtcHost(signaling: signaling, channelCount: 65),
    'a host without connections': (signaling) =>
        WebRtcHost(signaling: signaling, maxConnections: 0),
    'a host with a TURN server lacking credentials': (signaling) => WebRtcHost(
      signaling: signaling,
      iceServers: const [
        IceServer(['turn:turn.example.com']),
      ],
    ),
    'a client without a connect timeout': (signaling) =>
        WebRtcClient.connect(signaling.join(), connectTimeout: Duration.zero),
    'a client with a negative close timeout': (signaling) =>
        WebRtcClient.connect(
          signaling.join(),
          closeTimeout: const Duration(seconds: -1),
        ),
    'a client with an HTTP ICE server': (signaling) => WebRtcClient.connect(
      signaling.join(),
      iceServers: const [
        IceServer(['https://stun.example.com']),
      ],
    ),
  };
  for (final MapEntry(key: name, value: create) in invalid.entries) {
    test('$name is rejected before WebRTC is used', () {
      final signaling = InMemorySignaling();
      expect(() => create(signaling), throwsArgumentError);
      expect(signaling.isClosed, isFalse);
    });
  }

  test('peers advertise every delivery mode on their channels', () {
    if (!WebRtcHost.isSupported) {
      expect(
        () => WebRtcHost(signaling: InMemorySignaling()),
        throwsUnsupportedError,
      );
      return;
    }
    final peer = WebRtcHost(signaling: InMemorySignaling(), channelCount: 4);
    addTearDown(() async {
      peer.close();
      await peer.done;
    });
    expect(peer.isHost, isTrue);
    expect(peer.capabilities.channelCount, 4);
    expect(peer.capabilities.deliveryModes, DeliveryMode.values.toSet());
    expect(peer.capabilities.maxUnreliableMessageBytes, 1000);
  });
}
