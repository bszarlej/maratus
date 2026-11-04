import 'dart:async';
import 'dart:math' as math;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:maratus_flame/maratus_flame.dart';

import 'chat_protocol.dart';
import 'network_monitor.dart';

/// The example's Flame tree, updated and rendered by its GameWidget.
final class ChatGame extends FlameGame {
  /// Reports session events after the scope and its gameplay have updated.
  ///
  /// [clock] times the [diagnostics] summary.
  ChatGame({
    required void Function() onFrame,
    required void Function() onRemoved,
    MonotonicClock clock = const SystemClock(),
  }) : _onFrame = onFrame,
       _onRemoved = onRemoved,
       _clock = clock;

  final void Function() _onFrame;
  final void Function() _onRemoved;
  final MonotonicClock _clock;
  MultiplayerScope? _scope;
  ChatNetworkComponent? _chat;
  MultiplayerSpawner? _spawner;
  NetworkMonitor? _monitor;
  var _disposed = false;

  /// Whether avatars that other participants move show interpolated offsets
  /// rather than the latest ones received.
  var smoothing = true;

  /// Lines summarizing the session's network diagnostics, refreshed twice a
  /// second while a session is installed.
  final diagnostics = ValueNotifier<List<String>>(const []);

  /// The current static networked component, including while it loads.
  ChatNetworkComponent? get chatComponent => _chat;

  /// The avatars of the current session in entity order, which every
  /// participant shares.
  List<AvatarComponent> get avatars {
    final avatars = [
      ...?_spawner?.spawnedComponents.values.whereType<AvatarComponent>(),
    ];
    return avatars..sort(
      (a, b) => a.networkEntity.id.value.compareTo(b.networkEntity.id.value),
    );
  }

  /// Installs a new scope after the controller starts the session.
  ///
  /// The scope holds the static chat component and a spawner that creates an
  /// [AvatarComponent] for each avatar the host spawns.
  void installSession({
    required MultiplayerSession session,
    required NetworkEntity entity,
    required ChatProtocol protocol,
    required void Function(PeerId sender, String text) onMessage,
  }) {
    if (_disposed) throw StateError('The chat game has been disposed.');
    if (_scope != null) throw StateError('Remove the previous session first.');
    final component = _chat = ChatNetworkComponent(
      networkEntity: entity,
      message: protocol.message,
      onMessage: onMessage,
    );
    final spawner = _spawner = MultiplayerSpawner()
      ..register(
        protocol.avatar,
        (context) => AvatarComponent(
          context,
          offsetField: protocol.avatarOffset,
          isLocal: context.entity.owner == session.localPeer,
        ),
      );
    final scope = _scope = MultiplayerScope(
      session: session,
      children: [component, spawner],
    );
    _monitor = NetworkMonitor(session, clock: _clock);
    unawaited(Future<void>.sync(() => add(scope)));
  }

  /// Immediately detaches handlers before Flame processes tree removal.
  void clearSession() {
    final scope = _scope;
    _scope = null;
    _chat = null;
    _spawner = null;
    _monitor = null;
    if (!_disposed) diagnostics.value = const [];
    if (scope == null) return;
    scope.dispose();
    scope.removeFromParent();
  }

  @override
  Color backgroundColor() => const Color(0xff18242a);

  @override
  void update(double dt) {
    if (_disposed) return;
    super.update(dt);
    final row = avatars;
    for (var i = 0; i < row.length; i++) {
      row[i].position.setValues(
        14 + i * 76.0,
        size.y - 34 + row[i].shownOffset(smoothing: smoothing),
      );
    }
    final lines = _monitor?.sample([
      for (final avatar in row) avatar.smoothingState,
    ]);
    if (lines != null) diagnostics.value = lines;
    _onFrame();
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (_chat == null) {
      final text = TextPainter(
        text: const TextSpan(
          text: 'Host or join to mount the chat component.',
          style: TextStyle(color: Color(0xffc7d4d9), fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(0, size.x - 28));
      text.paint(canvas, const Offset(14, 20));
      text.dispose();
    }
  }

  @override
  void onRemove() {
    clearSession();
    _onRemoved();
    super.onRemove();
  }

  @override
  void dispose() {
    if (_disposed) return;
    clearSession();
    _disposed = true;
    diagnostics.dispose();
    super.dispose();
  }
}

/// A mounted Flame component that receives typed chat RPCs.
final class ChatNetworkComponent extends Component with NetworkedComponent {
  /// Creates the static chat component for the supplied registered entity.
  ChatNetworkComponent({
    required this.networkEntity,
    required Rpc<String> message,
    required void Function(PeerId sender, String text) onMessage,
  }) : _message = message,
       _onMessage = onMessage;

  @override
  final NetworkEntity networkEntity;
  final Rpc<String> _message;
  final void Function(PeerId sender, String text) _onMessage;
  var _messageCount = 0;
  var _capturedMessageCount = 0;
  var _lastMessage = 'Ready for messages.';
  var _pulse = 0.0;
  final _viewport = Vector2.zero();

  /// How many RPCs this mounted component has handled.
  int get messageCount => _messageCount;

  /// The message count sampled after gameplay in the most recent frame.
  int get capturedMessageCount => _capturedMessageCount;

  /// The latest message rendered by the component.
  String get lastMessage => _lastMessage;

  @override
  void onNetworkAttach(EntityAttachment attachment) {
    attachment.bindRpc(_message, (context, text) {
      _messageCount++;
      _lastMessage = 'Peer ${context.sender.value}: $text';
      _pulse = 1;
      _onMessage(context.sender, text);
    });
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    _viewport.setFrom(size);
  }

  @override
  void update(double dt) {
    super.update(dt);
    _pulse = math.max(0, _pulse - dt * 2);
  }

  @override
  void captureNetworkState(double dt) {
    _capturedMessageCount = _messageCount;
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    canvas.drawCircle(
      const Offset(22, 24),
      6 + _pulse * 3,
      Paint()
        ..color = Color.lerp(
          const Color(0xff65c7ad),
          const Color(0xffffd089),
          _pulse,
        )!,
    );
    _paintText(
      canvas,
      'Mounted chat component · $_capturedMessageCount received',
      const Offset(38, 14),
      13,
      const Color(0xffa7d7cc),
      maxLines: 1,
    );
    _paintText(
      canvas,
      _lastMessage,
      const Offset(14, 48),
      16,
      const Color(0xfff2f6f7),
      maxLines: 2,
    );
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset offset,
    double fontSize,
    Color color, {
    required int maxLines,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: math.max(0, _viewport.x - offset.dx - 14));
    painter.paint(canvas, offset);
    painter.dispose();
  }
}

/// A participant's avatar, which the spawner creates on every peer.
///
/// Its owner comes from the replicated entity and its color from the
/// construction data the host chose. The host simulates vertical movement;
/// clients receive the offset through property synchronization, and show it
/// interpolated between samples while smoothing is on.
final class AvatarComponent extends PositionComponent with NetworkedComponent {
  /// Creates the avatar of a spawned entity; [isLocal] marks this
  /// participant's own avatar.
  AvatarComponent(
    SpawnContext<int> context, {
    required SyncField<double> offsetField,
    required this.isLocal,
  }) : networkEntity = context.entity,
       colorIndex = context.data,
       _offsetField = offsetField,
       super(size: Vector2(70, 24));

  static const _palette = [
    Color(0xff65c7ad),
    Color(0xffffd089),
    Color(0xff8fb8ff),
    Color(0xfff28f8f),
    Color(0xffc9a3f5),
    Color(0xffa8d672),
  ];

  @override
  final NetworkEntity networkEntity;

  /// The index of the color that the host chose for this avatar.
  final int colorIndex;

  /// Whether this avatar belongs to this participant.
  final bool isLocal;

  final SyncField<double> _offsetField;
  MultiplayerSynchronizer? _synchronizer;
  InterpolatedValue<double>? _shown;
  var _elapsed = 0.0;
  var _verticalOffset = 0.0;

  /// The latest host-simulated movement offset, received directly on clients.
  double get verticalOffset => _verticalOffset;

  /// How the offset shown last was smoothed, or `null` if it was not: on
  /// the host, which simulates it, or with smoothing off.
  InterpolationState? get smoothingState => _shown?.state;

  /// The offset to show: interpolated between received samples when
  /// [smoothing] is on and another peer simulates the avatar, and the latest
  /// [verticalOffset] otherwise.
  double shownOffset({required bool smoothing}) {
    _shown = smoothing && isNetworkReady
        ? _synchronizer?.interpolated(_offsetField)
        : null;
    return _shown?.value ?? _verticalOffset;
  }

  /// The participant that controls this avatar.
  PeerId get owner => networkEntity.owner;

  /// The text drawn beside the avatar.
  String get label => isLocal ? 'You' : 'P${owner.value}';

  @override
  void onNetworkAttach(EntityAttachment attachment) {
    _synchronizer = attachment.synchronize([
      _offsetField.property(
        get: () => _verticalOffset,
        set: (value) => _verticalOffset = value,
        interpolator: const DoubleInterpolator(),
      ),
    ]);
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!isNetworkReady ||
        networkEntity.authority != multiplayerSession.localPeer) {
      return;
    }
    _elapsed += dt;
    _verticalOffset = math.sin(_elapsed * 2 + owner.value) * 12;
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    const center = Offset(12, 12);
    canvas.drawCircle(center, 10, Paint()..color = _palette[colorIndex]);
    if (isLocal) {
      canvas.drawCircle(
        center,
        11.5,
        Paint()
          ..color = const Color(0xfff2f6f7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    final text = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(color: Color(0xfff2f6f7), fontSize: 13),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: size.x - 28);
    text.paint(canvas, Offset(28, 12 - text.height / 2));
    text.dispose();
  }
}
