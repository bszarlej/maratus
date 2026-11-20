import 'dart:math';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/input.dart';
import 'package:flutter/widgets.dart' hide Viewport;
import 'package:maratus_flame/maratus_flame.dart';

import 'world.dart';

/// Runs a host and two clients that join and leave side by side.
void main() => runApp(GameWidget(game: SpawningGame()));

/// A host's view and two clients' views, joined by an in-memory network with
/// 60 ms of latency each way.
///
/// The host spawns crates, and a player for each client that joins. Each
/// client joins and leaves with a button, and asks the host for flags. A real
/// game hosts or joins over a transport such as WebSockets instead; see the
/// `maratus` documentation.
class SpawningGame extends FlameGame {
  /// Creates the game; its network and sessions run on [clock].
  SpawningGame({this.clock = const SystemClock()});

  /// The clock of the network and the sessions.
  final MonotonicClock clock;

  @override
  Future<void> onLoad() async {
    final schema = createSchema();
    final network = InMemoryNetwork(
      clock: clock,
      latency: const Duration(milliseconds: 60),
    );
    final host = MultiplayerSession(schema: schema, clock: clock)
      ..host(network.host());
    final views = <PeerView>[
      HostView(host),
      for (var i = 0; i < 2; i++)
        ClientView(
          () =>
              MultiplayerSession(schema: schema, clock: clock)
                ..join(network.connect()),
        ),
    ];
    for (final (index, view) in views.indexed) {
      view.position = Vector2(20 + index * (arenaSize + 20), 40);
    }
    await addAll(views);
  }
}

/// Creates a spawner for crates, players, and flags.
MultiplayerSpawner spawner() => MultiplayerSpawner()
  ..register(CrateNet.spawnType, Crate.new)
  ..register(PlayerNet.spawnType, Player.new)
  ..register(FlagNet.spawnType, Flag.new);

/// One peer's view: a framed arena, a title, a count of the components that
/// its spawner created, and buttons.
abstract class PeerView extends PositionComponent {
  /// Creates a view with a button for each of [actions].
  PeerView(this.actions) : super(size: Vector2.all(arenaSize));

  /// The buttons' labels, and what each does.
  final Map<String, void Function()> actions;

  /// The buttons, by label, so that a view can rename them.
  final buttons = <String, TextComponent>{};

  /// The spawner of this view's current session, if any.
  MultiplayerSpawner? get currentSpawner;

  /// The view's title.
  String get title;

  final _title = label('', Vector2(0, -24));
  final _count = label('', Vector2(0, arenaSize + 8));

  @override
  Future<void> onLoad() async {
    const width = (arenaSize - 8) / 2;
    await addAll([
      _title,
      _count,
      for (final (index, key) in actions.keys.indexed)
        button(
          key,
          () => actions[key]!(),
          Vector2(
            (index % 2) * (width + 8),
            arenaSize + 36 + (index ~/ 2) * 32,
          ),
          width,
          labels: buttons,
        ),
    ]);
  }

  @override
  void update(double dt) {
    super.update(dt);
    _title.text = title;
    final components = currentSpawner?.spawnedComponents.values ?? const [];
    int count<T>() => components.whereType<T>().length;
    _count.text =
        '${count<Crate>()} crates · ${count<Player>()} players · '
        '${count<Flag>()} flags';
  }

  static final _frame = Paint()
    ..style = PaintingStyle.stroke
    ..color = const Color(0xff8899aa);

  @override
  void render(Canvas canvas) => canvas.drawRect(size.toRect(), _frame);
}

/// The host's view. The host spawns crates with its buttons, and a player
/// for each client that joins.
class HostView extends PeerView {
  /// Creates the view of the hosting [session].
  HostView(this.session) : super({}) {
    actions
      ..['Spawn crate'] = spawnCrate
      ..['Despawn crate'] = despawnCrate;
  }

  /// The hosting session.
  final MultiplayerSession session;

  /// The spawner of the host's components.
  final MultiplayerSpawner hostSpawner = spawner();

  final _random = Random();

  @override
  MultiplayerSpawner get currentSpawner => hostSpawner;

  @override
  String get title => 'Host';

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    // The scope drives the session and closes it when the game is removed.
    await add(
      MultiplayerScope(
        session: session,
        onEvent: _onEvent,
        children: [hostSpawner],
      ),
    );
    for (var i = 0; i < 3; i++) {
      spawnCrate();
    }
  }

  void _onEvent(SessionEvent event) {
    if (event case PeerJoined(:final peer)) {
      // The player is despawned on every peer when its client leaves.
      session.spawn(
        PlayerNet.spawnType,
        _randomPoint(),
        owner: peer,
        onOwnerLeft: OwnerLeftPolicy.despawn,
      );
    }
  }

  /// Spawns a crate at a random point. The host owns it.
  void spawnCrate() => session.spawn(CrateNet.spawnType, _randomPoint());

  /// Despawns the oldest crate, if any.
  void despawnCrate() {
    final crate = hostSpawner.spawnedComponents.values
        .whereType<Crate>()
        .firstOrNull;
    if (crate != null) session.despawn(crate.networkEntity);
  }

  Vector2 _randomPoint() {
    double coordinate() => 30 + _random.nextDouble() * (arenaSize - 60);
    return Vector2(coordinate(), coordinate());
  }
}

/// A client's view, which joins the host with a new session and leaves it
/// again with its buttons.
class ClientView extends PeerView {
  /// Creates the view of a client whose sessions [connect] creates.
  ClientView(this.connect) : super({}) {
    actions
      ..[_join] = toggle
      ..['Drop flag'] = dropFlag;
  }

  static const _join = 'Join';
  static const _leave = 'Leave';

  /// Creates a session that joins the host.
  final MultiplayerSession Function() connect;

  MultiplayerScope? _scope;
  MultiplayerSpawner? _spawner;

  @override
  MultiplayerSpawner? get currentSpawner => _spawner;

  @override
  String get title => switch (_scope?.session) {
    null => 'Not joined',
    MultiplayerSession(state: SessionState.disconnected) => 'Disconnected',
    MultiplayerSession(:final localPeer?) => peerName(localPeer),
    _ => 'Joining…',
  };

  /// Joins the host with a new session, or leaves it.
  Future<void> toggle() async {
    if (_scope case final scope?) {
      // Removing the scope closes its session, and the host despawns the
      // player. A later join is a new peer with a new player.
      scope.removeFromParent();
      _scope = _spawner = null;
      buttons[_join]!.text = _join;
      return;
    }
    // The new session receives every entity that exists, then what changes.
    _spawner = spawner();
    final scope = _scope = MultiplayerScope(
      session: connect(),
      children: [_spawner!],
    );
    buttons[_join]!.text = _leave;
    await add(scope);
  }

  /// Asks the host to spawn a flag near this client's player.
  void dropFlag() {
    final session = _scope?.session;
    final peer = session?.localPeer;
    if (peer == null) return;
    final player = _spawner!
        .componentsOwnedBy(peer)
        .whereType<Player>()
        .firstOrNull;
    if (player != null && player.isNetworkReady) player.rpc.dropFlag();
  }
}

/// A button labelled [text] at [at], [width] wide, that calls [onPressed].
/// Its label is added to [labels] under [text].
ButtonComponent button(
  String text,
  void Function() onPressed,
  Vector2 at,
  double width, {
  required Map<String, TextComponent> labels,
}) => ButtonComponent(
  position: at,
  onPressed: onPressed,
  button: RectangleComponent(
    size: Vector2(width, 26),
    paint: Paint()..color = const Color(0xff2e3a4b),
    children: [labels[text] = label(text, Vector2(8, 4))],
  ),
);

/// A line of [text] at [position].
TextComponent label(String text, Vector2 position) => TextComponent(
  text: text,
  position: position,
  textRenderer: TextPaint(
    style: const TextStyle(fontSize: 14, color: Color(0xffffffff)),
  ),
);
