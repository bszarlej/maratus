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
    id: SpawnTypeId('test.player'),
    codec: IntCodec(min: 0, max: 3),
  );

  /// The RPC that [Player.hit] handles.
  static const hit = Rpc(
    id: RpcId('test.player.hit'),
    codec: IntCodec(min: 1, max: 100),
    caller: RpcCaller.host,
    target: RpcTarget.all,
    local: RpcLocal.include,
  );

  /// The RPC that [Player.fire] handles.
  static const fire = Rpc(
    id: RpcId('test.player.fire'),
    codec: _PlayerFirePayloadCodec(),
    caller: RpcCaller.owner,
  );

  /// The RPC that [Player.whisper] handles.
  static const whisper = Rpc(
    id: RpcId('test.player.whisper'),
    codec: StringCodec(maxLength: 120),
    target: RpcTarget.peer,
  );

  /// The synchronized field of [Player.health].
  static const health = SyncField(
    id: FieldId('test.player.health'),
    codec: IntCodec(min: 0, max: 100),
  );

  /// The synchronized field of [Player.syncedPosition].
  static const syncedPosition = SyncField(
    id: FieldId('test.player.position'),
    codec: arenaPoint,
  );

  static const _syncedPositionInterpolator = Vector2Interpolator();

  /// Registers the handles of [Player] with [builder].
  static void register(ProtocolSchemaBuilder builder) {
    builder
      ..addSpawnTypeDefinition(spawnType)
      ..addRpcDefinition(hit)
      ..addRpcDefinition(fire)
      ..addRpcDefinition(whisper)
      ..addFieldDefinition(health)
      ..addFieldDefinition(syncedPosition);
  }
}

/// The codec of the payload of [PlayerNet.fire]: the parameters of
/// [Player.fire] in a positional list.
final class _PlayerFirePayloadCodec
    extends ValueCodec<({Vector2 at, int weapon})> {
  const _PlayerFirePayloadCodec();

  static const _at = arenaPoint;
  static const _weapon = IntCodec(min: 0, max: 3);

  @override
  String get descriptor =>
      'test.player.fire@1(${_at.descriptor},${_weapon.descriptor})';

  @override
  Object? encode(({Vector2 at, int weapon}) value) => [
    _at.encode(value.at),
    _weapon.encode(value.weapon),
  ];

  @override
  ({Vector2 at, int weapon}) decode(Object? wire) {
    final list = WireList(wire, 2);
    return (at: list.read(0, _at), weapon: list.read(1, _weapon));
  }
}

/// Binds the annotated members of [Player].
mixin _$Player on NetworkedComponent {
  EntityAttachment? _$networkAttachment;
  MultiplayerSynchronizer? _$networkSynchronizer;

  /// The synchronizer of the synchronized fields of this [Player] while its
  /// attachment is live, or `null`.
  ///
  /// Read interpolated values from it, as in
  /// `networkSynchronizer?.interpolated(PlayerNet.syncedPosition)`.
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
    attachment
      ..bindRpc(PlayerNet.hit, (context, payload) => self.hit(payload))
      ..bindRpc(
        PlayerNet.fire,
        (context, payload) => self.fire(payload.at, payload.weapon, context),
      )
      ..bindRpc(
        PlayerNet.whisper,
        (context, payload) => self.whisper(payload, context),
      );
    _$networkAttachment = attachment;
    _$networkSynchronizer = attachment.synchronize([
      PlayerNet.health.property(
        get: () => self.health,
        set: (value) => self.health = value,
      ),
      PlayerNet.syncedPosition.property(
        get: () => self.syncedPosition,
        interpolator: PlayerNet._syncedPositionInterpolator,
      ),
    ]);
  }
}

/// Calls the RPCs of a [Player] over its session, as in
/// `component.rpc.hit(...)`.
///
/// Each method returns whether the session accepted the call, as
/// [MultiplayerSession.callRpc] does.
extension type PlayerRpc._(Player _$component) {
  /// Calls [Player.hit] through [PlayerNet.hit].
  bool hit(int damage) => _$call(PlayerNet.hit, damage);

  /// Calls [Player.fire] through [PlayerNet.fire].
  bool fire(Vector2 at, int weapon) =>
      _$call(PlayerNet.fire, (at: at, weapon: weapon));

  /// Calls [Player.whisper] through [PlayerNet.whisper].
  bool whisper(String text, {required PeerId to}) =>
      _$call(PlayerNet.whisper, text, peer: to);

  bool _$call<T>(Rpc<T> rpc, T payload, {PeerId? peer}) => _$component
      .multiplayerSession
      .callRpc(_$component.networkEntity, rpc, payload, peer: peer);
}

/// Provides the typed RPC senders of a [Player].
extension PlayerRpcAccess on Player {
  /// Calls the RPCs of this component over its session.
  PlayerRpc get rpc => PlayerRpc._(this);
}
