import 'identifiers.dart';

/// A handle for a static entity: an entity that exists in every session
/// without being spawned, such as a scoreboard or a level.
///
/// Obtain registered handles from `ProtocolSchemaBuilder.addStaticEntity`,
/// and the entity of a running session from
/// `MultiplayerSession.staticEntity`. Sessions accept the handles retained by
/// their schema, so constructing another handle with the same identifier
/// does not declare an entity.
final class StaticEntity {
  /// Describes static entity [id].
  const StaticEntity({required this.id});

  /// The stable identifier of the entity, independent of Dart names or
  /// object hashes.
  final StaticEntityId id;
}
