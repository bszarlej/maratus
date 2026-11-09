/// The maximum length of a schema identifier, as `maratus` defines it.
const maxIdentifierLength = 64;

final _identifierPattern = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$');

/// Whether [value] is a valid schema identifier, by the rule that
/// `ProtocolSchemaBuilder` enforces when registering it.
bool isValidIdentifier(String value) =>
    value.length <= maxIdentifierLength && _identifierPattern.hasMatch(value);

/// A single-quoted Dart string literal whose value is [value].
String stringLiteral(String value) {
  final buffer = StringBuffer("'");
  for (final rune in value.runes) {
    switch (rune) {
      case 0x5C:
        buffer.write(r'\\');
      case 0x27:
        buffer.write(r"\'");
      case 0x24:
        buffer.write(r'\$');
      case 0x0A:
        buffer.write(r'\n');
      case 0x0D:
        buffer.write(r'\r');
      case 0x09:
        buffer.write(r'\t');
      default:
        if (rune < 0x20 || rune == 0x7F) {
          buffer.write('\\u{${rune.toRadixString(16)}}');
        } else {
          buffer.writeCharCode(rune);
        }
    }
  }
  buffer.write("'");
  return buffer.toString();
}

/// A Dart literal whose value is [value], which must be finite.
String numberLiteral(num value) {
  if (value is int) return '$value';
  if (!value.isFinite) {
    throw ArgumentError.value(value, 'value', 'must be finite');
  }
  return '$value';
}

/// [name] without leading underscores.
String publicPart(String name) => name.replaceFirst(RegExp('^_+'), '');

/// [name] with its first letter in upper case.
String upperFirst(String name) =>
    name.isEmpty ? name : name[0].toUpperCase() + name.substring(1);

/// [name] with its first letter in lower case.
String lowerFirst(String name) =>
    name.isEmpty ? name : name[0].toLowerCase() + name.substring(1);

/// Members that every Dart object has, which no generated static member may
/// shadow or declare.
const objectMembers = {'hashCode', 'runtimeType', 'toString', 'noSuchMethod'};
