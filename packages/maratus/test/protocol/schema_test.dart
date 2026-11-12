import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

import 'protocol_test_utils.dart';

/// The canonical description of the test schema that its fingerprint
/// digests.
const _canonicalTestSchema =
    '{"format":5,'
    '"spawnTypes":[["player","string(maxLength=16)"]],'
    '"rpcs":[["player.move","test.move_input@1","any","host","exclude",'
    '"reliable",0]],'
    '"fields":[["player.health","int(min=0,max=100)","reliable",0],'
    '["player.name","string(maxLength=16)","reliable",0]],'
    '"staticEntities":[],"joinRequest":null}';

/// The SHA-256 digest of [_canonicalTestSchema], computed independently.
const _testSchemaFingerprint =
    'b1c06ff7101f63487ad8ff3a1d8733e5e021cf4deae0ada45d00da9cedd8dbe0';

void main() {
  group('ProtocolSchemaBuilder', () {
    test('registers spawn types, RPCs, and fields', () {
      final schema = buildTestSchema();

      expect(
        schema.spawnType(const SpawnTypeId('player'))?.codec.descriptor,
        'string(maxLength=16)',
      );
      expect(
        schema.rpc(const RpcId('player.move'))?.codec,
        isA<MoveInputCodec>(),
      );
      expect(
        schema.field(const FieldId('player.health'))?.codec.descriptor,
        'int(min=0,max=100)',
      );
    });

    test('returns null for unregistered identifiers', () {
      final schema = buildTestSchema();

      expect(schema.spawnType(const SpawnTypeId('monster')), isNull);
      expect(schema.spawnTypeDefinition(const SpawnTypeId('monster')), isNull);
      expect(schema.rpc(const RpcId('player.fly')), isNull);
      expect(schema.rpcDefinition(const RpcId('player.fly')), isNull);
      expect(schema.field(const FieldId('player.mana')), isNull);
      expect(schema.joinRequest, isNull);
    });

    test('registers a typed join request codec', () {
      const codec = StringCodec(maxLength: 16);
      final schema = (ProtocolSchemaBuilder()..setJoinRequest(codec)).build();
      final entry = schema.joinRequest!;

      expect(entry.codec, same(codec));
      expect(entry.encode('Ada'), 'Ada');
      expect(entry.decode('Ada'), 'Ada');
      expect(() => entry.encode(7), throwsArgumentError);
      expect(
        () => entry.decode(7),
        throwsProtocolException(ProtocolErrorCode.invalidValue),
      );
    });

    test('rejects a second join request codec without replacing the first', () {
      const original = StringCodec(maxLength: 16);
      final builder = ProtocolSchemaBuilder()..setJoinRequest(original);
      final schema = builder.build();

      expect(() => builder.setJoinRequest(const BoolCodec()), throwsStateError);
      expect(builder.build().joinRequest, same(schema.joinRequest));
      expect(builder.build().joinRequest!.codec, same(original));
      expect(builder.build().fingerprint, schema.fingerprint);
    });

    test('adding a join request codec leaves an earlier schema unchanged', () {
      final builder = ProtocolSchemaBuilder();
      final before = builder.build();
      final fingerprint = before.fingerprint;

      builder.setJoinRequest(const BoolCodec());

      expect(before.joinRequest, isNull);
      expect(before.fingerprint, fingerprint);
      expect(builder.build().joinRequest!.codec, isA<BoolCodec>());
      expect(builder.build().fingerprint, isNot(fingerprint));
    });

    test('returns a typed handle with default policies', () {
      final builder = ProtocolSchemaBuilder();
      final Rpc<int> rpc = builder.addRpc(
        const RpcId('ping'),
        const IntCodec(),
      );
      final schema = builder.build();

      expect(rpc.id, const RpcId('ping'));
      expect(rpc.codec, isA<IntCodec>());
      expect(rpc.caller, RpcCaller.anyPeer);
      expect(rpc.target, RpcTarget.host);
      expect(rpc.local, RpcLocal.exclude);
      expect(rpc.deliveryMode, DeliveryMode.reliable);
      expect(rpc.channel, 0);
      expect(schema.rpcDefinition(rpc.id), same(rpc));
      expect(schema.rpc(rpc.id)?.codec, same(rpc.codec));
    });

    test('retains the registered handle and its explicit policies', () {
      final builder = ProtocolSchemaBuilder();
      final rpc = builder.addRpc(
        const RpcId('player.input'),
        const MoveInputCodec(),
        caller: RpcCaller.owner,
        target: RpcTarget.authority,
        local: RpcLocal.include,
        deliveryMode: DeliveryMode.unreliableOrdered,
        channel: 2,
      );
      final schema = builder.build();

      expect(rpc.caller, RpcCaller.owner);
      expect(rpc.target, RpcTarget.authority);
      expect(rpc.local, RpcLocal.include);
      expect(rpc.deliveryMode, DeliveryMode.unreliableOrdered);
      expect(rpc.channel, 2);
      expect(schema.rpcDefinition(rpc.id), same(rpc));
      expect(builder.build().rpcDefinition(rpc.id), same(rpc));
    });

    test('retains the typed spawn type handle it returns', () {
      final builder = ProtocolSchemaBuilder();
      final SpawnType<String> player = builder.addSpawnType(
        const SpawnTypeId('player'),
        const StringCodec(maxLength: 16),
      );
      final schema = builder.build();

      expect(player.id, const SpawnTypeId('player'));
      expect(player.codec, isA<StringCodec>());
      expect(schema.spawnTypeDefinition(player.id), same(player));
      expect(schema.spawnType(player.id)?.codec, same(player.codec));
      expect(
        () => builder.addSpawnType(
          const SpawnTypeId('player'),
          const BoolCodec(),
        ),
        throwsArgumentError,
      );
      expect(builder.build().spawnTypeDefinition(player.id), same(player));
    });

    test('retains the typed field handle it returns', () {
      final builder = ProtocolSchemaBuilder();
      final SyncField<int> health = builder.addField(
        const FieldId('player.health'),
        const IntCodec(min: 0, max: 100),
      );
      final schema = builder.build();

      expect(health.id, const FieldId('player.health'));
      expect(health.codec, isA<IntCodec>());
      expect(health.deliveryMode, DeliveryMode.reliable);
      expect(health.channel, 0);
      expect(health.writer, FieldWriter.authority);
      expect(schema.fieldDefinition(health.id), same(health));
      expect(schema.field(health.id)?.codec, same(health.codec));
      expect(schema.fieldDefinition(const FieldId('player.mana')), isNull);
      expect(
        () =>
            builder.addField(const FieldId('player.health'), const BoolCodec()),
        throwsArgumentError,
      );
      expect(builder.build().fieldDefinition(health.id), same(health));
    });

    test('registers and retains existing handles', () {
      const player = SpawnType(
        id: SpawnTypeId('player'),
        codec: StringCodec(maxLength: 16),
      );
      const move = Rpc(id: RpcId('player.move'), codec: MoveInputCodec());
      const health = SyncField(
        id: FieldId('player.health'),
        codec: IntCodec(min: 0, max: 100),
      );
      const name = SyncField(
        id: FieldId('player.name'),
        codec: StringCodec(maxLength: 16),
      );
      final builder = ProtocolSchemaBuilder();

      expect(builder.addSpawnTypeDefinition(player), same(player));
      expect(builder.addRpcDefinition(move), same(move));
      expect(builder.addFieldDefinition(health), same(health));
      expect(builder.addFieldDefinition(name), same(name));
      final schema = builder.build();

      expect(schema.spawnTypeDefinition(player.id), same(player));
      expect(schema.spawnType(player.id)?.codec, same(player.codec));
      expect(schema.rpcDefinition(move.id), same(move));
      expect(schema.rpc(move.id)?.codec, same(move.codec));
      expect(schema.fieldDefinition(health.id), same(health));
      expect(schema.field(health.id)?.codec, same(health.codec));
      expect(schema.fingerprint, buildTestSchema().fingerprint);
    });

    test('retains field delivery settings and lists registered handles', () {
      final builder = ProtocolSchemaBuilder();
      final field = builder.addField(
        const FieldId('player.x'),
        const DoubleCodec(),
        deliveryMode: DeliveryMode.unreliable,
        channel: 3,
      );
      final rpc = builder.addRpc(const RpcId('ping'), const BoolCodec());
      final schema = builder.build();
      builder.addField(const FieldId('player.y'), const DoubleCodec());
      builder.addRpc(const RpcId('pong'), const BoolCodec());

      expect(field.deliveryMode, DeliveryMode.unreliable);
      expect(field.channel, 3);
      expect(schema.fieldDefinition(field.id), same(field));
      expect(schema.fieldDefinitions, [field]);
      expect(schema.rpcDefinitions, [rpc]);
      expect(
        schema.fingerprint,
        (ProtocolSchemaBuilder()
              ..addRpcDefinition(rpc)
              ..addFieldDefinition(
                const SyncField(
                  id: FieldId('player.x'),
                  codec: DoubleCodec(),
                  deliveryMode: DeliveryMode.unreliable,
                  channel: 3,
                ),
              ))
            .build()
            .fingerprint,
      );
    });

    test('retains the writer of a field', () {
      final builder = ProtocolSchemaBuilder();
      final input = builder.addField(
        const FieldId('player.input'),
        const IntCodec(min: -1, max: 1),
        writer: FieldWriter.owner,
      );
      const aim = SyncField(
        id: FieldId('player.aim'),
        codec: DoubleCodec(),
        writer: FieldWriter.owner,
      );
      builder.addFieldDefinition(aim);
      final schema = builder.build();

      expect(input.writer, FieldWriter.owner);
      expect(schema.fieldDefinition(input.id), same(input));
      expect(schema.fieldDefinition(aim.id)!.writer, FieldWriter.owner);
      expect(
        schema.fingerprint,
        (ProtocolSchemaBuilder()
              ..addFieldDefinition(
                const SyncField(
                  id: FieldId('player.input'),
                  codec: IntCodec(min: -1, max: 1),
                  writer: FieldWriter.owner,
                ),
              )
              ..addField(
                const FieldId('player.aim'),
                const DoubleCodec(),
                writer: FieldWriter.owner,
              ))
            .build()
            .fingerprint,
      );
    });

    test('rejects negative channels without retaining any registration', () {
      final builder = ProtocolSchemaBuilder();
      final original = builder.build().fingerprint;
      for (final register in <void Function()>[
        () =>
            builder.addRpc(const RpcId('ping'), const BoolCodec(), channel: -1),
        () => builder.addRpcDefinition(
          const Rpc(id: RpcId('ping'), codec: BoolCodec(), channel: -1),
        ),
        () => builder.addField(
          const FieldId('health'),
          const IntCodec(),
          channel: -1,
        ),
        () => builder.addFieldDefinition(
          const SyncField(
            id: FieldId('health'),
            codec: IntCodec(),
            channel: -1,
          ),
        ),
      ]) {
        expect(register, throwsArgumentError);
        expect(builder.build().rpcDefinitions, isEmpty);
        expect(builder.build().fieldDefinitions, isEmpty);
        expect(builder.build().fingerprint, original);
      }
      expect(
        () => builder.addRpc(const RpcId('ping'), const BoolCodec()),
        returnsNormally,
      );
      expect(
        () => builder.addField(const FieldId('health'), const IntCodec()),
        returnsNormally,
      );
    });

    test('fingerprints a registered RPC handle with its policies', () {
      final byArguments = ProtocolSchemaBuilder()
        ..addRpc(
          const RpcId('hit'),
          const IntCodec(min: 1, max: 100),
          caller: RpcCaller.host,
          target: RpcTarget.all,
          local: RpcLocal.include,
          deliveryMode: DeliveryMode.unreliableOrdered,
          channel: 4,
        );
      final byHandle = ProtocolSchemaBuilder()
        ..addRpcDefinition(
          const Rpc(
            id: RpcId('hit'),
            codec: IntCodec(min: 1, max: 100),
            caller: RpcCaller.host,
            target: RpcTarget.all,
            local: RpcLocal.include,
            deliveryMode: DeliveryMode.unreliableOrdered,
            channel: 4,
          ),
        );
      final withDefaults = ProtocolSchemaBuilder()
        ..addRpcDefinition(
          const Rpc(id: RpcId('hit'), codec: IntCodec(min: 1, max: 100)),
        );

      expect(byHandle.build().fingerprint, byArguments.build().fingerprint);
      expect(
        withDefaults.build().fingerprint,
        isNot(byArguments.build().fingerprint),
      );
    });

    test(
      'rejects existing handles with duplicate or malformed identifiers',
      () {
        final builder = ProtocolSchemaBuilder();
        final ping = builder.addRpc(const RpcId('ping'), const BoolCodec());
        final player = builder.addSpawnType(
          const SpawnTypeId('player'),
          const BoolCodec(),
        );
        final health = builder.addField(
          const FieldId('player.health'),
          const BoolCodec(),
        );
        final fingerprint = builder.build().fingerprint;

        expect(
          () => builder.addRpcDefinition(
            const Rpc(id: RpcId('ping'), codec: IntCodec()),
          ),
          throwsArgumentError,
        );
        expect(
          () => builder.addSpawnTypeDefinition(
            const SpawnType(id: SpawnTypeId('player'), codec: IntCodec()),
          ),
          throwsArgumentError,
        );
        expect(
          () => builder.addFieldDefinition(
            const SyncField(id: FieldId('player.health'), codec: IntCodec()),
          ),
          throwsArgumentError,
        );
        expect(
          () => builder.addRpcDefinition(
            const Rpc(id: RpcId('Bad.ID'), codec: BoolCodec()),
          ),
          throwsArgumentError,
        );
        expect(
          () => builder.addSpawnTypeDefinition(
            const SpawnType(id: SpawnTypeId(''), codec: BoolCodec()),
          ),
          throwsArgumentError,
        );
        expect(
          () => builder.addFieldDefinition(
            const SyncField(id: FieldId('player.'), codec: BoolCodec()),
          ),
          throwsArgumentError,
        );

        final schema = builder.build();
        expect(schema.rpcDefinition(ping.id), same(ping));
        expect(schema.spawnTypeDefinition(player.id), same(player));
        expect(schema.fieldDefinition(health.id), same(health));
        expect(schema.rpcDefinition(const RpcId('Bad.ID')), isNull);
        expect(schema.spawnTypeDefinition(const SpawnTypeId('')), isNull);
        expect(schema.fieldDefinition(const FieldId('player.')), isNull);
        expect(schema.fingerprint, fingerprint);
      },
    );

    test('lists static entities in identifier order', () {
      final builder = ProtocolSchemaBuilder();
      final level = builder.addStaticEntity(const StaticEntityId('level'));
      final board = builder.addStaticEntity(const StaticEntityId('board'));
      final schema = builder.build();

      expect(level.id, const StaticEntityId('level'));
      expect(schema.staticEntities, [board, level]);
      expect(schema.staticEntityDefinition(board.id), same(board));
      expect(schema.staticEntityDefinition(level.id), same(level));
      expect(
        schema.staticEntityDefinition(const StaticEntityId('lobby')),
        isNull,
      );
      expect(() => schema.staticEntities.add(board), throwsUnsupportedError);

      final lobby = builder.addStaticEntity(const StaticEntityId('lobby'));
      expect(schema.staticEntities, [board, level]);
      expect(builder.build().staticEntities, [board, level, lobby]);
    });

    test('rejects duplicate and malformed static entity identifiers', () {
      final builder = ProtocolSchemaBuilder();
      final board = builder.addStaticEntity(const StaticEntityId('board'));

      for (final id in ['board', 'Board', 'board.', '']) {
        expect(
          () => builder.addStaticEntity(StaticEntityId(id)),
          throwsArgumentError,
          reason: id,
        );
      }
      expect(builder.build().staticEntities, [board]);
    });

    test('keeps a separate namespace for each kind of registration', () {
      final builder = ProtocolSchemaBuilder()
        ..addRpc(const RpcId('ping'), const BoolCodec())
        ..addField(const FieldId('ping'), const IntCodec());
      final ping = builder.addStaticEntity(const StaticEntityId('ping'));
      final schema = builder.build();

      expect(schema.rpc(const RpcId('ping'))?.codec, isA<BoolCodec>());
      expect(schema.field(const FieldId('ping'))?.codec, isA<IntCodec>());
      expect(schema.spawnType(const SpawnTypeId('ping')), isNull);
      expect(schema.staticEntityDefinition(ping.id), same(ping));
    });

    test('rejects duplicate identifiers', () {
      final builder = ProtocolSchemaBuilder();
      final original = builder.addRpc(const RpcId('ping'), const BoolCodec());

      expect(
        () => builder.addRpc(const RpcId('ping'), const IntCodec()),
        throwsArgumentError,
      );
      expect(builder.build().rpcDefinition(original.id), same(original));
      expect(builder.build().rpc(original.id)?.codec, same(original.codec));
    });

    test('does not retain RPC definitions with malformed identifiers', () {
      final builder = ProtocolSchemaBuilder();
      final empty = builder.build().fingerprint;

      expect(
        () => builder.addRpc(const RpcId('Bad.ID'), const BoolCodec()),
        throwsArgumentError,
      );
      expect(builder.build().rpcDefinition(const RpcId('Bad.ID')), isNull);
      expect(builder.build().fingerprint, empty);
    });

    test('accepts explicit dot-separated identifiers', () {
      for (final id in [
        'player',
        'player.move',
        'arena_v2.score_board',
        'a' * 64,
      ]) {
        expect(
          () => ProtocolSchemaBuilder().addSpawnType(
            SpawnTypeId(id),
            const BoolCodec(),
          ),
          returnsNormally,
          reason: id,
        );
      }
    });

    test('rejects malformed identifiers', () {
      for (final id in [
        '',
        'Player',
        '1player',
        'player.',
        '.player',
        'player..move',
        'player-move',
        'player move',
        'player.2d',
        'a' * 65,
      ]) {
        expect(
          () => ProtocolSchemaBuilder().addSpawnType(
            SpawnTypeId(id),
            const BoolCodec(),
          ),
          throwsArgumentError,
          reason: id,
        );
      }
    });

    test('builds schemas that later registrations do not change', () {
      final builder = ProtocolSchemaBuilder();
      final first = builder.addRpc(const RpcId('first'), const BoolCodec());
      final schema = builder.build();
      final second = builder.addRpc(const RpcId('second'), const BoolCodec());

      expect(schema.rpc(const RpcId('second')), isNull);
      expect(schema.rpcDefinition(second.id), isNull);
      expect(schema.rpcDefinition(first.id), same(first));
      expect(builder.build().rpcDefinition(second.id), same(second));
      expect(schema.fingerprint, isNot(builder.build().fingerprint));
    });
  });

  group('fingerprint', () {
    String fingerprintOf(
      Iterable<void Function(ProtocolSchemaBuilder builder)> registrations,
    ) {
      final builder = ProtocolSchemaBuilder();
      for (final register in registrations) {
        register(builder);
      }
      return builder.build().fingerprint;
    }

    test('matches the recorded fixture', () {
      expect(buildTestSchema().fingerprint, _testSchemaFingerprint);
      expect(
        sha256.convert(utf8.encode(_canonicalTestSchema)).toString(),
        _testSchemaFingerprint,
      );
    });

    test('does not depend on registration order', () {
      final registrations = <void Function(ProtocolSchemaBuilder builder)>[
        (b) => b.setJoinRequest(const StringCodec(maxLength: 32)),
        (b) => b.addSpawnType(
          const SpawnTypeId('player'),
          const StringCodec(maxLength: 16),
        ),
        (b) => b.addSpawnType(const SpawnTypeId('bullet'), const DoubleCodec()),
        (b) => b.addRpc(
          const RpcId('player.move'),
          const MoveInputCodec(),
          caller: RpcCaller.owner,
          target: RpcTarget.authority,
          local: RpcLocal.include,
        ),
        (b) => b.addRpc(
          const RpcId('player.fire'),
          const BoolCodec(),
          caller: RpcCaller.host,
          target: RpcTarget.all,
        ),
        (b) => b.addField(
          const FieldId('player.health'),
          const IntCodec(min: 0, max: 100),
        ),
        (b) => b.addField(
          const FieldId('player.name'),
          const StringCodec(maxLength: 16),
        ),
        (b) => b.addStaticEntity(const StaticEntityId('board')),
        (b) => b.addStaticEntity(const StaticEntityId('level')),
      ];
      final expected = fingerprintOf(registrations);
      final random = Random(1);

      expect(fingerprintOf(registrations.reversed), expected);
      for (var i = 0; i < 20; i++) {
        expect(
          fingerprintOf(registrations.toList()..shuffle(random)),
          expected,
        );
      }
    });

    test('changes when an identifier, codec, or registration kind changes', () {
      final base = fingerprintOf([
        (b) => b.addRpc(const RpcId('ping'), const IntCodec()),
      ]);
      final variants = {
        'empty schema': fingerprintOf([]),
        'renamed RPC': fingerprintOf([
          (b) => b.addRpc(const RpcId('pong'), const IntCodec()),
        ]),
        'changed codec range': fingerprintOf([
          (b) => b.addRpc(const RpcId('ping'), const IntCodec(max: 10)),
        ]),
        'field instead of RPC': fingerprintOf([
          (b) => b.addField(const FieldId('ping'), const IntCodec()),
        ]),
        'spawn type instead of RPC': fingerprintOf([
          (b) => b.addSpawnType(const SpawnTypeId('ping'), const IntCodec()),
        ]),
        'added static entity': fingerprintOf([
          (b) => b.addRpc(const RpcId('ping'), const IntCodec()),
          (b) => b.addStaticEntity(const StaticEntityId('ping')),
        ]),
        'static entity instead of RPC': fingerprintOf([
          (b) => b.addStaticEntity(const StaticEntityId('ping')),
        ]),
      };

      for (final MapEntry(key: change, value: fingerprint)
          in variants.entries) {
        expect(fingerprint, isNot(base), reason: change);
      }
    });

    test('cannot be matched by descriptors that imitate other entries', () {
      final forged = fingerprintOf([
        (b) => b.addRpc(
          const RpcId('a'),
          const _DescribedCodec('int"],["b","int'),
        ),
      ]);
      final genuine = fingerprintOf([
        (b) => b.addRpc(const RpcId('a'), const _DescribedCodec('int')),
        (b) => b.addRpc(const RpcId('b'), const _DescribedCodec('int')),
      ]);

      expect(forged, isNot(genuine));
    });

    test('includes the join request codec and its descriptor', () {
      final absent = fingerprintOf([]);
      final descriptors = <ValueCodec<Object?>>[
        const StringCodec(maxLength: 16),
        const StringCodec(maxLength: 32),
        const BoolCodec(),
        const _DescribedCodec('game.join@1'),
        const _DescribedCodec('game.join@2'),
      ];
      final fingerprints = <String>{absent};

      for (final codec in descriptors) {
        final fingerprint = fingerprintOf([(b) => b.setJoinRequest(codec)]);
        expect(fingerprints.add(fingerprint), isTrue, reason: codec.descriptor);
        expect(fingerprintOf([(b) => b.setJoinRequest(codec)]), fingerprint);
      }
    });

    test('changes independently with each RPC policy', () {
      String forPolicies({
        RpcCaller caller = RpcCaller.anyPeer,
        RpcTarget target = RpcTarget.host,
        RpcLocal local = RpcLocal.exclude,
      }) => fingerprintOf([
        (b) => b.addRpc(
          const RpcId('ping'),
          const IntCodec(),
          caller: caller,
          target: target,
          local: local,
        ),
      ]);

      final base = forPolicies();
      final fingerprints = <String>{base};
      for (final caller in RpcCaller.values.skip(1)) {
        final changed = forPolicies(caller: caller);
        expect(fingerprints.add(changed), isTrue, reason: caller.name);
      }
      for (final target in RpcTarget.values.skip(1)) {
        final changed = forPolicies(target: target);
        expect(fingerprints.add(changed), isTrue, reason: target.name);
      }
      expect(
        fingerprints.add(forPolicies(local: RpcLocal.include)),
        isTrue,
        reason: 'local invocation',
      );
    });

    test('changes independently with each RPC and field delivery setting', () {
      String forDelivery({
        DeliveryMode rpcMode = DeliveryMode.reliable,
        int rpcChannel = 0,
        DeliveryMode fieldMode = DeliveryMode.reliable,
        int fieldChannel = 0,
      }) => fingerprintOf([
        (b) => b.addRpc(
          const RpcId('ping'),
          const IntCodec(),
          deliveryMode: rpcMode,
          channel: rpcChannel,
        ),
        (b) => b.addField(
          const FieldId('health'),
          const IntCodec(),
          deliveryMode: fieldMode,
          channel: fieldChannel,
        ),
      ]);

      final fingerprints = <String>{forDelivery()};
      for (final mode in DeliveryMode.values.skip(1)) {
        expect(fingerprints.add(forDelivery(rpcMode: mode)), isTrue);
        expect(fingerprints.add(forDelivery(fieldMode: mode)), isTrue);
      }
      expect(fingerprints.add(forDelivery(rpcChannel: 1)), isTrue);
      expect(fingerprints.add(forDelivery(fieldChannel: 1)), isTrue);
    });

    test('describes an owner-written field with its writer', () {
      final schema =
          (ProtocolSchemaBuilder()
                ..addField(
                  const FieldId('player.health'),
                  const IntCodec(min: 0, max: 100),
                )
                ..addField(
                  const FieldId('player.input'),
                  const IntCodec(min: -1, max: 1),
                  writer: FieldWriter.owner,
                ))
              .build();
      const canonical =
          '{"format":5,"spawnTypes":[],"rpcs":[],'
          '"fields":[["player.health","int(min=0,max=100)","reliable",0],'
          '["player.input","int(min=-1,max=1)","reliable",0,"owner"]],'
          '"staticEntities":[],"joinRequest":null}';

      expect(
        schema.fingerprint,
        sha256.convert(utf8.encode(canonical)).toString(),
      );
    });

    test('changes with the writer of a field', () {
      String forWriter(FieldWriter writer) => fingerprintOf([
        (b) => b.addField(
          const FieldId('health'),
          const IntCodec(),
          writer: writer,
        ),
      ]);

      expect(
        forWriter(FieldWriter.owner),
        isNot(forWriter(FieldWriter.authority)),
      );
      // Authority-written fields keep the description of earlier schemas.
      expect(
        forWriter(FieldWriter.authority),
        fingerprintOf([
          (b) => b.addField(const FieldId('health'), const IntCodec()),
        ]),
      );
    });
  });

  group('SchemaEntry', () {
    test('refuses to encode values of another type', () {
      final entry = buildTestSchema().field(const FieldId('player.health'))!;

      expect(() => entry.encode('full'), throwsArgumentError);
    });

    test('reports unexpected codec errors as invalid values', () {
      final schema =
          (ProtocolSchemaBuilder()
                ..addRpc(const RpcId('broken'), const _DescribedCodec('bug')))
              .build();

      expect(
        () => schema.rpc(const RpcId('broken'))!.decode(1),
        throwsProtocolException(ProtocolErrorCode.invalidValue),
      );
    });
  });
}

/// A codec with a fixed [descriptor] whose decoding always fails with an
/// unexpected error.
final class _DescribedCodec extends ValueCodec<int> {
  const _DescribedCodec(this.descriptor);

  @override
  final String descriptor;

  @override
  Object? encode(int value) => value;

  @override
  int decode(Object? wire) => throw StateError('codec bug');
}
