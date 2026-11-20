import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/widgets.dart' hide Viewport;
import 'package:maratus_flame/maratus_flame.dart';

import 'orb.dart';

/// Runs a host and two clients side by side, with sliders for the network.
void main() => runApp(GameWidget(game: InterpolationGame()));

/// A host's view and two clients' views, joined by an in-memory network.
///
/// The host moves an orb and sends its position. One client shows each
/// sample as it arrives, and the other blends between them. A real game
/// hosts or joins over a transport such as WebSockets instead; see the
/// `maratus` documentation.
class InterpolationGame extends FlameGame {
  /// Creates the game; its network and sessions run on [clock].
  InterpolationGame({this.clock = const SystemClock()});

  /// The clock of the network and the sessions.
  final MonotonicClock clock;

  var _settings = const NetworkSettings();
  Component? _demo;

  @override
  Future<void> onLoad() async {
    const top = 40 + arenaSize + 56;
    int interval() => _settings.interval.inMilliseconds;
    await addAll([
      SettingSlider(
        (value) => 'Latency: ${value.round()} ms each way',
        value: _settings.latency.inMilliseconds.toDouble(),
        min: 0,
        max: 300,
        divisions: 30,
        position: Vector2(sliderLeft, top),
        onChanged: (value) => _settings = _settings.copyWith(
          latency: Duration(milliseconds: value.round()),
        ),
        onChangeEnd: restart,
      ),
      SettingSlider(
        (value) => 'Send rate: ${value.round()} a second (${interval()} ms)',
        value: _settings.sendRate.toDouble(),
        min: 2,
        max: 30,
        divisions: 28,
        position: Vector2(sliderLeft, top + 36),
        onChanged: (value) =>
            _settings = _settings.copyWith(sendRate: value.round()),
        onChangeEnd: restart,
      ),
      SettingSlider(
        (value) =>
            'Interpolation delay: ${value % 1 == 0 ? value.round() : value} intervals '
            '(${_settings.delay.inMilliseconds} ms)',
        value: _settings.delayIntervals,
        min: 0.5,
        max: 4,
        divisions: 7,
        position: Vector2(sliderLeft, top + 72),
        onChanged: (value) =>
            _settings = _settings.copyWith(delayIntervals: value),
        onChangeEnd: restart,
      ),
    ]);
    await restart();
  }

  /// Replaces the network and the sessions with new ones that run with the
  /// current settings.
  ///
  /// The latency of a link and the interval of a synchronizer are fixed when
  /// they are created, so new settings need new ones.
  Future<void> restart() async {
    // Removing the views removes their scopes, which close their sessions.
    _demo?.removeFromParent();
    final demo = _demo = Component(children: _views(_settings));
    await add(demo);
  }

  List<PeerView> _views(NetworkSettings settings) {
    final schema = createSchema();
    final network = InMemoryNetwork(clock: clock, latency: settings.latency);
    MultiplayerSession session() =>
        MultiplayerSession(schema: schema, clock: clock);
    final host = PeerView(
      'Host',
      session()..host(network.host()),
      settings,
      caption: (_) => 'Sends ${settings.sendRate} samples a second',
    );
    Orb? hostOrb() => host.orb;
    final views = [
      host,
      PeerView(
        'Client: each sample',
        session()..join(network.connect()),
        settings,
        hostOrb: hostOrb,
        caption: (_) =>
            'Jumps to each sample ${settings.latency.inMilliseconds} ms '
            'after the host sent it',
      ),
      PeerView(
        'Client: interpolated',
        session()..join(network.connect()),
        settings,
        smooth: true,
        hostOrb: hostOrb,
        caption: (view) =>
            '${(settings.latency + settings.delay).inMilliseconds} ms behind '
            'the host · waiting for a sample in '
            '${(view.holding * 100).round()}% of frames',
      ),
    ];
    for (final (index, view) in views.indexed) {
      view.position = Vector2(20 + index * (arenaSize + 20), 40);
    }
    return views;
  }
}

/// One peer's view: a framed arena with the peer's orb, a title, and a
/// caption.
class PeerView extends PositionComponent {
  /// Creates the view of [session], whose orbs run with [settings] and blend
  /// between samples if [smooth].
  ///
  /// If [hostOrb] is given, the view outlines where the host's orb is now.
  PeerView(
    String title,
    this.session,
    this.settings, {
    required this.caption,
    this.smooth = false,
    this.hostOrb,
  }) : _title = label(title, Vector2(0, -24)),
       super(size: Vector2.all(arenaSize));

  /// The view's session.
  final MultiplayerSession session;

  /// The settings of the view's orb.
  final NetworkSettings settings;

  /// Whether the view's orb blends between samples.
  final bool smooth;

  /// The text below the view.
  final String Function(PeerView view) caption;

  /// The host's orb, if this view outlines it.
  final Orb? Function()? hostOrb;

  /// The share of recent frames in which the orb held its newest sample,
  /// waiting for the next one.
  double holding = 0;

  late final _spawner = MultiplayerSpawner()
    ..register(
      OrbNet.spawnType,
      (context) => Orb(context, settings: settings, smooth: smooth),
    );
  final TextComponent _title;
  final _caption = label('', Vector2(0, arenaSize + 8));

  /// The orb that this view's spawner created, if any.
  Orb? get orb =>
      _spawner.spawnedComponents.values.whereType<Orb>().firstOrNull;

  @override
  Future<void> onLoad() async {
    await addAll([
      _title,
      _caption,
      // The scope drives the session and closes it when it is removed.
      MultiplayerScope(session: session, children: [_spawner]),
    ]);
    if (session.state == SessionState.hosting) {
      session.spawn(
        OrbNet.spawnType,
        Vector2(arenaSize / 2 + 90, arenaSize / 2),
      );
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    final waiting = orb?.interpolationState == InterpolationState.holding;
    holding += ((waiting ? 1 : 0) - holding) * 0.05;
    _caption.text = caption(this);
  }

  static final _frame = Paint()
    ..style = PaintingStyle.stroke
    ..color = const Color(0xff8899aa);
  static final _hostOutline = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..color = const Color(0x88ffffff);

  @override
  void render(Canvas canvas) {
    canvas.drawRect(size.toRect(), _frame);
    if (hostOrb?.call() case final host?) {
      canvas.drawCircle(host.position.toOffset(), Orb.radius, _hostOutline);
    }
  }
}

/// Where the tracks of the sliders start, right of their labels.
const sliderLeft = 20.0 + 340;

/// A slider for a setting, labelled on its left by [text] of its value.
///
/// It calls [onChanged] while it is dragged or tapped, and [onChangeEnd]
/// when it is released.
class SettingSlider extends PositionComponent with DragCallbacks, TapCallbacks {
  /// Creates a slider for [value], from [min] to [max] in [divisions] steps.
  SettingSlider(
    this.text, {
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
    super.position,
  }) : super(size: Vector2(3 * (arenaSize + 20) - 340 - 20, 24));

  /// The label for a value.
  final String Function(double value) text;

  /// The current value.
  double value;

  /// The smallest value.
  final double min;

  /// The largest value.
  final double max;

  /// The number of steps from [min] to [max].
  final int divisions;

  /// Called with each new value.
  final void Function(double value) onChanged;

  /// Called when the slider is released.
  final void Function() onChangeEnd;

  late final _label = label('', Vector2(-340, 4));

  static final _track = Paint()..color = const Color(0xff2e3a4b);
  static final _knob = Paint()..color = const Color(0xff65c7ad);

  @override
  Future<void> onLoad() async {
    _label.text = text(value);
    await add(_label);
  }

  void _moveTo(double x) {
    final step = (max - min) / divisions;
    final t = (x / size.x).clamp(0.0, 1.0);
    final next = min + ((t * (max - min)) / step).round() * step;
    if (next == value) return;
    value = next;
    onChanged(value);
    _label.text = text(value);
  }

  @override
  void onTapDown(TapDownEvent event) => _moveTo(event.localPosition.x);

  @override
  void onTapUp(TapUpEvent event) => onChangeEnd();

  @override
  void onDragUpdate(DragUpdateEvent event) => _moveTo(event.localEndPosition.x);

  @override
  void onDragEnd(DragEndEvent event) {
    super.onDragEnd(event);
    onChangeEnd();
  }

  @override
  void render(Canvas canvas) {
    final y = size.y / 2;
    final x = (value - min) / (max - min) * size.x;
    canvas
      ..drawRRect(
        RRect.fromLTRBR(0, y - 3, size.x, y + 3, const Radius.circular(3)),
        _track,
      )
      ..drawCircle(Offset(x, y), 9, _knob);
  }
}

/// A line of [text] at [position].
TextComponent label(String text, Vector2 position) => TextComponent(
  text: text,
  position: position,
  textRenderer: TextPaint(
    style: const TextStyle(fontSize: 14, color: Color(0xffffffff)),
  ),
);
