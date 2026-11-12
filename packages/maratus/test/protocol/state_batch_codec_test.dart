import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:maratus/src/protocol/state_batch_codec.dart';
import 'package:maratus/src/protocol/wire_codec.dart';
import 'package:test/test.dart';

void main() {
  final builder = ProtocolSchemaBuilder()
    ..addField(const FieldId('position'), const DoubleCodec());
  final protocol = ProtocolCodec(builder.build());
  const batch = StateBatchCodec();

  Uint8List state(int entity, {int generation = 1, int? sequence}) =>
      protocol.encode(
        MessageEnvelope(
          StateMessage(
            entity: EntityId(entity),
            values: {const FieldId('position'): entity + 0.25},
            sampledAt: Duration(microseconds: entity * 1000),
            sequence: sequence,
          ),
          generation: generation,
          revision: entity,
        ),
      );

  Matcher fails(ProtocolErrorCode code) => throwsA(
    isA<ProtocolException>().having((error) => error.code, 'code', code),
  );

  test('shares headers while retaining each complete state envelope', () {
    final messages = [state(1), state(2, sequence: 9), state(3)];
    final packet = batch.encode(messages);
    expect(packet.take(5), [78, 2, 1, 1, 3]);
    expect(
      packet.length,
      lessThan(messages.fold<int>(0, (sum, m) => sum + m.length)),
    );
    final decoded = batch.decode(packet);
    expect(decoded, messages);
    for (var i = 0; i < decoded.length; i++) {
      final envelope = protocol.decode(decoded[i]);
      final message = envelope.message as StateMessage;
      expect(envelope.generation, 1);
      expect(envelope.revision, i + 1);
      expect(message.entity, EntityId(i + 1));
      expect(message.values[const FieldId('position')], i + 1.25);
      expect(message.sampledAt, Duration(microseconds: (i + 1) * 1000));
      expect(message.sequence, i == 1 ? 9 : null);
    }
  });

  test('packets decode independently in any arrival order', () {
    final messages = [
      [
        state(1, generation: IntCodec.maxSafe),
        state(2, generation: IntCodec.maxSafe),
      ],
      [state(128), state(16384)],
    ];
    final packets = messages.map(batch.encode).toList();
    for (var i = packets.length - 1; i >= 0; i--) {
      expect(batch.decode(packets[i]), messages[i]);
    }
  });

  test('a singleton keeps its existing wire representation', () {
    final message = state(1);
    expect(batch.encode([message]), same(message));
    expect(batch.decode(message).single, same(message));
    final control = protocol.encode(const MessageEnvelope(ReadyMessage()));
    expect(batch.decode(control).single, same(control));
  });

  test('encoding rejects empty, mixed-generation, and non-state inputs', () {
    expect(() => batch.encode([]), throwsArgumentError);
    expect(
      () => batch.encode([state(1), state(2, generation: 2)]),
      throwsArgumentError,
    );
    final control = protocol.encode(const MessageEnvelope(ReadyMessage()));
    expect(() => batch.encode([control]), throwsArgumentError);
    expect(() => batch.encode([state(1), control]), throwsArgumentError);
    final packet = batch.encode([state(1), state(2)]);
    expect(() => batch.encode([packet, state(3)]), throwsArgumentError);
  });

  test('every truncated packet and trailing bytes are rejected', () {
    final packet = batch.encode([state(1), state(2)]);
    for (var length = 0; length < packet.length; length++) {
      expect(
        () => batch.decode(Uint8List.sublistView(packet, 0, length)),
        fails(ProtocolErrorCode.malformed),
        reason: 'truncation at $length',
      );
    }
    expect(
      () => batch.decode(Uint8List.fromList([...packet, 0])),
      fails(ProtocolErrorCode.malformed),
    );
  });

  test('unknown format and protocol versions are rejected', () {
    final packet = batch.encode([state(1), state(2)]);
    for (final index in [1, 2]) {
      final unknown = Uint8List.fromList(packet)..[index] = 3;
      expect(
        () => batch.decode(unknown),
        fails(ProtocolErrorCode.unsupportedVersion),
      );
    }
    final oldEnvelope = Uint8List.fromList(state(1))..[1] = 1;
    expect(() => batch.encode([oldEnvelope]), throwsArgumentError);
  });

  test('packet size and collection limits apply before expansion', () {
    final messages = [state(1), state(2)];
    final packet = batch.encode(messages);
    final small = StateBatchCodec(
      limits: WireLimits(maxMessageBytes: packet.length - 1),
    );
    expect(() => small.encode(messages), throwsArgumentError);
    expect(() => small.decode(packet), fails(ProtocolErrorCode.limitExceeded));
    const few = StateBatchCodec(limits: WireLimits(maxCollectionLength: 1));
    expect(() => few.encode(messages), throwsArgumentError);
    expect(() => few.decode(packet), fails(ProtocolErrorCode.limitExceeded));
    const singleSmall = StateBatchCodec(limits: WireLimits(maxMessageBytes: 1));
    expect(() => singleSmall.encode([messages.first]), throwsArgumentError);
    expect(
      () => singleSmall.decode(messages.first),
      fails(ProtocolErrorCode.limitExceeded),
    );
  });

  test('invalid counts, lengths, varints, and nested entries are rejected', () {
    final packet = batch.encode([state(1), state(2)]);
    final invalid = <List<int>>[
      [0],
      [78, 2, 1, 1, 0],
      [78, 2, 1, 1, 1],
      [78, 2, 1, 1, 127],
      [78, 2, 1, 128, 0, ...packet.skip(4)], // Overlong generation.
      [78, 2, 1, 1, 130, 0, ...packet.skip(5)], // Overlong count.
      [...packet.take(5), packet[5] + 128, 0, ...packet.skip(6)],
      [...packet.take(5), 0, ...packet.skip(6)],
      [...packet.take(5), 127, ...packet.skip(6)],
      [...packet.take(6), 129, 0, ...packet.skip(7)], // Overlong revision.
      [78, 2, 1, 255, 255, 255, 255, 255, 255, 255, 127],
      // A nested packet and a full non-state envelope cannot be entry tails.
      [78, 2, 1, 1, 2, packet.length, ...packet, 3, 1, 3, 0],
      [78, 2, 1, 1, 2, 7, 77, 2, 1, 3, 1, 0, 0, 3, 1, 3, 0],
    ];
    for (final bytes in invalid) {
      expect(
        () => batch.decode(Uint8List.fromList(bytes)),
        fails(ProtocolErrorCode.malformed),
        reason: '$bytes',
      );
    }
  });

  test('a malicious advertised count is bounded before allocation', () {
    expect(
      () => batch.decode(Uint8List.fromList([78, 2, 1, 1, 128, 8])),
      fails(ProtocolErrorCode.malformed),
    );
    expect(
      () => batch.decode(Uint8List.fromList([78, 2, 1, 1, 129, 8])),
      fails(ProtocolErrorCode.limitExceeded),
    );
  });
}
