import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

import 'avatar.dart';
import 'inputs.dart';

/// A hand-written codec with the descriptor of the generated payload codec
/// of [AvatarNet.say].
final class _SayPayloadCodec extends ValueCodec<({String text, int volume})> {
  const _SayPayloadCodec();

  static const _text = StringCodec(maxLength: 64);
  static const _volume = IntCodec(min: 0, max: 10);

  @override
  String get descriptor =>
      'test.avatar.say@2(${_text.descriptor},${_volume.descriptor})';

  @override
  Object? encode(({String text, int volume}) value) => [
    _text.encode(value.text),
    _volume.encode(value.volume),
  ];

  @override
  ({String text, int volume}) decode(Object? wire) {
    final list = WireList(wire, 2);
    return (text: list.read(0, _text), volume: list.read(1, _volume));
  }
}

/// A hand-written codec with the descriptor of the generated payload codec
/// of [AvatarNet.jump].
final class _JumpPayloadCodec extends ValueCodec<()> {
  const _JumpPayloadCodec();

  @override
  String get descriptor => 'test.avatar.jump@1()';

  @override
  Object? encode(() value) => const <Object?>[];

  @override
  () decode(Object? wire) {
    WireList(wire, 0);
    return ();
  }
}

/// Registers by hand what the annotations of [Avatar] declare.
void _registerByHand(ProtocolSchemaBuilder builder) => builder
  ..addSpawnType(
    const SpawnTypeId('test.avatar'),
    const StringCodec(maxLength: 32),
  )
  ..addRpc(
    const RpcId('test.avatar.steer'),
    const IntCodec(min: -1, max: 1),
    caller: RpcCaller.owner,
  )
  ..addRpc(
    const RpcId('test.avatar.say'),
    const _SayPayloadCodec(),
    target: RpcTarget.all,
    local: RpcLocal.include,
  )
  ..addRpc(const RpcId('test.avatar.jump'), const _JumpPayloadCodec())
  ..addField(
    const FieldId('test.avatar.x'),
    const DoubleCodec(min: -100, max: 100),
  )
  ..addField(const FieldId('test.avatar.input'), const MoveInputCodec())
  ..addField(
    const FieldId('test.avatar.label'),
    const StringCodec(maxLength: 40),
  );

ProtocolSchema _schema(Iterable<void Function(ProtocolSchemaBuilder)> steps) {
  final builder = ProtocolSchemaBuilder();
  for (final step in steps) {
    step(builder);
  }
  return builder.build();
}

/// A session that creates an [Avatar] for each spawned avatar entity and
/// binds its annotated members.
final class _Peer {
  _Peer(this.session) {
    session.bindSpawn(
      AvatarNet.spawnType,
      onSpawn: (context) {
        final avatar = Avatar(context);
        avatars[context.entity] = avatar;
        avatar.bindNetworkMembers(
          session.attachEntity(
            context.entity,
            isReady: () => true,
            isValid: () => identical(avatars[context.entity], avatar),
          ),
        );
      },
      onDespawn: avatars.remove,
    );
  }

  final MultiplayerSession session;
  final avatars = <NetworkEntity, Avatar>{};

  NetworkEntity get entity => avatars.keys.single;
  Avatar get avatar => avatars.values.single;
}

void main() {
  test('generated registration has the hand-written fingerprint', () {
    expect(
      _schema([AvatarNet.register]).fingerprint,
      _schema([_registerByHand]).fingerprint,
    );
  });

  test('the schema retains the generated const handles', () {
    final schema = _schema([AvatarNet.register]);

    expect(
      schema.spawnTypeDefinition(AvatarNet.spawnType.id),
      same(AvatarNet.spawnType),
    );
    expect(schema.rpcDefinition(AvatarNet.steer.id), same(AvatarNet.steer));
    expect(schema.rpcDefinition(AvatarNet.say.id), same(AvatarNet.say));
    expect(schema.rpcDefinition(AvatarNet.jump.id), same(AvatarNet.jump));
    expect(schema.fieldDefinition(AvatarNet.x.id), same(AvatarNet.x));
    expect(schema.fieldDefinition(AvatarNet.label.id), same(AvatarNet.label));
    expect(AvatarNet.steer.caller, RpcCaller.owner);
    expect(AvatarNet.say.target, RpcTarget.all);
    expect(AvatarNet.say.local, RpcLocal.include);
    expect(AvatarNet.jump.caller, RpcCaller.anyPeer);
  });

  test('generated and hand-written registrations mix in one schema', () {
    void chat(ProtocolSchemaBuilder builder) => builder.addRpc(
      const RpcId('test.chat'),
      const StringCodec(maxLength: 240),
      target: RpcTarget.all,
    );

    expect(
      _schema([AvatarNet.register, chat]).fingerprint,
      _schema([_registerByHand, chat]).fingerprint,
    );
    expect(
      () => _schema([AvatarNet.register, _registerByHand]),
      throwsArgumentError,
    );
  });

  test('payloads of several or no parameters travel as lists', () {
    final say = AvatarNet.say.codec;
    final jump = AvatarNet.jump.codec;

    expect(say.encode((text: 'hi', volume: 3)), ['hi', 3]);
    expect(say.decode(['hi', 3]), (text: 'hi', volume: 3));
    expect(jump.encode(()), isEmpty);
    expect(jump.decode(<Object?>[]), ());
    for (final (codec, wire, path) in [
      (say, ['hi'], <String>[]),
      (say, ['hi', 11], ['1']),
      (say, [3, 'hi'], ['0']),
      (jump, [1], <String>[]),
      (jump, null, <String>[]),
    ]) {
      expect(
        () => codec.decode(wire),
        throwsA(
          isA<ProtocolException>()
              .having(
                (error) => error.code,
                'code',
                ProtocolErrorCode.invalidValue,
              )
              .having((error) => error.path, 'path', path),
        ),
        reason: '$wire',
      );
    }
  });

  group('generated bindings', () {
    late ManualClock clock;
    late _Peer host;
    late _Peer client;

    void run([int frames = 8]) {
      for (var i = 0; i < frames; i++) {
        clock.advance(const Duration(milliseconds: 10));
        host.session.update();
        client.session.update();
        host.session.captureState();
        client.session.captureState();
      }
    }

    setUp(() {
      clock = ManualClock();
      final network = InMemoryNetwork(clock: clock);
      final schema = _schema([AvatarNet.register]);
      host = _Peer(MultiplayerSession(schema: schema, clock: clock));
      client = _Peer(MultiplayerSession(schema: schema, clock: clock));
      host.session.host(network.host());
      client.session.join(network.connect());
      addTearDown(client.session.close);
      addTearDown(host.session.close);
      run();
      expect(client.session.state, SessionState.ready);
      host.session.spawn(
        AvatarNet.spawnType,
        'Ada',
        owner: client.session.localPeer!,
      );
      run();
    });

    test('construct spawned objects from their spawn data', () {
      expect(host.avatar.name, 'Ada');
      expect(client.avatar.name, 'Ada');
      expect(client.entity.owner, client.session.localPeer);
    });

    test('route calls to the annotated handlers', () {
      final clientPeer = client.session.localPeer!;

      expect(client.session.callRpc(client.entity, AvatarNet.steer, 1), isTrue);
      expect(client.session.callRpc(client.entity, AvatarNet.jump, ()), isTrue);
      expect(
        host.session.callRpc(host.entity, AvatarNet.say, (
          text: 'hi',
          volume: 3,
        )),
        isTrue,
      );
      run();

      expect(host.avatar.direction, 1);
      expect(client.avatar.direction, 0);
      expect(host.avatar.jumps, [clientPeer]);
      expect(host.avatar.messages, [(PeerId.host, 'hi', 3)]);
      expect(client.avatar.messages, [(PeerId.host, 'hi', 3)]);
    });

    test('enforce the caller policy of the annotation', () {
      host.session.callRpc(host.entity, AvatarNet.steer, -1);
      run();

      expect(host.avatar.direction, 0);
    });

    test('synchronize the annotated fields from the authority', () {
      host.avatar
        ..x = 42
        ..input = const MoveInput(1, -1);
      run();

      expect(client.avatar.x, 42);
      expect(client.avatar.input.x, 1);
      expect(client.avatar.input.y, -1);
      expect(client.avatar.networkSynchronizer, isNotNull);
      expect(
        client.avatar.networkSynchronizer!.properties.map(
          (property) => property.field,
        ),
        [AvatarNet.x, AvatarNet.input, AvatarNet.label],
      );
    });

    test('release the synchronizer when the entity despawns', () {
      final avatar = client.avatar;
      expect(avatar.networkSynchronizer, isNotNull);

      host.session.despawn(host.entity);
      run();

      expect(client.avatars, isEmpty);
      expect(avatar.networkSynchronizer, isNull);
    });
  });
}
