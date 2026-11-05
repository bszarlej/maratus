import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

void main() {
  group('Admission', () {
    test('admits without a rejection reason', () {
      const admission = Admission.admit();

      expect(admission.isAdmitted, isTrue);
      expect(admission.reason, isNull);
    });

    test('rejects with an optional reason, including the length boundary', () {
      for (final reason in [
        null,
        '',
        'Match full',
        'a' * Admission.maxReasonLength,
      ]) {
        final admission = Admission.reject(reason);

        expect(admission.isAdmitted, isFalse);
        expect(admission.reason, reason);
      }
    });

    test('rejects reasons exceeding the UTF-16 code unit limit', () {
      final boundary = '\u{1f577}' * (Admission.maxReasonLength ~/ 2);

      expect(Admission.reject(boundary).reason, boundary);
      expect(
        () => Admission.reject('a' * (Admission.maxReasonLength + 1)),
        throwsArgumentError,
      );
      expect(() => Admission.reject('${boundary}a'), throwsArgumentError);
    });
  });
}
