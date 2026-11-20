import 'package:maratus/maratus.dart';
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:test/test.dart';

void main() {
  test('RpcMethod defaults to the policies of addRpc', () {
    final rpc = ProtocolSchemaBuilder().addRpc(
      const RpcId('ping'),
      const BoolCodec(),
    );
    const annotation = RpcMethod('ping');

    expect(annotation.id, 'ping');
    expect(annotation.caller, rpc.caller);
    expect(annotation.target, rpc.target);
    expect(annotation.local, rpc.local);
    expect(annotation.deliveryMode, rpc.deliveryMode);
    expect(annotation.channel, rpc.channel);
    expect(annotation.version, isNull);
  });

  test('RpcMethod keeps explicit policies and version', () {
    const annotation = RpcMethod(
      'arena.player.hit',
      caller: RpcCaller.host,
      target: RpcTarget.all,
      local: RpcLocal.include,
      deliveryMode: DeliveryMode.unreliableOrdered,
      channel: 1,
      version: 2,
    );

    expect(annotation.caller, RpcCaller.host);
    expect(annotation.target, RpcTarget.all);
    expect(annotation.local, RpcLocal.include);
    expect(annotation.deliveryMode, DeliveryMode.unreliableOrdered);
    expect(annotation.channel, 1);
    expect(annotation.version, 2);
  });

  test('SyncedField defaults to the mode of a synchronized property', () {
    final field = ProtocolSchemaBuilder().addField(
      const FieldId('arena.player.health'),
      const IntCodec(),
    );
    const annotation = SyncedField('arena.player.health');

    expect(annotation.id, 'arena.player.health');
    expect(annotation.mode, field.property(get: () => 0).mode);
    expect(annotation.deliveryMode, field.deliveryMode);
    expect(annotation.channel, field.channel);
    expect(annotation.writer, field.writer);
    expect(annotation.interpolator, isNull);
    expect(
      annotation.applyInterpolated,
      field.property(get: () => 0).applyInterpolated,
    );
  });

  test('SyncedField keeps its mode, writer, and interpolation', () {
    const annotation = SyncedField(
      'arena.player.speed',
      mode: SyncMode.always,
      deliveryMode: DeliveryMode.unreliable,
      channel: 2,
      writer: FieldWriter.owner,
      interpolator: DoubleInterpolator(teleportDistance: 50),
      applyInterpolated: false,
    );

    expect(annotation.mode, SyncMode.always);
    expect(annotation.deliveryMode, DeliveryMode.unreliable);
    expect(annotation.channel, 2);
    expect(annotation.writer, FieldWriter.owner);
    expect(
      annotation.interpolator,
      isA<DoubleInterpolator>().having(
        (interpolator) => interpolator.teleportDistance,
        'teleportDistance',
        50,
      ),
    );
    expect(annotation.applyInterpolated, isFalse);
  });

  test('Prediction defaults to the delivery of addInput', () {
    final input = ProtocolSchemaBuilder().addInput(
      const InputId('arena.player.move'),
      const IntCodec(),
      tick: const Duration(milliseconds: 20),
    );
    const annotation = Prediction(
      'arena.player.move',
      of: 'syncedPosition',
      input: 'direction',
      tick: Duration(milliseconds: 20),
    );

    expect(annotation.id, 'arena.player.move');
    expect(annotation.of, 'syncedPosition');
    expect(annotation.input, 'direction');
    expect(annotation.tick, input.tick);
    expect(annotation.deliveryMode, input.deliveryMode);
    expect(annotation.channel, input.channel);
    expect(annotation.smoothing, isNull);
    expect(annotation.idleInput, isNull);
  });

  test('Prediction keeps its delivery, smoothing, and idle input', () {
    const annotation = Prediction(
      'arena.player.move',
      of: 'syncedPosition',
      input: 'direction',
      tick: Duration(milliseconds: 20),
      deliveryMode: DeliveryMode.unreliableOrdered,
      channel: 1,
      smoothing: Duration(milliseconds: 50),
      idleInput: 0,
    );

    expect(annotation.deliveryMode, DeliveryMode.unreliableOrdered);
    expect(annotation.channel, 1);
    expect(annotation.smoothing, const Duration(milliseconds: 50));
    expect(annotation.idleInput, 0);
  });

  test('Networked leaves unset options to the session defaults', () {
    const plain = Networked();
    const spawned = Networked(
      spawnType: 'arena.player',
      syncInterval: Duration(milliseconds: 100),
      interpolationDelay: Duration(milliseconds: 150),
    );

    expect(plain.spawnType, isNull);
    expect(plain.syncInterval, isNull);
    expect(plain.interpolationDelay, isNull);
    expect(spawned.spawnType, 'arena.player');
    expect(spawned.syncInterval, const Duration(milliseconds: 100));
    expect(spawned.interpolationDelay, const Duration(milliseconds: 150));
  });
}
