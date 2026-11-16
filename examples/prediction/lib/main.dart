import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/widgets.dart' hide Viewport;
import 'package:maratus_flame/maratus_flame.dart';

import 'player.dart';

/// Runs a host and a client side by side.
void main() => runApp(GameWidget(game: PredictionGame()));

/// A host's view on the left and a client's view on the right, joined by an
/// in-memory network with [latency] each way.
///
/// The host spawns a player for the client, which steers it with the arrow
/// keys. A real game hosts or joins over a transport such as WebSockets
/// instead; see the `maratus` documentation.
class PredictionGame extends FlameGame with HasKeyboardHandlerComponents {
  /// Creates the game; its network and sessions run on [clock].
  PredictionGame({this.clock = const SystemClock()});

  /// How long each message takes to cross the simulated network.
  static const latency = Duration(milliseconds: 150);

  /// The clock of the network and both sessions.
  final MonotonicClock clock;

  /// The hosting session.
  late final MultiplayerSession host;

  /// The joining session.
  late final MultiplayerSession client;

  @override
  Future<void> onLoad() async {
    final schema = createSchema();
    final network = InMemoryNetwork(clock: clock, latency: latency);
    host = MultiplayerSession(schema: schema, clock: clock)
      ..host(network.host());
    client = MultiplayerSession(schema: schema, clock: clock)
      ..join(network.connect());

    // Each scope drives its session and closes it when the game is removed.
    await addAll([
      PeerView(
        'Host',
        host,
        position: Vector2(20, 40),
        onEvent: (event) => spawnPlayer(host, event),
      ),
      PeerView(
        'Client, ${latency.inMilliseconds} ms from the host',
        client,
        position: Vector2(40 + arenaSize, 40),
      ),
      label(
        "Hold the arrow keys to move the client's square. Press R to "
        'respawn it.',
        Vector2(20, 60 + arenaSize),
      ),
      label(
        'The client outlines where the host last had its square.',
        Vector2(20, 84 + arenaSize),
      ),
    ]);
  }
}

/// Spawns a player for the client that [event] reports joined the hosting
/// [session].
///
/// The host's scope passes each event of its session here.
void spawnPlayer(MultiplayerSession session, SessionEvent event) {
  if (event case PeerJoined(:final peer)) {
    session.spawn(
      PlayerNet.spawnType,
      Vector2.all(arenaSize / 2),
      owner: peer,
      onOwnerLeft: OwnerLeftPolicy.despawn,
    );
  }
}

/// One peer's view: a framed arena whose scope drives that peer's session.
class PeerView extends PositionComponent {
  /// Creates the view of [session], titled [title], whose scope passes the
  /// session's events to [onEvent].
  PeerView(
    String title,
    MultiplayerSession session, {
    super.position,
    void Function(SessionEvent event)? onEvent,
  }) : super(
         size: Vector2.all(arenaSize),
         children: [
           MultiplayerScope(
             session: session,
             onEvent: onEvent,
             children: [
               MultiplayerSpawner()..register(PlayerNet.spawnType, Player.new),
             ],
           ),
           label(title, Vector2(0, -24)),
         ],
       );

  static final _frame = Paint()
    ..style = PaintingStyle.stroke
    ..color = const Color(0xff8899aa);

  @override
  void render(Canvas canvas) => canvas.drawRect(size.toRect(), _frame);
}

/// A line of [text] at [position].
TextComponent label(String text, Vector2 position) => TextComponent(
  text: text,
  position: position,
  textRenderer: TextPaint(
    style: const TextStyle(fontSize: 14, color: Color(0xffffffff)),
  ),
);
