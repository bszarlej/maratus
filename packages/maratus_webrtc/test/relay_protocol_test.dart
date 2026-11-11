import 'dart:convert';

import 'package:maratus_webrtc/src/relay_protocol.dart';
import 'package:maratus_webrtc/src/signaling_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('every message survives encoding and decoding', () {
    T roundTrip<T extends RelayMessage>(T message) =>
        RelayMessage.decode(message.encode()) as T;

    expect(roundTrip(const RelayHost()).room, isNull);
    expect(roundTrip(const RelayHost('lobby-1')).room, 'lobby-1');
    expect(roundTrip(const RelayRoom('ABC')).room, 'ABC');
    expect(roundTrip(const RelayJoin('ABC')).room, 'ABC');
    expect(roundTrip(const RelayJoined(7)).client, 7);
    final fromHost = roundTrip(const RelaySignal('data', client: 3));
    expect(fromHost.data, 'data');
    expect(fromHost.client, 3);
    expect(roundTrip(const RelaySignal('data')).client, isNull);
    expect(roundTrip(const RelayLeave(maxRelayClient)).client, maxRelayClient);
    expect(roundTrip(const RelayError(RelayError.full)).reason, 'full');
  });

  test('room names allow letters, digits, underscores, and hyphens', () {
    expect(isValidRoom('Room_1-a'), isTrue);
    expect(isValidRoom('x' * 64), isTrue);
    expect(isValidRoom(''), isFalse);
    expect(isValidRoom('x' * 65), isFalse);
    expect(isValidRoom('two words'), isFalse);
    expect(isValidRoom('room/1'), isFalse);
  });

  final invalid = <String, String>{
    'not JSON': '{',
    'not an object': '"room"',
    'an unknown type': jsonEncode({'type': 'peek'}),
    'an invalid requested room': jsonEncode({'type': 'host', 'room': 'a b'}),
    'a room without a name': jsonEncode({'type': 'room'}),
    'a join without a room': jsonEncode({'type': 'join'}),
    'a zero client': jsonEncode({'type': 'joined', 'client': 0}),
    'a client beyond the range': jsonEncode({
      'type': 'leave',
      'client': maxRelayClient + 1,
    }),
    'a fractional client': jsonEncode({'type': 'joined', 'client': 1.5}),
    'a signal without data': jsonEncode({'type': 'signal'}),
    'a signal with empty data': jsonEncode({'type': 'signal', 'data': ''}),
    'an oversized signal': jsonEncode({
      'type': 'signal',
      'data': 'x' * (maxSignalingMessageLength + 1),
    }),
    'an oversized message': jsonEncode({
      'type': 'error',
      'reason': 'full',
      'padding': 'x' * maxRelayMessageLength,
    }),
    'an error without a reason': jsonEncode({'type': 'error'}),
  };
  for (final MapEntry(key: name, value: text) in invalid.entries) {
    test('decoding rejects $name', () {
      expect(() => RelayMessage.decode(text), throwsFormatException);
    });
  }
}
