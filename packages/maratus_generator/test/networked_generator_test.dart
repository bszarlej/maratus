import 'package:test/test.dart';

import 'support/generate.dart';

const _imports = '''
import 'package:maratus/maratus.dart';
import 'package:maratus_annotations/maratus_annotations.dart';
''';

/// Stands in for the Flame bindings, which this pure Dart test cannot load.
const _flame = {
  'maratus_flame|lib/maratus_flame.dart': '''
import 'package:maratus/maratus.dart';

export 'package:maratus/maratus.dart';

mixin NetworkedComponent {
  NetworkEntity get networkEntity;
  MultiplayerSession get multiplayerSession => throw UnimplementedError();
  void bindNetworkMembers(EntityAttachment attachment) {}
}
''',
};

void main() {
  test('writes handles, their registration, and a binding mixin', () async {
    final generation = await generate('''
$_imports
@Networked(spawnType: 'test.avatar')
final class Avatar with _\$Avatar {
  Avatar(@Range(min: 0, max: 3) SpawnContext<int> context);

  @SyncedField('test.avatar.health')
  @Range(min: 0, max: 100)
  int health = 100;

  @RpcMethod('test.avatar.hit', caller: RpcCaller.host, target: RpcTarget.all)
  void hit(@Range(min: 1, max: 100) int damage) => health -= damage;
}
''');

    expect(generation.errors, isEmpty);
    final output = generation.output!;
    expect(output, contains('abstract final class AvatarNet'));
    expect(output, contains('static const spawnType = SpawnType('));
    expect(output, contains('codec: IntCodec(min: 0, max: 3),'));
    expect(output, contains("id: RpcId('test.avatar.hit'),"));
    expect(output, contains('caller: RpcCaller.host,'));
    expect(output, contains('target: RpcTarget.all,'));
    expect(output, isNot(contains('local:')));
    expect(output, contains("id: FieldId('test.avatar.health'),"));
    expect(output, contains('..addSpawnTypeDefinition(spawnType)'));
    expect(output, contains('..addRpcDefinition(hit)'));
    expect(output, contains('..addFieldDefinition(health);'));
    expect(output, contains(r'mixin _$Avatar {'));
    expect(
      output,
      contains('void bindNetworkMembers(EntityAttachment attachment) {'),
    );
    expect(output, contains('self.hit(payload)'));
    expect(output, contains('set: (value) => self.health = value'));
    expect(output, isNot(contains('extension type')));
  });

  test('binds components through their hook and writes RPC senders', () async {
    final generation = await generate('''
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:maratus_flame/maratus_flame.dart';

@Networked()
final class Player with NetworkedComponent, _\$Player {
  Player(this.networkEntity);

  @override
  final NetworkEntity networkEntity;

  @RpcMethod('test.player.whisper', target: RpcTarget.peer)
  void whisper(@MaxLength(120) String text, RpcContext context) {}

  @RpcMethod('test.player.fire', caller: RpcCaller.owner)
  void fire(@Range(min: 0, max: 3) int weapon, {required bool charged}) {}
}
''', assets: _flame);

    expect(generation.errors, isEmpty);
    final output = generation.output!;
    expect(output, contains(r'mixin _$Player on NetworkedComponent {'));
    expect(output, contains('@override'));
    expect(output, contains('super.bindNetworkMembers(attachment);'));
    expect(output, contains('self.whisper(payload, context)'));
    expect(
      output,
      contains('self.fire(payload.weapon, charged: payload.charged)'),
    );
    expect(output, contains(r'extension type PlayerRpc._(Player _$component)'));
    expect(output, contains('bool whisper(String text, {required PeerId to})'));
    expect(output, contains('peer: to'));
    expect(output, contains('bool fire(int weapon, {required bool charged})'));
    expect(output, contains('(weapon: weapon, charged: charged)'));
    expect(output, contains('extension PlayerRpcAccess on Player'));
    expect(output, contains("'test.player.fire@1("));
  });

  test('copies interpolators and synchronizer options', () async {
    final generation = await generate('''
$_imports
@Networked(
  syncInterval: Duration(milliseconds: 100),
  interpolationDelay: Duration(milliseconds: 250),
)
final class Mover with _\$Mover {
  static const _blend = DoubleInterpolator(teleportDistance: 10);

  @SyncedField('test.mover.x', interpolator: _blend, mode: SyncMode.always)
  double x = 0;

  @SyncedField('test.mover.name')
  @MaxLength(8)
  String get name => 'mover';
}
''');

    expect(generation.errors, isEmpty);
    final output = generation.output!;
    expect(output, contains('static const _xInterpolator = Mover._blend;'));
    expect(
      output,
      contains('static const _syncInterval = Duration(milliseconds: 100);'),
    );
    expect(
      output,
      contains(
        'static const _interpolationDelay = Duration(milliseconds: 250);',
      ),
    );
    expect(output, contains('interpolator: MoverNet._xInterpolator'));
    expect(output, contains('mode: SyncMode.always'));
    expect(output, contains('interval: MoverNet._syncInterval'));
    expect(
      output,
      contains('interpolationDelay: MoverNet._interpolationDelay'),
    );
    expect(output, contains('MoverNet.name.property(get: () => self.name)'));
  });

  group('rejects', () {
    for (final (description, declaration, message) in [
      (
        'classes that do not mix in their binding mixin',
        '''
@Networked()
final class Avatar {
  @RpcMethod('test.avatar.jump') void jump() {}
}''',
        r'does not mix in _$Avatar',
      ),
      (
        'classes with nothing to generate',
        '@Networked() final class Avatar {}',
        'declares nothing to generate',
      ),
      (
        'invalid identifiers',
        '''
@Networked()
final class Avatar with _\$Avatar {
  @RpcMethod('Test.Jump') void jump() {}
}''',
        '"Test.Jump" is not a valid RPC identifier',
      ),
      (
        'duplicate RPC identifiers',
        '''
@Networked()
final class Avatar with _\$Avatar {
  @RpcMethod('test.avatar.act') void jump() {}
  @RpcMethod('test.avatar.act') void duck() {}
}''',
        'declares the RPC "test.avatar.act" more than once',
      ),
      (
        'optional parameters',
        '''
@Networked()
final class Avatar with _\$Avatar {
  @RpcMethod('test.avatar.jump') void jump([int height = 1]) {}
}''',
        'Parameter height of Avatar.jump is optional',
      ),
      (
        'several call contexts',
        '''
@Networked()
final class Avatar with _\$Avatar {
  @RpcMethod('test.avatar.jump')
  void jump(RpcContext first, RpcContext second) {}
}''',
        'takes more than one RpcContext',
      ),
      (
        'handlers that return a value',
        '''
@Networked()
final class Avatar with _\$Avatar {
  @RpcMethod('test.avatar.jump') int jump() => 1;
}''',
        'nothing comes back from an RPC',
      ),
      (
        'versions of single-parameter payloads',
        '''
@Networked()
final class Avatar with _\$Avatar {
  @RpcMethod('test.avatar.jump', version: 2) void jump(int height) {}
}''',
        'the version of @RpcMethod does not apply',
      ),
      (
        'parameters that cannot name record fields',
        '''
@Networked()
final class Avatar with _\$Avatar {
  @RpcMethod('test.avatar.move') void move(int _x, int y) {}
}''',
        'cannot name a field of the record',
      ),
      (
        'peer parameters called to',
        '''
@Networked()
final class Avatar with _\$Avatar {
  @RpcMethod('test.avatar.say', target: RpcTarget.peer)
  void say(String to) {}
}''',
        'no other parameter can be called `to`',
      ),
      (
        'spawn types without a spawn context',
        "@Networked(spawnType: 'test.avatar') final class Avatar {}",
        'needs exactly one constructor parameter of type SpawnContext',
      ),
      (
        'synchronizer options without synchronized fields',
        '''
@Networked(spawnType: 'test.avatar', syncInterval: Duration(seconds: 1))
final class Avatar {
  Avatar(SpawnContext<int> context);
}''',
        'apply only to classes with @SyncedField members',
      ),
      (
        'interpolators of another type',
        '''
@Networked()
final class Avatar with _\$Avatar {
  @SyncedField('test.avatar.x', interpolator: DoubleInterpolator())
  int x = 0;
}''',
        'blends double, but the member is int',
      ),
      (
        'static members',
        '''
@Networked()
final class Avatar with _\$Avatar {
  @SyncedField('test.avatar.count') static int count = 0;
}''',
        '@SyncedField applies only to instance members',
      ),
      (
        'members that the handles would collide with',
        '''
@Networked()
final class Avatar with _\$Avatar {
  @RpcMethod('test.avatar.register') void register() {}
}''',
        'cannot have a handle called register',
      ),
      (
        'generic classes',
        '''
@Networked()
final class Avatar<T> with _\$Avatar {
  @RpcMethod('test.avatar.jump') void jump() {}
}''',
        'does not support generic classes',
      ),
    ]) {
      test(description, () => expectError('$_imports\n$declaration', message));
    }
  });
}
