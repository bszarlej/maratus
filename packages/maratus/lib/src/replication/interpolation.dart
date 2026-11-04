part of '../core/multiplayer_session.dart';

/// Blends values of a synchronized field for presentation.
///
/// Peers other than an entity's authority receive its synchronized values
/// as samples, a few times a second. With an interpolator,
/// [MultiplayerSynchronizer.interpolated] presents values between those
/// samples, so motion looks smooth while the authoritative state that
/// setters and snapshots receive stays exactly as sent.
///
/// [DoubleInterpolator] blends numbers. Implement an interpolator for
/// another type by extending this class:
///
/// ```dart
/// class PointInterpolator extends Interpolator<Point> {
///   const PointInterpolator();
///
///   @override
///   Point lerp(Point from, Point to, double t) =>
///       Point(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
/// }
/// ```
abstract class Interpolator<T> {
  /// Allows subclasses to define const constructors.
  const Interpolator();

  /// Returns a new value the fraction [t] of the way from [from] to [to].
  ///
  /// [t] is greater than 0 and less than 1. Must not modify [from] or [to].
  T lerp(T from, T to, double t);

  /// Whether the change from [from] to [to] is a discontinuity, such as a
  /// respawn, to show as a jump instead of blending.
  ///
  /// Returns `false` unless overridden.
  bool isTeleport(T from, T to) => false;
}

/// Blends [double] values linearly.
final class DoubleInterpolator extends Interpolator<double> {
  /// Creates an interpolator that shows changes of at least
  /// [teleportDistance] as jumps, or blends every change if it is `null`.
  const DoubleInterpolator({this.teleportDistance})
    : assert(teleportDistance == null || teleportDistance > 0);

  /// The smallest change shown as a jump instead of blending, or `null` to
  /// blend every change.
  final double? teleportDistance;

  @override
  double lerp(double from, double to, double t) => from + (to - from) * t;

  @override
  bool isTeleport(double from, double to) {
    final distance = teleportDistance;
    return distance != null && (to - from).abs() >= distance;
  }
}

/// How [MultiplayerSynchronizer.interpolated] produced a value.
enum InterpolationState {
  /// Blended between the samples around the presentation time, or the
  /// earlier sample while its value still held, as after a pause in
  /// sampling.
  interpolating,

  /// No samples lie on both sides of the presentation time, so the nearest
  /// one is shown: the first while samples start to arrive, and the newest
  /// when the next one is late, a buffer underrun. Values are never
  /// extrapolated.
  holding,

  /// The change to the next sample is a teleport, so the earlier sample is
  /// shown until the presentation time reaches the next one.
  snapped,
}

/// A value of a synchronized field to present, from
/// [MultiplayerSynchronizer.interpolated].
final class InterpolatedValue<T> {
  const InterpolatedValue._(this.value, this.state);

  /// A new value, which the caller may change.
  final T value;

  /// How the value was produced.
  final InterpolationState state;

  @override
  String toString() => 'InterpolatedValue($value, ${state.name})';
}

/// Maps an authority's sample times onto this peer's clock.
///
/// Peers' clocks are not synchronized, so the timeline estimates their
/// offset: the smallest difference between a sample's local arrival and
/// its authority's sample time over a recent window, which includes the
/// fastest delivery. Later arrivals, such as a burst after a stall, do not
/// move it, while a lasting latency change does once the window passes.
final class _Timeline {
  _Timeline(this.delay);

  /// How far presentation trails the newest sample.
  final Duration delay;

  /// The arrivals whose offsets may still be the smallest in the window,
  /// oldest first. Their offsets increase from first to last, so the first
  /// one is the smallest.
  final _arrivals = ListQueue<({Duration at, Duration offset})>();
  Duration? _presented;

  /// The span of arrivals over which the smallest offset is taken.
  static const _window = Duration(seconds: 1);

  /// Records a sample taken at [sampledAt] on the authority's clock that
  /// arrived [at] this peer's time.
  void observe(Duration at, Duration sampledAt) {
    final offset = at - sampledAt;
    while (_arrivals.isNotEmpty && _arrivals.last.offset >= offset) {
      _arrivals.removeLast();
    }
    _arrivals.addLast((at: at, offset: offset));
    _expire(at);
  }

  /// The time on the authority's clock to present at [now], or `null`
  /// before any arrival.
  ///
  /// The time never decreases, so presentation pauses instead of rewinding
  /// when the estimated offset grows.
  Duration? presentationAt(Duration now) {
    if (_arrivals.isEmpty) return null;
    _expire(now);
    var time = now - _arrivals.first.offset - delay;
    final presented = _presented;
    if (presented != null && time < presented) time = presented;
    return _presented = time;
  }

  void _expire(Duration now) {
    while (_arrivals.length > 1 && now - _arrivals.first.at > _window) {
      _arrivals.removeFirst();
    }
  }
}

/// The received samples of one interpolated field, oldest first.
final class _Samples {
  final _entries = ListQueue<_Sample>();

  /// The most samples retained, which bounds memory if presentation is not
  /// read.
  static const _capacity = 32;

  bool get isEmpty => _entries.isEmpty;

  /// Adds a sample, unless it is not newer than the latest one.
  void add(Duration sampledAt, Uint8List bytes, Object? value) {
    if (_entries.isNotEmpty && sampledAt <= _entries.last.sampledAt) return;
    _entries.addLast(_Sample(sampledAt, bytes, value));
    if (_entries.length > _capacity) _entries.removeFirst();
  }

  /// The value to present at [time] on the authority's clock.
  ///
  /// Samples before the one in effect at [time] are forgotten. [copy]
  /// decodes a sample into a new value. After a pause longer than twice
  /// [interval], such as an unchanged [SyncMode.onChange] field, the
  /// earlier value holds until one interval before the next sample.
  InterpolatedValue<T> evaluate<T>(
    Duration time, {
    required Duration interval,
    required SyncProperty<Object?> property,
    required T Function(Uint8List bytes) copy,
  }) {
    while (_entries.length > 1 && _entries.elementAt(1).sampledAt <= time) {
      _entries.removeFirst();
    }
    final from = _entries.first;
    if (_entries.length == 1 || time < from.sampledAt) {
      return InterpolatedValue._(copy(from.bytes), InterpolationState.holding);
    }
    final to = _entries.elementAt(1);
    if (property._isTeleport(from.value, to.value)) {
      return InterpolatedValue._(copy(from.bytes), InterpolationState.snapped);
    }
    var start = from.sampledAt;
    if (to.sampledAt - start > interval * 2) start = to.sampledAt - interval;
    if (time <= start) {
      return InterpolatedValue._(
        copy(from.bytes),
        InterpolationState.interpolating,
      );
    }
    final t =
        (time - start).inMicroseconds / (to.sampledAt - start).inMicroseconds;
    return InterpolatedValue._(
      property._lerp(from.value, to.value, t) as T,
      InterpolationState.interpolating,
    );
  }
}

final class _Sample {
  const _Sample(this.sampledAt, this.bytes, this.value);

  /// When the authority sampled the value, on its clock.
  final Duration sampledAt;

  /// The canonical encoding, which [_Samples.evaluate] decodes into copies.
  final Uint8List bytes;

  /// The decoded value, which interpolators blend without modifying.
  final Object? value;
}
