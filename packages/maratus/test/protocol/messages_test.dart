import 'package:maratus/src/protocol/identifiers.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:test/test.dart';

void main() {
  test('message kinds keep their wire codes', () {
    expect(
      {for (final kind in MessageKind.values) kind.name: kind.code},
      {
        'hello': 'hello',
        'welcome': 'welcome',
        'synced': 'synced',
        'ready': 'ready',
        'goodbye': 'goodbye',
        'ping': 'ping',
        'pong': 'pong',
        'peerJoined': 'peer_joined',
        'peerReady': 'peer_ready',
        'peerLeft': 'peer_left',
        'spawn': 'spawn',
        'despawn': 'despawn',
        'authority': 'authority',
        'authorityAck': 'authority_ack',
        'rpc': 'rpc',
        'rpcDelivery': 'rpc_delivery',
        'state': 'state',
        'input': 'input',
      },
    );
  });

  test('goodbye reasons keep their wire codes', () {
    expect(
      {for (final reason in GoodbyeReason.values) reason.name: reason.code},
      {
        'kicked': 'kicked',
        'versionMismatch': 'version',
        'schemaMismatch': 'schema',
        'timeout': 'timeout',
        'bootstrapFailed': 'bootstrap',
        'protocolViolation': 'violation',
        'rejected': 'rejected',
        'notAdmitting': 'not_admitting',
      },
    );
  });

  test('departure reasons keep their wire codes', () {
    expect(
      {for (final reason in DepartureReason.values) reason.name: reason.code},
      {
        'left': 'left',
        'kicked': 'kicked',
        'timeout': 'timeout',
        'bootstrapFailed': 'bootstrap',
        'protocolViolation': 'violation',
        'transportError': 'transport',
      },
    );
  });

  test('state messages keep an unmodifiable copy of their values', () {
    final values = {const FieldId('player.health'): 75};
    final message = StateMessage(
      entity: const EntityId(7),
      values: values,
      sampledAt: Duration.zero,
    );
    values[const FieldId('player.health')] = 10;

    expect(message.values, {const FieldId('player.health'): 75});
    expect(
      () => message.values[const FieldId('player.name')] = 'Ada',
      throwsUnsupportedError,
    );
  });

  test('input messages keep an unmodifiable copy of their inputs', () {
    final values = <Object?>[1, 2];
    final message = InputMessage(
      entity: const EntityId(7),
      input: const InputId('player.steer'),
      sequence: 4,
      values: values,
    );
    values[0] = 3;

    expect(message.kind, MessageKind.input);
    expect(message.values, [1, 2]);
    expect(() => message.values.add(3), throwsUnsupportedError);
  });
}
