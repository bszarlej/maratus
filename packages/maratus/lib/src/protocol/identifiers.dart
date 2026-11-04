/// Identifies a spawnable entity type in a protocol schema.
extension type const SpawnTypeId(String value) {}

/// Identifies a remote procedure call in a protocol schema.
extension type const RpcId(String value) {}

/// Identifies a synchronized field in a protocol schema.
extension type const FieldId(String value) {}

/// Identifies a networked entity within a session.
///
/// Valid entity IDs are integers from 1 to 2^53 - 1.
extension type const EntityId(int value) {}

/// Identifies a peer within a session.
///
/// The host is always [PeerId.host]. Clients get IDs from 2 to 2^53 - 1,
/// assigned by the host.
extension type const PeerId(int value) {
  /// The ID of the host.
  static const host = PeerId(1);
}

/// The maximum length of a schema identifier.
const int maxIdentifierLength = 64;

/// Whether [value] is a valid schema identifier.
///
/// Identifiers are explicit, stable names such as `player` or
/// `player.move`: dot-separated segments of lowercase letters, digits, and
/// underscores that each start with a letter, with at most
/// [maxIdentifierLength] characters in total.
bool isValidIdentifier(String value) =>
    value.length <= maxIdentifierLength && _identifierPattern.hasMatch(value);

final _identifierPattern = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$');
