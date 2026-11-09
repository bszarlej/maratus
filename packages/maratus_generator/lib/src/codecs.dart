import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:source_gen/source_gen.dart';

import 'annotation_source.dart';
import 'checkers.dart';
import 'library_context.dart';
import 'names.dart';

/// The codec of a value that crosses the network.
final class CodecSource {
  /// Creates a codec from its constant [expression] and the [freeNames] it
  /// looks up in the library's scope.
  const CodecSource(this.expression, this.freeNames);

  /// A constant expression that creates the codec, valid in a constant
  /// context anywhere in the library.
  final String expression;

  /// The names that [expression] looks up in the library's scope.
  final Set<String> freeNames;

  /// Whether a scope declaring [names] would shadow a name [expression] uses.
  bool isShadowedBy(Set<String> names) => freeNames.any(names.contains);
}

/// Selects the codec of each annotated value, as the documentation of
/// `UseCodec` describes.
final class CodecResolver {
  /// Creates a resolver for declarations of [library].
  CodecResolver(this.library, this._sources);

  /// The library whose declarations this resolver reads.
  final LibraryContext library;

  final AnnotationSources _sources;

  /// The largest integer every platform represents exactly.
  static const _maxSafeInteger = 9007199254740991;

  /// The codec of the value of [type] that [declaration] declares,
  /// described as [description] in error messages.
  ///
  /// The codec comes from the `UseCodec` annotation of [declaration] if it
  /// has one, and otherwise from [type], limited by the declaration's
  /// `Range` and `MaxLength` annotations.
  Future<CodecSource> resolve(
    Element declaration,
    DartType type,
    String description,
  ) async {
    final use = useCodecChecker.firstAnnotationOf(declaration);
    final range = rangeChecker.firstAnnotationOf(declaration);
    final maxLength = maxLengthChecker.firstAnnotationOf(declaration);
    if (use != null) {
      if (range != null || maxLength != null) {
        throw InvalidGenerationSourceError(
          '$description combines @UseCodec with @Range or @MaxLength.',
          todo: 'Give the codec of @UseCodec those limits instead.',
          element: declaration,
        );
      }
      final encoded = encodedType(use.getField('codec')?.type);
      if (encoded == null || !library.sameType(encoded, type)) {
        throw InvalidGenerationSourceError(
          'The codec of @UseCodec on $description encodes '
          '${encoded?.getDisplayString() ?? 'an unknown type'}, but '
          '$description is ${type.getDisplayString()}.',
          todo: 'Use a codec of exactly ${type.getDisplayString()}.',
          element: declaration,
        );
      }
      final copied = await _sources.argument(
        declaration,
        useCodecChecker,
        positional: 0,
      );
      return CodecSource(copied.source, copied.freeNames);
    }
    final names = <String>{};
    final expression = _infer(
      type,
      _Limits(declaration, description, range, maxLength),
      names,
    );
    return CodecSource(expression, names);
  }

  String _infer(DartType type, _Limits limits, Set<String> names) {
    final declaration = limits.declaration;
    final maratus = library.maratus(declaration);
    String codec(String name) {
      names.add(maratus.isEmpty ? name : maratus.split('.').first);
      return '$maratus$name';
    }

    if (type.nullabilitySuffix == NullabilitySuffix.question &&
        type is! DynamicType &&
        !type.isDartCoreNull) {
      final inner = _infer(
        library.typeSystem.promoteToNonNull(type),
        limits,
        names,
      );
      return '${codec('NullableCodec')}($inner)';
    }
    if (type.isDartCoreBool) {
      limits.allow();
      return '${codec('BoolCodec')}()';
    }
    if (type.isDartCoreInt) {
      limits.allow(range: true);
      return '${codec('IntCodec')}(${_rangeArguments(limits, integer: true)})';
    }
    if (type.isDartCoreDouble) {
      limits.allow(range: true);
      return '${codec('DoubleCodec')}'
          '(${_rangeArguments(limits, integer: false)})';
    }
    if (type.isDartCoreString) {
      limits.allow(maxLength: true);
      return '${codec('StringCodec')}(${_maxLengthArgument(limits)})';
    }
    if (type is InterfaceType && type.isDartCoreList) {
      limits.allow(maxLength: true);
      final element = _infer(
        type.typeArguments.single,
        _Limits(
          declaration,
          'the elements of ${limits.description}',
          null,
          null,
        ),
        names,
      );
      final maxLength = _maxLengthArgument(limits);
      return '${codec('ListCodec')}'
          '($element${maxLength.isEmpty ? '' : ', $maxLength'})';
    }
    if (type is InterfaceType &&
        networkCodecChecker.hasAnnotationOf(
          type.element,
          throwOnUnresolved: false,
        )) {
      limits.allow();
      final reference = library.reference(type.element, declaration);
      final prefix = library.prefixOf(type.element) ?? '';
      names.add(prefix.isEmpty ? '${reference}Codec' : prefix.split('.').first);
      return '${reference}Codec()';
    }
    throw InvalidGenerationSourceError(
      'No codec is known for ${type.getDisplayString()}, the type of '
      '${limits.description}.',
      todo:
          'Annotate ${limits.description} with @UseCodec, or the class of '
          'its type with @NetworkCodec.',
      element: declaration,
    );
  }

  String _rangeArguments(_Limits limits, {required bool integer}) {
    final range = limits.range;
    if (range == null) return '';
    num? bound(String name) {
      final value = range.getField(name);
      if (value == null || value.isNull) return null;
      final number = value.toIntValue() ?? value.toDoubleValue();
      if (number == null) return null;
      if (integer &&
          (number is! int ||
              number < -_maxSafeInteger ||
              number > _maxSafeInteger)) {
        throw InvalidGenerationSourceError(
          'The $name of @Range on ${limits.description} must be an integer '
          'from -$_maxSafeInteger to $_maxSafeInteger.',
          element: limits.declaration,
        );
      }
      if (!number.isFinite) {
        throw InvalidGenerationSourceError(
          'The $name of @Range on ${limits.description} must be finite.',
          todo: 'Leave it out to leave that side of the range unlimited.',
          element: limits.declaration,
        );
      }
      return number;
    }

    final min = bound('min');
    final max = bound('max');
    if (min != null && max != null && min > max) {
      throw InvalidGenerationSourceError(
        'The range of ${limits.description} has a min greater than its max.',
        element: limits.declaration,
      );
    }
    return [
      if (min != null) 'min: ${numberLiteral(min)}',
      if (max != null) 'max: ${numberLiteral(max)}',
    ].join(', ');
  }

  String _maxLengthArgument(_Limits limits) {
    final length = limits.maxLength?.getField('length')?.toIntValue();
    if (length == null) return '';
    if (length < 0) {
      throw InvalidGenerationSourceError(
        'The @MaxLength of ${limits.description} must not be negative.',
        element: limits.declaration,
      );
    }
    return 'maxLength: $length';
  }
}

/// The limits that a declaration's annotations put on its value.
final class _Limits {
  _Limits(this.declaration, this.description, this.range, this.maxLength);

  final Element declaration;
  final String description;
  final DartObject? range;
  final DartObject? maxLength;

  /// Throws if the declaration has a limit that its type does not take.
  void allow({bool range = false, bool maxLength = false}) {
    if (this.range != null && !range) {
      throw InvalidGenerationSourceError(
        '@Range does not apply to $description, which is not an int or '
        'double.',
        element: declaration,
      );
    }
    if (this.maxLength != null && !maxLength) {
      throw InvalidGenerationSourceError(
        '@MaxLength does not apply to $description, which is not a String '
        'or List.',
        element: declaration,
      );
    }
  }
}
