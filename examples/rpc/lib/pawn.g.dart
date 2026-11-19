// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'pawn.dart';

// **************************************************************************
// NetworkedGenerator
// **************************************************************************

/// The protocol handles of [Pawn], generated from its annotations.
///
/// Register them on every peer with [register].
abstract final class PawnNet {
  /// The spawn type of [Pawn].
  static const spawnType = SpawnType(
    id: SpawnTypeId('rpc.pawn'),
    codec: IntCodec(min: 0, max: 1),
  );

  /// The RPC that [Pawn.step] handles.
  static const step = Rpc(
    id: RpcId('rpc.pawn.step'),
    codec: IntCodec(min: -1, max: 1),
    caller: RpcCaller.owner,
  );

  /// The RPC that [Pawn.say] handles.
  static const say = Rpc(
    id: RpcId('rpc.pawn.say'),
    codec: StringCodec(maxLength: 12),
    target: RpcTarget.all,
    local: RpcLocal.include,
  );

  /// The RPC that [Pawn.poke] handles.
  static const poke = Rpc(
    id: RpcId('rpc.pawn.poke'),
    codec: _PawnPokePayloadCodec(),
    target: RpcTarget.owner,
  );

  /// The RPC that [Pawn.whisper] handles.
  static const whisper = Rpc(
    id: RpcId('rpc.pawn.whisper'),
    codec: StringCodec(maxLength: 12),
    target: RpcTarget.peer,
  );

  /// The RPC that [Pawn.award] handles.
  static const award = Rpc(
    id: RpcId('rpc.pawn.award'),
    codec: IntCodec(min: 1, max: 3),
    caller: RpcCaller.host,
    target: RpcTarget.all,
    local: RpcLocal.include,
  );

  /// The synchronized field of [Pawn.column].
  static const column = SyncField(
    id: FieldId('rpc.pawn.column'),
    codec: IntCodec(min: 0, max: 7),
  );

  /// Registers the handles of [Pawn] with [builder].
  static void register(ProtocolSchemaBuilder builder) {
    builder
      ..addSpawnTypeDefinition(spawnType)
      ..addRpcDefinition(step)
      ..addRpcDefinition(say)
      ..addRpcDefinition(poke)
      ..addRpcDefinition(whisper)
      ..addRpcDefinition(award)
      ..addFieldDefinition(column);
  }
}

/// The codec of the payload of [PawnNet.poke]: the parameters of
/// [Pawn.poke] in a positional list.
final class _PawnPokePayloadCodec extends ValueCodec<()> {
  const _PawnPokePayloadCodec();

  @override
  String get descriptor => 'rpc.pawn.poke@1()';

  @override
  Object? encode(() value) => const <Object?>[];

  @override
  () decode(Object? wire) {
    WireList(wire, 0);
    return ();
  }
}

/// Binds the annotated members of [Pawn].
mixin _$Pawn on NetworkedComponent {
  EntityAttachment? _$networkAttachment;
  MultiplayerSynchronizer? _$networkSynchronizer;

  /// The synchronizer of the synchronized fields of this [Pawn] while its
  /// attachment is live, or `null`.
  ///
  /// Read the latest values from it, as in
  /// `networkSynchronizer?.snapshot(PawnNet.column)`.
  MultiplayerSynchronizer? get networkSynchronizer {
    final attachment = _$networkAttachment;
    return attachment == null || attachment.isDisposed
        ? null
        : _$networkSynchronizer;
  }

  @override
  void bindNetworkMembers(EntityAttachment attachment) {
    super.bindNetworkMembers(attachment);
    final self = this as Pawn;
    attachment
      ..bindRpc(PawnNet.step, (context, payload) => self.step(payload))
      ..bindRpc(PawnNet.say, (context, payload) => self.say(payload, context))
      ..bindRpc(PawnNet.poke, (context, payload) => self.poke(context))
      ..bindRpc(
        PawnNet.whisper,
        (context, payload) => self.whisper(payload, context),
      )
      ..bindRpc(PawnNet.award, (context, payload) => self.award(payload));
    _$networkAttachment = attachment;
    _$networkSynchronizer = attachment.synchronize([
      PawnNet.column.property(
        get: () => self.column,
        set: (value) => self.column = value,
      ),
    ]);
  }
}

/// Calls the RPCs of a [Pawn] over its session, as in
/// `component.rpc.step(...)`.
///
/// Each method returns whether the session accepted the call, as
/// [MultiplayerSession.callRpc] does.
extension type PawnRpc._(Pawn _$component) {
  /// Calls [Pawn.step] through [PawnNet.step].
  bool step(int direction) => _$call(PawnNet.step, direction);

  /// Calls [Pawn.say] through [PawnNet.say].
  bool say(String text) => _$call(PawnNet.say, text);

  /// Calls [Pawn.poke] through [PawnNet.poke].
  bool poke() => _$call(PawnNet.poke, ());

  /// Calls [Pawn.whisper] through [PawnNet.whisper].
  bool whisper(String text, {required PeerId to}) =>
      _$call(PawnNet.whisper, text, peer: to);

  /// Calls [Pawn.award] through [PawnNet.award].
  bool award(int stars) => _$call(PawnNet.award, stars);

  bool _$call<T>(Rpc<T> rpc, T payload, {PeerId? peer}) => _$component
      .multiplayerSession
      .callRpc(_$component.networkEntity, rpc, payload, peer: peer);
}

/// Provides the typed RPC senders of a [Pawn].
extension PawnRpcAccess on Pawn {
  /// Calls the RPCs of this component over its session.
  PawnRpc get rpc => PawnRpc._(this);
}
