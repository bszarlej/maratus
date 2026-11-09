// Libraries never print, but this example reports its progress.
// ignore_for_file: avoid_print

import 'package:maratus/maratus.dart';
import 'package:maratus_annotations/maratus_annotations.dart';

part 'main.g.dart';

/// Hosts a session and joins it from a client in one process, over an
/// in-memory network with 20 milliseconds of latency each way.
///
/// The host spawns an avatar for the client. The client steers it with an
/// owner-only RPC, the host moves it, and the avatar's position is
/// synchronized back to the client. The annotations of [Avatar] declare all
/// three, and `dart run build_runner build` generates their handles and
/// bindings into `main.g.dart`.
void main() {
  final builder = ProtocolSchemaBuilder();
  AvatarNet.register(builder);
  final schema = builder.build();

  final clock = ManualClock();
  final network = InMemoryNetwork(
    clock: clock,
    latency: const Duration(milliseconds: 20),
  );
  final host = MultiplayerSession(schema: schema, clock: clock);
  final client = MultiplayerSession(schema: schema, clock: clock);
  final hostAvatars = bindAvatars(host);
  final clientAvatars = bindAvatars(client);

  host.host(network.host());
  client.join(network.connect());

  const frame = Duration(milliseconds: 16);
  var steered = false;
  try {
    // About two seconds of 60 Hz frames, as a game loop would run them.
    for (var i = 0; i < 120; i++) {
      clock.advance(frame);

      // 1. Consume network events and apply received changes.
      host.update();
      client.update();

      // 2. Run gameplay.
      for (var event = host.poll(); event != null; event = host.poll()) {
        if (event case PeerJoined(:final peer)) {
          host.spawn(
            AvatarNet.spawnType,
            'Player ${peer.value}',
            owner: peer,
            onOwnerLeft: OwnerLeftPolicy.despawn,
          );
        }
      }
      if (!steered && client.state == SessionState.ready) {
        final own = clientAvatars.keys.firstWhere(
          (entity) => entity.owner == client.localPeer,
        );
        steered = client.callRpc(own, AvatarNet.steer, 1);
        print('Client: steering ${clientAvatars[own]!.name} to the right.');
      }

      // The host is the avatars' authority, so only it moves them.
      for (final avatar in hostAvatars.values) {
        avatar.move(frame);
      }

      // 3. Send the authority's changed properties.
      host.captureState();
      client.captureState();
    }

    final authoritative = hostAvatars.values.single;
    for (final avatar in clientAvatars.values) {
      print(
        'Client sees ${avatar.name} at x = ${avatar.x.toStringAsFixed(1)}; '
        'the host has it at x = ${authoritative.x.toStringAsFixed(1)}.',
      );
    }
  } finally {
    client.close();
    host.close();
  }
}

/// Creates a local [Avatar] for each avatar that [session] spawns or
/// receives, binds its annotated members, and returns the avatars by entity.
Map<NetworkEntity, Avatar> bindAvatars(MultiplayerSession session) {
  final avatars = <NetworkEntity, Avatar>{};
  session.bindSpawn(
    AvatarNet.spawnType,
    onSpawn: (context) {
      final avatar = avatars[context.entity] = Avatar(context);
      // Attaching a ready entity lets the client finish joining.
      avatar.bindNetworkMembers(
        session.attachEntity(
          context.entity,
          isReady: () => true,
          isValid: () => avatars[context.entity] == avatar,
        ),
      );
    },
    onDespawn: avatars.remove,
  );
  return avatars;
}

/// A player's avatar, as each peer represents it.
@Networked(spawnType: 'example.avatar')
final class Avatar with _$Avatar {
  /// Creates the avatar of a spawned entity, named by its spawn data.
  Avatar(@MaxLength(32) SpawnContext<String> context) : name = context.data;

  /// How far from the origin an avatar may move.
  static const bound = 100.0;

  /// The speed of a moving avatar, in units per second.
  static const speed = 20.0;

  /// The player's name, sent once when the avatar spawns.
  final String name;

  /// The horizontal position, written by the avatar's authority.
  @SyncedField('example.avatar.x')
  @Range(min: -bound, max: bound)
  double x = 0;

  /// The direction of movement: -1, 0, or 1.
  int direction = 0;

  /// Steers the avatar in [direction]; only its owner may ask.
  @RpcMethod('example.avatar.steer', caller: RpcCaller.owner)
  void steer(@Range(min: -1, max: 1) int direction) =>
      this.direction = direction;

  /// Moves the avatar for the time of one [frame].
  void move(Duration frame) {
    final seconds = frame.inMicroseconds / Duration.microsecondsPerSecond;
    x = (x + direction * speed * seconds).clamp(-bound, bound);
  }
}
