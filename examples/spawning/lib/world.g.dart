// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'world.dart';

// **************************************************************************
// NetworkedGenerator
// **************************************************************************

/// The protocol handles of [Crate], generated from its annotations.
///
/// Register them on every peer with [register].
abstract final class CrateNet {
  /// The spawn type of [Crate].
  static const spawnType = SpawnType(
    id: SpawnTypeId('spawning.crate'),
    codec: arenaPoint,
  );

  /// Registers the handles of [Crate] with [builder].
  static void register(ProtocolSchemaBuilder builder) {
    builder.addSpawnTypeDefinition(spawnType);
  }
}

/// The protocol handles of [Player], generated from its annotations.
///
/// Register them on every peer with [register].
abstract final class PlayerNet {
  /// The spawn type of [Player].
  static const spawnType = SpawnType(
    id: SpawnTypeId('spawning.player'),
    codec: arenaPoint,
  );

  /// The RPC that [Player.dropFlag] handles.
  static const dropFlag = Rpc(
    id: RpcId('spawning.player.drop_flag'),
    codec: _PlayerDropFlagPayloadCodec(),
    caller: RpcCaller.owner,
  );

  /// Registers the handles of [Player] with [builder].
  static void register(ProtocolSchemaBuilder builder) {
    builder
      ..addSpawnTypeDefinition(spawnType)
      ..addRpcDefinition(dropFlag);
  }
}

/// The codec of the payload of [PlayerNet.dropFlag]: the parameters of
/// [Player.dropFlag] in a positional list.
final class _PlayerDropFlagPayloadCodec extends ValueCodec<()> {
  const _PlayerDropFlagPayloadCodec();

  @override
  String get descriptor => 'spawning.player.drop_flag@1()';

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
    attachment.bindRpc(
      PlayerNet.dropFlag,
      (context, payload) => self.dropFlag(),
    );
  }
}

/// Calls the RPCs of a [Player] over its session, as in
/// `component.rpc.dropFlag(...)`.
///
/// Each method returns whether the session accepted the call, as
/// [MultiplayerSession.callRpc] does.
extension type PlayerRpc._(Player _$component) {
  /// Calls [Player.dropFlag] through [PlayerNet.dropFlag].
  bool dropFlag() => _$call(PlayerNet.dropFlag, ());

  bool _$call<T>(Rpc<T> rpc, T payload, {PeerId? peer}) => _$component
      .multiplayerSession
      .callRpc(_$component.networkEntity, rpc, payload, peer: peer);
}

/// Provides the typed RPC senders of a [Player].
extension PlayerRpcAccess on Player {
  /// Calls the RPCs of this component over its session.
  PlayerRpc get rpc => PlayerRpc._(this);
}

/// The protocol handles of [Flag], generated from its annotations.
///
/// Register them on every peer with [register].
abstract final class FlagNet {
  /// The spawn type of [Flag].
  static const spawnType = SpawnType(
    id: SpawnTypeId('spawning.flag'),
    codec: arenaPoint,
  );

  /// Registers the handles of [Flag] with [builder].
  static void register(ProtocolSchemaBuilder builder) {
    builder.addSpawnTypeDefinition(spawnType);
  }
}
