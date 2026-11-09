import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:source_gen/source_gen.dart';

import 'annotation_source.dart';
import 'checkers.dart';
import 'codecs.dart';
import 'library_context.dart';
import 'names.dart';
import 'output.dart';

/// Generates the codec of each class annotated with [NetworkCodec].
final class NetworkCodecGenerator extends GeneratorForAnnotation<NetworkCodec> {
  /// Creates the generator.
  const NetworkCodecGenerator() : super(inPackage: 'maratus_annotations');

  @override
  Future<String> generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) async {
    if (element is! ClassElement) {
      throw InvalidGenerationSourceError(
        '@NetworkCodec applies only to classes.',
        element: element,
      );
    }
    final library = LibraryContext(element.library);
    final codecs = CodecResolver(library, AnnotationSources(buildStep));
    return _DataClass(
      element,
      library,
      codecs,
    ).generate(annotation.read('descriptor').stringValue);
  }
}

final class _WireField {
  _WireField(this.element, this.key, this.codec);

  final FieldElement element;
  final String key;
  final CodecSource codec;

  String get name => element.name!;
}

final class _DataClass {
  _DataClass(this.element, this.library, this.codecs);

  final ClassElement element;
  final LibraryContext library;
  final CodecResolver codecs;

  String get name => element.name!;

  Future<String> generate(String descriptor) async {
    if (element.typeParameters.isNotEmpty) {
      throw InvalidGenerationSourceError(
        '@NetworkCodec does not support generic classes.',
        element: element,
      );
    }
    if (descriptor.isEmpty) {
      throw InvalidGenerationSourceError(
        'The descriptor of @NetworkCodec must not be empty.',
        todo: 'Give it a name and version, such as "game.move_input@1".',
        element: element,
      );
    }
    final fields = await _fields();
    final maratus = library.maratus(element);
    final self = library.reference(element, element);
    final codecName = '${name}Codec';

    final topLevel = TopLevelConstants(name);
    final statics = UniqueNames({
      'descriptor',
      'encode',
      'decode',
      ...objectMembers,
    });
    final staticNames = <String, String>{};
    final staticDeclarations = <String>[];
    for (final field in fields) {
      staticNames[field.name] = statics.add('_${publicPart(field.name)}');
    }
    final arguments = _constructorArguments(fields, staticNames);
    for (final field in fields) {
      final initializer = field.codec.isShadowedBy(statics.names)
          ? topLevel.add(
              '${publicPart(field.name)}Codec',
              field.codec.expression,
            )
          : field.codec.expression;
      staticDeclarations.add(
        'static const ${staticNames[field.name]} = $initializer;',
      );
    }

    final keys = fields.map((field) => stringLiteral(field.key)).join(', ');
    final encoded = fields.isEmpty
        ? 'const <String, Object?>{}'
        : '{${fields.map((field) => '${stringLiteral(field.key)}: '
              '${staticNames[field.name]}.encode(value.${field.name})').join(', ')},}';
    final decode = fields.isEmpty
        ? '${maratus}WireObject(wire, const <String>{});\n'
              'return $self($arguments);'
        : 'final object = ${maratus}WireObject(wire, const {$keys});\n'
              'return $self($arguments);';

    return '''
${topLevel.declarations}

/// The codec of [$self], generated from its annotations.
final class $codecName extends ${maratus}ValueCodec<$self> {
  /// Creates the codec.
  const $codecName();

  ${staticDeclarations.join('\n')}

  @override
  String get descriptor => ${stringLiteral(descriptor)};

  @override
  Object? encode($self value) => $encoded;

  @override
  $self decode(Object? wire) {
    $decode
  }
}
''';
  }

  Future<List<_WireField>> _fields() async {
    final fields = <_WireField>[];
    final keys = <String>{};
    for (final field in element.fields) {
      // Skip the fields that getters and setters imply.
      if (field.nonSynthetic != field) continue;
      final key = wireKeyChecker.firstAnnotationOf(field);
      if (key == null) {
        if (!field.isStatic && _hasCodecAnnotation(field)) {
          throw InvalidGenerationSourceError(
            'Field ${field.name} of $name has a codec annotation but no '
            '@WireKey, so it is not sent.',
            todo: 'Annotate it with @WireKey, or remove its codec annotation.',
            element: field,
          );
        }
        continue;
      }
      if (field.isStatic) {
        throw InvalidGenerationSourceError(
          '@WireKey applies only to instance fields.',
          element: field,
        );
      }
      final value = key.getField('key')!.toStringValue()!;
      if (!keys.add(value)) {
        throw InvalidGenerationSourceError(
          'Two fields of $name use the wire key "$value".',
          element: field,
        );
      }
      fields.add(
        _WireField(
          field,
          value,
          await codecs.resolve(field, field.type, 'field ${field.name}'),
        ),
      );
    }
    return fields;
  }

  static bool _hasCodecAnnotation(Element element) =>
      useCodecChecker.hasAnnotationOf(element) ||
      rangeChecker.hasAnnotationOf(element) ||
      maxLengthChecker.hasAnnotationOf(element);

  /// The arguments that construct a decoded value from the wire object, which
  /// reads each field with the codec in the static constant [staticNames]
  /// gives it.
  String _constructorArguments(
    List<_WireField> fields,
    Map<String, String> staticNames,
  ) {
    final constructor = element.unnamedConstructor;
    if (constructor == null || (element.isAbstract && !constructor.isFactory)) {
      throw InvalidGenerationSourceError(
        '$name needs an unnamed constructor that creates instances, which '
        'the generated codec calls to decode values.',
        element: element,
      );
    }
    final byName = {for (final field in fields) field.name: field};
    final passed = <String>{};
    final positional = <String>[];
    final named = <String>[];
    String? skipped;
    for (final parameter in constructor.formalParameters) {
      final parameterName = parameter.name!;
      final field = byName[parameterName];
      if (field == null) {
        if (parameter.isRequiredPositional || parameter.isRequiredNamed) {
          throw InvalidGenerationSourceError(
            'Parameter $parameterName of the unnamed constructor of $name '
            'is required, but no field of the same name has a @WireKey.',
            element: constructor,
          );
        }
        if (parameter.isPositional) skipped ??= parameterName;
        continue;
      }
      if (!library.typeSystem.isAssignableTo(
        field.element.type,
        parameter.type,
      )) {
        throw InvalidGenerationSourceError(
          'Field ${field.name} of $name is a '
          '${field.element.type.getDisplayString()}, which parameter '
          '$parameterName of its unnamed constructor does not accept.',
          element: constructor,
        );
      }
      final read =
          'object.read(${stringLiteral(field.key)}, '
          '${staticNames[field.name]})';
      if (parameter.isNamed) {
        named.add('$parameterName: $read');
      } else {
        if (skipped != null) {
          throw InvalidGenerationSourceError(
            'The unnamed constructor of $name takes $parameterName after '
            'the optional positional parameter $skipped, which has no field '
            'with a @WireKey.',
            element: constructor,
          );
        }
        positional.add(read);
      }
      passed.add(field.name);
    }
    for (final field in fields) {
      if (!passed.contains(field.name)) {
        throw InvalidGenerationSourceError(
          'Field ${field.name} of $name is not a parameter of its unnamed '
          'constructor, so decoded values could not include it.',
          element: field.element,
        );
      }
    }
    return [...positional, ...named].join(', ');
  }
}
