// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'avatar.dart';

// **************************************************************************
// NetworkedGenerator
// **************************************************************************

/// The protocol handles of [Avatar], generated from its annotations.
///
/// Register them on every peer with [register].
abstract final class AvatarNet {
  /// The spawn type of [Avatar].
  static const spawnType = SpawnType(
    id: SpawnTypeId('test.avatar'),
    codec: StringCodec(maxLength: 32),
  );

  /// The RPC that [Avatar.steer] handles.
  static const steer = Rpc(
    id: RpcId('test.avatar.steer'),
    codec: IntCodec(min: -1, max: 1),
    caller: RpcCaller.owner,
    deliveryMode: DeliveryMode.unreliableOrdered,
    channel: 1,
  );

  /// The RPC that [Avatar.say] handles.
  static const say = Rpc(
    id: RpcId('test.avatar.say'),
    codec: _AvatarSayPayloadCodec(),
    target: RpcTarget.all,
    local: RpcLocal.include,
  );

  /// The RPC that [Avatar.jump] handles.
  static const jump = Rpc(
    id: RpcId('test.avatar.jump'),
    codec: _AvatarJumpPayloadCodec(),
  );

  /// The synchronized field of [Avatar.x].
  static const x = SyncField(
    id: FieldId('test.avatar.x'),
    codec: DoubleCodec(min: -100.0, max: 100.0),
  );

  static const _xInterpolator = DoubleInterpolator();

  /// The synchronized field of [Avatar.input].
  static const input = SyncField(
    id: FieldId('test.avatar.input'),
    codec: MoveInputCodec(),
    deliveryMode: DeliveryMode.unreliable,
    channel: 2,
  );

  /// The synchronized field of [Avatar.altitude].
  static const altitude = SyncField(
    id: FieldId('test.avatar.altitude'),
    codec: DoubleCodec(min: 0, max: 100.0),
    deliveryMode: DeliveryMode.unreliable,
    channel: 1,
  );

  static const _altitudeInterpolator = DoubleInterpolator();

  /// The synchronized field of [Avatar.label].
  static const label = SyncField(
    id: FieldId('test.avatar.label'),
    codec: StringCodec(maxLength: 40),
  );

  /// The input stream whose inputs [Avatar.fly] applies.
  static const fly = InputStream(
    id: InputId('test.avatar.fly'),
    codec: BoolCodec(),
    tick: Duration(milliseconds: 20),
    deliveryMode: DeliveryMode.unreliableOrdered,
    channel: 2,
  );

  static const _flySmoothing = Duration(milliseconds: 40);

  static const _flyIdleInput = false;

  static const _syncInterval = Duration(milliseconds: 20);

  /// Registers the handles of [Avatar] with [builder].
  static void register(ProtocolSchemaBuilder builder) {
    builder
      ..addSpawnTypeDefinition(spawnType)
      ..addRpcDefinition(steer)
      ..addRpcDefinition(say)
      ..addRpcDefinition(jump)
      ..addFieldDefinition(x)
      ..addFieldDefinition(input)
      ..addFieldDefinition(altitude)
      ..addFieldDefinition(label)
      ..addInputDefinition(fly);
  }
}

/// The codec of the payload of [AvatarNet.say]: the parameters of
/// [Avatar.say] in a positional list.
final class _AvatarSayPayloadCodec
    extends ValueCodec<({String text, int volume})> {
  const _AvatarSayPayloadCodec();

  static const _text = StringCodec(maxLength: 64);
  static const _volume = IntCodec(min: 0, max: 10);

  @override
  String get descriptor =>
      'test.avatar.say@2(${_text.descriptor},${_volume.descriptor})';

  @override
  Object? encode(({String text, int volume}) value) => [
    _text.encode(value.text),
    _volume.encode(value.volume),
  ];

  @override
  ({String text, int volume}) decode(Object? wire) {
    final list = WireList(wire, 2);
    return (text: list.read(0, _text), volume: list.read(1, _volume));
  }
}

/// The codec of the payload of [AvatarNet.jump]: the parameters of
/// [Avatar.jump] in a positional list.
final class _AvatarJumpPayloadCodec extends ValueCodec<()> {
  const _AvatarJumpPayloadCodec();

  @override
  String get descriptor => 'test.avatar.jump@1()';

  @override
  Object? encode(() value) => const <Object?>[];

  @override
  () decode(Object? wire) {
    WireList(wire, 0);
    return ();
  }
}

/// Binds the annotated members of [Avatar].
mixin _$Avatar {
  EntityAttachment? _$networkAttachment;
  MultiplayerSynchronizer? _$networkSynchronizer;
  Predictor<double, bool>? _$networkPredictor;

  /// The synchronizer of the synchronized fields of this [Avatar] while its
  /// attachment is live, or `null`.
  ///
  /// Read the latest values from it, as in
  /// `networkSynchronizer?.snapshot(AvatarNet.x)`.
  MultiplayerSynchronizer? get networkSynchronizer {
    final attachment = _$networkAttachment;
    return attachment == null || attachment.isDisposed
        ? null
        : _$networkSynchronizer;
  }

  /// The predictor of [Avatar.altitude] while the attachment of
  /// this [Avatar] is live, or `null`.
  ///
  /// [updateNetworkMembers] runs it every frame. To change the state outside
  /// its step, such as to respawn, set its state on the entity's authority.
  Predictor<double, bool>? get networkPredictor {
    final attachment = _$networkAttachment;
    return attachment == null || attachment.isDisposed
        ? null
        : _$networkPredictor;
  }

  /// Binds the annotated RPC handlers and synchronized fields of this [Avatar]
  /// through [attachment], and predicts [Avatar.altitude].
  ///
  /// Call it once for each attachment of the object's entity, such as the one
  /// that [MultiplayerSession.attachEntity] returns.
  void bindNetworkMembers(EntityAttachment attachment) {
    final self = this as Avatar;
    attachment
      ..bindRpc(AvatarNet.steer, (context, payload) => self.steer(payload))
      ..bindRpc(
        AvatarNet.say,
        (context, payload) =>
            self.say(payload.text, context, volume: payload.volume),
      )
      ..bindRpc(AvatarNet.jump, (context, payload) => self.jump(context));
    _$networkAttachment = attachment;
    final prediction = attachment.predict(
      state: AvatarNet.altitude,
      input: AvatarNet.fly,
      initial: self.altitude,
      step: Avatar.fly,
      interpolator: AvatarNet._altitudeInterpolator,
      smoothing: AvatarNet._flySmoothing,
      idleInput: AvatarNet._flyIdleInput,
    );
    _$networkPredictor = prediction;
    _$networkSynchronizer = attachment.synchronize([
      AvatarNet.x.property(
        get: () => self.x,
        set: (value) => self.x = value,
        interpolator: AvatarNet._xInterpolator,
      ),
      AvatarNet.input.property(
        get: () => self.input,
        set: (value) => self.input = value,
        mode: SyncMode.always,
      ),
      prediction.property(mode: SyncMode.always),
      AvatarNet.label.property(get: () => self.label),
    ], interval: AvatarNet._syncInterval);
  }

  /// Runs the prediction of [Avatar.altitude] for one frame of [elapsed].
  ///
  /// The entity's owner advances it with [Avatar.thrusting], and every peer
  /// writes the state to present to [Avatar.altitude].
  ///
  /// Call it once per frame, after [MultiplayerSession.update] and
  /// before [MultiplayerSession.captureState].
  void updateNetworkMembers(Duration elapsed) {
    final prediction = networkPredictor;
    if (prediction == null) return;
    final self = this as Avatar;
    self.altitude = prediction.update(self.thrusting, elapsed);
  }
}
