import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/input.dart';
import 'package:flutter/widgets.dart' hide Viewport;
import 'package:maratus_flame/maratus_flame.dart';

import 'ball.dart';

/// Runs a host and two clients side by side.
void main() => runApp(GameWidget(game: OwnershipGame()));

/// What a button does in a view.
typedef Action = void Function(PeerView view);

/// A host's view and two clients' views, joined by an in-memory network with
/// 40 ms of latency each way.
///
/// The host spawns one ball, and each view's buttons move it or hand it to
/// another peer. A real game hosts or joins over a transport such as
/// WebSockets instead; see the `maratus` documentation.
class OwnershipGame extends FlameGame {
  /// Creates the game; its network and sessions run on [clock].
  OwnershipGame({this.clock = const SystemClock()});

  /// The clock of the network and the sessions.
  final MonotonicClock clock;

  @override
  Future<void> onLoad() async {
    final schema = createSchema();
    final network = InMemoryNetwork(
      clock: clock,
      latency: const Duration(milliseconds: 40),
    );
    MultiplayerSession session() =>
        MultiplayerSession(schema: schema, clock: clock);
    void transfer(PeerView view, PeerId Function(Ball ball) to) {
      final ball = view.ball;
      view.session.transferOwnership(ball.networkEntity, to(ball));
    }

    final moves = <String, Action>{
      '◀ Move': (view) => view.ball.move(-1),
      'Move ▶': (view) => view.ball.move(1),
    };
    final host = PeerView(session()..host(network.host()), {
      ...moves,
      'Give to next': (view) =>
          transfer(view, (ball) => nextPeer(view.session, ball.owner)),
      'Take back': (view) => transfer(view, (_) => PeerId.host),
    });
    final clients = [
      for (var i = 0; i < 2; i++)
        PeerView(session()..join(network.connect()), {
          ...moves,
          'Claim': (view) => view.ball.rpc.claim(),
          'Pass to next': (view) => view.ball.rpc.pass(),
        }),
    ];

    final views = [host, ...clients];
    for (final (index, view) in views.indexed) {
      view.position = Vector2(20 + index * (columns * cell + 20), 40);
    }
    await addAll(views);
  }
}

/// One peer's view: the ball, and buttons that move it or hand it over.
class PeerView extends PositionComponent {
  /// Creates the view of [session], with a button for each of [actions].
  PeerView(this.session, this.actions)
    : super(size: Vector2(columns * cell, trackHeight));

  /// The session that this view's scope drives.
  final MultiplayerSession session;

  /// The buttons' labels, and what each does.
  final Map<String, Action> actions;

  /// The spawner that creates this view's ball.
  final spawner = MultiplayerSpawner()..register(BallNet.spawnType, Ball.new);

  final _title = _label('', Vector2(0, -24));

  /// The ball in this view, if it has arrived.
  Ball? get _ball =>
      spawner.spawnedComponents.values.whereType<Ball>().firstOrNull;

  /// The ball in this view.
  Ball get ball => _ball!;

  @override
  Future<void> onLoad() async {
    const width = (columns * cell - 8) / 2;
    await addAll([
      // The scope drives the session and closes it when the game is removed.
      MultiplayerScope(
        session: session,
        children: [spawner, SessionEvents(this)],
      ),
      _title,
      for (final (index, MapEntry(:key, :value)) in actions.entries.indexed)
        _button(
          key,
          () => _call(value),
          Vector2((index % 2) * (width + 8), size.y + 12 + (index ~/ 2) * 32),
          width,
        ),
    ]);
  }

  void _call(Action action) {
    if (_ball?.isNetworkReady != true) return;
    try {
      action(this);
    } on ArgumentError catch (error) {
      // The host refused the transfer, for example to a client that left.
      ball.note('${error.message}', rejected: true);
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    final peer = session.localPeer;
    final owner = _ball?.owner;
    _title.text = [
      if (peer == null) 'Joining…' else peerName(peer),
      if (owner != null) 'ball owned by ${peerName(owner)}',
    ].join(' · ');
  }

  static final _frame = Paint()
    ..style = PaintingStyle.stroke
    ..color = const Color(0xff8899aa);

  @override
  void render(Canvas canvas) => canvas.drawRect(size.toRect(), _frame);
}

/// Handles the events of a view's session: the host spawns the ball once the
/// first client joins, every peer notes each ownership transfer, and the host
/// notes the calls it refuses.
class SessionEvents extends Component {
  /// Creates the handler of [view]'s session events.
  SessionEvents(this.view);

  /// The view whose session's events this handles.
  final PeerView view;

  var _spawned = false;

  @override
  void update(double dt) {
    final session = view.session;
    // The scope has updated the session before this runs.
    for (var event = session.poll(); event != null; event = session.poll()) {
      switch (event) {
        case PeerJoined() when session.isHost && !_spawned:
          _spawned = true;
          session.spawn(BallNet.spawnType, columns ~/ 2);
        case OwnerChanged(:final previous, :final owner):
          view.ball.note('${peerName(previous)} → ${peerName(owner)}');
        case RpcRejected(:final rpc, :final sender, :final reason):
          view.ball.note(
            '${rpc.value.split('.').last} from ${peerName(sender)}: '
            '${reason.name}',
            rejected: true,
          );
        default:
          break;
      }
    }
  }
}

ButtonComponent _button(
  String text,
  void Function() onPressed,
  Vector2 at,
  double width,
) => ButtonComponent(
  position: at,
  onPressed: onPressed,
  button: RectangleComponent(
    size: Vector2(width, 26),
    paint: Paint()..color = const Color(0xff2e3a4b),
    children: [_label(text, Vector2(8, 4))],
  ),
);

TextComponent _label(String text, Vector2 position) => TextComponent(
  text: text,
  position: position,
  textRenderer: TextPaint(
    style: const TextStyle(fontSize: 13, color: Color(0xffffffff)),
  ),
);
