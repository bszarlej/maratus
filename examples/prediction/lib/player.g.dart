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

  /// The synchronized field of [Player.syncedPosition].
  static const syncedPosition = SyncField(
    id: FieldId('prediction.player.position'),
    codec: arenaPoint,
  );

  static const _syncedPositionInterpolator = Vector2Interpolator(
    teleportDistance: 50,
  );

  /// The input stream whose inputs [Player.move] applies.
  static const move = InputStream(
    id: InputId('prediction.player.move'),
    codec: steering,
    tick: Duration(milliseconds: 20),
  );

  /// Registers the handles of [Player] with [builder].
  static void register(ProtocolSchemaBuilder builder) {
    builder
      ..addSpawnTypeDefinition(spawnType)
      ..addRpcDefinition(respawn)
      ..addFieldDefinition(syncedPosition)
      ..addInputDefinition(move);
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
  EntityAttachment? _$networkAttachment;
  MultiplayerSynchronizer? _$networkSynchronizer;
  Predictor<Vector2, Vector2>? _$networkPredictor;

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

  /// The predictor of [Player.syncedPosition] while the attachment of
  /// this [Player] is live, or `null`.
  ///
  /// [updateNetworkMembers] runs it every frame. To change the state outside
  /// its step, such as to respawn, set its state on the entity's authority.
  Predictor<Vector2, Vector2>? get networkPredictor {
    final attachment = _$networkAttachment;
    return attachment == null || attachment.isDisposed
        ? null
        : _$networkPredictor;
  }

  @override
  void bindNetworkMembers(EntityAttachment attachment) {
    super.bindNetworkMembers(attachment);
    final self = this as Player;
    attachment.bindRpc(PlayerNet.respawn, (context, payload) => self.respawn());
    _$networkAttachment = attachment;
    final prediction = attachment.predict(
      state: PlayerNet.syncedPosition,
      input: PlayerNet.move,
      initial: self.syncedPosition,
      step: Player.move,
      interpolator: PlayerNet._syncedPositionInterpolator,
    );
    _$networkPredictor = prediction;
    _$networkSynchronizer = attachment.synchronize([prediction.property()]);
  }

  @override
  void updateNetworkMembers(double dt) {
    super.updateNetworkMembers(dt);
    final prediction = networkPredictor;
    if (prediction == null) return;
    final self = this as Player;
    final elapsed = Duration(
      microseconds: (dt * Duration.microsecondsPerSecond).round(),
    );
    self.syncedPosition = prediction.update(self.direction, elapsed);
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
