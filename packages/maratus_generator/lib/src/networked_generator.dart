import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:source_gen/source_gen.dart';

import 'annotation_source.dart';
import 'checkers.dart';
import 'codecs.dart';
import 'library_context.dart';
import 'names.dart';
import 'output.dart';

/// Generates the handles, registration, binding mixin, and RPC senders of
/// each class annotated with [Networked].
final class NetworkedGenerator extends GeneratorForAnnotation<Networked> {
  /// Creates the generator.
  const NetworkedGenerator() : super(inPackage: 'maratus_annotations');

  @override
  Future<String> generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) async {
    if (element is! ClassElement) {
      throw InvalidGenerationSourceError(
        '@Networked applies only to classes.',
        element: element,
      );
    }
    final library = LibraryContext(element.library);
    final sources = AnnotationSources(buildStep);
    final mixinName = '_\$${element.name}';
    final declaration = await buildStep.resolver.astNodeFor(
      element.firstFragment,
      resolve: true,
    );
    var mentionsMixin = false;
    if (declaration is AnnotatedNode) {
      // A documentation comment begins the declaration, but its tokens do
      // not lead to the code.
      for (
        Token? token = declaration.firstTokenAfterCommentAndMetadata;
        token != null && !token.isEof && token.offset < declaration.end;
        token = token.next
      ) {
        if (token.lexeme == mixinName) {
          mentionsMixin = true;
          break;
        }
      }
    }
    return _NetworkedClass(
      element,
      library,
      sources,
      CodecResolver(library, sources),
    ).generate(annotation, mentionsMixin: mentionsMixin);
  }
}

final class _Rpc {
  _Rpc({
    required this.method,
    required this.id,
    required this.caller,
    required this.target,
    required this.local,
    required this.deliveryMode,
    required this.channel,
    required this.version,
    required this.parameters,
  });

  final MethodElement method;
  final String id;
  final String caller;
  final String target;
  final String local;
  final String deliveryMode;
  final int channel;
  final int version;
  final List<_Parameter> parameters;

  String get name => method.name!;

  Iterable<_Parameter> get payload =>
      parameters.where((parameter) => !parameter.isContext);

  /// Whether the payload is a record of all parameters, rather than the
  /// value of the only one.
  bool get isRecord => payload.length != 1;
}

final class _Parameter {
  _Parameter(this.element, {this.codec});

  final FormalParameterElement element;

  /// The codec of the parameter, or `null` for the call's context.
  final CodecSource? codec;

  bool get isContext => codec == null;

  String get name => element.name!;
}

final class _Field {
  _Field({
    required this.member,
    required this.type,
    required this.id,
    required this.mode,
    required this.deliveryMode,
    required this.channel,
    required this.writer,
    required this.interpolator,
    required this.applyInterpolated,
    required this.isWritable,
    required this.codec,
  });

  final Element member;
  final DartType type;
  final String id;
  final String mode;
  final String deliveryMode;
  final int channel;
  final String writer;
  final CopiedExpression? interpolator;

  /// Whether the setter receives the values that [interpolator] blends.
  final bool applyInterpolated;
  final bool isWritable;
  final CodecSource codec;

  String get name => member.name!;
}

final class _Spawn {
  _Spawn(this.id, this.codec);

  final String id;
  final CodecSource codec;
}

final class _Prediction {
  _Prediction({
    required this.method,
    required this.id,
    required this.state,
    required this.input,
    required this.inputType,
    required this.codec,
    required this.tick,
    required this.deliveryMode,
    required this.channel,
    required this.smoothing,
    required this.idleInput,
  });

  /// The step, which also names the handle of the input stream.
  final MethodElement method;
  final String id;

  /// The synchronized member whose state the step advances.
  final _Field state;

  /// The name of the member that holds the owner's current input.
  final String input;

  /// The type of the inputs.
  final DartType inputType;
  final CodecSource codec;
  final CopiedExpression tick;
  final String deliveryMode;
  final int channel;
  final CopiedExpression? smoothing;
  final CopiedExpression? idleInput;

  String get name => method.name!;
}

final class _NetworkedClass {
  _NetworkedClass(this.element, this.library, this.sources, this.codecs);

  final ClassElement element;
  final LibraryContext library;
  final AnnotationSources sources;
  final CodecResolver codecs;

  String get name => element.name!;
  String get netName => '${name}Net';
  String get mixinName => '_\$$name';

  late final String maratus = library.maratus(element);
  late final String self = library.reference(element, element);

  Future<String> generate(
    ConstantReader annotation, {
    required bool mentionsMixin,
  }) async {
    if (element.typeParameters.isNotEmpty) {
      throw InvalidGenerationSourceError(
        '@Networked does not support generic classes.',
        element: element,
      );
    }
    final component = _networkedComponent();
    final spawnId = annotation.peek('spawnType')?.stringValue;
    final spawn = spawnId == null ? null : await _spawn(spawnId);
    final rpcs = await _rpcs();
    final fields = await _fields();
    // A prediction's state is one of the fields, so a class that declares
    // only a prediction fails here with the reason.
    final prediction = await _prediction(fields);
    if (spawn == null && rpcs.isEmpty && fields.isEmpty) {
      throw InvalidGenerationSourceError(
        '@Networked class $name declares nothing to generate.',
        todo:
            'Give it a spawnType, @RpcMethod methods, or @SyncedField '
            'members.',
        element: element,
      );
    }
    final syncInterval = annotation.peek('syncInterval') == null
        ? null
        : await sources.argument(
            element,
            networkedChecker,
            named: 'syncInterval',
          );
    final interpolationDelay = annotation.peek('interpolationDelay') == null
        ? null
        : await sources.argument(
            element,
            networkedChecker,
            named: 'interpolationDelay',
          );
    if (fields.isEmpty &&
        (syncInterval != null || interpolationDelay != null)) {
      throw InvalidGenerationSourceError(
        'syncInterval and interpolationDelay apply only to classes with '
        '@SyncedField members, which $name does not have.',
        element: element,
      );
    }
    final binds = rpcs.isNotEmpty || fields.isNotEmpty;
    if (binds && !mentionsMixin) {
      throw InvalidGenerationSourceError(
        '$name has annotated members, but does not mix in $mixinName, which '
        'binds them.',
        todo: 'Add $mixinName to the with clause of $name.',
        element: element,
      );
    }

    final topLevel = TopLevelConstants(name);
    final net = _netClass(
      spawn,
      rpcs,
      fields,
      prediction,
      topLevel,
      syncInterval: syncInterval,
      interpolationDelay: interpolationDelay,
    );
    return [
      net.source,
      net.payloadCodecs.join('\n\n'),
      if (mentionsMixin) _mixin(component, rpcs, fields, prediction, net),
      if (component != null && rpcs.isNotEmpty) _senders(rpcs),
      topLevel.declarations,
    ].where((part) => part.isNotEmpty).join('\n\n');
  }

  InterfaceElement? _networkedComponent() {
    for (final supertype in element.allSupertypes) {
      if (isDeclaredIn(
        supertype.element,
        'NetworkedComponent',
        'maratus_flame',
      )) {
        return supertype.element;
      }
    }
    return null;
  }

  // Reading the declarations.

  Future<_Spawn> _spawn(String id) async {
    _checkIdentifier(id, 'spawn type', element);
    final parameters = [
      for (final constructor in element.constructors)
        for (final parameter in constructor.formalParameters)
          if (isDeclaredIn(parameter.type.element, 'SpawnContext', 'maratus'))
            parameter,
    ];
    if (parameters.length != 1) {
      throw InvalidGenerationSourceError(
        '$name declares the spawn type "$id", so it needs exactly one '
        'constructor parameter of type SpawnContext, which gives the type '
        'and codec of its construction data. It has ${parameters.length}.',
        element: element,
      );
    }
    final parameter = parameters.single;
    final data = (parameter.type as InterfaceType).typeArguments.single;
    return _Spawn(
      id,
      await codecs.resolve(parameter, data, 'the spawn data of $name'),
    );
  }

  Future<List<_Rpc>> _rpcs() async {
    final rpcs = <_Rpc>[];
    final ids = <String>{};
    for (final method in element.methods) {
      final annotation = rpcMethodChecker.firstAnnotationOf(method);
      if (annotation == null) continue;
      final description = '$name.${method.name}';
      if (method.isStatic || method.typeParameters.isNotEmpty) {
        throw InvalidGenerationSourceError(
          '@RpcMethod applies only to instance methods without type '
          'parameters, unlike $description.',
          element: method,
        );
      }
      if (!_returnsNothing(method.returnType)) {
        throw InvalidGenerationSourceError(
          '$description returns ${method.returnType.getDisplayString()}, but '
          'nothing comes back from an RPC.',
          todo: 'Return void or Future<void>.',
          element: method,
        );
      }
      final reader = ConstantReader(annotation);
      final id = reader.read('id').stringValue;
      _checkIdentifier(id, 'RPC', method);
      if (!ids.add(id)) {
        throw InvalidGenerationSourceError(
          '$name declares the RPC "$id" more than once.',
          element: method,
        );
      }
      final parameters = <_Parameter>[];
      var hasContext = false;
      for (final parameter in method.formalParameters) {
        if (_isContext(parameter.type)) {
          if (hasContext) {
            throw InvalidGenerationSourceError(
              '$description takes more than one RpcContext.',
              element: method,
            );
          }
          hasContext = true;
          parameters.add(_Parameter(parameter));
          continue;
        }
        if (parameter.isOptional) {
          throw InvalidGenerationSourceError(
            'Parameter ${parameter.name} of $description is optional, but '
            'every call sends a value for it.',
            todo: 'Make it required.',
            element: method,
          );
        }
        parameters.add(
          _Parameter(
            parameter,
            codec: await codecs.resolve(
              parameter,
              parameter.type,
              'parameter ${parameter.name} of $description',
            ),
          ),
        );
      }
      final rpc = _Rpc(
        method: method,
        id: id,
        caller: _enumName(reader.read('caller').objectValue),
        target: _enumName(reader.read('target').objectValue),
        local: _enumName(reader.read('local').objectValue),
        deliveryMode: _enumName(reader.read('deliveryMode').objectValue),
        channel: _channel(reader, method),
        version: reader.peek('version')?.intValue ?? 1,
        parameters: parameters,
      );
      _checkPayload(rpc, versioned: reader.peek('version') != null);
      rpcs.add(rpc);
    }
    return rpcs;
  }

  void _checkPayload(_Rpc rpc, {required bool versioned}) {
    final description = '$name.${rpc.name}';
    if (!rpc.isRecord) {
      if (versioned) {
        throw InvalidGenerationSourceError(
          'The payload of $description is its only parameter, whose codec '
          'is its own, so the version of @RpcMethod does not apply.',
          todo: 'Remove the version, or change the descriptor of the codec.',
          element: rpc.method,
        );
      }
    } else {
      if (rpc.version < 1) {
        throw InvalidGenerationSourceError(
          'The version of @RpcMethod on $description must be positive.',
          element: rpc.method,
        );
      }
      for (final parameter in rpc.payload) {
        if (parameter.name.startsWith('_') ||
            objectMembers.contains(parameter.name) ||
            RegExp(r'^\$[0-9]+$').hasMatch(parameter.name)) {
          throw InvalidGenerationSourceError(
            'Parameter ${parameter.name} of $description cannot name a field '
            'of the record that carries its payload.',
            todo: 'Rename the parameter.',
            element: rpc.method,
          );
        }
      }
    }
    if (rpc.target == 'peer' && rpc.payload.any((p) => p.name == 'to')) {
      throw InvalidGenerationSourceError(
        '$description targets a peer, which its sender takes as `to:`, so '
        'no other parameter can be called `to`.',
        todo: 'Rename the parameter.',
        element: rpc.method,
      );
    }
  }

  Future<List<_Field>> _fields() async {
    final fields = <_Field>[];
    final ids = <String>{};
    Future<void> add(
      Element member,
      DartObject annotation,
      DartType type, {
      required bool isStatic,
      required bool isWritable,
    }) async {
      final description = 'synchronized member $name.${member.name}';
      if (isStatic) {
        throw InvalidGenerationSourceError(
          '@SyncedField applies only to instance members, unlike '
          '$description.',
          element: member,
        );
      }
      final reader = ConstantReader(annotation);
      final id = reader.read('id').stringValue;
      _checkIdentifier(id, 'synchronized field', member);
      if (!ids.add(id)) {
        throw InvalidGenerationSourceError(
          '$name declares the synchronized field "$id" more than once.',
          element: member,
        );
      }
      CopiedExpression? interpolator;
      final mode = _enumName(reader.read('mode').objectValue);
      final deliveryMode = _enumName(reader.read('deliveryMode').objectValue);
      if (deliveryMode != 'reliable' && mode != 'always') {
        throw InvalidGenerationSourceError(
          'Unreliable delivery of $description requires SyncMode.always '
          'so later samples can repair packet loss.',
          todo: 'Use mode: SyncMode.always or DeliveryMode.reliable.',
          element: member,
        );
      }
      final interpolatorValue = reader.peek('interpolator')?.objectValue;
      if (interpolatorValue != null) {
        final blended = interpolatedType(interpolatorValue.type);
        if (blended == null || !library.sameType(blended, type)) {
          throw InvalidGenerationSourceError(
            'The interpolator of $description blends '
            '${blended?.getDisplayString() ?? 'an unknown type'}, but the '
            'member is ${type.getDisplayString()}.',
            element: member,
          );
        }
        interpolator = await sources.argument(
          member,
          syncedFieldChecker,
          named: 'interpolator',
        );
      }
      final applyInterpolated = reader.read('applyInterpolated').boolValue;
      if (!applyInterpolated && interpolator == null) {
        throw InvalidGenerationSourceError(
          'applyInterpolated applies only to members with an interpolator, '
          'unlike $description.',
          todo: 'Remove applyInterpolated, or give the member an interpolator.',
          element: member,
        );
      }
      fields.add(
        _Field(
          member: member,
          type: type,
          id: id,
          mode: mode,
          deliveryMode: deliveryMode,
          channel: _channel(reader, member),
          writer: _enumName(reader.read('writer').objectValue),
          interpolator: interpolator,
          applyInterpolated: applyInterpolated,
          isWritable: isWritable,
          codec: await codecs.resolve(member, type, description),
        ),
      );
    }

    for (final field in element.fields) {
      // Skip the fields that getters and setters imply.
      if (field.nonSynthetic != field) continue;
      final annotation = syncedFieldChecker.firstAnnotationOf(field);
      if (annotation == null) continue;
      await add(
        field,
        annotation,
        field.type,
        isStatic: field.isStatic,
        isWritable: !field.isFinal && !field.isConst,
      );
    }
    for (final getter in element.getters) {
      // Skip the getters that fields imply.
      if (getter.nonSynthetic != getter) continue;
      final annotation = syncedFieldChecker.firstAnnotationOf(getter);
      if (annotation == null) continue;
      await add(
        getter,
        annotation,
        getter.returnType,
        isStatic: getter.isStatic,
        isWritable: _hasSetter(getter.name!),
      );
    }
    return fields;
  }

  bool _hasSetter(String member) =>
      element.getSetter(member) != null ||
      element.allSupertypes.any(
        (supertype) => supertype.element.getSetter(member) != null,
      );

  /// Reads the prediction of the class, whose state is one of [fields], or
  /// returns `null` if it declares none.
  Future<_Prediction?> _prediction(List<_Field> fields) async {
    _Prediction? prediction;
    for (final method in element.methods) {
      final annotation = predictionChecker.firstAnnotationOf(method);
      if (annotation == null) continue;
      final description = '$name.${method.name}';
      if (prediction != null) {
        throw InvalidGenerationSourceError(
          '$name declares the predictions ${prediction.name} and '
          '${method.name}, but an entity has at most one prediction.',
          element: method,
        );
      }
      if (!method.isStatic) {
        throw InvalidGenerationSourceError(
          '@Prediction applies only to static methods, unlike $description: '
          'the host and the owner run the same step, which sees only the '
          'state and one input.',
          todo: 'Make $description static.',
          element: method,
        );
      }
      if (method.typeParameters.isNotEmpty) {
        throw InvalidGenerationSourceError(
          '@Prediction does not support methods with type parameters, such as '
          '$description.',
          element: method,
        );
      }
      final parameters = method.formalParameters;
      if (parameters.length != 2 ||
          parameters.any((parameter) => !parameter.isRequiredPositional)) {
        throw InvalidGenerationSourceError(
          '$description must take the state and one input, as two required '
          'positional parameters.',
          element: method,
        );
      }
      final reader = ConstantReader(annotation);
      final id = reader.read('id').stringValue;
      _checkIdentifier(id, 'input stream', method);

      final stateName = reader.read('of').stringValue;
      final state = fields
          .where((field) => field.name == stateName)
          .firstOrNull;
      if (state == null) {
        throw InvalidGenerationSourceError(
          'The state of the prediction $description is $stateName, which is '
          'not a @SyncedField member of $name.',
          todo: 'Name a member of $name that is annotated with @SyncedField.',
          element: method,
        );
      }
      final stateDescription = '$name.$stateName';
      if (state.writer != 'authority') {
        throw InvalidGenerationSourceError(
          'The state of the prediction $description is $stateDescription, '
          "which the entity's owner writes, but the entity's authority writes "
          'the state of a prediction.',
          todo: 'Remove the writer of $stateDescription.',
          element: method,
        );
      }
      if (!state.applyInterpolated) {
        throw InvalidGenerationSourceError(
          'The state of the prediction $description is $stateDescription, '
          'whose applyInterpolated does not apply: the prediction presents '
          'its state.',
          todo: 'Remove applyInterpolated from $stateDescription.',
          element: method,
        );
      }
      final stateType = state.type.getDisplayString();
      if (!library.sameType(method.returnType, state.type)) {
        throw InvalidGenerationSourceError(
          '$description returns ${method.returnType.getDisplayString()}, but '
          'its state $stateDescription is $stateType.',
          todo: 'Return $stateType.',
          element: method,
        );
      }
      final [stateParameter, inputParameter] = parameters;
      if (!library.sameType(stateParameter.type, state.type)) {
        throw InvalidGenerationSourceError(
          'Parameter ${stateParameter.name} of $description is '
          '${stateParameter.type.getDisplayString()}, but its state '
          '$stateDescription is $stateType.',
          todo: 'Take $stateType.',
          element: method,
        );
      }
      if (hasCodecAnnotation(stateParameter)) {
        throw InvalidGenerationSourceError(
          'Parameter ${stateParameter.name} of $description has a codec '
          'annotation, but the state takes its codec from $stateDescription.',
          todo: 'Annotate $stateDescription instead.',
          element: method,
        );
      }

      final inputType = inputParameter.type;
      final codec = await codecs.resolve(
        inputParameter,
        inputType,
        'parameter ${inputParameter.name} of $description',
      );
      final inputName = reader.read('input').stringValue;
      final input = _instanceValue(inputName);
      if (input == null) {
        throw InvalidGenerationSourceError(
          'The input of the prediction $description is $inputName, which is '
          'not an instance field or getter of $name.',
          todo:
              "Name the field or getter of $name that holds the owner's "
              'current input.',
          element: method,
        );
      }
      final inputDescription = '$name.$inputName';
      if (!library.typeSystem.isAssignableTo(input.type, inputType)) {
        throw InvalidGenerationSourceError(
          '$inputDescription, the input of the prediction $description, is '
          '${input.type.getDisplayString()}, but $description takes '
          '${inputType.getDisplayString()}.',
          element: method,
        );
      }
      if (!syncedFieldChecker.hasAnnotationOf(input.element) &&
          hasCodecAnnotation(input.element)) {
        throw InvalidGenerationSourceError(
          '$inputDescription has a codec annotation, but the inputs of '
          '$description take their codec from parameter '
          '${inputParameter.name}.',
          todo: 'Annotate parameter ${inputParameter.name} instead.',
          element: method,
        );
      }
      final tick = _microseconds(reader.read('tick').objectValue);
      if (tick != null && tick <= 0) {
        throw InvalidGenerationSourceError(
          'The tick of the prediction $description must be positive.',
          element: method,
        );
      }
      CopiedExpression? smoothing;
      if (reader.peek('smoothing') case final value?) {
        final microseconds = _microseconds(value.objectValue);
        if (microseconds != null && microseconds < 0) {
          throw InvalidGenerationSourceError(
            'The smoothing of the prediction $description must not be '
            'negative.',
            element: method,
          );
        }
        smoothing = await sources.argument(
          method,
          predictionChecker,
          named: 'smoothing',
        );
      }
      CopiedExpression? idleInput;
      if (reader.peek('idleInput') case final value?) {
        final type = value.objectValue.type;
        if (type == null ||
            !library.typeSystem.isAssignableTo(type, inputType)) {
          throw InvalidGenerationSourceError(
            'The idle input of the prediction $description is '
            '${type?.getDisplayString() ?? 'of an unknown type'}, but its '
            'inputs are ${inputType.getDisplayString()}.',
            element: method,
          );
        }
        idleInput = await sources.argument(
          method,
          predictionChecker,
          named: 'idleInput',
        );
      }
      prediction = _Prediction(
        method: method,
        id: id,
        state: state,
        input: inputName,
        inputType: inputType,
        codec: codec,
        tick: await sources.argument(method, predictionChecker, named: 'tick'),
        deliveryMode: _enumName(reader.read('deliveryMode').objectValue),
        channel: _channel(reader, method),
        smoothing: smoothing,
        idleInput: idleInput,
      );
    }
    return prediction;
  }

  /// The declaration and type of the instance field or getter [member] that
  /// the class declares, or `null` if it declares none.
  ({Element element, DartType type})? _instanceValue(String member) {
    for (final field in element.fields) {
      // Skip the fields that getters and setters imply.
      if (field.nonSynthetic != field || field.isStatic) continue;
      if (field.name == member) return (element: field, type: field.type);
    }
    for (final getter in element.getters) {
      // Skip the getters that fields imply.
      if (getter.nonSynthetic != getter || getter.isStatic) continue;
      if (getter.name == member) {
        return (element: getter, type: getter.returnType);
      }
    }
    return null;
  }

  void _checkIdentifier(String id, String kind, Element at) {
    if (!isValidIdentifier(id)) {
      throw InvalidGenerationSourceError(
        '"$id" is not a valid $kind identifier.',
        todo:
            'Use dot-separated segments of lowercase letters, digits, and '
            'underscores that each start with a letter, such as '
            '"arena.player.hit", with at most $maxIdentifierLength '
            'characters.',
        element: at,
      );
    }
  }

  static bool _isContext(DartType type) =>
      type.nullabilitySuffix == NullabilitySuffix.none &&
      isDeclaredIn(type.element, 'RpcContext', 'maratus');

  static bool _returnsNothing(DartType type) {
    if (type is VoidType) return true;
    return type is InterfaceType &&
        (type.isDartAsyncFuture || type.isDartAsyncFutureOr) &&
        type.typeArguments.single is VoidType;
  }

  static String _enumName(DartObject value) =>
      value.variable?.name ?? value.getField('_name')!.toStringValue()!;

  /// The length of the constant [duration] in microseconds, or `null` if it
  /// cannot be read.
  static int? _microseconds(DartObject duration) {
    // Since Dart 3.13, a duration keeps its length in a public field;
    // earlier SDKs keep it in a private one.
    for (final field in const ['inMicroseconds', '_duration']) {
      if (duration.getField(field)?.toIntValue() case final microseconds?) {
        return microseconds;
      }
    }
    return null;
  }

  static int _channel(ConstantReader reader, Element at) {
    final channel = reader.read('channel').intValue;
    if (channel < 0) {
      throw InvalidGenerationSourceError(
        'The transport channel must be nonnegative.',
        element: at,
      );
    }
    return channel;
  }

  List<String> _delivery(String mode, int channel) => [
    if (mode != 'reliable') 'deliveryMode: ${maratus}DeliveryMode.$mode,',
    if (channel != 0) 'channel: $channel,',
  ];

  // Writing the generated code.

  _Net _netClass(
    _Spawn? spawn,
    List<_Rpc> rpcs,
    List<_Field> fields,
    _Prediction? prediction,
    TopLevelConstants topLevel, {
    required CopiedExpression? syncInterval,
    required CopiedExpression? interpolationDelay,
  }) {
    final handles = [
      if (spawn != null) 'spawnType',
      for (final rpc in rpcs) rpc.name,
      for (final field in fields) field.name,
      if (prediction != null) prediction.name,
    ];
    final scope = UniqueNames({'register', ...objectMembers});
    for (final handle in handles) {
      if (scope.names.contains(handle)) {
        throw InvalidGenerationSourceError(
          'The generated $netName cannot have a handle called $handle.',
          todo: 'Rename the member of $name.',
          element: element,
        );
      }
      scope.add(handle);
    }
    final interpolators = <String, String>{
      for (final field in fields)
        if (field.interpolator != null)
          field.name: scope.add('_${publicPart(field.name)}Interpolator'),
    };
    final step = prediction == null ? null : publicPart(prediction.name);
    final smoothingName = prediction?.smoothing == null
        ? null
        : scope.add('_${step}Smoothing');
    final idleInputName = prediction?.idleInput == null
        ? null
        : scope.add('_${step}IdleInput');
    final syncIntervalName = syncInterval == null
        ? null
        : scope.add('_syncInterval');
    final interpolationDelayName = interpolationDelay == null
        ? null
        : scope.add('_interpolationDelay');

    String constant(String purpose, String expression, Set<String> freeNames) =>
        freeNames.any(scope.names.contains)
        ? topLevel.add(purpose, expression)
        : expression;

    final members = <String>[];
    final payloadCodecs = <String>[];
    final registrations = <String>[];
    if (spawn != null) {
      members.add('''
/// The spawn type of [$self].
static const spawnType = ${maratus}SpawnType(
  id: ${maratus}SpawnTypeId(${stringLiteral(spawn.id)}),
  codec: ${constant('spawnCodec', spawn.codec.expression, spawn.codec.freeNames)},
);''');
      registrations.add('addSpawnTypeDefinition(spawnType)');
    }
    for (final rpc in rpcs) {
      final String codec;
      if (rpc.isRecord) {
        final codecName =
            '_$name${upperFirst(publicPart(rpc.name))}PayloadCodec';
        payloadCodecs.add(_payloadCodec(codecName, rpc, topLevel));
        codec = '$codecName()';
      } else {
        final single = rpc.payload.single.codec!;
        codec = constant(
          '${publicPart(rpc.name)}Codec',
          single.expression,
          single.freeNames,
        );
      }
      final policies = [
        if (rpc.caller != 'anyPeer')
          'caller: ${maratus}RpcCaller.${rpc.caller},',
        if (rpc.target != 'host') 'target: ${maratus}RpcTarget.${rpc.target},',
        if (rpc.local != 'exclude') 'local: ${maratus}RpcLocal.${rpc.local},',
        ..._delivery(rpc.deliveryMode, rpc.channel),
      ];
      members.add('''
/// The RPC that [$self.${rpc.name}] handles.
static const ${rpc.name} = ${maratus}Rpc(
  id: ${maratus}RpcId(${stringLiteral(rpc.id)}),
  codec: $codec,
  ${policies.join('\n')}
);''');
      registrations.add('addRpcDefinition(${rpc.name})');
    }
    for (final field in fields) {
      members.add('''
/// The synchronized field of [$self.${field.name}].
static const ${field.name} = ${maratus}SyncField(
  id: ${maratus}FieldId(${stringLiteral(field.id)}),
  codec: ${constant('${publicPart(field.name)}Codec', field.codec.expression, field.codec.freeNames)},
  ${_delivery(field.deliveryMode, field.channel).join('\n')}
  ${field.writer != 'authority' ? 'writer: ${maratus}FieldWriter.${field.writer},' : ''}
);''');
      registrations.add('addFieldDefinition(${field.name})');
      final interpolator = field.interpolator;
      if (interpolator != null) {
        members.add(
          'static const ${interpolators[field.name]} = '
          '${constant('${publicPart(field.name)}Interpolator', interpolator.source, interpolator.freeNames)};',
        );
      }
    }
    if (prediction != null) {
      final codec = prediction.codec;
      final tick = prediction.tick;
      members.add('''
/// The input stream whose inputs [$self.${prediction.name}] applies.
static const ${prediction.name} = ${maratus}InputStream(
  id: ${maratus}InputId(${stringLiteral(prediction.id)}),
  codec: ${constant('${step}Codec', codec.expression, codec.freeNames)},
  tick: ${constant('${step}Tick', tick.source, tick.freeNames)},
  ${_delivery(prediction.deliveryMode, prediction.channel).join('\n')}
);''');
      registrations.add('addInputDefinition(${prediction.name})');
      if (prediction.smoothing case final smoothing?) {
        members.add(
          'static const $smoothingName = '
          '${constant('${step}Smoothing', smoothing.source, smoothing.freeNames)};',
        );
      }
      if (prediction.idleInput case final idleInput?) {
        members.add(
          'static const $idleInputName = '
          '${constant('${step}IdleInput', idleInput.source, idleInput.freeNames)};',
        );
      }
    }
    if (syncInterval != null) {
      members.add(
        'static const $syncIntervalName = '
        '${constant('syncInterval', syncInterval.source, syncInterval.freeNames)};',
      );
    }
    if (interpolationDelay != null) {
      members.add(
        'static const $interpolationDelayName = '
        '${constant('interpolationDelay', interpolationDelay.source, interpolationDelay.freeNames)};',
      );
    }

    final source =
        '''
/// The protocol handles of [$self], generated from its annotations.
///
/// Register them on every peer with [register].
abstract final class $netName {
  ${members.join('\n\n')}

  /// Registers the handles of [$self] with [builder].
  static void register(${maratus}ProtocolSchemaBuilder builder) {
    ${_calls('builder', registrations)};
  }
}''';
    return _Net(
      source,
      payloadCodecs,
      interpolators,
      smoothing: smoothingName,
      idleInput: idleInputName,
      syncInterval: syncIntervalName,
      interpolationDelay: interpolationDelayName,
    );
  }

  String _payloadCodec(String codecName, _Rpc rpc, TopLevelConstants topLevel) {
    final payload = rpc.payload.toList();
    final recordType = payload.isEmpty
        ? '()'
        : '({${payload.map((parameter) => '${library.typeSource(parameter.element.type, rpc.method)} ${parameter.name}').join(', ')}})';
    final scope = UniqueNames({
      'descriptor',
      'encode',
      'decode',
      ...objectMembers,
      for (final parameter in payload) '_${parameter.name}',
    });
    final statics = [
      for (final parameter in payload)
        'static const _${parameter.name} = '
            '${parameter.codec!.isShadowedBy(scope.names) ? topLevel.add('${publicPart(rpc.name)}${upperFirst(parameter.name)}Codec', parameter.codec!.expression) : parameter.codec!.expression};',
    ];
    final descriptor =
        "'${rpc.id}@${rpc.version}"
        "(${payload.map((parameter) => '\${_${parameter.name}.descriptor}').join(',')})'";
    final encode = payload.isEmpty
        ? 'const <Object?>[]'
        : '[${payload.map((parameter) => '_${parameter.name}.encode(value.${parameter.name})').join(', ')},]';
    final decode = payload.isEmpty
        ? '${maratus}WireList(wire, 0);\nreturn ();'
        : 'final list = ${maratus}WireList(wire, ${payload.length});\n'
              'return (${[for (final (index, parameter) in payload.indexed) '${parameter.name}: list.read($index, _${parameter.name})'].join(', ')},);';
    return '''
/// The codec of the payload of [$netName.${rpc.name}]: the parameters of
/// [$self.${rpc.name}] in a positional list.
final class $codecName extends ${maratus}ValueCodec<$recordType> {
  const $codecName();

  ${statics.join('\n')}

  @override
  String get descriptor => $descriptor;

  @override
  Object? encode($recordType value) => $encode;

  @override
  $recordType decode(Object? wire) {
    $decode
  }
}''';
  }

  String _mixin(
    InterfaceElement? component,
    List<_Rpc> rpcs,
    List<_Field> fields,
    _Prediction? prediction,
    _Net net,
  ) {
    final body = <String>[];
    final predictionType = prediction == null
        ? null
        : '${maratus}Predictor<'
              '${library.typeSource(prediction.state.type, prediction.method)}, '
              '${library.typeSource(prediction.inputType, prediction.method)}>';
    if (fields.isNotEmpty) {
      body.add('''
${maratus}EntityAttachment? _\$networkAttachment;
${maratus}MultiplayerSynchronizer? _\$networkSynchronizer;
${predictionType == null ? '' : '$predictionType? _\$networkPredictor;'}

/// The synchronizer of the synchronized fields of this [$self] while its
/// attachment is live, or `null`.
///
/// ${_synchronizerUse(fields, prediction)}
${maratus}MultiplayerSynchronizer? get networkSynchronizer {
  final attachment = _\$networkAttachment;
  return attachment == null || attachment.isDisposed
      ? null
      : _\$networkSynchronizer;
}''');
    }
    if (prediction != null) {
      body.add('''
/// The predictor of [$self.${prediction.state.name}] while the attachment of
/// this [$self] is live, or `null`.
///
/// [updateNetworkMembers] runs it every frame. To change the state outside
/// its step, such as to respawn, set its state on the entity's authority.
$predictionType? get networkPredictor {
  final attachment = _\$networkAttachment;
  return attachment == null || attachment.isDisposed
      ? null
      : _\$networkPredictor;
}''');
    }
    if (rpcs.isNotEmpty || fields.isNotEmpty) {
      final statements = <String>[
        if (component != null) 'super.bindNetworkMembers(attachment);',
        'final self = this as $self;',
        if (rpcs.isNotEmpty)
          '${_calls('attachment', [for (final rpc in rpcs) 'bindRpc($netName.${rpc.name}, (context, payload) => self.${rpc.name}(${_handlerArguments(rpc)}))'])};',
        if (fields.isNotEmpty) ...[
          r'_$networkAttachment = attachment;',
          // The synchronizer binds the prediction's property, so the
          // prediction comes first.
          if (prediction != null) ...[
            'final prediction = attachment.predict('
                '${_predictArguments(prediction, net)});',
            r'_$networkPredictor = prediction;',
          ],
          '_\$networkSynchronizer = attachment.synchronize(['
              '${fields.map((field) => _property(field, prediction, net)).join(', ')},'
              ']${net.syncInterval == null ? '' : ', interval: $netName.${net.syncInterval}'}'
              '${net.interpolationDelay == null ? '' : ', interpolationDelay: $netName.${net.interpolationDelay}'});',
        ],
      ];
      body.add(
        component == null
            ? '''
/// Binds the annotated RPC handlers and synchronized fields of this [$self]
/// through [attachment]${prediction == null ? '' : ', and predicts [$self.${prediction.state.name}]'}.
///
/// Call it once for each attachment of the object's entity, such as the one
/// that [${maratus}MultiplayerSession.attachEntity] returns.
void bindNetworkMembers(${maratus}EntityAttachment attachment) {
  ${statements.join('\n')}
}'''
            : '''
@override
void bindNetworkMembers(${maratus}EntityAttachment attachment) {
  ${statements.join('\n')}
}''',
      );
    }
    if (prediction != null) body.add(_update(component, prediction));
    final on = component == null
        ? ''
        : ' on ${library.reference(component, element)}';
    return '''
/// Binds the annotated members of [$self].
mixin $mixinName$on {
  ${body.join('\n\n')}
}''';
  }

  /// The method that runs [prediction] every frame: an override of the hook
  /// of a Flame [component], or a method that other classes call.
  String _update(InterfaceElement? component, _Prediction prediction) {
    final state = prediction.state;
    final input = prediction.input;
    final update = 'prediction.update(self.$input, elapsed)';
    final statements = [
      if (component != null) 'super.updateNetworkMembers(dt);',
      'final prediction = networkPredictor;',
      'if (prediction == null) return;',
      'final self = this as $self;',
      if (component != null)
        'final elapsed = Duration('
            'microseconds: (dt * Duration.microsecondsPerSecond).round());',
      // A member without a setter leaves presenting the state to the game.
      if (state.isWritable) 'self.${state.name} = $update;' else '$update;',
    ];
    if (component != null) {
      return '''
@override
void updateNetworkMembers(double dt) {
  ${statements.join('\n')}
}''';
    }
    final presents = state.isWritable
        ? ', and every peer\n'
              '/// writes the state to present to [$self.${state.name}].'
        : '. [$self.${state.name}] has no\n'
              '/// setter, so present the state of [networkPredictor].';
    return '''
/// Runs the prediction of [$self.${state.name}] for one frame of [elapsed].
///
/// The entity's owner advances it with [$self.$input]$presents
///
/// Call it once per frame, after [${maratus}MultiplayerSession.update] and
/// before [${maratus}MultiplayerSession.captureState].
void updateNetworkMembers(Duration elapsed) {
  ${statements.join('\n')}
}''';
  }

  /// How to read the values of [fields] from their synchronizer, for its
  /// documentation.
  String _synchronizerUse(List<_Field> fields, _Prediction? prediction) {
    // The prediction presents its own state, and the members whose setters
    // receive their interpolated values hold them.
    final interpolated = fields.where(
      (field) =>
          field.interpolator != null &&
          !identical(field, prediction?.state) &&
          !(field.isWritable && field.applyInterpolated),
    );
    return interpolated.isEmpty
        ? 'Read the latest values from it, as in\n'
              '/// `networkSynchronizer?.snapshot($netName.${fields.first.name})`.'
        : 'Read interpolated values from it, as in\n'
              '/// `networkSynchronizer?.interpolated($netName.${interpolated.first.name})`.';
  }

  /// Calls each of [calls] on [target], with a cascade if there are several.
  static String _calls(String target, List<String> calls) => calls.length == 1
      ? '$target.${calls.single}'
      : '$target${calls.map((call) => '..$call').join()}';

  String _handlerArguments(_Rpc rpc) => [
    for (final parameter in rpc.parameters)
      '${parameter.element.isNamed ? '${parameter.name}: ' : ''}'
          '${parameter.isContext
              ? 'context'
              : rpc.isRecord
              ? 'payload.${parameter.name}'
              : 'payload'}',
  ].join(', ');

  /// The arguments of the call that creates [prediction].
  String _predictArguments(_Prediction prediction, _Net net) {
    final state = prediction.state;
    return [
      'state: $netName.${state.name}',
      'input: $netName.${prediction.name}',
      'initial: self.${state.name}',
      'step: $self.${prediction.name}',
      if (net.interpolators[state.name] case final interpolator?)
        'interpolator: $netName.$interpolator',
      if (net.smoothing case final smoothing?) 'smoothing: $netName.$smoothing',
      if (net.idleInput case final idleInput?) 'idleInput: $netName.$idleInput',
    ].join(', ');
  }

  String _property(_Field field, _Prediction? prediction, _Net net) {
    // The prediction backs the property of its state, with the member's
    // interpolator.
    if (identical(field, prediction?.state)) {
      return 'prediction.property('
          '${field.mode == 'onChange' ? '' : 'mode: ${maratus}SyncMode.${field.mode}'})';
    }
    final arguments = [
      'get: () => self.${field.name}',
      if (field.isWritable) 'set: (value) => self.${field.name} = value',
      if (field.mode != 'onChange') 'mode: ${maratus}SyncMode.${field.mode}',
      if (field.interpolator != null)
        'interpolator: $netName.${net.interpolators[field.name]}',
      if (!field.applyInterpolated) 'applyInterpolated: false',
    ];
    return '$netName.${field.name}.property(${arguments.join(', ')})';
  }

  String _senders(List<_Rpc> rpcs) {
    final senderName = '${name}Rpc';
    final methods = <String>[];
    for (final rpc in rpcs) {
      final payload = rpc.payload.toList();
      final positional = [
        for (final parameter in payload)
          if (!parameter.element.isNamed)
            '${library.typeSource(parameter.element.type, rpc.method)} '
                '${parameter.name}',
      ];
      final named = [
        for (final parameter in payload)
          if (parameter.element.isNamed)
            'required ${library.typeSource(parameter.element.type, rpc.method)} '
                '${parameter.name}',
        if (rpc.target == 'peer') 'required ${maratus}PeerId to',
      ];
      final parameters = [
        ...positional,
        if (named.isNotEmpty) '{${named.join(', ')}}',
      ].join(', ');
      final value = !rpc.isRecord
          ? payload.single.name
          : payload.isEmpty
          ? '()'
          : '(${payload.map((parameter) => '${parameter.name}: ${parameter.name}').join(', ')})';
      final peer = rpc.target == 'peer' ? ', peer: to' : '';
      methods.add(
        '''
/// Calls [$self.${rpc.name}] through [$netName.${rpc.name}].
bool ${rpc.name}($parameters) => _\$call($netName.${rpc.name}, $value$peer);''',
      );
    }
    return '''
/// Calls the RPCs of a [$self] over its session, as in
/// `component.rpc.${rpcs.first.name}(...)`.
///
/// Each method returns whether the session accepted the call, as
/// [${maratus}MultiplayerSession.callRpc] does.
extension type $senderName._($self _\$component) {
  ${methods.join('\n\n')}

  bool _\$call<T>(${maratus}Rpc<T> rpc, T payload, {${maratus}PeerId? peer}) =>
      _\$component.multiplayerSession.callRpc(
        _\$component.networkEntity,
        rpc,
        payload,
        peer: peer,
      );
}

/// Provides the typed RPC senders of a [$self].
extension ${senderName}Access on $self {
  /// Calls the RPCs of this component over its session.
  $senderName get rpc => $senderName._(this);
}''';
  }
}

/// The generated handle class and what the rest of the code refers to in it.
final class _Net {
  _Net(
    this.source,
    this.payloadCodecs,
    this.interpolators, {
    required this.smoothing,
    required this.idleInput,
    required this.syncInterval,
    required this.interpolationDelay,
  });

  final String source;
  final List<String> payloadCodecs;

  /// The names of the interpolator constants, by field.
  final Map<String, String> interpolators;

  /// The names of the constants of the prediction's options.
  final String? smoothing;
  final String? idleInput;

  final String? syncInterval;
  final String? interpolationDelay;
}
