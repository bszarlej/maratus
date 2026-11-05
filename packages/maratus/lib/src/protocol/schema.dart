import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'identifiers.dart';
import 'protocol_exception.dart';
import 'rpc.dart';
import 'spawn_type.dart';
import 'static_entity.dart';
import 'sync_field.dart';
import 'value_codec.dart';

/// A registered identifier and the codec for its values.
final class SchemaEntry<T> {
  SchemaEntry._(this.id, this.codec);

  /// The registered identifier.
  final String id;

  /// The codec for values of this entry.
  final ValueCodec<T> codec;

  /// Encodes [value] with [codec].
  ///
  /// Throws an [ArgumentError] if [value] is not a [T] or [codec] cannot
  /// encode it.
  Object? encode(Object? value) {
    if (value is! T) {
      throw ArgumentError.value(
        value,
        'value',
        'is not valid for "$id" (${codec.descriptor})',
      );
    }
    try {
      return codec.encode(value);
    } on ArgumentError {
      rethrow;
    } on Object catch (error) {
      throw ArgumentError(
        '${codec.descriptor} could not encode the value: $error',
      );
    }
  }

  /// Decodes a received [wire] value with [codec].
  ///
  /// Every failure is reported as a [ProtocolException], including
  /// unexpected errors thrown by [codec].
  Object? decode(Object? wire) {
    try {
      return codec.decode(wire);
    } on ProtocolException {
      rethrow;
    } on Object catch (error) {
      throw ProtocolException(
        ProtocolErrorCode.invalidValue,
        '${codec.descriptor} rejected the value: $error',
      );
    }
  }
}

/// The registrations that host and clients must agree on.
///
/// A schema maps stable identifiers for spawn types, RPCs, and synchronized
/// fields to the codecs of their values, and declares the static entities
/// that every session contains. Peers compare [fingerprint]s when
/// connecting.
final class ProtocolSchema {
  ProtocolSchema._(
    this._spawnTypes,
    this._rpcs,
    this._fields,
    this._spawnTypeDefinitions,
    this._rpcDefinitions,
    this._fieldDefinitions,
    this._staticEntityDefinitions,
  ) : staticEntities = List.unmodifiable([
        for (final id in _staticEntityDefinitions.keys.toList()..sort())
          _staticEntityDefinitions[id]!,
      ]),
      fingerprint = _fingerprint(
        _spawnTypes,
        _rpcDefinitions,
        _fields,
        _staticEntityDefinitions.keys,
      );

  final Map<String, SchemaEntry<Object?>> _spawnTypes;
  final Map<String, SchemaEntry<Object?>> _rpcs;
  final Map<String, SchemaEntry<Object?>> _fields;
  final Map<String, SpawnType<Object?>> _spawnTypeDefinitions;
  final Map<String, Rpc<Object?>> _rpcDefinitions;
  final Map<String, SyncField<Object?>> _fieldDefinitions;
  final Map<String, StaticEntity> _staticEntityDefinitions;

  /// The declared static entities, in the order of their entity IDs: sorted
  /// by identifier, so that the first has ID 1, the next ID 2, and so on.
  ///
  /// Every session registers these entities when it starts hosting or
  /// joining, and the entities it spawns take the IDs that follow.
  final List<StaticEntity> staticEntities;

  /// A SHA-256 digest, in lowercase hexadecimal, of every identifier and
  /// codec descriptor in this schema, including each RPC's caller, target,
  /// and local-invocation policies, and of the static entities.
  ///
  /// Equal registrations produce equal fingerprints on every platform,
  /// regardless of the order in which they were registered.
  final String fingerprint;

  /// The registration for spawn type [id], or `null` if there is none.
  SchemaEntry<Object?>? spawnType(SpawnTypeId id) => _spawnTypes[id.value];

  /// The registered spawn type handle for [id], or `null` if there is none.
  ///
  /// This is the same handle returned when the type was registered,
  /// retaining its construction data type and codec.
  SpawnType<Object?>? spawnTypeDefinition(SpawnTypeId id) =>
      _spawnTypeDefinitions[id.value];

  /// The registration for RPC [id], or `null` if there is none.
  SchemaEntry<Object?>? rpc(RpcId id) => _rpcs[id.value];

  /// The registered RPC handle for [id], or `null` if there is none.
  ///
  /// This is the same handle returned when the RPC was registered, retaining
  /// its payload type, codec, and routing policies.
  Rpc<Object?>? rpcDefinition(RpcId id) => _rpcDefinitions[id.value];

  /// The registration for synchronized field [id], or `null` if there is
  /// none.
  SchemaEntry<Object?>? field(FieldId id) => _fields[id.value];

  /// The registered field handle for [id], or `null` if there is none.
  ///
  /// This is the same handle returned when the field was registered,
  /// retaining its value type and codec.
  SyncField<Object?>? fieldDefinition(FieldId id) =>
      _fieldDefinitions[id.value];

  /// The declared static entity handle for [id], or `null` if there is
  /// none.
  ///
  /// This is the same handle returned when the entity was declared.
  StaticEntity? staticEntityDefinition(StaticEntityId id) =>
      _staticEntityDefinitions[id.value];

  /// The version of the canonical description that [fingerprint] digests.
  static const _canonicalFormat = 3;

  static String _fingerprint(
    Map<String, SchemaEntry<Object?>> spawnTypes,
    Map<String, Rpc<Object?>> rpcs,
    Map<String, SchemaEntry<Object?>> fields,
    Iterable<String> staticEntities,
  ) {
    List<List<String>> describe(Map<String, SchemaEntry<Object?>> entries) => [
      for (final id in entries.keys.toList()..sort())
        [id, entries[id]!.codec.descriptor],
    ];
    // JSON escaping keeps descriptors from being mistaken for structure.
    final canonical = jsonEncode({
      'format': _canonicalFormat,
      'spawnTypes': describe(spawnTypes),
      'rpcs': [
        for (final id in rpcs.keys.toList()..sort())
          [
            id,
            rpcs[id]!.codec.descriptor,
            rpcs[id]!.caller.code,
            rpcs[id]!.target.code,
            rpcs[id]!.local.code,
          ],
      ],
      'fields': describe(fields),
      'staticEntities': staticEntities.toList()..sort(),
    });
    return sha256.convert(utf8.encode(canonical)).toString();
  }
}

/// Collects registrations for a [ProtocolSchema].
final class ProtocolSchemaBuilder {
  final _spawnTypes = <String, SchemaEntry<Object?>>{};
  final _rpcs = <String, SchemaEntry<Object?>>{};
  final _fields = <String, SchemaEntry<Object?>>{};
  final _spawnTypeDefinitions = <String, SpawnType<Object?>>{};
  final _rpcDefinitions = <String, Rpc<Object?>>{};
  final _fieldDefinitions = <String, SyncField<Object?>>{};
  final _staticEntities = <String, StaticEntity>{};

  /// Registers spawn type [id] with the [codec] for its construction data
  /// and returns its handle.
  ///
  /// Throws an [ArgumentError] if [id] is not a valid identifier or is
  /// already registered as a spawn type.
  SpawnType<T> addSpawnType<T>(SpawnTypeId id, ValueCodec<T> codec) {
    _add(_spawnTypes, 'spawn type', id.value, codec);
    final type = SpawnType<T>(id: id, codec: codec);
    _spawnTypeDefinitions[id.value] = type;
    return type;
  }

  /// Registers RPC [id] with the [codec] for its payload and returns its handle.
  ///
  /// [caller] controls permission independently of the destinations selected by
  /// [target]. [local] controls execution when the caller is a selected target.
  /// All three policies are included in the schema fingerprint.
  ///
  /// Throws an [ArgumentError] if [id] is not a valid identifier or is
  /// already registered as an RPC.
  Rpc<T> addRpc<T>(
    RpcId id,
    ValueCodec<T> codec, {
    RpcCaller caller = RpcCaller.anyPeer,
    RpcTarget target = RpcTarget.host,
    RpcLocal local = RpcLocal.exclude,
  }) {
    _add(_rpcs, 'RPC', id.value, codec);
    final rpc = Rpc<T>(
      id: id,
      codec: codec,
      caller: caller,
      target: target,
      local: local,
    );
    _rpcDefinitions[id.value] = rpc;
    return rpc;
  }

  /// Registers synchronized field [id] with the [codec] for its values and
  /// returns its handle.
  ///
  /// Throws an [ArgumentError] if [id] is not a valid identifier or is
  /// already registered as a field.
  SyncField<T> addField<T>(FieldId id, ValueCodec<T> codec) {
    _add(_fields, 'field', id.value, codec);
    final field = SyncField<T>(id: id, codec: codec);
    _fieldDefinitions[id.value] = field;
    return field;
  }

  /// Declares static entity [id], an entity that exists in every session
  /// without being spawned, and returns its handle.
  ///
  /// Each session registers the declared entities when it starts hosting or
  /// joining, before it handles any message. Every peer gives them the same
  /// entity IDs: sorted by identifier, they take the IDs from 1 up, as
  /// [ProtocolSchema.staticEntities] lists them. The host owns them and is
  /// their authority. Peers that declare different static entities have
  /// different fingerprints, so they cannot connect.
  ///
  /// Throws an [ArgumentError] if [id] is not a valid identifier or is
  /// already declared as a static entity.
  StaticEntity addStaticEntity(StaticEntityId id) {
    if (!isValidIdentifier(id.value)) {
      throw ArgumentError.value(
        id.value,
        'id',
        'is not a valid static entity identifier',
      );
    }
    if (_staticEntities.containsKey(id.value)) {
      throw ArgumentError.value(
        id.value,
        'id',
        'is already declared as a static entity',
      );
    }
    return _staticEntities[id.value] = StaticEntity(id: id);
  }

  /// Creates a schema from the registrations made so far.
  ProtocolSchema build() => ProtocolSchema._(
    Map.of(_spawnTypes),
    Map.of(_rpcs),
    Map.of(_fields),
    Map.of(_spawnTypeDefinitions),
    Map.of(_rpcDefinitions),
    Map.of(_fieldDefinitions),
    Map.of(_staticEntities),
  );

  static void _add<T>(
    Map<String, SchemaEntry<Object?>> entries,
    String kind,
    String id,
    ValueCodec<T> codec,
  ) {
    if (!isValidIdentifier(id)) {
      throw ArgumentError.value(id, 'id', 'is not a valid $kind identifier');
    }
    if (entries.containsKey(id)) {
      throw ArgumentError.value(id, 'id', 'is already registered as a $kind');
    }
    entries[id] = SchemaEntry<T>._(id, codec);
  }
}
