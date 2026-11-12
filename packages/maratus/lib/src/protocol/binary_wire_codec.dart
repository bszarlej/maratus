import 'dart:convert';
import 'dart:typed_data';

import 'protocol_exception.dart';
import 'schema.dart';
import 'value_codec.dart';
import 'wire_codec.dart';

/// Self-contained binary envelopes with schema-derived identifier tables.
///
/// Tables are sorted lexicographically, independently for each identifier kind.
/// Peers must compare schema fingerprints before exchanging application data.
/// Doubles use 32 bits only when the value is preserved exactly, including the
/// sign of zero; other doubles retain their full 64-bit precision.
final class BinaryWireCodec implements WireCodec {
  /// Creates a codec using [schema] and bounded decoding allocations.
  BinaryWireCodec(ProtocolSchema schema, {this.limits = const WireLimits()})
    : _fields = _Table(schema.fieldDefinitions.map((e) => e.id.value)),
      _rpcs = _Table(schema.rpcDefinitions.map((e) => e.id.value)),
      _types = _Table(schema.spawnTypeDefinitions.map((e) => e.id.value));

  /// Limits checked before allocating collections or descending into values.
  final WireLimits limits;
  final _Table _fields;
  final _Table _rpcs;
  final _Table _types;

  // Wire assignments are append-only. Changing existing entries requires a
  // binary format version bump. Body keys are encoded as a presence bit mask.
  static const _kinds = [
    'hello',
    'welcome',
    'synced',
    'ready',
    'goodbye',
    'ping',
    'pong',
    'peer_joined',
    'peer_ready',
    'peer_left',
    'spawn',
    'despawn',
    'authority',
    'authority_ack',
    'rpc',
    'rpc_delivery',
    'state',
  ];
  static const _keys = [
    'e',
    'f',
    't',
    'd',
    'o',
    'a',
    'p',
    'm',
    's',
    'n',
    'c',
    'j',
  ];

  @override
  Uint8List encode(Object? value) {
    try {
      checkWireValue(value, limits);
    } on ProtocolException catch (error) {
      throw ArgumentError(error.message);
    }
    final writer = _Writer()..value(value);
    final bytes = writer.bytes.takeBytes();
    if (bytes.length > limits.maxMessageBytes) {
      throw ArgumentError('Encoded value exceeds message size limit');
    }
    return bytes;
  }

  @override
  Object? decode(Uint8List bytes) {
    if (bytes.length > limits.maxMessageBytes) _limit();
    final reader = _Reader(bytes, limits);
    final value = reader.value(0);
    if (reader.offset != bytes.length) _malformed();
    return value;
  }

  /// Encodes a validated protocol envelope using compact metadata.
  Uint8List encodeEnvelope(Object? value) {
    final envelope = value! as Map<String, Object?>;
    final kind = envelope['k']! as String;
    final body = envelope['b']! as Map<String, Object?>;
    final writer = _Writer();
    writer.bytes.add([77, 2]);
    writer.uint(envelope['v']! as int);
    final kindIndex = _kinds.indexOf(kind);
    if (kindIndex < 0) throw ArgumentError('Unknown message kind: $kind');
    writer.uint(kindIndex);
    writer.uint(envelope['g']! as int);
    writer.uint(envelope['r']! as int);
    var mask = 0;
    for (final key in body.keys) {
      final index = _keys.indexOf(key);
      if (index < 0) throw ArgumentError('Unknown body key: $key');
      mask |= 1 << index;
    }
    writer.uint(mask);
    for (final key in _keys) {
      if (!body.containsKey(key)) continue;
      final item = body[key];
      if (kind == 'state' && key == 'f') {
        final fields = item! as Map<String, Object?>;
        writer.uint(fields.length);
        for (final entry in fields.entries) {
          writer.uint(_fields.number(entry.key));
          writer.value(entry.value);
        }
      } else if (kind == 'spawn' && key == 't') {
        writer.uint(_types.number(item! as String));
      } else if ((kind == 'rpc' || kind == 'rpc_delivery') && key == 'm') {
        writer.uint(_rpcs.number(item! as String));
      } else {
        writer.value(item);
      }
    }
    return writer.bytes.takeBytes();
  }

  /// Decodes compact metadata before protocol validation.
  Object? decodeEnvelope(Uint8List bytes) {
    if (bytes.length > limits.maxMessageBytes) _limit();
    final reader = _Reader(bytes, limits);
    if (reader.byte() != 77) _malformed();
    if (reader.byte() != 2) {
      throw const ProtocolException(
        ProtocolErrorCode.unsupportedVersion,
        'unsupported binary format version',
      );
    }
    final version = reader.uint();
    // Preserve the protocol layer's version-first validation.
    if (version != 1) return <String, Object?>{'v': version};
    final kindIndex = reader.uint();
    if (kindIndex >= _kinds.length) {
      throw const ProtocolException(
        ProtocolErrorCode.unknownKind,
        'unknown binary message kind',
      );
    }
    final kind = _kinds[kindIndex];
    final generation = reader.uint();
    final revision = reader.uint();
    final mask = reader.uint();
    if (mask >= 1 << _keys.length) _malformed();
    final body = <String, Object?>{};
    for (var i = 0; i < _keys.length; i++) {
      if (mask & (1 << i) == 0) continue;
      final key = _keys[i];
      if (kind == 'state' && key == 'f') {
        final count = reader.length();
        final fields = <String, Object?>{};
        for (var j = 0; j < count; j++) {
          final id = _fields.identifier(reader.uint());
          if (fields.containsKey(id)) _malformed();
          fields[id] = reader.value(3);
        }
        body[key] = fields;
      } else if (kind == 'spawn' && key == 't') {
        body[key] = _types.identifier(reader.uint());
      } else if ((kind == 'rpc' || kind == 'rpc_delivery') && key == 'm') {
        body[key] = _rpcs.identifier(reader.uint());
      } else {
        body[key] = reader.value(2);
      }
    }
    if (reader.offset != bytes.length) _malformed();
    return <String, Object?>{
      'v': version,
      'k': kind,
      'g': generation,
      'r': revision,
      'b': body,
    };
  }
}

final class _Table {
  _Table(Iterable<String> ids) : ids = ids.toList()..sort() {
    for (var i = 0; i < this.ids.length; i++) {
      numbers[this.ids[i]] = i;
    }
  }
  final List<String> ids;
  final numbers = <String, int>{};
  int number(String id) =>
      numbers[id] ?? (throw ArgumentError('Unknown ID: $id'));
  String identifier(int number) {
    if (number >= ids.length) {
      throw const ProtocolException(
        ProtocolErrorCode.unknownIdentifier,
        'unknown binary schema identifier',
      );
    }
    return ids[number];
  }
}

final class _Writer {
  final bytes = BytesBuilder(copy: false);
  void uint(int value) {
    if (value < 0 || value > IntCodec.maxSafe) {
      throw ArgumentError.value(value, 'value', 'outside safe integer range');
    }
    while (value >= 128) {
      bytes.addByte(value % 128 + 128);
      value ~/= 128;
    }
    bytes.addByte(value);
  }

  void string(String value) {
    final encoded = utf8.encode(value);
    uint(encoded.length);
    bytes.add(encoded);
  }

  void value(Object? value) {
    switch (value) {
      case null:
        bytes.addByte(0);
      case false:
        bytes.addByte(1);
      case true:
        bytes.addByte(2);
      case num():
        if (!value.isFinite) throw ArgumentError('Non-finite number');
        // JavaScript does not distinguish integral doubles from integers.
        // Canonicalize them on every platform, preserving negative zero.
        if (!(value == 0 && value.isNegative) &&
            value >= -IntCodec.maxSafe &&
            value <= IntCodec.maxSafe &&
            value == value.truncateToDouble()) {
          final integer = value.toInt();
          bytes.addByte(integer < 0 ? 4 : 3);
          uint(integer < 0 ? -(integer + 1) : integer);
        } else {
          if (value is int &&
              value is! double &&
              (value < -IntCodec.maxSafe || value > IntCodec.maxSafe)) {
            throw ArgumentError.value(
              value,
              'value',
              'outside safe integer range',
            );
          }
          final number = value.toDouble();
          final data = ByteData(8)..setFloat32(0, number, Endian.little);
          final rounded = data.getFloat32(0, Endian.little);
          if (rounded == number && rounded.isNegative == number.isNegative) {
            bytes.addByte(9);
            bytes.add(data.buffer.asUint8List(0, 4));
          } else {
            bytes.addByte(5);
            data.setFloat64(0, number, Endian.little);
            bytes.add(data.buffer.asUint8List());
          }
        }
      case String():
        bytes.addByte(6);
        string(value);
      case List<Object?>():
        bytes.addByte(7);
        uint(value.length);
        for (final item in value) {
          this.value(item);
        }
      case Map<String, Object?>():
        bytes.addByte(8);
        uint(value.length);
        for (final entry in value.entries) {
          string(entry.key);
          this.value(entry.value);
        }
      default:
        throw ArgumentError('Unsupported wire value');
    }
  }
}

final class _Reader {
  _Reader(this.bytes, this.limits);
  final Uint8List bytes;
  final WireLimits limits;
  int offset = 0;
  int byte() {
    if (offset == bytes.length) _malformed();
    return bytes[offset++];
  }

  int uint() {
    var result = 0;
    var factor = 1;
    for (var i = 0; i < 8; i++) {
      final next = byte();
      final digit = next % 128;
      if (digit > (IntCodec.maxSafe - result) ~/ factor) _malformed();
      result += digit * factor;
      if (next < 128) {
        if (i > 0 && digit == 0) _malformed();
        return result;
      }
      factor *= 128;
    }
    _malformed();
  }

  int length() {
    final count = uint();
    if (count > limits.maxCollectionLength) _limit();
    if (count > bytes.length - offset) _malformed();
    return count;
  }

  String string() {
    final count = uint();
    if (count > bytes.length - offset) _malformed();
    final start = offset;
    offset += count;
    try {
      return utf8.decode(Uint8List.sublistView(bytes, start, offset));
    } on FormatException {
      _malformed();
    }
  }

  Object? value(int depth) {
    final tag = byte();
    switch (tag) {
      case 0:
        return null;
      case 1:
        return false;
      case 2:
        return true;
      case 3:
        return uint();
      case 4:
        final magnitude = uint();
        if (magnitude == IntCodec.maxSafe) _malformed();
        return -magnitude - 1;
      case 5:
        if (bytes.length - offset < 8) _malformed();
        final result = ByteData.sublistView(
          bytes,
          offset,
          offset + 8,
        ).getFloat64(0, Endian.little);
        offset += 8;
        if (!result.isFinite) _malformed();
        return result;
      case 6:
        return string();
      case 7:
        if (depth >= limits.maxDepth) _limit();
        final count = length();
        return [for (var i = 0; i < count; i++) value(depth + 1)];
      case 8:
        if (depth >= limits.maxDepth) _limit();
        final count = length();
        final result = <String, Object?>{};
        for (var i = 0; i < count; i++) {
          final key = string();
          if (result.containsKey(key)) _malformed();
          result[key] = value(depth + 1);
        }
        return result;
      case 9:
        if (bytes.length - offset < 4) _malformed();
        final result = ByteData.sublistView(
          bytes,
          offset,
          offset + 4,
        ).getFloat32(0, Endian.little);
        offset += 4;
        if (!result.isFinite) _malformed();
        return result;
      default:
        _malformed();
    }
  }
}

Never _malformed() => throw const ProtocolException(
  ProtocolErrorCode.malformed,
  'invalid binary encoding',
);
Never _limit() => throw const ProtocolException(
  ProtocolErrorCode.limitExceeded,
  'binary decoding limit exceeded',
);
