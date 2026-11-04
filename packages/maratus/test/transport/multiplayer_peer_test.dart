import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

void main() {
  group('TransportCapabilities', () {
    test('default to reliable delivery on a single channel', () {
      const capabilities = TransportCapabilities(canHost: false);

      expect(capabilities.canHost, isFalse);
      expect(capabilities.supports(DeliveryMode.reliable), isTrue);
      expect(capabilities.supports(DeliveryMode.unreliableOrdered), isFalse);
      expect(capabilities.supports(DeliveryMode.unreliable), isFalse);
      expect(capabilities.supports(DeliveryMode.reliable, channel: 1), isFalse);
      expect(
        capabilities.supports(DeliveryMode.reliable, channel: -1),
        isFalse,
      );
    });

    test('describe additional delivery modes and channels', () {
      const capabilities = TransportCapabilities(
        canHost: true,
        deliveryModes: {DeliveryMode.reliable, DeliveryMode.unreliable},
        channelCount: 2,
      );

      expect(
        capabilities.supports(DeliveryMode.unreliable, channel: 1),
        isTrue,
      );
      expect(capabilities.supports(DeliveryMode.unreliableOrdered), isFalse);
      expect(capabilities.supports(DeliveryMode.reliable, channel: 2), isFalse);
    });
  });

  group('QueueLimits', () {
    test('accept messages up to the message count', () {
      const limits = QueueLimits(maxMessages: 2);

      expect(limits.accepts((messages: 1, bytes: 0), 0), isTrue);
      expect(limits.accepts((messages: 2, bytes: 0), 0), isFalse);
    });

    test('accept messages up to the total size', () {
      const limits = QueueLimits(maxBytes: 10);

      expect(limits.accepts((messages: 1, bytes: 4), 6), isTrue);
      expect(limits.accepts((messages: 1, bytes: 4), 7), isFalse);
      expect(limits.accepts((messages: 0, bytes: 0), 11), isFalse);
    });
  });
}
