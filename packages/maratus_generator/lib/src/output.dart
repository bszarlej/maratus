import 'names.dart';

/// Hands out names that differ from one another and from reserved names.
final class UniqueNames {
  /// Creates a set of names that already contains [reserved].
  UniqueNames([Iterable<String> reserved = const []]) : names = {...reserved};

  /// Every name handed out or reserved so far.
  final Set<String> names;

  /// Returns [candidate], or [candidate] with a number appended if it is
  /// taken, and marks the result as taken.
  String add(String candidate) {
    var name = candidate;
    for (var number = 2; !names.add(name); number++) {
      name = '$candidate$number';
    }
    return name;
  }
}

/// Private top-level constants that hold copied expressions, where a
/// declaration of the generated code would otherwise shadow a name that the
/// expression uses.
final class TopLevelConstants {
  /// Creates the constants of the declaration named [owner].
  TopLevelConstants(this.owner);

  /// The name of the declaration whose generated code uses the constants.
  final String owner;

  final _names = UniqueNames();
  final _declarations = <String>[];

  /// Declares a constant for [purpose] with the value of [expression], and
  /// returns its name.
  String add(String purpose, String expression) {
    final name = _names.add(
      '_\$${lowerFirst(publicPart(owner))}${upperFirst(purpose)}',
    );
    _declarations.add('const $name = $expression;');
    return name;
  }

  /// The declarations of the constants added so far.
  String get declarations => _declarations.join('\n');
}
