import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/widgets.dart' hide Viewport;
import 'package:maratus_flame/maratus_flame.dart';

import 'arena.dart';

/// Runs a host and a client side by side.
void main() => runApp(GameWidget(game: VisibilityGame()));

/// A host's view on the left and a client's view on the right, joined by an
/// in-memory network.
///
/// The host spawns a grid of crates and a player for the client, and shows
/// the client only the crates near its player. A real game hosts or joins
/// over a transport such as WebSockets instead; see the `maratus`
/// documentation.
class VisibilityGame extends FlameGame with HasKeyboardHandlerComponents {
  /// Creates the game; its network and sessions run on [clock].
  VisibilityGame({this.clock = const SystemClock()});

  /// The clock of the network and both sessions.
  final MonotonicClock clock;

  /// The hosting session.
  late final MultiplayerSession host;

  /// The joining session.
  late final MultiplayerSession client;

  @override
  Future<void> onLoad() async {
    final schema = createSchema();
    final network = InMemoryNetwork(clock: clock);
    host = MultiplayerSession(schema: schema, clock: clock)
      ..host(network.host());
    client = MultiplayerSession(schema: schema, clock: clock)
      ..join(network.connect());

    // Each scope drives its session and closes it when the game is removed.
    await addAll([
      PeerView(
        'Host: every crate',
        host,
        spawner(),
        position: Vector2(20, 40),
        extra: [
          ArenaRules(host),
          // Shows the client the crates near the player that it owns, and
          // runs again five times a second, as the player moves.
          ProximityVisibility(
            showRange: showRange,
            hideRange: hideRange,
            interval: 0.2,
          ),
        ],
      ),
      PeerView(
        'Client: the crates near its player',
        client,
        spawner(),
        position: Vector2(40 + arenaSize, 40),
      ),
      label(
        "Hold the arrow keys to move the client's player. Crates come into "
        "the client's view inside its circle.",
        Vector2(20, 60 + arenaSize),
      ),
      label(
        'The host dims the crates that no client sees.',
        Vector2(20, 84 + arenaSize),
      ),
    ]);
  }
}

/// Creates a spawner for players and crates.
MultiplayerSpawner spawner() => MultiplayerSpawner()
  ..register(PlayerNet.spawnType, Player.new)
  ..register(CrateNet.spawnType, Crate.new);

/// The host's rules: a grid of crates and a player for each client that
/// joins.
class ArenaRules extends Component {
  /// Creates the rules of the hosting [session].
  ArenaRules(this.session);

  /// The hosting session.
  final MultiplayerSession session;

  @override
  void onLoad() {
    for (var x = 25.0; x < arenaSize; x += 50) {
      for (var y = 25.0; y < arenaSize; y += 50) {
        session.spawn(CrateNet.spawnType, Vector2(x, y));
      }
    }
  }

  @override
  void update(double dt) {
    // The scope has updated the session before this runs.
    for (var event = session.poll(); event != null; event = session.poll()) {
      if (event case PeerJoined(:final peer)) {
        session.spawn(
          PlayerNet.spawnType,
          Vector2.all(arenaSize / 2),
          owner: peer,
          onOwnerLeft: OwnerLeftPolicy.despawn,
        );
      }
    }
  }
}

/// One peer's view: a framed arena whose scope drives that peer's session.
class PeerView extends PositionComponent {
  /// Creates the view of [session], titled [title], with [spawner] and
  /// [extra] components in its scope.
  PeerView(
    String title,
    MultiplayerSession session,
    MultiplayerSpawner spawner, {
    super.position,
    List<Component> extra = const [],
  }) : super(
         size: Vector2.all(arenaSize),
         children: [
           MultiplayerScope(session: session, children: [spawner, ...extra]),
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
