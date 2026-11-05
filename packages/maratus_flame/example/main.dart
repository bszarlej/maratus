import 'dart:math' as math;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/widgets.dart' hide Viewport;
import 'package:maratus_flame/maratus_flame.dart';

/// Runs a host and a client side by side in one game, joined by an
/// in-memory network with 60 milliseconds of latency each way.
///
/// The host spawns an avatar for itself and for the client. The host moves
/// both avatars, and the client shows their synchronized positions,
/// interpolated between samples. Tap the left or right half of either view to
/// steer that peer's own avatar with an owner-only RPC.
///
/// A real game hosts or joins over WebSockets instead; see the
/// `maratus` documentation for `WebSocketPeer`.
void main() {
  runApp(GameWidget(game: SplitScreenGame()));
}

/// A game with a host's view on the left and a client's view on the right.
class SplitScreenGame extends FlameGame {
  /// Creates the game; its network and sessions run on [clock].
  SplitScreenGame({this.clock = const SystemClock()});

  /// The clock of the network and both sessions.
  final MonotonicClock clock;

  /// The schema that both sessions register.
  final protocol = ArenaProtocol();

  /// The hosting session.
  late final MultiplayerSession host;

  /// The joining session.
  late final MultiplayerSession client;

  @override
  Future<void> onLoad() async {
    final network = InMemoryNetwork(
      clock: clock,
      latency: const Duration(milliseconds: 60),
    );
    host = MultiplayerSession(schema: protocol.schema, clock: clock)
      ..host(network.host());
    client = MultiplayerSession(schema: protocol.schema, clock: clock)
      ..join(network.connect());

    // Each scope drives its session and closes it when the game is removed.
    await addAll([
      PeerView(
        title: 'Host',
        session: host,
        protocol: protocol,
        position: Vector2(20, 20),
        extra: [HostRules(host, protocol)],
      ),
      PeerView(
        title: 'Client',
        session: client,
        protocol: protocol,
        position: Vector2(40 + ArenaProtocol.width, 20),
      ),
    ]);
  }
}

/// The definitions that the host and the client share.
final class ArenaProtocol {
  /// Registers the arena's spawn type, field, and RPC.
  factory ArenaProtocol() {
    final builder = ProtocolSchemaBuilder();
    final avatar = builder.addSpawnType(
      const SpawnTypeId('arena.avatar'),
      const IntCodec(min: 0, max: lanes - 1), // The avatar's lane.
    );
    final position = builder.addField(
      const FieldId('arena.avatar.position'),
      const Vector2Codec(
        x: DoubleCodec(min: 0, max: width),
        y: DoubleCodec(min: 0, max: height),
      ),
    );
    final steer = builder.addRpc(
      const RpcId('arena.avatar.steer'),
      const IntCodec(min: -1, max: 1),
      caller: RpcCaller.owner,
      target: RpcTarget.host,
      // Lets the host steer its own avatar with the same call.
      local: RpcLocal.include,
    );
    return ArenaProtocol._(builder.build(), avatar, position, steer);
  }

  ArenaProtocol._(this.schema, this.avatar, this.position, this.steer);

  /// The width of the arena.
  static const width = 360.0;

  /// The height of the arena.
  static const height = 280.0;

  /// The number of horizontal lanes that avatars move along.
  static const lanes = 4;

  /// The built schema.
  final ProtocolSchema schema;

  /// The avatar spawn type, constructed from its lane.
  final SpawnType<int> avatar;

  /// An avatar's position, written by the host.
  final SyncField<Vector2> position;

  /// The direction an avatar's owner asks it to move in.
  final Rpc<int> steer;
}

/// Spawns an avatar for the host and for each client that joins.
class HostRules extends Component {
  /// Creates the rules of the hosting [session].
  HostRules(this.session, this.protocol);

  /// The hosting session.
  final MultiplayerSession session;

  /// The shared definitions.
  final ArenaProtocol protocol;

  @override
  void onMount() {
    super.onMount();
    _spawnAvatar(PeerId.host);
  }

  @override
  void update(double dt) {
    // The scope has updated the session before this runs.
    for (var event = session.poll(); event != null; event = session.poll()) {
      if (event case PeerJoined(:final peer)) _spawnAvatar(peer);
    }
  }

  void _spawnAvatar(PeerId owner) {
    final lane = math.min(owner.value - 1, ArenaProtocol.lanes - 1);
    session.spawn(
      protocol.avatar,
      lane,
      owner: owner,
      onOwnerLeft: OwnerLeftPolicy.despawn,
    );
  }
}

/// One peer's view: a framed arena whose scope drives that peer's session.
class PeerView extends PositionComponent with TapCallbacks {
  /// Creates the view of [session], titled [title], with [extra] components
  /// in its scope.
  PeerView({
    required String title,
    required MultiplayerSession session,
    required ArenaProtocol protocol,
    super.position,
    List<Component> extra = const [],
  }) : super(
         size: Vector2(ArenaProtocol.width, ArenaProtocol.height),
         children: [
           MultiplayerScope(
             session: session,
             children: [
               MultiplayerSpawner()..register(
                 protocol.avatar,
                 (context) => Avatar(context, protocol),
               ),
               ...extra,
             ],
           ),
           SessionStatus(title, session, position: Vector2(10, 10)),
         ],
       );

  static final _frame = Paint()
    ..style = PaintingStyle.stroke
    ..color = const Color(0xff8899aa);

  @override
  void render(Canvas canvas) => canvas.drawRect(size.toRect(), _frame);

  @override
  void onTapDown(TapDownEvent event) {
    final direction = event.localPosition.x < size.x / 2 ? -1 : 1;
    for (final avatar in descendants().whereType<Avatar>()) {
      if (avatar.isOwn) avatar.steer(direction);
    }
  }
}

/// Shows a session's title and state.
class SessionStatus extends TextComponent {
  /// Creates a status line for [session].
  SessionStatus(this.title, this.session, {super.position});

  /// The name of the view.
  final String title;

  /// The session whose state is shown.
  final MultiplayerSession session;

  @override
  void update(double dt) {
    text = '$title: ${session.state.name}';
  }
}

/// An avatar that the spawner creates on both peers.
///
/// The host, its authority, moves it. The client presents the synchronized
/// position, interpolated between samples.
class Avatar extends PositionComponent with NetworkedComponent {
  /// Creates the component of a spawned avatar.
  Avatar(SpawnContext<int> context, this.protocol)
    : networkEntity = context.entity,
      lane = context.data,
      super(
        size: Vector2.all(24),
        anchor: Anchor.center,
        position: Vector2(ArenaProtocol.width / 2, 70 + context.data * 50),
      );

  static const _speed = 120.0;
  static const _colors = [
    Color(0xff65c7ad),
    Color(0xffffd089),
    Color(0xff8fb8ff),
    Color(0xfff28f8f),
  ];

  @override
  final NetworkEntity networkEntity;

  /// The shared definitions.
  final ArenaProtocol protocol;

  /// The lane the avatar moves along, from its construction data.
  final int lane;

  MultiplayerSynchronizer? _synchronizer;
  var _direction = 1;

  /// Whether this peer owns the avatar and may steer it.
  bool get isOwn =>
      isNetworkReady && networkEntity.owner == multiplayerSession.localPeer;

  bool get _isAuthority =>
      networkEntity.authority == multiplayerSession.localPeer;

  @override
  void onNetworkAttach(EntityAttachment attachment) {
    _synchronizer = attachment.synchronize([
      protocol.position.property(
        get: () => position,
        interpolator: const Vector2Interpolator(teleportDistance: 100),
      ),
    ]);
    attachment.bindRpc(protocol.steer, (call, direction) {
      _direction = direction;
    });
  }

  /// Asks the host to move this avatar in [direction].
  void steer(int direction) {
    multiplayerSession.callRpc(networkEntity, protocol.steer, direction);
  }

  @override
  void update(double dt) {
    if (!isNetworkReady) return;
    if (_isAuthority) {
      // Bounce between the arena's sides.
      position.x += _direction * _speed * dt;
      if (position.x < size.x || position.x > ArenaProtocol.width - size.x) {
        position.x = position.x.clamp(size.x, ArenaProtocol.width - size.x);
        _direction = -_direction;
      }
    } else if (_synchronizer?.interpolated(protocol.position)
        case final shown?) {
      position.setFrom(shown.value);
    }
  }

  @override
  void render(Canvas canvas) {
    canvas.drawRect(size.toRect(), Paint()..color = _colors[lane]);
  }
}
