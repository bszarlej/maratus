import 'dart:async';

import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

const _ms = Duration(milliseconds: 1);

void main() {
  group('ManualClock', () {
    test('starts at zero and moves only when advanced', () {
      final clock = ManualClock();
      expect(clock.now, Duration.zero);

      clock.advance(_ms * 5);
      expect(clock.now, _ms * 5);

      clock.advance(Duration.zero);
      expect(clock.now, _ms * 5);
    });

    test('rejects negative advances', () {
      final clock = ManualClock();

      expect(
        () => clock.advance(const Duration(microseconds: -1)),
        throwsArgumentError,
      );
      expect(clock.now, Duration.zero);
    });

    test('runs a timer once it is due, with now at its due time', () {
      final clock = ManualClock();
      final runs = <Duration>[];
      clock.schedule(_ms * 10, () => runs.add(clock.now));

      clock.advance(_ms * 9);
      expect(runs, isEmpty);

      clock.advance(_ms * 5);
      expect(runs, [_ms * 10]);
      expect(clock.now, _ms * 14);
    });

    test('runs timers by due time, then in scheduling order', () {
      final clock = ManualClock();
      final runs = <String>[];
      clock
        ..schedule(_ms * 3, () => runs.add('c'))
        ..schedule(_ms * 1, () => runs.add('a'))
        ..schedule(_ms * 3, () => runs.add('d'))
        ..schedule(_ms * 2, () => runs.add('b'));

      clock.advance(_ms * 3);

      expect(runs, ['a', 'b', 'c', 'd']);
    });

    test('runs timers scheduled by timers that become due', () {
      final clock = ManualClock();
      final runs = <(String, Duration)>[];
      clock.schedule(_ms * 2, () {
        runs.add(('outer', clock.now));
        clock
          ..schedule(_ms * 3, () => runs.add(('inner', clock.now)))
          ..schedule(_ms * 9, () => runs.add(('late', clock.now)));
      });

      clock.advance(_ms * 6);

      expect(runs, [('outer', _ms * 2), ('inner', _ms * 5)]);
      expect(clock.pendingTimerCount, 1);
    });

    test('runs zero and negative delays on the next advance only', () {
      final clock = ManualClock();
      var runs = 0;
      clock
        ..schedule(Duration.zero, () => runs++)
        ..schedule(-_ms, () => runs++);
      expect(runs, 0);

      clock.advance(Duration.zero);
      expect(runs, 2);
    });

    test('tracks whether a timer is pending', () {
      final clock = ManualClock();
      final timer = clock.schedule(_ms, () {});
      expect(timer.isActive, isTrue);
      expect(timer.tick, 0);
      expect(clock.pendingTimerCount, 1);

      clock.advance(_ms);
      expect(timer.isActive, isFalse);
      expect(timer.tick, 1);
      expect(clock.pendingTimerCount, 0);
    });

    test('does not run cancelled timers', () {
      final clock = ManualClock();
      final timer = clock.schedule(_ms, () => fail('a cancelled timer ran'));

      timer
        ..cancel()
        ..cancel();
      clock.advance(_ms * 2);

      expect(timer.isActive, isFalse);
      expect(timer.tick, 0);
      expect(clock.pendingTimerCount, 0);
    });

    test('cancels a timer from an earlier timer due at the same time', () {
      final clock = ManualClock();
      late final Timer second;
      clock.schedule(_ms, () => second.cancel());
      second = clock.schedule(_ms, () => fail('a cancelled timer ran'));

      clock.advance(_ms);

      expect(clock.pendingTimerCount, 0);
    });

    test('rejects advancing from a timer', () {
      final clock = ManualClock();
      Object? error;
      clock.schedule(_ms, () {
        try {
          clock.advance(_ms);
        } on StateError catch (e) {
          error = e;
        }
      });

      clock.advance(_ms * 2);

      expect(error, isStateError);
      expect(clock.now, _ms * 2);
    });

    test('stops at a timer that throws and keeps later timers', () {
      final clock = ManualClock();
      var laterRuns = 0;
      clock
        ..schedule(_ms, () => throw StateError('timer failed'))
        ..schedule(_ms * 2, () => laterRuns++);

      expect(() => clock.advance(_ms * 3), throwsStateError);
      expect(clock.now, _ms);
      expect(clock.pendingTimerCount, 1);

      clock.advance(_ms * 2);
      expect(laterRuns, 1);
      expect(clock.now, _ms * 3);
    });
  });

  group('SystemClock', () {
    test('never goes backwards', () {
      const clock = SystemClock();
      var previous = clock.now;
      for (var i = 0; i < 1000; i++) {
        final current = clock.now;
        expect(current, greaterThanOrEqualTo(previous));
        previous = current;
      }
    });

    test('runs timers on the event loop', () async {
      const clock = SystemClock();
      var runs = 0;
      final timer = clock.schedule(Duration.zero, () => runs++);
      expect(timer.isActive, isTrue);
      expect(runs, 0);

      await Future<void>.delayed(Duration.zero);
      expect(runs, 1);
      expect(timer.isActive, isFalse);
    });

    test('does not run cancelled timers', () async {
      const clock = SystemClock();
      clock
          .schedule(Duration.zero, () => fail('a cancelled timer ran'))
          .cancel();

      await Future<void>.delayed(Duration.zero);
    });
  });
}
