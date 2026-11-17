import 'package:maratus/maratus.dart';
import 'package:meta/meta_meta.dart';

/// Generates the network declarations of the annotated class.
///
/// For a class `Player`, `maratus_generator` writes into the library's
/// `.g.dart` part:
///
/// - `PlayerNet`, with a const handle for each [RpcMethod] and [SyncedField]
///   member, for the input stream of a [Prediction] method, and for the
///   [spawnType], and a static `register` function that registers them all
///   with a [ProtocolSchemaBuilder].
/// - `_$Player`, a mixin that binds the annotated members through an
///   [EntityAttachment] and runs the prediction of a [Prediction] method. Mix it
///   into the class whenever it declares any. A Flame `NetworkedComponent`
///   binds them on every attachment and runs the prediction every frame;
///   other classes call the mixin's `bindNetworkMembers` with their
///   attachment, and its `updateNetworkMembers` once per frame.
/// - `PlayerRpc`, for Flame components with RPC methods: `player.rpc.hit(25)`
///   invokes the RPC over the component's session.
///
/// ```dart
/// part 'player.g.dart';
///
/// @Networked(spawnType: 'arena.player')
/// final class Player extends PositionComponent
///     with NetworkedComponent, _$Player {
///   Player(@Range(min: 0, max: 3) SpawnContext<int> context)
///     : networkEntity = context.entity;
///
///   @override
///   final NetworkEntity networkEntity;
///
///   @SyncedField('arena.player.health')
///   @Range(min: 0, max: 100)
///   int health = 100;
///
///   @RpcMethod(
///     'arena.player.hit',
///     caller: RpcCaller.host,
///     target: RpcTarget.all,
///     local: RpcLocal.include,
///   )
///   void hit(@Range(min: 1, max: 100) int damage) => add(HitFlash(damage));
/// }
/// ```
///
/// Each value that crosses the network takes its codec from its declaration;
/// see `UseCodec` for the rules. The generated handles have the same codecs,
/// policies, and fingerprint as the equivalent registrations with
/// [ProtocolSchemaBuilder.addSpawnType], [ProtocolSchemaBuilder.addRpc],
/// [ProtocolSchemaBuilder.addField], and [ProtocolSchemaBuilder.addInput],
/// and both kinds of registration mix freely in one schema.
@Target({TargetKind.classType})
final class Networked {
  /// Marks a class whose network declarations are generated.
  const Networked({this.spawnType, this.syncInterval, this.interpolationDelay});

  /// The identifier of the spawn type that creates this class, or `null` if
  /// the class is not spawned.
  ///
  /// The class then needs exactly one constructor parameter of type
  /// [SpawnContext]. Its type argument is the type of the construction data,
  /// and its annotations select their codec as for any other value. The
  /// generated handle is `spawnType`, such as `PlayerNet.spawnType`.
  final String? spawnType;

  /// The minimum time between two samples of the class's synchronized
  /// fields, or `null` for the default of [EntityAttachment.synchronize].
  final Duration? syncInterval;

  /// How far interpolated fields trail the newest sample, or `null` for the
  /// default of [EntityAttachment.synchronize].
  final Duration? interpolationDelay;
}

/// Makes the annotated method the handler of the RPC [id].
///
/// The generated handle has the same codec, policies, and fingerprint as a
/// call to [ProtocolSchemaBuilder.addRpc] with the same arguments, whose
/// defaults these match. Its payload is the method's single parameter, with
/// the codec that the parameter selects. Several parameters, or none, travel
/// as a positional list with a generated codec, whose descriptor carries the
/// [id], the [version], and the parameters' codecs.
///
/// A parameter of type [RpcContext], at most one, receives the context of
/// each call and is not sent. Every other parameter must be required.
/// Handlers return `void` or `Future<void>`: nothing comes back over the
/// network, as with [MultiplayerSession.callRpc].
@Target({TargetKind.method})
final class RpcMethod {
  /// Declares the RPC [id] with its routing policies.
  const RpcMethod(
    this.id, {
    this.caller = RpcCaller.anyPeer,
    this.target = RpcTarget.host,
    this.local = RpcLocal.exclude,
    this.deliveryMode = DeliveryMode.reliable,
    this.channel = 0,
    this.version,
  });

  /// The stable identifier of the RPC, which renaming the method does not
  /// change.
  final String id;

  /// The peers permitted to invoke the RPC on an entity.
  final RpcCaller caller;

  /// The destinations to which the host routes a permitted call.
  final RpcTarget target;

  /// Whether the caller executes the RPC when [target] selects it.
  final RpcLocal local;

  /// How this call is delivered, including when the host forwards it.
  final DeliveryMode deliveryMode;

  /// The transport channel for this RPC, numbered from zero.
  ///
  /// The transport must support [deliveryMode] on this channel.
  final int channel;

  /// The version of the generated codec for a payload of zero or several
  /// parameters, or `null` for version 1.
  ///
  /// Bump it when the meaning of the parameters changes but their codecs do
  /// not, such as when two `int` parameters swap places. The payload of a
  /// single parameter uses that parameter's codec, so it takes no version.
  final int? version;
}

/// Synchronizes the annotated field or getter as the synchronized field [id].
///
/// The generated handle has the same codec and fingerprint as a call to
/// [ProtocolSchemaBuilder.addField] with the same arguments. The generated
/// mixin synchronizes every annotated member of a class with one
/// [EntityAttachment.synchronize] call: the field's [writer], the entity's
/// authority or its owner, reads the member, and other peers write received
/// values to it, if it can be written. A getter is written through a setter
/// of the same name.
///
/// To synchronize an inherited value, such as a Flame component's `position`,
/// annotate a getter that returns it.
@Target({TargetKind.field, TargetKind.getter})
final class SyncedField {
  /// Declares the synchronized field [id].
  const SyncedField(
    this.id, {
    this.mode = SyncMode.onChange,
    this.deliveryMode = DeliveryMode.reliable,
    this.channel = 0,
    this.writer = FieldWriter.authority,
    this.interpolator,
  });

  /// The stable identifier of the field, which renaming the member does not
  /// change.
  final String id;

  /// When the field's [writer] sends the value.
  final SyncMode mode;

  /// How incremental updates are delivered.
  ///
  /// Unreliable delivery requires [SyncMode.always] so later samples can
  /// repair packet loss. Initial state and late-join snapshots are reliable.
  final DeliveryMode deliveryMode;

  /// The transport channel for incremental updates, numbered from zero.
  ///
  /// The transport must support [deliveryMode] on this channel.
  final int channel;

  /// The peer that writes the value: the entity's authority, the default,
  /// or its owner, as for input that the owner controls.
  final FieldWriter writer;

  /// Blends received values for [MultiplayerSynchronizer.interpolated], or
  /// `null` if the value is not interpolated.
  ///
  /// Its type argument must be the member's type.
  final Interpolator<Object?>? interpolator;
}

/// Predicts the [SyncedField] member that [of] names on the entity's owner,
/// from the owner's [input], with the annotated method as the step that
/// applies one input of the input stream [id] for one [tick].
///
/// The method must be static. It takes the state and one input and returns
/// the next state, as a [PredictionStep] does: the host runs it with the
/// owner's inputs to compute the authoritative state, and the owner runs it
/// with the same inputs to show their effect without waiting for that state.
/// [of] names the [SyncedField] member that holds the state, which the
/// entity's authority writes, and whose type the method takes and returns.
/// [input] names the member that holds the owner's current input.
///
/// ```dart
/// final direction = Vector2.zero();
///
/// @SyncedField('arena.player.position', interpolator: Vector2Interpolator())
/// @UseCodec(arenaPoint)
/// Vector2 get syncedPosition => position;
/// set syncedPosition(Vector2 value) => position.setFrom(value);
///
/// @Prediction(
///   'arena.player.move',
///   of: 'syncedPosition',
///   input: 'direction',
///   tick: Duration(milliseconds: 20),
/// )
/// static Vector2 move(Vector2 position, @UseCodec(steering) Vector2 input) =>
///     position + input * 4;
/// ```
///
/// The generated handle of the input stream, named after the method, has the
/// same codec, tick, and fingerprint as a call to
/// [ProtocolSchemaBuilder.addInput] with the same arguments. Its codec is the
/// one that the method's input parameter selects, as for an RPC parameter.
///
/// The generated mixin calls [EntityAttachment.predict] before it
/// synchronizes the class's members. The prediction starts from the value of
/// the member that [of] names, blends with that member's interpolator, and
/// replaces the member in the synchronizer. The mixin's `updateNetworkMembers`
/// then runs it every frame with [Predictor.update]: the entity's owner
/// advances it with the value of the [input] member, and every peer writes
/// the state to present to the predicted member, if it can be written. A Flame
/// `NetworkedComponent` updates its members before each frame's gameplay;
/// other classes call `updateNetworkMembers` once per frame.
///
/// The prediction holds the state, so writing the member does not change
/// it. To change the state outside the step, such as to respawn a player,
/// set [Predictor.state] on the entity's authority, through the mixin's
/// `networkPredictor`. A class declares at most one prediction.
@Target({TargetKind.method})
final class Prediction {
  /// Declares the input stream [id], whose inputs advance the member that
  /// [of] names one [tick] at a time.
  const Prediction(
    this.id, {
    required this.of,
    required this.input,
    required this.tick,
    this.deliveryMode = DeliveryMode.reliable,
    this.channel = 0,
    this.smoothing,
    this.idleInput,
  });

  /// The stable identifier of the input stream, which renaming the method
  /// does not change.
  final String id;

  /// The name of the [SyncedField] member of the same class that holds the
  /// predicted state.
  final String of;

  /// The name of the field or getter of the same class that holds the
  /// owner's current input, which the generated code reads once per frame on
  /// the entity's owner.
  ///
  /// Its type must be the type of the method's input.
  final String input;

  /// The fixed time step that each input covers, which must be positive.
  final Duration tick;

  /// How inputs are delivered to the entity's authority.
  final DeliveryMode deliveryMode;

  /// The transport channel for inputs, numbered from zero.
  ///
  /// The transport must support [deliveryMode] on this channel.
  final int channel;

  /// How long a correction of the owner's prediction takes to blend out, or
  /// `null` for the default of [EntityAttachment.predict].
  final Duration? smoothing;

  /// The input that the host applies while the owner's inputs are late, or
  /// `null` if it waits for them, as [EntityAttachment.predict] describes.
  ///
  /// Its type must be the type of the method's input.
  final Object? idleInput;
}
