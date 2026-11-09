import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_system.dart';
import 'package:source_gen/source_gen.dart';

/// Whether [element] is the declaration [name] in a library of [package].
bool isDeclaredIn(Element? element, String name, String package) {
  if (element == null || element.name != name) return false;
  final uri = element.library?.uri;
  return uri != null &&
      uri.scheme == 'package' &&
      uri.pathSegments.isNotEmpty &&
      uri.pathSegments.first == package;
}

/// How generated code refers to declarations from the library it is a part
/// of, including the import prefix of each one.
final class LibraryContext {
  /// Creates the context of [library].
  LibraryContext(this.library);

  /// The library whose part is generated.
  final LibraryElement library;

  /// The type system of [library].
  TypeSystem get typeSystem => library.typeSystem;

  String? _maratusPrefix;

  /// The import prefix, such as `''` or `'m.'`, through which [library]
  /// sees the public API of `maratus`, directly or through a package that
  /// exports it.
  ///
  /// Throws an [InvalidGenerationSourceError] at [context] if [library] does
  /// not import it.
  String maratus(Element context) => _maratusPrefix ??=
      _prefixOfName(
        'ProtocolSchemaBuilder',
        (element) => isDeclaredIn(element, 'ProtocolSchemaBuilder', 'maratus'),
      ) ??
      (throw InvalidGenerationSourceError(
        'The generated code needs the maratus API, which '
        '${library.uri} does not import.',
        todo:
            "Import 'package:maratus/maratus.dart', or "
            "'package:maratus_flame/maratus_flame.dart' in a Flame game, "
            'without a show or hide combinator.',
        element: context,
      ));

  /// The import prefix, such as `''` or `'m.'`, through which [library]
  /// sees [element], or `null` if it does not see it.
  String? prefixOf(Element element) {
    final name = element.name;
    if (name == null) return null;
    return _prefixOfName(name, (found) => found == element);
  }

  String? _prefixOfName(String name, bool Function(Element) matches) {
    final local = library.firstFragment.scope.lookup(name).getter;
    if (local != null && matches(local)) return '';
    for (final prefix in library.firstFragment.prefixes) {
      if (prefix.firstFragment.isDeferred) continue;
      final found = prefix.scope.lookup(name).getter;
      if (found != null && matches(found)) return '${prefix.name}.';
    }
    return null;
  }

  /// A reference to [element] that is valid in [library].
  ///
  /// Throws an [InvalidGenerationSourceError] at [context] if [library]
  /// does not see [element].
  String reference(Element element, Element context) {
    final prefix = prefixOf(element);
    if (prefix == null) {
      throw InvalidGenerationSourceError(
        '${element.name} is not visible in ${library.uri}, so the generated '
        'code cannot refer to it.',
        todo: 'Import the library that declares ${element.name}.',
        element: context,
      );
    }
    return '$prefix${element.name}';
  }

  /// The source of [type], valid in [library].
  ///
  /// Throws an [InvalidGenerationSourceError] at [context] for types that
  /// generated code cannot name, such as type parameters and function types.
  String typeSource(DartType type, Element context) {
    final suffix = type.nullabilitySuffix == NullabilitySuffix.question
        ? '?'
        : '';
    if (type is DynamicType) return 'dynamic';
    if (type is VoidType) return 'void';
    if (type is NeverType) return 'Never$suffix';
    if (type is InterfaceType) {
      final arguments = type.typeArguments.isEmpty
          ? ''
          : '<${type.typeArguments.map((argument) => typeSource(argument, context)).join(', ')}>';
      return '${reference(type.element, context)}$arguments$suffix';
    }
    if (type is RecordType) {
      final fields = [
        for (final field in type.positionalFields)
          typeSource(field.type, context),
        if (type.namedFields.isNotEmpty)
          '{${type.namedFields.map((field) => '${typeSource(field.type, context)} ${field.name}').join(', ')}}',
      ];
      final trailing =
          type.positionalFields.length == 1 && type.namedFields.isEmpty
          ? ','
          : '';
      return '(${fields.join(', ')}$trailing)$suffix';
    }
    throw InvalidGenerationSourceError(
      'The generated code cannot name the type '
      '${type.getDisplayString()}.',
      todo: 'Use a class, record, or built-in type instead.',
      element: context,
    );
  }

  /// Whether [a] and [b] are the same type.
  bool sameType(DartType a, DartType b) =>
      typeSystem.isSubtypeOf(a, b) && typeSystem.isSubtypeOf(b, a);
}
