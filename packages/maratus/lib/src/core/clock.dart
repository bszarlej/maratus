import 'dart:async';
import 'dart:collection';

/// A source of monotonic time, and of timers that follow it.
///
/// Sessions and transports read time from an injected clock instead of the
/// system, so tests can control time with a [ManualClock].
abstract interface class MonotonicClock {
  /// The time elapsed since an arbitrary origin. It never decreases.
  Duration get now;

  /// Calls [callback] once [delay] has elapsed on this clock, unless the
  /// returned timer is cancelled first.
  ///
  /// A negative [delay] is treated as zero. The callback never runs before
  /// this method returns.
  Timer schedule(Duration delay, void Function() callback);
}

/// A [MonotonicClock] that follows real time, using [Stopwatch] for time and
/// [Timer] for timers.
///
/// All instances share the same origin.
final class SystemClock implements MonotonicClock {
  /// Creates a clock that follows real time.
  const SystemClock();

  static final _stopwatch = Stopwatch()..start();

  @override
  Duration get now => _stopwatch.elapsed;

  @override
  Timer schedule(Duration delay, void Function() callback) =>
      Timer(delay, callback);
}

/// A [MonotonicClock] that only moves when [advance] is called.
///
/// Timers run during [advance], in the order of their due times, so code
/// driven by this clock behaves the same on every run and never waits for
/// real time to pass.
final class ManualClock implements MonotonicClock {
  /// Creates a clock that starts at [Duration.zero].
  ManualClock();

  final _timers = SplayTreeSet<_ManualTimer>(_compareTimers);
  var _now = Duration.zero;
  var _nextSequence = 0;
  var _advancing = false;

  @override
  Duration get now => _now;

  /// The number of timers that have neither run nor been cancelled.
  int get pendingTimerCount => _timers.length;

  @override
  Timer schedule(Duration delay, void Function() callback) {
    final due = _now + (delay.isNegative ? Duration.zero : delay);
    final timer = _ManualTimer(this, due, _nextSequence++, callback);
    _timers.add(timer);
    return timer;
  }

  /// Moves the clock forward by [duration], running each timer that becomes
  /// due.
  ///
  /// Timers run in the order of their due times, and timers that are due at
  /// the same time run in the order they were scheduled. While a timer runs,
  /// [now] is its due time. Timers scheduled by a running timer also run
  /// during this call if they become due within [duration]. If a timer
  /// throws, the clock stays at that timer's due time and the error
  /// propagates; later timers remain scheduled.
  ///
  /// Throws an [ArgumentError] if [duration] is negative, and a [StateError]
  /// if called from a timer.
  void advance(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'must not be negative');
    }
    if (_advancing) {
      throw StateError('Cannot advance the clock from one of its timers.');
    }
    _advancing = true;
    try {
      final target = _now + duration;
      while (_timers.isNotEmpty && _timers.first.due <= target) {
        final timer = _timers.first;
        _now = timer.due;
        timer._run();
      }
      _now = target;
    } finally {
      _advancing = false;
    }
  }
}

int _compareTimers(_ManualTimer a, _ManualTimer b) {
  final byDue = a.due.compareTo(b.due);
  return byDue != 0 ? byDue : a.sequence.compareTo(b.sequence);
}

final class _ManualTimer implements Timer {
  _ManualTimer(this._clock, this.due, this.sequence, this._callback);

  final ManualClock _clock;
  final Duration due;
  final int sequence;
  void Function()? _callback;
  var _tick = 0;

  @override
  bool get isActive => _callback != null;

  @override
  int get tick => _tick;

  @override
  void cancel() {
    if (_callback == null) return;
    _callback = null;
    _clock._timers.remove(this);
  }

  void _run() {
    final callback = _callback!;
    cancel();
    _tick = 1;
    callback();
  }
}
