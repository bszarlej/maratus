import 'package:maratus/maratus.dart';
import 'package:meta/meta_meta.dart';

/// Generates the network declarations of the annotated class.
///
/// For a class `Player`, `maratus_generator` writes into the library's
/// `.g.dart` part:
///
/// - `PlayerNet`, with a const handle for each [RpcMethod] and [SyncedField]
///   member and for the [spawnType], and a static `register` function that
///   registers them all with a [ProtocolSchemaBuilder].
/// - `_$Player`, a mixin that binds the annotated members through an
///   [EntityAttachment]. Mix it into the class whenever it declares any. A
///   Flame `NetworkedComponent` binds them on every attachment; other classes
///   call the mixin's `bindNetworkMembers` with their attachment.
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
/// [ProtocolSchemaBuilder.addSpawnType], [ProtocolSchemaBuilder.addRpc], and
/// [ProtocolSchemaBuilder.addField], and both kinds of registration mix
/// freely in one schema.
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
/// [EntityAttachment.synchronize] call: the entity's authority reads the
/// member, and other peers write received values to it, if it can be
/// written. A getter is written through a setter of the same name.
///
/// To synchronize an inherited value, such as a Flame component's `position`,
/// annotate a getter that returns it.
@Target({TargetKind.field, TargetKind.getter})
final class SyncedField {
  /// Declares the synchronized field [id].
  const SyncedField(
    this.id, {
    this.mode = SyncMode.onChange,
    this.interpolator,
  });

  /// The stable identifier of the field, which renaming the member does not
  /// change.
  final String id;

  /// When the entity's authority sends the value.
  final SyncMode mode;

  /// Blends received values for [MultiplayerSynchronizer.interpolated], or
  /// `null` if the value is not interpolated.
  ///
  /// Its type argument must be the member's type.
  final Interpolator<Object?>? interpolator;
}
