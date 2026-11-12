import 'dart:typed_data';

import 'protocol_exception.dart';
import 'value_codec.dart';
import 'wire_codec.dart';

/// Frames state envelopes in one independently decodable binary packet.
///
/// A batch shares its format, protocol version, message kind, and generation.
/// Each length-delimited entry retains its own revision and complete body.
/// The caller must validate every reconstructed envelope before dispatching
/// any of them; this codec validates framing, not field values or the schema.
final class StateBatchCodec {
  /// Creates a batch codec bounded by [limits].
  const StateBatchCodec({this.limits = const WireLimits()});

  /// Bounds the packet size and number of entries in a batch.
  final WireLimits limits;

  /// Packs already validated binary state [messages] sharing a generation.
  ///
  /// A single envelope keeps its original representation. Throws an
  /// [ArgumentError] for invalid input or a packet exceeding [limits].
  Uint8List encode(List<Uint8List> messages) {
    try {
      if (messages.isEmpty) _malformed();
      if (messages.length > 1 && messages.length > limits.maxCollectionLength) {
        _limit();
      }
      final first = _state(messages.first);
      if (messages.length == 1) return messages.single;
      final writer = _BatchWriter()
        ..bytes.add([78, 2, 1])
        ..uint(first.generation)
        ..uint(messages.length);
      for (var i = 0; i < messages.length; i++) {
        final entry = i == 0 ? first : _state(messages[i]);
        if (entry.generation != first.generation) _malformed();
        writer.uint(entry.tail.length);
        if (writer.bytes.length + entry.tail.length > limits.maxMessageBytes) {
          _limit();
        }
        writer.bytes.add(entry.tail);
      }
      return writer.bytes.takeBytes();
    } on ProtocolException catch (error) {
      throw ArgumentError('Cannot batch state messages: ${error.message}');
    }
  }

  /// Expands a packet into ordinary binary envelopes in their original order.
  ///
  /// A normal single envelope is returned unchanged for protocol validation.
  /// Throws a [ProtocolException] for invalid framing or exceeded [limits].
  List<Uint8List> decode(Uint8List packet) {
    if (packet.length > limits.maxMessageBytes) _limit();
    final reader = _BatchReader(packet);
    final marker = reader.byte();
    if (marker == 77) return [packet];
    if (marker != 78) _malformed();
    _versions(reader);
    final generation = reader.uint();
    final count = reader.uint();
    if (count < 2) _malformed();
    if (count > limits.maxCollectionLength) _limit();
    // Every entry needs a length, a revision, and a body mask. Check before
    // allocating the result, even when the advertised count is very large.
    if (count > (packet.length - reader.offset) ~/ 3) _malformed();
    final prefix = _BatchWriter()
      ..bytes.add([77, 2, 1, 16])
      ..uint(generation);
    final header = prefix.bytes.takeBytes();
    final messages = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final length = reader.uint();
      if (length > packet.length - reader.offset) _malformed();
      if (header.length + length > limits.maxMessageBytes) _limit();
      final tail = Uint8List.sublistView(
        packet,
        reader.offset,
        reader.offset + length,
      );
      _checkTail(tail);
      reader.offset += length;
      final message = Uint8List(header.length + length)
        ..setRange(0, header.length, header)
        ..setRange(header.length, header.length + length, tail);
      messages.add(message);
    }
    if (reader.offset != packet.length) _malformed();
    return messages;
  }

  ({int generation, Uint8List tail}) _state(Uint8List message) {
    if (message.length > limits.maxMessageBytes) _limit();
    final reader = _BatchReader(message);
    if (reader.byte() != 77) _malformed();
    _versions(reader);
    if (reader.uint() != 16) _malformed();
    final generation = reader.uint();
    final tail = Uint8List.sublistView(message, reader.offset);
    _checkTail(tail);
    return (generation: generation, tail: tail);
  }
}

void _versions(_BatchReader reader) {
  if (reader.byte() != 2 || reader.uint() != 1) {
    throw const ProtocolException(
      ProtocolErrorCode.unsupportedVersion,
      'unsupported state batch format or protocol version',
    );
  }
}

void _checkTail(Uint8List tail) {
  final reader = _BatchReader(tail)..uint();
  final mask = reader.uint();
  // State requires the entity and fields, and permits a sample time and
  // sequence. Framed envelopes or nested batches cannot serve as entries.
  if (mask != 3 && mask != 7 && mask != 515 && mask != 519) _malformed();
  if (reader.offset == tail.length) _malformed();
}

final class _BatchWriter {
  final bytes = BytesBuilder(copy: false);

  void uint(int value) {
    while (value >= 128) {
      bytes.addByte(value % 128 + 128);
      value ~/= 128;
    }
    bytes.addByte(value);
  }
}

final class _BatchReader {
  _BatchReader(this.bytes);

  final Uint8List bytes;
  var offset = 0;

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
}

Never _malformed() => throw const ProtocolException(
  ProtocolErrorCode.malformed,
  'invalid state batch encoding',
);

Never _limit() => throw const ProtocolException(
  ProtocolErrorCode.limitExceeded,
  'state batch exceeds configured limits',
);
