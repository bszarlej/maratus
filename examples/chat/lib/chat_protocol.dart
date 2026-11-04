import 'package:maratus/maratus.dart';

/// The shared wire schema used by the Flutter app and the command-line host.
final class ChatProtocol {
  /// Registers one bounded string RPC broadcast to every ready peer, and the
  /// avatar spawn type.
  factory ChatProtocol() {
    final builder = ProtocolSchemaBuilder();
    final message = builder.addRpc(
      const RpcId('example.chat'),
      const StringCodec(maxLength: messageLimit),
      caller: RpcCaller.anyPeer,
      target: RpcTarget.all,
      local: RpcLocal.include,
    );
    final avatar = builder.addSpawnType(
      const SpawnTypeId('example.avatar'),
      const IntCodec(min: 0, max: avatarColors - 1),
    );
    final avatarOffset = builder.addField(
      const FieldId('example.avatar.offset'),
      const DoubleCodec(min: -12, max: 12),
    );
    return ChatProtocol._(builder.build(), message, avatar, avatarOffset);
  }

  ChatProtocol._(this.schema, this.message, this.avatar, this.avatarOffset);

  /// The maximum message length in UTF-16 code units.
  static const messageLimit = 240;

  /// The number of colors that the host chooses avatar colors from.
  static const avatarColors = 6;

  /// The schema all participants compare during the handshake.
  final ProtocolSchema schema;

  /// The typed handle used to send messages.
  final Rpc<String> message;

  /// A participant's avatar, constructed from the color index the host chose.
  final SpawnType<int> avatar;

  /// The avatar's vertical movement, simulated by the host and sent to clients.
  final SyncField<double> avatarOffset;

  /// Installs the same static entity on each peer after host or join starts.
  ///
  /// Installing before the first update ensures that the entity exists before
  /// any message for it can arrive. The session still gates RPC dispatch until
  /// the client is ready.
  NetworkEntity bind(
    MultiplayerSession session,
    void Function(PeerId sender, String text) onMessage,
  ) {
    final entity = register(session);
    session.bindRpc(entity, message, (context, text) {
      onMessage(context.sender, text);
    });
    session.registry.markReady(entity.id);
    return entity;
  }

  /// Registers the static chat entity, ID 1, owned by the host.
  ///
  /// Register it before spawning avatars, which take the following IDs.
  NetworkEntity register(MultiplayerSession session) => session.registry
      .register(const EntityId(1), owner: PeerId.host, authority: PeerId.host);

  /// Spawns the avatar of [owner] from a hosting [session].
  ///
  /// The host chooses the color, and despawns the avatar when [owner]
  /// leaves. Clients receive the avatar with every other replicated entity.
  NetworkEntity spawnAvatar(MultiplayerSession session, PeerId owner) =>
      session.spawn(
        avatar,
        (owner.value - 1) % avatarColors,
        owner: owner,
        onOwnerLeft: OwnerLeftPolicy.despawn,
      );

  /// Spawns an avatar for a client that [event] reports joined, if it is
  /// still connected to the hosting [session].
  void spawnJoinedAvatar(MultiplayerSession session, SessionEvent event) {
    if (event case PeerJoined(:final peer)
        when session.state == SessionState.hosting &&
            session.peers.contains(peer)) {
      spawnAvatar(session, peer);
    }
  }
}

/// Makes lifecycle and RPC diagnostics readable in both example frontends.
String describeEvent(SessionEvent event) => switch (event) {
  SessionStateChanged(:final state, :final reason) =>
    'Session: ${state.name}${reason == null ? '' : ' (${reason.name})'}',
  PeerJoined(:final peer) => 'Peer ${peer.value} joined',
  PeerReady(:final peer) => 'Peer ${peer.value} is ready',
  PeerLeft(:final peer, :final reason) =>
    'Peer ${peer.value} left (${reason.name})',
  RpcRejected(:final sender, :final reason) =>
    'Message from peer ${sender.value} rejected: ${reason.name}',
  RpcHandlerFailed(:final error) => 'Message handler failed: $error',
  SpawnHandlerFailed(:final entity, :final error) =>
    'Entity ${entity.value} could not be shown: $error',
  StateRejected(:final entity, :final sender, :final reason) =>
    'State of entity ${entity.value} from peer ${sender.value} ignored: '
        '${reason.name}',
  PropertySyncFailed(:final entity, :final field, :final error) =>
    'Entity ${entity.value} could not sync ${field.value}: $error',
};
