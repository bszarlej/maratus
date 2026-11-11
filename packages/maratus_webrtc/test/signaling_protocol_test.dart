import 'dart:convert';

import 'package:maratus_webrtc/src/signaling_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('every message survives encoding and decoding', () {
    final offer =
        SignalingMessage.decode(
              const OfferMessage(sdp: 'v=0 offer', channelCount: 3).encode(),
            )
            as OfferMessage;
    expect(offer.sdp, 'v=0 offer');
    expect(offer.channelCount, 3);
    expect(offer.version, webRtcProtocolVersion);

    final answer =
        SignalingMessage.decode(const AnswerMessage('v=0 answer').encode())
            as AnswerMessage;
    expect(answer.sdp, 'v=0 answer');

    final candidate =
        SignalingMessage.decode(
              const CandidateMessage(
                'candidate:1 1 udp 1 h 1 typ host',
                '0',
              ).encode(),
            )
            as CandidateMessage;
    expect(candidate.candidate, 'candidate:1 1 udp 1 h 1 typ host');
    expect(candidate.mid, '0');

    final reject =
        SignalingMessage.decode(
              const RejectMessage(RejectMessage.full).encode(),
            )
            as RejectMessage;
    expect(reject.reason, RejectMessage.full);
  });

  test('a candidate without a media section omits the field', () {
    final json = const CandidateMessage('candidate:1').toJson();
    expect(json.containsKey('mid'), isFalse);
    final decoded =
        SignalingMessage.decode(jsonEncode(json)) as CandidateMessage;
    expect(decoded.mid, isNull);
  });

  test('an offer from another protocol version still decodes', () {
    final offer =
        SignalingMessage.decode(
              jsonEncode({
                'type': 'offer',
                'version': 7,
                'channels': 1,
                'sdp': 'v=0',
              }),
            )
            as OfferMessage;
    expect(offer.version, 7);
  });

  test('unknown fields are ignored', () {
    final answer =
        SignalingMessage.decode(
              jsonEncode({'type': 'answer', 'sdp': 'v=0', 'extra': true}),
            )
            as AnswerMessage;
    expect(answer.sdp, 'v=0');
  });

  final invalid = <String, String>{
    'not JSON': '{',
    'not an object': '[]',
    'an unknown type': jsonEncode({'type': 'hello'}),
    'a missing type': jsonEncode({'sdp': 'v=0'}),
    'a missing SDP': jsonEncode({'type': 'answer'}),
    'an empty SDP': jsonEncode({'type': 'answer', 'sdp': ''}),
    'a non-string SDP': jsonEncode({'type': 'answer', 'sdp': 1}),
    'an oversized SDP': jsonEncode({
      'type': 'answer',
      'sdp': 'x' * (32 * 1024 + 1),
    }),
    'a fractional channel count': jsonEncode({
      'type': 'offer',
      'version': 1,
      'channels': 1.5,
      'sdp': 'v=0',
    }),
    'a missing version': jsonEncode({
      'type': 'offer',
      'channels': 1,
      'sdp': 'v=0',
    }),
    'an oversized candidate': jsonEncode({
      'type': 'candidate',
      'candidate': 'x' * 1025,
    }),
    'an empty candidate': jsonEncode({'type': 'candidate', 'candidate': ''}),
    'a non-string media section': jsonEncode({
      'type': 'candidate',
      'candidate': 'candidate:1',
      'mid': 0,
    }),
    'an empty reason': jsonEncode({'type': 'reject', 'reason': ''}),
  };
  for (final MapEntry(key: name, value: text) in invalid.entries) {
    test('decoding rejects $name', () {
      expect(() => SignalingMessage.decode(text), throwsFormatException);
    });
  }

  test('decoding rejects messages over the length limit', () {
    final text = jsonEncode({
      'type': 'answer',
      'sdp': 'x' * maxSignalingMessageLength,
    });
    expect(text.length, greaterThan(maxSignalingMessageLength));
    expect(() => SignalingMessage.decode(text), throwsFormatException);
  });
}
