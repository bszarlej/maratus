import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/input.dart';
import 'package:flutter/widgets.dart' hide Viewport;
import 'package:maratus_flame/maratus_flame.dart';

import 'pawn.dart';

/// Runs a host and two clients side by side.
void main() => runApp(GameWidget(game: RpcGame()));

/// What a button does in a view.
typedef Action = void Function(PeerView view);

/// A host's view and two clients' views, joined by an in-memory network with
/// 40 ms of latency each way.
///
/// The host spawns a pawn for each client, and each view's buttons call the
/// pawns' RPCs. A real game hosts or joins over a transport such as
/// WebSockets instead; see the `maratus` documentation.
class RpcGame extends FlameGame {
  /// Creates the game; its network and sessions run on [clock].
  RpcGame({this.clock = const SystemClock()});

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

    final host = PeerView(session()..host(network.host()), {
      'Poke every pawn': (view) {
        for (final pawn in view.pawns) {
          pawn.rpc.poke();
        }
      },
      'Award every pawn': (view) {
        for (final pawn in view.pawns) {
          pawn.rpc.award(pawn.row + 1);
        }
      },
      'Step (not allowed)': (view) => view.pawns.first.rpc.step(1),
    });
    final clients = [
      for (var i = 0; i < rows; i++)
        PeerView(session()..join(network.connect()), {
          '◀ Step': (view) => view.own.rpc.step(-1),
          'Step ▶': (view) => view.own.rpc.step(1),
          'Say hello': (view) => view.own.rpc.say('hello'),
          'Say too much': (view) => view.own.rpc.say('hello, everybody!'),
          'Whisper to other': (view) {
            final to = view.other.networkEntity.owner;
            if (view.own.rpc.whisper('psst', to: to)) {
              view.own.note('to ${peerName(to)}: psst');
            }
          },
          "Poke other's pawn": (view) => view.other.rpc.poke(),
          "Step other's (not allowed)": (view) => view.other.rpc.step(1),
          'Award (not allowed)': (view) => view.own.rpc.award(3),
        }),
    ];

    final views = [host, ...clients];
    for (final (index, view) in views.indexed) {
      view.position = Vector2(20 + index * (columns * cell + 20), 40);
    }
    await addAll(views);
  }
}

/// One peer's view: the pawns, and buttons that call their RPCs.
class PeerView extends PositionComponent {
  /// Creates the view of [session], with a button for each of [actions].
  PeerView(this.session, this.actions)
    : super(size: Vector2(columns * cell, rows * rowHeight));

  /// The session that this view's scope drives.
  final MultiplayerSession session;

  /// The buttons' labels, and what each does.
  final Map<String, Action> actions;

  /// The spawner that creates this view's pawns.
  final spawner = MultiplayerSpawner()..register(PawnNet.spawnType, Pawn.new);

  final _title = _label('', Vector2(0, -24));

  /// The pawns in this view.
  Iterable<Pawn> get pawns => spawner.spawnedComponents.values.whereType();

  /// The pawn that this view's client owns.
  Pawn get own => pawns.firstWhere((pawn) => pawn.isNetworkOwner);

  /// The pawn that the other client owns.
  Pawn get other => pawns.firstWhere((pawn) => !pawn.isNetworkOwner);

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
    // Wait until both pawns are ready on this peer.
    if (pawns.where((pawn) => pawn.isNetworkReady).length < rows) return;
    try {
      action(this);
    } on ArgumentError catch (error) {
      // The payload's codec refused it on this peer, so nothing was sent.
      own.note('not sent: ${error.message}', rejected: true);
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    _title.text = switch (session.localPeer) {
      final peer? => peerName(peer),
      null => 'Joining…',
    };
  }

  static final _frame = Paint()
    ..style = PaintingStyle.stroke
    ..color = const Color(0xff8899aa);

  @override
  void render(Canvas canvas) => canvas.drawRect(size.toRect(), _frame);
}

/// Handles the events of a view's session: the host spawns a pawn for each
/// client that joins, and a peer that rejects a call shows why on the pawn.
class SessionEvents extends Component {
  /// Creates the handler of [view]'s session events.
  SessionEvents(this.view);

  /// The view whose session's events this handles.
  final PeerView view;

  @override
  void update(double dt) {
    final session = view.session;
    // The scope has updated the session before this runs.
    for (var event = session.poll(); event != null; event = session.poll()) {
      switch (event) {
        case PeerJoined(:final peer) when session.isHost:
          final row = view.pawns.length;
          if (row >= rows) break;
          session.spawn(
            PawnNet.spawnType,
            row,
            owner: peer,
            onOwnerLeft: OwnerLeftPolicy.despawn,
          );
        case RpcRejected(
          :final entity,
          :final rpc,
          :final sender,
          :final reason,
        ):
          final pawn = view.pawns.where((p) => p.networkEntity.id == entity);
          pawn.firstOrNull?.note(
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
    style: const TextStyle(fontSize: 14, color: Color(0xffffffff)),
  ),
);
