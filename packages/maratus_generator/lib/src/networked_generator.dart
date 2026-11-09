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
    required this.version,
    required this.parameters,
  });

  final MethodElement method;
  final String id;
  final String caller;
  final String target;
  final String local;
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
    required this.interpolator,
    required this.isWritable,
    required this.codec,
  });

  final Element member;
  final DartType type;
  final String id;
  final String mode;
  final CopiedExpression? interpolator;
  final bool isWritable;
  final CodecSource codec;

  String get name => member.name!;
}

final class _Spawn {
  _Spawn(this.id, this.codec);

  final String id;
  final CodecSource codec;
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
      topLevel,
      syncInterval: syncInterval,
      interpolationDelay: interpolationDelay,
    );
    return [
      net.source,
      net.payloadCodecs.join('\n\n'),
      if (mentionsMixin) _mixin(component, rpcs, fields, net),
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
      fields.add(
        _Field(
          member: member,
          type: type,
          id: id,
          mode: _enumName(reader.read('mode').objectValue),
          interpolator: interpolator,
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

  // Writing the generated code.

  _Net _netClass(
    _Spawn? spawn,
    List<_Rpc> rpcs,
    List<_Field> fields,
    TopLevelConstants topLevel, {
    required CopiedExpression? syncInterval,
    required CopiedExpression? interpolationDelay,
  }) {
    final handles = [
      if (spawn != null) 'spawnType',
      for (final rpc in rpcs) rpc.name,
      for (final field in fields) field.name,
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
    _Net net,
  ) {
    final body = <String>[];
    if (fields.isNotEmpty) {
      body.add('''
${maratus}EntityAttachment? _\$networkAttachment;
${maratus}MultiplayerSynchronizer? _\$networkSynchronizer;

/// The synchronizer of the synchronized fields of this [$self] while its
/// attachment is live, or `null`.
///
/// ${_synchronizerUse(fields)}
${maratus}MultiplayerSynchronizer? get networkSynchronizer {
  final attachment = _\$networkAttachment;
  return attachment == null || attachment.isDisposed
      ? null
      : _\$networkSynchronizer;
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
          '_\$networkSynchronizer = attachment.synchronize(['
              '${fields.map((field) => _property(field, net)).join(', ')},'
              ']${net.syncInterval == null ? '' : ', interval: $netName.${net.syncInterval}'}'
              '${net.interpolationDelay == null ? '' : ', interpolationDelay: $netName.${net.interpolationDelay}'});',
        ],
      ];
      body.add(
        component == null
            ? '''
/// Binds the annotated RPC handlers and synchronized fields of this [$self]
/// through [attachment].
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
    final on = component == null
        ? ''
        : ' on ${library.reference(component, element)}';
    return '''
/// Binds the annotated members of [$self].
mixin $mixinName$on {
  ${body.join('\n\n')}
}''';
  }

  /// How to read the values of [fields] from their synchronizer, for its
  /// documentation.
  String _synchronizerUse(List<_Field> fields) {
    final interpolated = fields.where((field) => field.interpolator != null);
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

  String _property(_Field field, _Net net) {
    final arguments = [
      'get: () => self.${field.name}',
      if (field.isWritable) 'set: (value) => self.${field.name} = value',
      if (field.mode != 'onChange') 'mode: ${maratus}SyncMode.${field.mode}',
      if (field.interpolator != null)
        'interpolator: $netName.${net.interpolators[field.name]}',
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
    required this.syncInterval,
    required this.interpolationDelay,
  });

  final String source;
  final List<String> payloadCodecs;

  /// The names of the interpolator constants, by field.
  final Map<String, String> interpolators;

  final String? syncInterval;
  final String? interpolationDelay;
}
