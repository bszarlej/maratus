import 'dart:math';
import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/binary_wire_codec.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:maratus/src/protocol/wire_codec.dart';
import 'package:test/test.dart';

void main() {
  ProtocolSchema schema({bool reverse = false}) {
    final builder = ProtocolSchemaBuilder();
    final ids = ['player.position.x', 'player.position.y'];
    for (final id in reverse ? ids.reversed : ids) {
      builder.addField(FieldId(id), const DoubleCodec());
      builder.addRpc(RpcId(id), const IntCodec());
      builder.addSpawnType(SpawnTypeId(id), const IntCodec());
      builder.addInput(
        InputId(id),
        const IntCodec(),
        tick: const Duration(milliseconds: 20),
      );
    }
    return builder.build();
  }

  test('schema order and packet arrival order do not affect decoding', () {
    final sender = ProtocolCodec(schema());
    final receiver = ProtocolCodec(schema(reverse: true));
    expect(sender.schema.fingerprint, receiver.schema.fingerprint);
    final messages = <MessageEnvelope>[
      for (var i = 1; i <= 3; i++)
        MessageEnvelope(
          StateMessage(
            entity: const EntityId(1),
            values: {
              const FieldId('player.position.x'): (i + 0.25),
              const FieldId('player.position.y'): -(i + 0.25),
            },
          ),
          generation: 1,
          revision: i,
        ),
      const MessageEnvelope(
        RpcMessage(
          entity: EntityId(1),
          rpc: RpcId('player.position.y'),
          payload: 42,
        ),
      ),
      const MessageEnvelope(
        SpawnMessage(
          entity: EntityId(2),
          type: SpawnTypeId('player.position.y'),
          data: 17,
          owner: PeerId(1),
          authority: PeerId(1),
        ),
      ),
      MessageEnvelope(
        InputMessage(
          entity: const EntityId(1),
          input: const InputId('player.position.y'),
          sequence: 300,
          values: const [-1, 0, 1],
        ),
        generation: 1,
      ),
      MessageEnvelope(
        StateMessage(
          entity: const EntityId(1),
          values: const {FieldId('player.position.y'): 0.5},
          sampledAt: const Duration(milliseconds: 20),
          inputSequence: 302,
        ),
        generation: 1,
        revision: 4,
      ),
    ];
    for (final message in messages.reversed) {
      final bytes = sender.encode(message);
      expect(receiver.encode(receiver.decode(bytes)), bytes);
    }
    final json = ProtocolCodec(schema(), wire: const JsonWireCodec());
    final binaryBytes = sender.encode(messages.first).length;
    final jsonBytes = json.encode(messages.first).length;
    expect(binaryBytes, 22);
    expect(sender.encode(messages.first), [
      77,
      2,
      1,
      16,
      1,
      1,
      3,
      3,
      1,
      2,
      0,
      9,
      0,
      0,
      160,
      63,
      1,
      9,
      0,
      0,
      160,
      191,
    ]);
    expect(jsonBytes, 100);
  });

  final codec = BinaryWireCodec(schema());
  Map<String, Object?> envelope(Object? payload) => {
    'v': 1,
    'k': 'hello',
    'g': 0,
    'r': 0,
    'b': <String, Object?>{'f': 'fingerprint', 'j': payload},
  };

  test('all wire values and safe integer boundaries round-trip', () {
    final value = envelope([
      null,
      false,
      true,
      0,
      127,
      128,
      -1,
      -128,
      -129,
      IntCodec.maxSafe,
      -IntCodec.maxSafe,
      0.5,
      1e100,
      -1e100,
      -0.0,
      'Zażółć 🕷',
      <Object?>[],
      <String, Object?>{},
      {
        'nested': [true, 1.25],
      },
    ]);
    expect(codec.decode(codec.encode(value)), value);
  });

  test('uses float32 only when every bit of the value is preserved', () {
    final cases = <double, List<int>>{
      1.5: [9, 0, 0, 192, 63],
      -1.5: [9, 0, 0, 192, 191],
      1.401298464324817e-45: [9, 1, 0, 0, 0], // Smallest subnormal.
      1.1754943508222875e-38: [9, 0, 0, 128, 0], // Smallest normal.
      3.4028234663852886e38: [9, 255, 255, 127, 127], // Largest finite.
      9007199254740992.0: [9, 0, 0, 0, 90], // Beyond safe integer range.
      0.1: [5, 154, 153, 153, 153, 153, 153, 185, 63],
      1.0000000000000002: [5, 1, 0, 0, 0, 0, 0, 240, 63],
    };
    for (final entry in cases.entries) {
      expect(codec.encode(entry.key), entry.value, reason: '${entry.key}');
      expect(codec.decode(Uint8List.fromList(entry.value)), entry.key);
    }
    // Underflow and overflow must fall back to float64, without rounding.
    for (final value in [1e-50, -1e-50, 1e100, -1e100]) {
      final bytes = codec.encode(value);
      expect(bytes.first, 5);
      expect(bytes.length, 9);
      expect(codec.decode(bytes), value);
    }
    expect(codec.encode(0.0), [3, 0]);
    expect(codec.encode(1.0), [3, 1]);
    expect(codec.encode(-1.0), [4, 0]);
    expect(codec.encode(-0.0), [9, 0, 0, 0, 128]);
    expect((codec.decode(codec.encode(-0.0))! as num).isNegative, isTrue);
  });

  test(
    'rejects unknown identifiers, tags, overflowing and overlong varints',
    () {
      for (final bytes in <List<int>>[
        [77, 1],
        [77, 2, 1, 99],
        [77, 2, 129, 0],
        [77, 2, ...List.filled(8, 255)],
        [77, 2, 1, 0, 0, 0, 2, 99],
        [77, 2, 1, 16, 0, 0, 2, 1, 99, 0],
        [77, 2, 1, 16, 0, 0, 2, 2, 0, 0, 0, 0],
        // An input stream number that the schema does not assign.
        [77, 2, 1, 17, 0, 0, 128, 1, 99],
        // A message kind and a body key beyond the assigned ones.
        [77, 2, 1, 18, 0, 0, 0],
        [77, 2, 1, 16, 0, 0, 128, 64],
      ]) {
        expect(
          () => codec.decodeEnvelope(Uint8List.fromList(bytes)),
          throwsA(isA<ProtocolException>()),
        );
      }
    },
  );

  test('rejects incompatible binary formats before reading an envelope', () {
    for (final version in [1, 3]) {
      expect(
        () => codec.decodeEnvelope(Uint8List.fromList([77, version])),
        throwsA(
          isA<ProtocolException>().having(
            (error) => error.code,
            'code',
            ProtocolErrorCode.unsupportedVersion,
          ),
        ),
      );
    }
  });

  test('rejects malformed scalar values and duplicate object keys', () {
    for (final bytes in <List<int>>[
      [6, 1, 255], // Invalid UTF-8.
      [6, 127], // Truncated string.
      [5, 0, 0, 0, 0, 0, 0, 240, 127], // Infinity.
      [5, 0, 0, 0, 0, 0, 0, 248, 127], // NaN.
      [9, 0, 0, 128, 127], // Float32 infinity.
      [9, 0, 0, 128, 255], // Float32 negative infinity.
      [9, 0, 0, 192, 127], // Float32 NaN.
      [9, 0, 0, 0], // Truncated float32.
      [8, 2, 1, 97, 0, 1, 97, 0], // Duplicate key.
      [7, 127], // Truncated collection.
      [99], // Unknown tag.
    ]) {
      expect(
        () => codec.decode(Uint8List.fromList(bytes)),
        throwsA(isA<ProtocolException>()),
      );
    }
    expect((codec.decode(codec.encode(-0.0))! as num).isNegative, isTrue);
    expect(codec.encode(1.0), codec.encode(1));
    expect(() => codec.encode(double.infinity), throwsArgumentError);
  });

  test('enforces size, nesting and collection limits during parsing', () {
    final payload = codec.encode(
      envelope([
        [1, 2, 3],
      ]),
    );
    for (final limits in [
      const WireLimits(maxMessageBytes: 8),
      const WireLimits(maxDepth: 3),
      const WireLimits(maxCollectionLength: 2),
    ]) {
      expect(
        () => BinaryWireCodec(schema(), limits: limits).decode(payload),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ProtocolErrorCode.limitExceeded,
          ),
        ),
      );
    }
  });

  test('random untrusted bytes only produce protocol errors', () {
    final random = Random(42);
    final protocol = ProtocolCodec(schema());
    for (var i = 0; i < 3000; i++) {
      final bytes = Uint8List.fromList([
        if (i.isEven) ...[77, 2, 1],
        for (var j = 0; j < random.nextInt(100); j++) random.nextInt(256),
      ]);
      try {
        protocol.decode(bytes);
      } on ProtocolException {
        continue;
      }
    }
  });
}
