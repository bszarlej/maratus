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
    expect(annotation.version, isNull);
  });

  test('RpcMethod keeps explicit policies and version', () {
    const annotation = RpcMethod(
      'arena.player.hit',
      caller: RpcCaller.host,
      target: RpcTarget.all,
      local: RpcLocal.include,
      version: 2,
    );

    expect(annotation.caller, RpcCaller.host);
    expect(annotation.target, RpcTarget.all);
    expect(annotation.local, RpcLocal.include);
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
    expect(annotation.interpolator, isNull);
  });

  test('SyncedField keeps its mode and interpolator', () {
    const annotation = SyncedField(
      'arena.player.speed',
      mode: SyncMode.always,
      interpolator: DoubleInterpolator(teleportDistance: 50),
    );

    expect(annotation.mode, SyncMode.always);
    expect(
      annotation.interpolator,
      isA<DoubleInterpolator>().having(
        (interpolator) => interpolator.teleportDistance,
        'teleportDistance',
        50,
      ),
    );
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
