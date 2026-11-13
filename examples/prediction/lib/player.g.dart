// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'player.dart';

// **************************************************************************
// NetworkedGenerator
// **************************************************************************

/// The protocol handles of [Player], generated from its annotations.
///
/// Register them on every peer with [register].
abstract final class PlayerNet {
  /// The spawn type of [Player].
  static const spawnType = SpawnType(
    id: SpawnTypeId('prediction.player'),
    codec: arenaPoint,
  );

  /// The RPC that [Player.respawn] handles.
  static const respawn = Rpc(
    id: RpcId('prediction.player.respawn'),
    codec: _PlayerRespawnPayloadCodec(),
    caller: RpcCaller.owner,
  );

  /// Registers the handles of [Player] with [builder].
  static void register(ProtocolSchemaBuilder builder) {
    builder
      ..addSpawnTypeDefinition(spawnType)
      ..addRpcDefinition(respawn);
  }
}

/// The codec of the payload of [PlayerNet.respawn]: the parameters of
/// [Player.respawn] in a positional list.
final class _PlayerRespawnPayloadCodec extends ValueCodec<()> {
  const _PlayerRespawnPayloadCodec();

  @override
  String get descriptor => 'prediction.player.respawn@1()';

  @override
  Object? encode(() value) => const <Object?>[];

  @override
  () decode(Object? wire) {
    WireList(wire, 0);
    return ();
  }
}

/// Binds the annotated members of [Player].
mixin _$Player on NetworkedComponent {
  @override
  void bindNetworkMembers(EntityAttachment attachment) {
    super.bindNetworkMembers(attachment);
    final self = this as Player;
    attachment.bindRpc(PlayerNet.respawn, (context, payload) => self.respawn());
  }
}

/// Calls the RPCs of a [Player] over its session, as in
/// `component.rpc.respawn(...)`.
///
/// Each method returns whether the session accepted the call, as
/// [MultiplayerSession.callRpc] does.
extension type PlayerRpc._(Player _$component) {
  /// Calls [Player.respawn] through [PlayerNet.respawn].
  bool respawn() => _$call(PlayerNet.respawn, ());

  bool _$call<T>(Rpc<T> rpc, T payload, {PeerId? peer}) => _$component
      .multiplayerSession
      .callRpc(_$component.networkEntity, rpc, payload, peer: peer);
}

/// Provides the typed RPC senders of a [Player].
extension PlayerRpcAccess on Player {
  /// Calls the RPCs of this component over its session.
  PlayerRpc get rpc => PlayerRpc._(this);
}
