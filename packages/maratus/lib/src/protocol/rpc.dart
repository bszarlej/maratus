import 'identifiers.dart';
import 'value_codec.dart';

/// Which peers may invoke an RPC on an entity.
///
/// This permission is independent of the peers selected by [RpcTarget].
enum RpcCaller {
  /// Any ready peer in the session.
  anyPeer('any'),

  /// Only the entity's input owner.
  owner('owner'),

  /// Only the entity's authority.
  authority('authority'),

  /// Only the host.
  host('host');

  const RpcCaller(this.code);

  /// The stable code included in the application's schema fingerprint.
  final String code;
}

/// Which peers receive an RPC that its caller is permitted to invoke.
enum RpcTarget {
  /// The host.
  host('host'),

  /// The entity's input owner.
  owner('owner'),

  /// The entity's authority.
  authority('authority'),

  /// Every ready peer in the session, including the host.
  all('all'),

  /// The ready peer explicitly selected when making the call.
  peer('peer');

  const RpcTarget(this.code);

  /// The stable code included in the application's schema fingerprint.
  final String code;
}

/// Whether a caller executes an RPC when it is among the selected targets.
enum RpcLocal {
  /// Exclude the caller from the selected targets.
  exclude('exclude'),

  /// Include the caller if it is among the selected targets.
  include('include');

  const RpcLocal(this.code);

  /// The stable code included in the application's schema fingerprint.
  final String code;
}

/// An immutable description and typed handle for an entity-addressed RPC.
///
/// Create and register a handle with `ProtocolSchemaBuilder.addRpc`, or
/// register an existing one, such as a `const` handle, with
/// `ProtocolSchemaBuilder.addRpcDefinition`. Sessions accept only the handles
/// retained by their schema, so constructing another handle with the same
/// identifier does not replace a registered RPC's permissions.
final class Rpc<T> {
  /// Describes the RPC [id] and its payload [codec].
  ///
  /// [caller] controls permission, [target] selects destinations, and [local]
  /// controls whether the caller executes when it is a selected destination.
  const Rpc({
    required this.id,
    required this.codec,
    this.caller = RpcCaller.anyPeer,
    this.target = RpcTarget.host,
    this.local = RpcLocal.exclude,
  });

  /// The stable method identifier, independent of Dart names or object hashes.
  final RpcId id;

  /// The codec used to serialize and validate the RPC's payload.
  final ValueCodec<T> codec;

  /// The peers permitted to invoke this RPC on an entity.
  final RpcCaller caller;

  /// The destinations to which the host routes a permitted call.
  final RpcTarget target;

  /// Whether the caller executes when selected by [target].
  final RpcLocal local;
}
