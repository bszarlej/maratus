// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ball.dart';

// **************************************************************************
// NetworkedGenerator
// **************************************************************************

/// The protocol handles of [Ball], generated from its annotations.
///
/// Register them on every peer with [register].
abstract final class BallNet {
  /// The spawn type of [Ball].
  static const spawnType = SpawnType(
    id: SpawnTypeId('ownership.ball'),
    codec: IntCodec(min: 0, max: 7),
  );

  /// The RPC that [Ball.claim] handles.
  static const claim = Rpc(
    id: RpcId('ownership.ball.claim'),
    codec: _BallClaimPayloadCodec(),
  );

  /// The RPC that [Ball.pass] handles.
  static const pass = Rpc(
    id: RpcId('ownership.ball.pass'),
    codec: _BallPassPayloadCodec(),
    caller: RpcCaller.owner,
  );

  /// The synchronized field of [Ball.column].
  static const column = SyncField(
    id: FieldId('ownership.ball.column'),
    codec: IntCodec(min: 0, max: 7),

    writer: FieldWriter.owner,
  );

  /// Registers the handles of [Ball] with [builder].
  static void register(ProtocolSchemaBuilder builder) {
    builder
      ..addSpawnTypeDefinition(spawnType)
      ..addRpcDefinition(claim)
      ..addRpcDefinition(pass)
      ..addFieldDefinition(column);
  }
}

/// The codec of the payload of [BallNet.claim]: the parameters of
/// [Ball.claim] in a positional list.
final class _BallClaimPayloadCodec extends ValueCodec<()> {
  const _BallClaimPayloadCodec();

  @override
  String get descriptor => 'ownership.ball.claim@1()';

  @override
  Object? encode(() value) => const <Object?>[];

  @override
  () decode(Object? wire) {
    WireList(wire, 0);
    return ();
  }
}

/// The codec of the payload of [BallNet.pass]: the parameters of
/// [Ball.pass] in a positional list.
final class _BallPassPayloadCodec extends ValueCodec<()> {
  const _BallPassPayloadCodec();

  @override
  String get descriptor => 'ownership.ball.pass@1()';

  @override
  Object? encode(() value) => const <Object?>[];

  @override
  () decode(Object? wire) {
    WireList(wire, 0);
    return ();
  }
}

/// Binds the annotated members of [Ball].
mixin _$Ball on NetworkedComponent {
  EntityAttachment? _$networkAttachment;
  MultiplayerSynchronizer? _$networkSynchronizer;

  /// The synchronizer of the synchronized fields of this [Ball] while its
  /// attachment is live, or `null`.
  ///
  /// Read the latest values from it, as in
  /// `networkSynchronizer?.snapshot(BallNet.column)`.
  MultiplayerSynchronizer? get networkSynchronizer {
    final attachment = _$networkAttachment;
    return attachment == null || attachment.isDisposed
        ? null
        : _$networkSynchronizer;
  }

  @override
  void bindNetworkMembers(EntityAttachment attachment) {
    super.bindNetworkMembers(attachment);
    final self = this as Ball;
    attachment
      ..bindRpc(BallNet.claim, (context, payload) => self.claim(context))
      ..bindRpc(BallNet.pass, (context, payload) => self.pass());
    _$networkAttachment = attachment;
    _$networkSynchronizer = attachment.synchronize([
      BallNet.column.property(
        get: () => self.column,
        set: (value) => self.column = value,
      ),
    ]);
  }
}

/// Calls the RPCs of a [Ball] over its session, as in
/// `component.rpc.claim(...)`.
///
/// Each method returns whether the session accepted the call, as
/// [MultiplayerSession.callRpc] does.
extension type BallRpc._(Ball _$component) {
  /// Calls [Ball.claim] through [BallNet.claim].
  bool claim() => _$call(BallNet.claim, ());

  /// Calls [Ball.pass] through [BallNet.pass].
  bool pass() => _$call(BallNet.pass, ());

  bool _$call<T>(Rpc<T> rpc, T payload, {PeerId? peer}) => _$component
      .multiplayerSession
      .callRpc(_$component.networkEntity, rpc, payload, peer: peer);
}

/// Provides the typed RPC senders of a [Ball].
extension BallRpcAccess on Ball {
  /// Calls the RPCs of this component over its session.
  BallRpc get rpc => BallRpc._(this);
}
