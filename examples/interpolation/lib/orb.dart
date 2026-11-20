import 'dart:collection';
import 'dart:math';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:maratus_flame/maratus_flame.dart';

/// The side of the square arena that each view shows.
const arenaSize = 240.0;

/// The codec of positions within the arena.
const arenaPoint = Vector2Codec(
  x: DoubleCodec(min: 0, max: arenaSize),
  y: DoubleCodec(min: 0, max: arenaSize),
);

/// The settings that the network and the sessions run with.
final class NetworkSettings {
  /// Creates settings with [latency] each way, [sendRate] samples a second,
  /// and an interpolation delay of [delayIntervals] sample intervals.
  const NetworkSettings({
    this.latency = const Duration(milliseconds: 60),
    this.sendRate = 10,
    this.delayIntervals = 2,
  });

  /// How long each message takes to cross the network.
  final Duration latency;

  /// How many samples of the position the host sends a second.
  final int sendRate;

  /// How many sample intervals the smoothed position trails the newest
  /// sample.
  final double delayIntervals;

  /// The time between two samples.
  Duration get interval => Duration(microseconds: 1000000 ~/ sendRate);

  /// How far the smoothed position trails the newest sample.
  Duration get delay => interval * delayIntervals;

  /// Returns a copy with the given settings replaced.
  NetworkSettings copyWith({
    Duration? latency,
    int? sendRate,
    double? delayIntervals,
  }) => NetworkSettings(
    latency: latency ?? this.latency,
    sendRate: sendRate ?? this.sendRate,
    delayIntervals: delayIntervals ?? this.delayIntervals,
  );
}

/// The protocol handles of [Orb], written by hand rather than generated, so
/// that [Orb] can choose its sample interval and interpolation delay when it
/// is created.
abstract final class OrbNet {
  /// The spawn type of [Orb], whose data is its starting position.
  static const spawnType = SpawnType(
    id: SpawnTypeId('interpolation.orb'),
    codec: arenaPoint,
  );

  /// The orb's position, which the host writes.
  static const position = SyncField(
    id: FieldId('interpolation.orb.position'),
    codec: arenaPoint,
  );

  /// Registers the handles of [Orb] with [builder].
  static void register(ProtocolSchemaBuilder builder) {
    builder
      ..addSpawnTypeDefinition(spawnType)
      ..addFieldDefinition(position);
  }
}

/// Creates the schema that the host and the clients share.
ProtocolSchema createSchema() {
  final builder = ProtocolSchemaBuilder();
  OrbNet.register(builder);
  return builder.build();
}

/// An orb that the host moves along a looping path, and whose position it
/// sends [NetworkSettings.sendRate] times a second.
///
/// A client that [smooth]s it blends between the samples it receives, and
/// presents the result [NetworkSettings.delay] behind the newest one. Any
/// other client jumps from sample to sample.
class Orb extends PositionComponent with NetworkedComponent {
  /// Creates the orb that the host spawned at the position in [context].
  Orb(
    SpawnContext<Vector2> context, {
    required this.settings,
    this.smooth = false,
  }) : networkEntity = context.entity,
       super(
         position: context.data,
         size: Vector2.all(radius * 2),
         anchor: Anchor.center,
       );

  /// The orb's radius.
  static const radius = 10.0;

  /// How many of the latest samples the orb shows as dots.
  static const trailLength = 12;

  /// The settings that the orb was created with.
  final NetworkSettings settings;

  /// Whether this peer blends between the samples that it receives.
  final bool smooth;

  @override
  final NetworkEntity networkEntity;

  /// The latest samples that this peer sent or received, oldest first.
  final samples = ListQueue<Vector2>();

  MultiplayerSynchronizer? _synchronizer;
  Duration? _sampleTime;
  double _time = 0;

  /// How the smoothed position was produced in the last frame, or `null` on
  /// the host and on a client that does not smooth it.
  InterpolationState? get interpolationState =>
      smooth ? _synchronizer?.interpolated(OrbNet.position)?.state : null;

  static final _fill = Paint()..color = const Color(0xff65c7ad);
  static final _sample = Paint()..color = const Color(0x99e0a458);

  @override
  void onNetworkAttach(EntityAttachment attachment) {
    _synchronizer = attachment.synchronize(
      [
        OrbNet.position.property(
          get: () => position,
          set: (value) => position.setFrom(value),
          // Without an interpolator, the setter receives each sample as it
          // arrives. With one, it receives values blended between them.
          interpolator: smooth ? const Vector2Interpolator() : null,
        ),
      ],
      // The host samples the position once per interval. A client presents
      // the smoothed position this far behind the newest sample.
      interval: settings.interval,
      interpolationDelay: settings.delay,
    );
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (isNetworkOwner) {
      _time += dt;
      position.setValues(
        arenaSize / 2 + cos(_time * 1.3) * 90,
        arenaSize / 2 + sin(_time * 2.1) * 90,
      );
    }
    _recordSample();
  }

  /// Keeps the latest sample that this peer sent or received.
  void _recordSample() {
    final snapshot = _synchronizer?.snapshot(OrbNet.position);
    if (snapshot == null || snapshot.time == _sampleTime) return;
    _sampleTime = snapshot.time;
    samples.addLast(snapshot.value);
    if (samples.length > trailLength) samples.removeFirst();
  }

  @override
  void render(Canvas canvas) {
    // The samples are in the arena's coordinates, and the canvas is the
    // orb's own.
    for (final sample in samples) {
      canvas.drawCircle((sample - position + size / 2).toOffset(), 3, _sample);
    }
    canvas.drawCircle((size / 2).toOffset(), radius, _fill);
  }
}
