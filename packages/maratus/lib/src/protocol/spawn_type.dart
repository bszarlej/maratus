import 'identifiers.dart';
import 'value_codec.dart';

/// An immutable description and typed handle for a spawnable entity type.
///
/// Create and register a handle with `ProtocolSchemaBuilder.addSpawnType`, or
/// register an existing one, such as a `const` handle, with
/// `ProtocolSchemaBuilder.addSpawnTypeDefinition`. Sessions accept only the
/// handles retained by their schema, so constructing another handle with the
/// same identifier does not register a type.
final class SpawnType<T> {
  /// Describes spawn type [id] and the [codec] for its construction data.
  const SpawnType({required this.id, required this.codec});

  /// The stable type identifier, independent of Dart names or object hashes.
  final SpawnTypeId id;

  /// The codec used to serialize and validate construction data.
  ///
  /// Construction data is sent once, when an entity is spawned. It is
  /// independent of the entity's synchronized fields.
  final ValueCodec<T> codec;
}
