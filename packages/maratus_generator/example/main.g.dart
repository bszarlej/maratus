// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'main.dart';

// **************************************************************************
// NetworkedGenerator
// **************************************************************************

/// The protocol handles of [Avatar], generated from its annotations.
///
/// Register them on every peer with [register].
abstract final class AvatarNet {
  /// The spawn type of [Avatar].
  static const spawnType = SpawnType(
    id: SpawnTypeId('example.avatar'),
    codec: StringCodec(maxLength: 32),
  );

  /// The RPC that [Avatar.steer] handles.
  static const steer = Rpc(
    id: RpcId('example.avatar.steer'),
    codec: IntCodec(min: -1, max: 1),
    caller: RpcCaller.owner,
  );

  /// The synchronized field of [Avatar.x].
  static const x = SyncField(
    id: FieldId('example.avatar.x'),
    codec: DoubleCodec(min: -100.0, max: 100.0),
  );

  /// Registers the handles of [Avatar] with [builder].
  static void register(ProtocolSchemaBuilder builder) {
    builder
      ..addSpawnTypeDefinition(spawnType)
      ..addRpcDefinition(steer)
      ..addFieldDefinition(x);
  }
}

/// Binds the annotated members of [Avatar].
mixin _$Avatar {
  EntityAttachment? _$networkAttachment;
  MultiplayerSynchronizer? _$networkSynchronizer;

  /// The synchronizer of the synchronized fields of this [Avatar] while its
  /// attachment is live, or `null`.
  ///
  /// Read interpolated values from it, as in
  /// `networkSynchronizer?.interpolated(AvatarNet.x)`.
  MultiplayerSynchronizer? get networkSynchronizer {
    final attachment = _$networkAttachment;
    return attachment == null || attachment.isDisposed
        ? null
        : _$networkSynchronizer;
  }

  /// Binds the annotated RPC handlers and synchronized fields of this [Avatar]
  /// through [attachment].
  ///
  /// Call it once for each attachment of the object's entity, such as the one
  /// that [MultiplayerSession.attachEntity] returns.
  void bindNetworkMembers(EntityAttachment attachment) {
    final self = this as Avatar;
    attachment.bindRpc(
      AvatarNet.steer,
      (context, payload) => self.steer(payload),
    );
    _$networkAttachment = attachment;
    _$networkSynchronizer = attachment.synchronize([
      AvatarNet.x.property(get: () => self.x, set: (value) => self.x = value),
    ]);
  }
}
