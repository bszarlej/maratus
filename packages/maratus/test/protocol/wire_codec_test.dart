import 'dart:convert';
import 'dart:typed_data';

import 'package:maratus/src/protocol/protocol_exception.dart';
import 'package:maratus/src/protocol/wire_codec.dart';
import 'package:test/test.dart';

import 'protocol_test_utils.dart';

void main() {
  group('JsonWireCodec', () {
    const codec = JsonWireCodec();

    test('round-trips wire values', () {
      const value = {
        'null': null,
        'bool': true,
        'int': -42,
        'double': 0.25,
        'string': 'zażółć 🎮',
        'list': [
          1,
          'two',
          [3],
        ],
        'object': {'nested': <String, Object?>{}},
      };

      expect(codec.decode(codec.encode(value)), value);
    });

    test('encodes compact UTF-8 JSON', () {
      expect(
        utf8.decode(
          codec.encode({
            'a': [1, true, null],
          }),
        ),
        '{"a":[1,true,null]}',
      );
    });

    test('rejects input that is not UTF-8 JSON', () {
      final inputs = {
        'empty': <int>[],
        'truncated': utf8.encode('{"a":'),
        'trailing data': utf8.encode('{"a":1}x'),
        'not JSON': utf8.encode("{'a':1}"),
        'invalid UTF-8': [0x7b, 0xff, 0x7d],
      };

      for (final MapEntry(key: reason, value: bytes) in inputs.entries) {
        expect(
          () => codec.decode(Uint8List.fromList(bytes)),
          throwsProtocolException(ProtocolErrorCode.malformed),
          reason: reason,
        );
      }
    });
  });

  group('checkWireValue', () {
    const limits = WireLimits(maxDepth: 3, maxCollectionLength: 2);

    test('accepts wire values within the limits', () {
      expect(
        () => checkWireValue({
          'a': [
            1,
            {'b': null},
          ],
        }, limits),
        returnsNormally,
      );
    });

    test('rejects non-finite numbers', () {
      for (final number in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          () => checkWireValue([number], limits),
          throwsProtocolException(ProtocolErrorCode.malformed),
          reason: '$number',
        );
      }
    });

    test('rejects numbers that overflow while parsing', () {
      final value = const JsonWireCodec().decode(utf8.encode('[1e400]'));

      expect(
        () => checkWireValue(value, limits),
        throwsProtocolException(ProtocolErrorCode.malformed),
      );
    });

    test('rejects values outside the wire value model', () {
      for (final value in [
        <Object?>{1},
        DateTime(2026),
        <int, Object?>{1: 'one'},
      ]) {
        expect(
          () => checkWireValue(value, limits),
          throwsProtocolException(ProtocolErrorCode.malformed),
          reason: '$value',
        );
      }
    });

    test('rejects values nested deeper than the limit', () {
      expect(
        () => checkWireValue({
          'a': [
            1,
            {'b': <Object?>[]},
          ],
        }, limits),
        throwsProtocolException(ProtocolErrorCode.limitExceeded),
      );
    });

    test('rejects collections longer than the limit', () {
      expect(
        () => checkWireValue([1, 2, 3], limits),
        throwsProtocolException(ProtocolErrorCode.limitExceeded),
      );
      expect(
        () => checkWireValue({'a': 1, 'b': 2, 'c': 3}, limits),
        throwsProtocolException(ProtocolErrorCode.limitExceeded),
      );
    });
  });
}
