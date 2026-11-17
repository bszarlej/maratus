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
  void updateNetworkMembers(double dt) {}
}
''',
};

/// A class whose static step `walk` predicts its synchronized member [x]
/// from its member [steering], with any other [members].
///
/// The other arguments replace parts of the prediction, and an empty [x] or
/// [steering] leaves that member out.
String _predicting({
  String id = 'test.avatar.walk',
  String of = 'x',
  String input = 'steering',
  String tick = 'Duration(milliseconds: 20)',
  String options = '',
  String step = 'static double walk(double x, int direction) => x + direction;',
  String x = "@SyncedField('test.avatar.x') double x = 0;",
  String steering = 'int steering = 0;',
  String members = '',
}) =>
    '''
@Networked()
final class Avatar with _\$Avatar {
  $x
  $steering
  $members

  @Prediction(
    '$id',
    of: '$of',
    input: '$input',
    tick: $tick,
    $options
  )
  $step
}''';

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
    expect(output, isNot(contains('deliveryMode:')));
    expect(output, isNot(contains('channel:')));
    expect(output, isNot(contains('writer:')));
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

  test(
    'preserves delivery modes and channels with a prefixed import',
    () async {
      final generation = await generate('''
import 'package:maratus/maratus.dart' as m;
import 'package:maratus_annotations/maratus_annotations.dart';

@Networked()
final class Mover with _\$Mover {
  @RpcMethod(
    'test.mover.steer',
    deliveryMode: m.DeliveryMode.unreliableOrdered,
    channel: 1,
  )
  void steer(double direction) {}

  @SyncedField(
    'test.mover.x',
    mode: m.SyncMode.always,
    deliveryMode: m.DeliveryMode.unreliable,
    channel: 2,
  )
  double x = 0;

  @SyncedField('test.mover.health', channel: 3)
  int health = 100;

  @SyncedField('test.mover.input', writer: m.FieldWriter.owner)
  int input = 0;
}
''');

      expect(generation.errors, isEmpty);
      final output = generation.output!;
      expect(
        output,
        contains('deliveryMode: m.DeliveryMode.unreliableOrdered,'),
      );
      expect(output, contains('channel: 1,'));
      expect(output, contains('deliveryMode: m.DeliveryMode.unreliable,'));
      expect(output, contains('channel: 2,'));
      expect(output, contains('channel: 3,'));
      expect(output, contains('mode: m.SyncMode.always'));
      expect(output, contains('writer: m.FieldWriter.owner,'));
      expect('writer:'.allMatches(output), hasLength(1));
    },
  );

  test('writes the input stream of a prediction and binds it first', () async {
    final generation = await generate('''
$_imports
@Networked()
final class Mover with _\$Mover {
  @SyncedField('test.mover.health')
  int health = 100;

  @SyncedField(
    'test.mover.x',
    interpolator: DoubleInterpolator(),
    mode: SyncMode.always,
    deliveryMode: DeliveryMode.unreliable,
  )
  double x = 0;

  int steering = 0;

  @Prediction(
    'test.mover.walk',
    of: 'x',
    input: 'steering',
    tick: Duration(milliseconds: 20),
  )
  static double walk(double x, @Range(min: -1, max: 1) int direction) =>
      x + direction;
}
''');

    expect(generation.errors, isEmpty);
    final output = generation.output!;
    expect(output, contains('static const walk = InputStream('));
    expect(output, contains("id: InputId('test.mover.walk'),"));
    expect(output, contains('codec: IntCodec(min: -1, max: 1),'));
    expect(output, contains('tick: Duration(milliseconds: 20),'));
    expect(output, contains('..addInputDefinition(walk);'));
    expect(output, contains('Predictor<double, int>? get networkPredictor'));
    final predict = output.indexOf('final prediction = attachment.predict(');
    expect(predict, isNonNegative);
    expect(predict, lessThan(output.indexOf('attachment.synchronize(')));
    expect(output, contains('state: MoverNet.x'));
    expect(output, contains('input: MoverNet.walk'));
    expect(output, contains('initial: self.x'));
    expect(output, contains('step: Mover.walk'));
    expect(output, contains('interpolator: MoverNet._xInterpolator'));
    expect(output, isNot(contains('smoothing:')));
    expect(output, isNot(contains('idleInput:')));
    // The prediction's property replaces the member's.
    expect(output, contains('prediction.property(mode: SyncMode.always)'));
    expect(output, isNot(contains('MoverNet.x.property(')));
    expect(output, contains('MoverNet.health.property('));
    // Each frame runs the prediction and presents its state.
    expect(output, contains('void updateNetworkMembers(Duration elapsed) {'));
    expect(
      output,
      contains('self.x = prediction.update(self.steering, elapsed);'),
    );
  });

  test('runs the prediction of a component in its frame hook', () async {
    final generation = await generate('''
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:maratus_flame/maratus_flame.dart';

@Networked()
final class Player with NetworkedComponent, _\$Player {
  Player(this.networkEntity);

  @override
  final NetworkEntity networkEntity;

  @SyncedField('test.player.x')
  double get x => 0;

  int get steering => 1;

  @Prediction(
    'test.player.run',
    of: 'x',
    input: 'steering',
    tick: Duration(milliseconds: 50),
  )
  static double run(double x, int direction) => x + direction;
}
''', assets: _flame);

    expect(generation.errors, isEmpty);
    final output = generation.output!;
    expect(output, contains('void updateNetworkMembers(double dt) {'));
    expect(output, contains('super.updateNetworkMembers(dt);'));
    expect(output, contains('(dt * Duration.microsecondsPerSecond).round()'));
    // Without a setter, the member keeps its value, and the prediction
    // still advances on the owner.
    expect(output, contains('    prediction.update(self.steering, elapsed);'));
    expect(output, isNot(contains('self.x =')));
  });

  test('copies the delivery and options of a prediction', () async {
    final generation = await generate('''
import 'package:maratus/maratus.dart' as m;
import 'package:maratus_annotations/maratus_annotations.dart';

@Networked()
final class Mover with _\$Mover {
  static const _tick = Duration(milliseconds: 20);

  @SyncedField('test.mover.x')
  double get x => 0;

  int steering = 0;

  @Prediction(
    'test.mover.walk',
    of: 'x',
    input: 'steering',
    tick: _tick,
    deliveryMode: m.DeliveryMode.unreliableOrdered,
    channel: 1,
    smoothing: Duration(milliseconds: 50),
    idleInput: 0,
  )
  static double walk(double x, int direction) => x + direction;
}
''');

    expect(generation.errors, isEmpty);
    final output = generation.output!;
    expect(output, contains('static const walk = m.InputStream('));
    expect(output, contains('codec: m.IntCodec(),'));
    expect(output, contains('tick: Mover._tick,'));
    expect(output, contains('deliveryMode: m.DeliveryMode.unreliableOrdered,'));
    expect(output, contains('channel: 1,'));
    expect(
      output,
      contains('static const _walkSmoothing = Duration(milliseconds: 50);'),
    );
    expect(output, contains('static const _walkIdleInput = 0;'));
    expect(output, contains('smoothing: MoverNet._walkSmoothing'));
    expect(output, contains('idleInput: MoverNet._walkIdleInput'));
    expect(output, isNot(contains('interpolator:')));
    expect(output, contains('m.Predictor<double, int>? get networkPredictor'));
    expect(output, contains('synchronize([prediction.property()])'));
  });

  group('rejects', () {
    for (final mode in ['unreliable', 'unreliableOrdered']) {
      for (final syncMode in ['', 'mode: SyncMode.onChange,']) {
        test(
          '$mode with ${syncMode.isEmpty ? 'default mode' : 'SyncMode.onChange'}',
          () => expectError('''
$_imports
@Networked()
final class Avatar with _\$Avatar {
  @SyncedField(
    'test.avatar.x',
    deliveryMode: DeliveryMode.$mode,
    $syncMode
  )
  double x = 0;
}''', 'requires SyncMode.always'),
        );
      }
    }
    for (final (description, declaration, message) in [
      (
        'negative RPC channels',
        '''
@Networked()
final class Avatar with _\$Avatar {
  @RpcMethod('test.avatar.jump', channel: -1) void jump() {}
}''',
        'channel must be nonnegative',
      ),
      (
        'negative field channels',
        '''
@Networked()
final class Avatar with _\$Avatar {
  @SyncedField('test.avatar.x', channel: -1) double x = 0;
}''',
        'channel must be nonnegative',
      ),
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
      (
        'prediction steps that are not static',
        _predicting(
          step: 'double walk(double x, int direction) => x + direction;',
        ),
        '@Prediction applies only to static methods, unlike Avatar.walk',
      ),
      (
        'prediction steps that return another type than the state',
        _predicting(step: 'static int walk(double x, int direction) => 0;'),
        'Avatar.walk returns int, but its state Avatar.x is double',
      ),
      (
        'prediction steps that take another type than the state',
        _predicting(step: 'static double walk(num x, int direction) => 0;'),
        'Parameter x of Avatar.walk is num, but its state Avatar.x is double',
      ),
      (
        'prediction steps without exactly a state and an input',
        _predicting(
          step: 'static double walk(double x, [int direction = 0]) => x;',
        ),
        'Avatar.walk must take the state and one input',
      ),
      (
        'prediction states that are not synchronized',
        _predicting(members: 'double y = 0;', of: 'y'),
        'is y, which is not a @SyncedField member of Avatar',
      ),
      (
        'predictions without synchronized members',
        _predicting(x: ''),
        'is x, which is not a @SyncedField member of Avatar',
      ),
      (
        'prediction states that the owner writes',
        _predicting(
          x:
              "@SyncedField('test.avatar.x', writer: FieldWriter.owner) "
              'double x = 0;',
        ),
        "which the entity's owner writes",
      ),
      (
        'codec annotations on the state of a prediction',
        _predicting(
          step: 'static double walk(@Range(min: 0) double x, int d) => x;',
        ),
        'the state takes its codec from Avatar.x',
      ),
      (
        'prediction inputs that are not members',
        _predicting(input: 'aim'),
        'The input of the prediction Avatar.walk is aim, which is not an '
            'instance field or getter of Avatar',
      ),
      (
        'prediction inputs that are static',
        _predicting(steering: 'static int steering = 0;'),
        'is steering, which is not an instance field or getter of Avatar',
      ),
      (
        'prediction inputs of another type',
        _predicting(steering: "String steering = '';"),
        'Avatar.steering, the input of the prediction Avatar.walk, is String, '
            'but Avatar.walk takes int',
      ),
      (
        'codec annotations on the input of a prediction',
        _predicting(steering: '@Range(min: -1, max: 1) int steering = 0;'),
        'the inputs of Avatar.walk take their codec from parameter direction',
      ),
      (
        'several predictions',
        _predicting(
          members: '''
@SyncedField('test.avatar.y') double y = 0;

  @Prediction(
    'test.avatar.climb',
    of: 'y',
    input: 'steering',
    tick: Duration(milliseconds: 20),
  )
  static double climb(double y, int direction) => y + direction;''',
        ),
        'an entity has at most one prediction',
      ),
      (
        'invalid input stream identifiers',
        _predicting(id: 'Walk'),
        '"Walk" is not a valid input stream identifier',
      ),
      (
        'ticks that are not positive',
        _predicting(tick: 'Duration.zero'),
        'The tick of the prediction Avatar.walk must be positive',
      ),
      (
        'negative input channels',
        _predicting(options: 'channel: -1,'),
        'channel must be nonnegative',
      ),
      (
        'negative smoothing',
        _predicting(options: 'smoothing: Duration(milliseconds: -1),'),
        'The smoothing of the prediction Avatar.walk must not be negative',
      ),
      (
        'idle inputs of another type',
        _predicting(options: "idleInput: 'stop',"),
        'The idle input of the prediction Avatar.walk is String, but its '
            'inputs are int',
      ),
    ]) {
      test(description, () => expectError('$_imports\n$declaration', message));
    }
  });
}
