import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

import 'protocol_test_utils.dart';

void main() {
  group('QuantizedDoubleCodec', () {
    test('uses small nonnegative indices anchored at the minimum', () {
      final codec = QuantizedDoubleCodec(min: -2, max: 2, step: 0.25);

      expect(codec.encode(-2), 0);
      expect(codec.encode(-1.75), 1);
      expect(codec.encode(0), 8);
      expect(codec.encode(2), 16);
      expect(codec.decode(0), -2);
      expect(codec.decode(16), 2);
    });

    test('rounds to the nearest step with ties toward the maximum', () {
      final codec = QuantizedDoubleCodec(min: -2, max: 2, step: 0.25);

      for (final (input, expected) in [
        (-1.88, -2.0),
        (-1.875, -1.75),
        (-0.125, 0.0),
        (0.12, 0.0),
        (0.125, 0.25),
        (1.88, 2.0),
      ]) {
        expect(codec.decode(codec.encode(input)), expected, reason: '$input');
      }
    });

    test('supports decimal steps and preserves exact endpoints', () {
      final codec = QuantizedDoubleCodec(min: 0.1, max: 0.7, step: 0.1);

      expect(codec.encode(0.1), 0);
      expect(codec.encode(0.7), 6);
      expect(codec.decode(0), 0.1);
      expect(codec.decode(6), 0.7);
      expect(codec.decode(codec.encode(0.34)), closeTo(0.3, 1e-15));
    });

    test('allows arithmetic roundoff for a single step', () {
      final codec = QuantizedDoubleCodec(min: 0.1, max: 0.3, step: 0.2);

      expect(codec.encode(0.1), 0);
      expect(codec.encode(0.3), 1);
      expect(codec.decode(0), 0.1);
      expect(codec.decode(1), 0.3);
    });

    test('bounds error and re-encodes every decoded step consistently', () {
      final codec = QuantizedDoubleCodec(min: -1000, max: 1000, step: 0.01);

      for (var index = 0; index <= 200000; index++) {
        final decoded = codec.decode(index);
        expect(codec.encode(decoded), index, reason: '$index');
        if (index == 200000) continue;
        final sample = -1000 + (index + 0.37) * codec.step;
        final error = (codec.decode(codec.encode(sample)) - sample).abs();
        expect(error, lessThanOrEqualTo(codec.step / 2 + 1e-12));
      }
    });

    test('accepts integral doubles from JSON and web platforms', () {
      final codec = QuantizedDoubleCodec(min: -1, max: 1, step: 0.5);

      expect(codec.decode(3.0), 0.5);
    });

    test('rejects non-finite and out-of-range input without clamping', () {
      final codec = QuantizedDoubleCodec(min: -1, max: 1, step: 0.1);

      for (final value in [
        -1.0001,
        1.0001,
        double.nan,
        double.negativeInfinity,
        double.infinity,
      ]) {
        expect(
          () => codec.encode(value),
          throwsArgumentError,
          reason: '$value',
        );
      }
    });

    test('validates received indices before producing a value', () {
      final codec = QuantizedDoubleCodec(min: -1, max: 1, step: 0.1);

      for (final wire in [
        null,
        true,
        '1',
        <Object?>[],
        <String, Object?>{},
        -1,
        21,
        1.5,
        1e100,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          () => codec.decode(wire),
          throwsProtocolException(ProtocolErrorCode.invalidValue),
          reason: '$wire',
        );
      }
    });

    test('validates configuration in release builds as well', () {
      for (final (min, max, step) in [
        (0.0, 0.0, 1.0),
        (1.0, 0.0, 1.0),
        (double.nan, 1.0, 0.1),
        (0.0, double.nan, 0.1),
        (double.negativeInfinity, 1.0, 0.1),
        (0.0, double.infinity, 0.1),
        (0.0, 1.0, double.nan),
        (0.0, 1.0, double.infinity),
        (0.0, 1.0, 0.0),
        (0.0, 1.0, -0.1),
        (0.0, 1.0, 2.0),
        (0.0, 1.0, 0.3),
        (-1e308, 1e308, 1.0),
        (0.0, 4294967296.0, 1.0),
        (1e15, 1e15 + 10, 0.1),
      ]) {
        expect(
          () => QuantizedDoubleCodec(min: min, max: max, step: step),
          throwsArgumentError,
          reason: 'min=$min, max=$max, step=$step',
        );
      }
    });

    test('round-trips indices at the 32-bit limit', () {
      final codec = QuantizedDoubleCodec(
        min: 0,
        max: QuantizedDoubleCodec.maxSteps.toDouble(),
        step: 1,
      );

      for (final index in [0, 1, 2147483648, 4294967294, 4294967295]) {
        expect(codec.encode(codec.decode(index)), index);
      }
      expect(
        () => codec.decode(4294967296),
        throwsProtocolException(ProtocolErrorCode.invalidValue),
      );
    });

    test('describes its constraints identically on every platform', () {
      expect(
        QuantizedDoubleCodec(min: -1, max: 1, step: 0.01).descriptor,
        'quantizedDouble(min=-1,max=1,step=0.01)',
      );
      expect(
        QuantizedDoubleCodec(min: -0.0, max: 1, step: 0.5).descriptor,
        'quantizedDouble(min=0,max=1,step=0.5)',
      );
    });

    test('changing any constraint changes the shared schema fingerprint', () {
      final fingerprints = <String>{};
      for (final codec in [
        QuantizedDoubleCodec(min: -1, max: 1, step: 0.1),
        QuantizedDoubleCodec(min: 0, max: 1, step: 0.1),
        QuantizedDoubleCodec(min: -1, max: 2, step: 0.1),
        QuantizedDoubleCodec(min: -1, max: 1, step: 0.01),
        const DoubleCodec(min: -1, max: 1),
      ]) {
        final builder = ProtocolSchemaBuilder()
          ..addField(const FieldId('position.x'), codec);
        expect(fingerprints.add(builder.build().fingerprint), isTrue);
      }
    });
  });
}
