// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'arena.dart';

// **************************************************************************
// NetworkedGenerator
// **************************************************************************

/// The protocol handles of [Player], generated from its annotations.
///
/// Register them on every peer with [register].
abstract final class PlayerNet {
  /// The spawn type of [Player].
  static const spawnType = SpawnType(
    id: SpawnTypeId('visibility.player'),
    codec: arenaPoint,
  );

  /// The synchronized field of [Player.syncedPosition].
  static const syncedPosition = SyncField(
    id: FieldId('visibility.player.position'),
    codec: arenaPoint,

    writer: FieldWriter.owner,
  );

  static const _syncInterval = Duration(milliseconds: 20);

  /// Registers the handles of [Player] with [builder].
  static void register(ProtocolSchemaBuilder builder) {
    builder
      ..addSpawnTypeDefinition(spawnType)
      ..addFieldDefinition(syncedPosition);
  }
}

/// Binds the annotated members of [Player].
mixin _$Player on NetworkedComponent {
  EntityAttachment? _$networkAttachment;
  MultiplayerSynchronizer? _$networkSynchronizer;

  /// The synchronizer of the synchronized fields of this [Player] while its
  /// attachment is live, or `null`.
  ///
  /// Read the latest values from it, as in
  /// `networkSynchronizer?.snapshot(PlayerNet.syncedPosition)`.
  MultiplayerSynchronizer? get networkSynchronizer {
    final attachment = _$networkAttachment;
    return attachment == null || attachment.isDisposed
        ? null
        : _$networkSynchronizer;
  }

  @override
  void bindNetworkMembers(EntityAttachment attachment) {
    super.bindNetworkMembers(attachment);
    final self = this as Player;
    _$networkAttachment = attachment;
    _$networkSynchronizer = attachment.synchronize([
      PlayerNet.syncedPosition.property(
        get: () => self.syncedPosition,
        set: (value) => self.syncedPosition = value,
      ),
    ], interval: PlayerNet._syncInterval);
  }
}

/// The protocol handles of [Crate], generated from its annotations.
///
/// Register them on every peer with [register].
abstract final class CrateNet {
  /// The spawn type of [Crate].
  static const spawnType = SpawnType(
    id: SpawnTypeId('visibility.crate'),
    codec: arenaPoint,
  );

  /// Registers the handles of [Crate] with [builder].
  static void register(ProtocolSchemaBuilder builder) {
    builder.addSpawnTypeDefinition(spawnType);
  }
}
