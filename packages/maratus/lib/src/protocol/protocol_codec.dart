import 'dart:typed_data';

import 'identifiers.dart';
import 'messages.dart';
import 'protocol_exception.dart';
import 'schema.dart';
import 'value_codec.dart';
import 'wire_codec.dart';

/// Encodes and decodes [MessageEnvelope]s for a [ProtocolSchema].
///
/// [decode] is the boundary for untrusted input: it either returns a message
/// whose structure, identifiers, and values have all been validated, or
/// throws a [ProtocolException].
///
/// An encoded envelope is an object with these keys:
///
/// - `v`: the protocol [version]. Every protocol version keeps this key, so
///   peers can always detect a version mismatch.
/// - `k`: the [MessageKind.code].
/// - `g`: the [MessageEnvelope.generation].
/// - `r`: the [MessageEnvelope.revision].
/// - `b`: the message body. Hello bodies hold the schema fingerprint `f`,
///   welcome bodies the client's peer ID `p` and the epoch `e`, and goodbye
///   bodies the reason code `c`; synced and ready bodies are empty. The
///   other bodies hold the entity ID `e`: spawn bodies add the spawn type `t`,
///   construction data `d`, owner `o`, authority `a`, and optionally a parent
///   entity `p`. RPC request bodies add the RPC `m`, its payload `p`, and
///   optionally a target peer `t`. RPC deliveries require both sender `s` and
///   target `t`; state bodies add an object `f` of field values. The session
///   validates the origin of RPC deliveries and the consistency of spawn
///   metadata.
final class ProtocolCodec {
  /// Creates a codec for the messages of [schema].
  ProtocolCodec(
    this.schema, {
    this.wire = const JsonWireCodec(),
    this.limits = const WireLimits(),
  });

  /// The protocol version that this codec writes and accepts.
  ///
  /// RPC routing and spawn metadata extend version 1; the schema fingerprint
  /// includes RPC routing metadata so earlier schemas fail the session
  /// handshake.
  static const int version = 1;

  /// The registrations that message bodies are validated against.
  final ProtocolSchema schema;

  /// The byte representation of wire values.
  final WireCodec wire;

  /// The size limits applied when encoding and decoding.
  final WireLimits limits;

  static const _versionCodec = IntCodec();
  static const _counterCodec = IntCodec(min: 0);
  static const _entityCodec = IntCodec(min: 1);
  static const _peerCodec = IntCodec(min: 1);
  static const _clientCodec = IntCodec(min: 2);
  static const _epochCodec = IntCodec(min: 1);
  static const _fingerprintCodec = StringCodec(maxLength: 64);
  static const _identifierCodec = StringCodec(maxLength: maxIdentifierLength);
  static final _kinds = {
    for (final kind in MessageKind.values) kind.code: kind,
  };
  static final _goodbyeReasons = {
    for (final reason in GoodbyeReason.values) reason.code: reason,
  };

  /// Encodes [envelope] as bytes.
  ///
  /// Throws an [ArgumentError] if the envelope refers to unregistered
  /// identifiers, contains values that its codecs reject, or exceeds
  /// [limits].
  Uint8List encode(MessageEnvelope envelope) {
    final value = <String, Object?>{
      'v': version,
      'k': envelope.message.kind.code,
      'g': _checkCounter(envelope.generation, 'generation'),
      'r': _checkCounter(envelope.revision, 'revision'),
      'b': _encodeBody(envelope.message),
    };
    try {
      checkWireValue(value, limits);
    } on ProtocolException catch (error) {
      throw ArgumentError('Envelope cannot be encoded: ${error.message}');
    }
    final bytes = wire.encode(value);
    if (bytes.length > limits.maxMessageBytes) {
      throw ArgumentError(
        'Envelope encodes to ${bytes.length} bytes, more than the limit of '
        '${limits.maxMessageBytes}',
      );
    }
    return bytes;
  }

  /// Decodes and validates received [bytes].
  ///
  /// Throws a [ProtocolException] if [bytes] are malformed or too large, use
  /// an unsupported protocol version or an unknown message kind, refer to
  /// identifiers missing from [schema], or contain invalid values.
  MessageEnvelope decode(Uint8List bytes) {
    if (bytes.length > limits.maxMessageBytes) {
      throw ProtocolException(
        ProtocolErrorCode.limitExceeded,
        'message has ${bytes.length} bytes, more than the limit of '
        '${limits.maxMessageBytes}',
      );
    }
    final Object? decoded;
    try {
      decoded = wire.decode(bytes);
    } on FormatException catch (error) {
      throw ProtocolException(ProtocolErrorCode.malformed, error.message);
    }
    checkWireValue(decoded, limits);
    if (decoded is! Map<String, Object?>) {
      throw const ProtocolException(
        ProtocolErrorCode.invalidValue,
        'expected an envelope object',
      );
    }
    final value = decoded;

    // Other protocol versions may use a different envelope shape, so check
    // the version before the shape.
    if (!value.containsKey('v')) {
      throw const ProtocolException(
        ProtocolErrorCode.invalidValue,
        'missing key "v"',
      );
    }
    final received = _within('v', () => _versionCodec.decode(value['v']));
    if (received != version) {
      throw ProtocolException(
        ProtocolErrorCode.unsupportedVersion,
        'protocol version $received is not supported; expected $version',
      );
    }

    final envelope = WireObject(value, const {'v', 'k', 'g', 'r', 'b'});
    final code = envelope.read('k', _identifierCodec);
    final kind = _kinds[code];
    if (kind == null) {
      throw ProtocolException(
        ProtocolErrorCode.unknownKind,
        'unknown message kind "$code"',
        path: const ['k'],
      );
    }
    final generation = envelope.read('g', _counterCodec);
    final revision = envelope.read('r', _counterCodec);
    final message = _within('b', () => _decodeBody(kind, envelope['b']));
    return MessageEnvelope(message, generation: generation, revision: revision);
  }

  Map<String, Object?> _encodeBody(ProtocolMessage message) =>
      switch (message) {
        HelloMessage(:final fingerprint) => {
          'f': _fingerprintCodec.encode(fingerprint),
        },
        WelcomeMessage(:final peer, :final epoch) => {
          'p': _clientCodec.encode(peer.value),
          'e': _epochCodec.encode(epoch),
        },
        SyncedMessage() || ReadyMessage() => const {},
        GoodbyeMessage(:final reason) => {'c': reason.code},
        SpawnMessage(
          :final entity,
          :final type,
          :final data,
          :final owner,
          :final authority,
          :final parent,
        ) =>
          {
            'e': _checkEntity(entity),
            't': type.value,
            'd': _registered(
              schema.spawnType(type),
              'spawn type',
              type.value,
            ).encode(data),
            'o': _peerCodec.encode(owner.value),
            'a': _peerCodec.encode(authority.value),
            if (parent != null) 'p': _checkEntity(parent),
          },
        DespawnMessage(:final entity) => {'e': _checkEntity(entity)},
        RpcMessage(:final entity, :final rpc, :final payload, :final target) =>
          {
            'e': _checkEntity(entity),
            'm': rpc.value,
            'p': _registered(schema.rpc(rpc), 'RPC', rpc.value).encode(payload),
            if (target != null) 't': _peerCodec.encode(target.value),
          },
        RpcDeliveryMessage(
          :final entity,
          :final rpc,
          :final payload,
          :final sender,
          :final target,
        ) =>
          {
            'e': _checkEntity(entity),
            'm': rpc.value,
            'p': _registered(schema.rpc(rpc), 'RPC', rpc.value).encode(payload),
            's': _peerCodec.encode(sender.value),
            't': _peerCodec.encode(target.value),
          },
        StateMessage(:final entity, :final values) => {
          'e': _checkEntity(entity),
          'f': _encodeFields(values),
        },
      };

  Map<String, Object?> _encodeFields(Map<FieldId, Object?> values) {
    if (values.isEmpty) {
      throw ArgumentError.value(values, 'values', 'must not be empty');
    }
    return {
      for (final MapEntry(:key, :value) in values.entries)
        key.value: _registered(
          schema.field(key),
          'field',
          key.value,
        ).encode(value),
    };
  }

  ProtocolMessage _decodeBody(MessageKind kind, Object? value) {
    switch (kind) {
      case MessageKind.hello:
        final body = WireObject(value, const {'f'});
        return HelloMessage(fingerprint: body.read('f', _fingerprintCodec));
      case MessageKind.welcome:
        final body = WireObject(value, const {'p', 'e'});
        return WelcomeMessage(
          peer: PeerId(body.read('p', _clientCodec)),
          epoch: body.read('e', _epochCodec),
        );
      case MessageKind.synced:
        WireObject(value, const {});
        return const SyncedMessage();
      case MessageKind.ready:
        WireObject(value, const {});
        return const ReadyMessage();
      case MessageKind.goodbye:
        final body = WireObject(value, const {'c'});
        final code = body.read('c', _identifierCodec);
        final reason = _goodbyeReasons[code];
        if (reason == null) {
          throw ProtocolException(
            ProtocolErrorCode.invalidValue,
            'unknown goodbye reason "$code"',
            path: const ['c'],
          );
        }
        return GoodbyeMessage(reason);
      case MessageKind.spawn:
        final hasParent =
            value is Map<String, Object?> && value.containsKey('p');
        final body = WireObject(
          value,
          hasParent
              ? const {'e', 't', 'd', 'o', 'a', 'p'}
              : const {'e', 't', 'd', 'o', 'a'},
        );
        final type = SpawnTypeId(body.read('t', _identifierCodec));
        final entry = _known(
          schema.spawnType(type),
          'spawn type',
          't',
          type.value,
        );
        return SpawnMessage(
          entity: _readEntity(body),
          type: type,
          data: _within('d', () => entry.decode(body['d'])),
          owner: PeerId(body.read('o', _peerCodec)),
          authority: PeerId(body.read('a', _peerCodec)),
          parent: hasParent ? EntityId(body.read('p', _entityCodec)) : null,
        );
      case MessageKind.despawn:
        final body = WireObject(value, const {'e'});
        return DespawnMessage(entity: _readEntity(body));
      case MessageKind.rpc:
        final hasTarget =
            value is Map<String, Object?> && value.containsKey('t');
        final body = WireObject(
          value,
          hasTarget ? const {'e', 'm', 'p', 't'} : const {'e', 'm', 'p'},
        );
        final rpc = RpcId(body.read('m', _identifierCodec));
        final entry = _known(schema.rpc(rpc), 'RPC', 'm', rpc.value);
        return RpcMessage(
          entity: _readEntity(body),
          rpc: rpc,
          payload: _within('p', () => entry.decode(body['p'])),
          target: hasTarget ? PeerId(body.read('t', _peerCodec)) : null,
        );
      case MessageKind.rpcDelivery:
        final body = WireObject(value, const {'e', 'm', 'p', 's', 't'});
        final rpc = RpcId(body.read('m', _identifierCodec));
        final entry = _known(schema.rpc(rpc), 'RPC', 'm', rpc.value);
        return RpcDeliveryMessage(
          entity: _readEntity(body),
          rpc: rpc,
          payload: _within('p', () => entry.decode(body['p'])),
          sender: PeerId(body.read('s', _peerCodec)),
          target: PeerId(body.read('t', _peerCodec)),
        );
      case MessageKind.state:
        final body = WireObject(value, const {'e', 'f'});
        return StateMessage(
          entity: _readEntity(body),
          values: _within('f', () => _decodeFields(body['f'])),
        );
    }
  }

  Map<FieldId, Object?> _decodeFields(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const ProtocolException(
        ProtocolErrorCode.invalidValue,
        'expected an object of field values',
      );
    }
    if (value.isEmpty) {
      throw const ProtocolException(
        ProtocolErrorCode.invalidValue,
        'expected at least one field value',
      );
    }
    return {
      for (final MapEntry(:key, value: fieldValue) in value.entries)
        FieldId(key): _decodeField(key, fieldValue),
    };
  }

  Object? _decodeField(String id, Object? value) {
    if (id.length > maxIdentifierLength) {
      throw const ProtocolException(
        ProtocolErrorCode.limitExceeded,
        'field identifier is longer than $maxIdentifierLength characters',
      );
    }
    final entry = _known(schema.field(FieldId(id)), 'field', id, id);
    return _within(id, () => entry.decode(value));
  }

  static EntityId _readEntity(WireObject body) =>
      EntityId(body.read('e', _entityCodec));

  static int _checkEntity(EntityId entity) {
    if (entity.value < 1 || entity.value > IntCodec.maxSafe) {
      throw ArgumentError.value(
        entity.value,
        'entity',
        'must be from 1 to ${IntCodec.maxSafe}',
      );
    }
    return entity.value;
  }

  static int _checkCounter(int value, String name) {
    if (value < 0 || value > IntCodec.maxSafe) {
      throw ArgumentError.value(
        value,
        name,
        'must be from 0 to ${IntCodec.maxSafe}',
      );
    }
    return value;
  }

  static SchemaEntry<Object?> _registered(
    SchemaEntry<Object?>? entry,
    String kind,
    String id,
  ) {
    if (entry != null) return entry;
    throw ArgumentError.value(id, 'id', 'is not a registered $kind');
  }

  static SchemaEntry<Object?> _known(
    SchemaEntry<Object?>? entry,
    String kind,
    String key,
    String id,
  ) {
    if (entry != null) return entry;
    throw ProtocolException(
      ProtocolErrorCode.unknownIdentifier,
      'unknown $kind "$id"',
      path: [key],
    );
  }
}

T _within<T>(String segment, T Function() decode) {
  try {
    return decode();
  } on ProtocolException catch (error) {
    throw error.within(segment);
  }
}
