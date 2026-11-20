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
    deliveryMode: DeliveryMode.unreliableOrdered,
    channel: 1,
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
  ..addField(
    const FieldId('test.avatar.input'),
    const MoveInputCodec(),
    deliveryMode: DeliveryMode.unreliable,
    channel: 2,
  )
  ..addField(
    const FieldId('test.avatar.label'),
    const StringCodec(maxLength: 40),
  )
  ..addField(
    const FieldId('test.avatar.altitude'),
    const DoubleCodec(min: 0, max: 100),
    deliveryMode: DeliveryMode.unreliable,
    channel: 1,
  )
  ..addInput(
    const InputId('test.avatar.fly'),
    const BoolCodec(),
    tick: const Duration(milliseconds: 20),
    deliveryMode: DeliveryMode.unreliableOrdered,
    channel: 2,
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
    expect(schema.inputDefinition(AvatarNet.fly.id), same(AvatarNet.fly));
    expect(AvatarNet.fly.tick, const Duration(milliseconds: 20));
    expect(AvatarNet.fly.deliveryMode, DeliveryMode.unreliableOrdered);
    expect(AvatarNet.fly.channel, 2);
    expect(AvatarNet.steer.caller, RpcCaller.owner);
    expect(AvatarNet.steer.deliveryMode, DeliveryMode.unreliableOrdered);
    expect(AvatarNet.steer.channel, 1);
    expect(AvatarNet.input.deliveryMode, DeliveryMode.unreliable);
    expect(AvatarNet.input.channel, 2);
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
      final network = InMemoryNetwork(
        clock: clock,
        deliveryModes: DeliveryMode.values.toSet(),
        channelCount: 3,
      );
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
        [AvatarNet.x, AvatarNet.input, AvatarNet.altitude, AvatarNet.label],
      );
    });

    test('write interpolated values to the annotated fields', () {
      host.avatar.x = 42;
      final shown = <double>[];
      for (var i = 0; i < 8; i++) {
        run(1);
        final presented = client.avatar.networkSynchronizer!.interpolated(
          AvatarNet.x,
        )!;
        expect(client.avatar.x, presented.value, reason: 'frame $i');
        shown.add(client.avatar.x);
      }

      expect(shown, orderedEquals([...shown]..sort()));
      expect(shown.where((x) => x > 0 && x < 42), isNotEmpty);
      expect(shown.last, 42);
      expect(host.avatar.x, 42);
    });

    group('prediction', () {
      late Predictor<double, bool> owned;
      late Predictor<double, bool> hosted;

      /// Runs [count] frames of one tick each, as a game loop does: every
      /// peer updates its avatar's members, except the owner while it
      /// [stalls], which then sends no inputs.
      void frames(int count, {bool stalls = false}) {
        const tick = Duration(milliseconds: 20);
        for (var i = 0; i < count; i++) {
          clock.advance(tick);
          host.session.update();
          client.session.update();
          host.avatar.updateNetworkMembers(tick);
          if (!stalls) client.avatar.updateNetworkMembers(tick);
          host.session.captureState();
          client.session.captureState();
        }
      }

      setUp(() {
        owned = client.avatar.networkPredictor!;
        hosted = host.avatar.networkPredictor!;
      });

      test('is configured by the annotations', () {
        expect(owned.field, same(AvatarNet.altitude));
        expect(owned.input, same(AvatarNet.fly));
        expect(owned.interpolator, isA<DoubleInterpolator>());
        expect(owned.smoothing, const Duration(milliseconds: 40));
        expect(owned.state, 0);
        expect(
          client.avatar.networkSynchronizer!.properties
              .singleWhere((property) => property.field == AvatarNet.altitude)
              .interpolator,
          same(owned.interpolator),
        );
      });

      test("shows the owner's input at once and converges with the host", () {
        client.avatar.thrusting = true;
        frames(1);

        expect(owned.state, 1);
        expect(owned.pendingInputs, 1);
        expect(hosted.state, 0);

        frames(4);
        expect(owned.state, 5);
        // Without new inputs, the host catches up with the owner's.
        frames(8, stalls: true);

        expect(hosted.state, 5);
        expect(owned.state, 5);
        expect(owned.pendingInputs, 0);
        expect(
          client.avatar.networkSynchronizer!
              .snapshot(AvatarNet.altitude)
              ?.value,
          5,
        );
      });

      test('writes the state to present to the member every frame', () {
        client.avatar.thrusting = true;
        for (var i = 0; i < 6; i++) {
          frames(1);

          expect(client.avatar.altitude, owned.presented);
          expect(host.avatar.altitude, hosted.presented);
        }
        expect(owned.state, 6);

        // Letting go, the owner predicts that the avatar sinks.
        client.avatar.thrusting = false;
        frames(3);
        expect(owned.state, 3);
        expect(client.avatar.altitude, owned.presented);
      });

      test("applies the idle input while the owner's inputs are late", () {
        client.avatar.thrusting = true;
        frames(5);
        frames(8, stalls: true);
        expect(hosted.state, 5);

        // The host waits a quarter of a second for the owner's inputs, then
        // lets the avatar sink one unit for each tick.
        frames(15, stalls: true);

        expect(hosted.state, lessThan(5));
        expect(host.avatar.altitude, hosted.state);
        expect(owned.state, hosted.state);
      });
    });

    test(
      'release the synchronizer and prediction when the entity despawns',
      () {
        final avatar = client.avatar;
        expect(avatar.networkSynchronizer, isNotNull);
        expect(avatar.networkPredictor, isNotNull);

        host.session.despawn(host.entity);
        run();

        expect(client.avatars, isEmpty);
        expect(avatar.networkSynchronizer, isNull);
        expect(avatar.networkPredictor, isNull);
      },
    );
  });
}
