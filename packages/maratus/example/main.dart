// Libraries never print, but this example reports its progress.
// ignore_for_file: avoid_print

import 'package:maratus/maratus.dart';

/// Hosts a session and joins it from a client in one process, over an
/// in-memory network with 20 milliseconds of latency each way.
///
/// The host spawns an avatar for the client. The client steers it with an
/// owner-only RPC, the host moves it, and the avatar's position is
/// synchronized back to the client. A [ManualClock] drives the network and
/// both sessions, so the run is deterministic and takes no real time.
void main() {
  final protocol = GameProtocol();
  final clock = ManualClock();
  final network = InMemoryNetwork(
    clock: clock,
    latency: const Duration(milliseconds: 20),
  );
  final host = MultiplayerSession(schema: protocol.schema, clock: clock);
  final client = MultiplayerSession(schema: protocol.schema, clock: clock);
  final hostAvatars = protocol.bindAvatars(host);
  final clientAvatars = protocol.bindAvatars(client);

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
        switch (event) {
          case PeerJoined(:final peer):
            host.spawn(
              protocol.avatar,
              'Player ${peer.value}',
              owner: peer,
              onOwnerLeft: OwnerLeftPolicy.despawn,
            );
          case PeerReady(:final peer):
            print('Host: client ${peer.value} is ready.');
          default:
        }
      }
      for (var event = client.poll(); event != null; event = client.poll()) {
        if (event case SessionStateChanged(:final state)) {
          print('Client: ${state.name}.');
        }
      }

      if (!steered && client.state == SessionState.ready) {
        final own = clientAvatars.keys.firstWhere(
          (entity) => entity.owner == client.localPeer,
        );
        steered = client.callRpc(own, protocol.steer, 1);
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

    for (final avatar in clientAvatars.values) {
      final authoritative = hostAvatars.values.single;
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

/// The schema that the host and every client register.
///
/// Peers whose schemas differ fail the handshake.
final class GameProtocol {
  /// Registers the game's spawn types, fields, and RPCs.
  factory GameProtocol() {
    final builder = ProtocolSchemaBuilder();
    final avatar = builder.addSpawnType(
      const SpawnTypeId('example.avatar'),
      const StringCodec(maxLength: 32), // The player's name.
    );
    final x = builder.addField(
      const FieldId('example.avatar.x'),
      const DoubleCodec(min: -Avatar.bound, max: Avatar.bound),
    );
    final steer = builder.addRpc(
      const RpcId('example.avatar.steer'),
      const IntCodec(min: -1, max: 1),
      caller: RpcCaller.owner,
      target: RpcTarget.host,
    );
    return GameProtocol._(builder.build(), avatar, x, steer);
  }

  GameProtocol._(this.schema, this.avatar, this.x, this.steer);

  /// The built schema, shared by every session.
  final ProtocolSchema schema;

  /// The avatar spawn type, constructed from the player's name.
  final SpawnType<String> avatar;

  /// An avatar's horizontal position, written by its authority.
  final SyncField<double> x;

  /// The direction an avatar's owner asks it to move in.
  final Rpc<int> steer;

  /// Creates a local [Avatar] for each avatar that [session] spawns or
  /// receives, and returns them by entity.
  Map<NetworkEntity, Avatar> bindAvatars(MultiplayerSession session) {
    final avatars = <NetworkEntity, Avatar>{};
    session.bindSpawn(
      avatar,
      onSpawn: (context) {
        final local = Avatar(context.data);
        avatars[context.entity] = local;
        // Attaching a ready entity lets the client finish joining.
        session.attachEntity(
            context.entity,
            isReady: () => true,
            isValid: () => avatars[context.entity] == local,
          )
          ..synchronize([
            x.property(get: () => local.x, set: (value) => local.x = value),
          ])
          // Only the host receives steering calls, which target it.
          ..bindRpc(steer, (call, direction) => local.direction = direction);
      },
      onDespawn: avatars.remove,
    );
    return avatars;
  }
}

/// A player's avatar, as each peer represents it.
final class Avatar {
  /// Creates an avatar for the player called [name].
  Avatar(this.name);

  /// How far from the origin an avatar may move.
  static const bound = 100.0;

  /// The speed of a moving avatar, in units per second.
  static const speed = 20.0;

  /// The player's name, sent once when the avatar spawns.
  final String name;

  /// The horizontal position.
  double x = 0;

  /// The direction of movement: -1, 0, or 1.
  int direction = 0;

  /// Moves the avatar for the time of one [frame].
  void move(Duration frame) {
    final seconds = frame.inMicroseconds / Duration.microsecondsPerSecond;
    x = (x + direction * speed * seconds).clamp(-bound, bound);
  }
}
