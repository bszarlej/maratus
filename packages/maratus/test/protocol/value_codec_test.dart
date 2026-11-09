import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

import 'protocol_test_utils.dart';

void main() {
  group('BoolCodec', () {
    const codec = BoolCodec();

    test('round-trips booleans', () {
      for (final value in [true, false]) {
        expect(codec.decode(codec.encode(value)), value);
      }
    });

    test('rejects other values', () {
      for (final wire in [null, 0, 'true']) {
        expect(
          () => codec.decode(wire),
          throwsProtocolException(ProtocolErrorCode.invalidValue),
          reason: '$wire',
        );
      }
    });
  });

  group('IntCodec', () {
    test('round-trips integers within the range', () {
      const codec = IntCodec(min: -5, max: 5);

      for (final value in [-5, 0, 5]) {
        expect(codec.decode(codec.encode(value)), value);
      }
    });

    test('accepts integral doubles produced by other platforms', () {
      expect(const IntCodec().decode(3.0), 3);
    });

    test('rejects values that are not integers', () {
      for (final wire in [null, '1', true, 1.5, double.nan, double.infinity]) {
        expect(
          () => const IntCodec().decode(wire),
          throwsProtocolException(ProtocolErrorCode.invalidValue),
          reason: '$wire',
        );
      }
    });

    test('rejects integers outside the range', () {
      const codec = IntCodec(min: 0, max: 10);

      for (final wire in [-1, 11, 1e300]) {
        expect(
          () => codec.decode(wire),
          throwsProtocolException(ProtocolErrorCode.invalidValue),
          reason: '$wire',
        );
      }
    });

    test('rejects integers that web platforms cannot represent exactly', () {
      expect(
        () => const IntCodec().decode(IntCodec.maxSafe + 1),
        throwsProtocolException(ProtocolErrorCode.invalidValue),
      );
    });

    test('refuses to encode integers outside the range', () {
      expect(() => const IntCodec(max: 10).encode(11), throwsArgumentError);
    });

    test('describes its range', () {
      expect(const IntCodec().descriptor, 'int');
      expect(const IntCodec(min: 1).descriptor, 'int(min=1)');
      expect(const IntCodec(min: 0, max: 100).descriptor, 'int(min=0,max=100)');
    });
  });

  group('DoubleCodec', () {
    test('round-trips finite numbers within the range', () {
      const codec = DoubleCodec(min: -1, max: 1);

      for (final value in [-1.0, -0.25, 0.0, 1.0]) {
        expect(codec.decode(codec.encode(value)), value);
      }
    });

    test('accepts integers', () {
      expect(const DoubleCodec().decode(2), allOf(isA<double>(), 2.0));
    });

    test('rejects values that are not finite numbers', () {
      for (final wire in [
        null,
        '1',
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          () => const DoubleCodec().decode(wire),
          throwsProtocolException(ProtocolErrorCode.invalidValue),
          reason: '$wire',
        );
      }
    });

    test('rejects numbers outside the range', () {
      const codec = DoubleCodec(min: 0, max: 1);

      for (final wire in [-0.5, 1.5]) {
        expect(
          () => codec.decode(wire),
          throwsProtocolException(ProtocolErrorCode.invalidValue),
          reason: '$wire',
        );
      }
    });

    test('refuses to encode non-finite or out-of-range numbers', () {
      expect(() => const DoubleCodec().encode(double.nan), throwsArgumentError);
      expect(() => const DoubleCodec(max: 1).encode(2), throwsArgumentError);
    });

    test('describes its range identically on every platform', () {
      expect(const DoubleCodec().descriptor, 'double');
      expect(
        const DoubleCodec(min: -1, max: 0.5).descriptor,
        'double(min=-1,max=0.5)',
      );
      expect(const DoubleCodec(min: -0.0).descriptor, 'double(min=0)');
      expect(const DoubleCodec(max: 1e21).descriptor, 'double(max=1e+21)');
    });
  });

  group('StringCodec', () {
    const codec = StringCodec(maxLength: 4);

    test('round-trips strings up to the maximum length', () {
      for (final value in ['', 'abcd', 'żółw']) {
        expect(codec.decode(codec.encode(value)), value);
      }
    });

    test('rejects longer strings', () {
      expect(
        () => codec.decode('abcde'),
        throwsProtocolException(ProtocolErrorCode.limitExceeded),
      );
      expect(() => codec.encode('abcde'), throwsArgumentError);
    });

    test('rejects values that are not strings', () {
      for (final wire in [
        null,
        1,
        ['a'],
      ]) {
        expect(
          () => codec.decode(wire),
          throwsProtocolException(ProtocolErrorCode.invalidValue),
          reason: '$wire',
        );
      }
    });

    test('describes its maximum length', () {
      expect(codec.descriptor, 'string(maxLength=4)');
    });
  });

  group('ListCodec', () {
    const codec = ListCodec(IntCodec(min: 0, max: 9), maxLength: 3);

    test('round-trips lists', () {
      expect(codec.decode(codec.encode([1, 2, 3])), [1, 2, 3]);
    });

    test('decodes unmodifiable lists', () {
      expect(() => codec.decode([1]).add(2), throwsUnsupportedError);
    });

    test('reports the index of an invalid element', () {
      expect(
        () => codec.decode([1, 10]),
        throwsProtocolException(ProtocolErrorCode.invalidValue, path: ['1']),
      );
    });

    test('rejects longer lists', () {
      expect(
        () => codec.decode([0, 0, 0, 0]),
        throwsProtocolException(ProtocolErrorCode.limitExceeded),
      );
      expect(() => codec.encode([0, 0, 0, 0]), throwsArgumentError);
    });

    test('rejects values that are not lists', () {
      for (final wire in [
        null,
        'abc',
        {'0': 1},
      ]) {
        expect(
          () => codec.decode(wire),
          throwsProtocolException(ProtocolErrorCode.invalidValue),
          reason: '$wire',
        );
      }
    });

    test('describes its elements', () {
      expect(codec.descriptor, 'list<int(min=0,max=9)>(maxLength=3)');
    });
  });

  group('NullableCodec', () {
    const codec = NullableCodec(StringCodec());

    test('round-trips null and values', () {
      expect(codec.decode(codec.encode(null)), isNull);
      expect(codec.decode(codec.encode('a')), 'a');
    });

    test('validates values with the inner codec', () {
      expect(
        () => codec.decode(1),
        throwsProtocolException(ProtocolErrorCode.invalidValue),
      );
    });

    test('refuses values that the inner codec encodes as null', () {
      expect(
        () => const NullableCodec(_NullEncodingCodec()).encode(1),
        throwsArgumentError,
      );
    });

    test('describes its inner codec', () {
      expect(codec.descriptor, 'nullable<string(maxLength=256)>');
    });
  });

  group('WireObject', () {
    test('reads declared keys', () {
      final object = WireObject({'a': 1, 'b': 'x'}, const {'a', 'b'});

      expect(object.read('a', const IntCodec()), 1);
      expect(object['b'], 'x');
    });

    test('rejects values that are not objects', () {
      for (final wire in [null, <Object?>[], 'a']) {
        expect(
          () => WireObject(wire, const {'a'}),
          throwsProtocolException(ProtocolErrorCode.invalidValue),
          reason: '$wire',
        );
      }
    });

    test('rejects missing and unexpected keys', () {
      expect(
        () => WireObject({'a': 1}, const {'a', 'b'}),
        throwsProtocolException(ProtocolErrorCode.invalidValue),
      );
      expect(
        () => WireObject({'a': 1, 'c': 2}, const {'a'}),
        throwsProtocolException(ProtocolErrorCode.invalidValue),
      );
    });

    test('reports the key of an invalid value', () {
      final object = WireObject({'a': 'x'}, const {'a'});

      expect(
        () => object.read('a', const IntCodec()),
        throwsProtocolException(ProtocolErrorCode.invalidValue, path: ['a']),
      );
    });

    test('refuses to read undeclared keys', () {
      final object = WireObject({'a': 1}, const {'a'});

      expect(() => object['b'], throwsArgumentError);
    });
  });

  group('WireList', () {
    test('reads elements by position', () {
      final list = WireList([1, 'x'], 2);

      expect(list.length, 2);
      expect(list.read(0, const IntCodec()), 1);
      expect(list[1], 'x');
    });

    test('accepts an empty list of length zero', () {
      expect(WireList(<Object?>[], 0).length, 0);
    });

    test('rejects values that are not lists', () {
      for (final wire in [null, <String, Object?>{}, 'a', 1]) {
        expect(
          () => WireList(wire, 1),
          throwsProtocolException(ProtocolErrorCode.invalidValue),
          reason: '$wire',
        );
      }
    });

    test('rejects lists of another length', () {
      for (final wire in [
        <Object?>[],
        [1, 2, 3],
      ]) {
        expect(
          () => WireList(wire, 2),
          throwsProtocolException(ProtocolErrorCode.invalidValue),
          reason: '$wire',
        );
      }
    });

    test('reports the index of an invalid element', () {
      final list = WireList([1, 'x'], 2);

      expect(
        () => list.read(1, const IntCodec()),
        throwsProtocolException(ProtocolErrorCode.invalidValue, path: ['1']),
      );
    });

    test('refuses to read outside the list', () {
      final list = WireList([1], 1);

      expect(() => list[1], throwsRangeError);
      expect(() => list.read(-1, const IntCodec()), throwsRangeError);
    });
  });

  group('custom codecs', () {
    const codec = MoveInputCodec();

    test('round-trip through composed codecs', () {
      final input = codec.decode(codec.encode(const MoveInput(0.5, -1)));

      expect(input.x, 0.5);
      expect(input.y, -1);
    });

    test('report the location of invalid nested values', () {
      expect(
        () => codec.decode({'x': 0.5, 'y': 2}),
        throwsProtocolException(ProtocolErrorCode.invalidValue, path: ['y']),
      );
    });
  });
}

final class _NullEncodingCodec extends ValueCodec<int> {
  const _NullEncodingCodec();

  @override
  String get descriptor => 'test.null_encoding@1';

  @override
  Object? encode(int value) => null;

  @override
  int decode(Object? wire) => 0;
}
