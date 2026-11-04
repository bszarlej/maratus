import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

import 'protocol_test_utils.dart';

/// The canonical description of the test schema that its fingerprint
/// digests.
const _canonicalTestSchema =
    '{"format":2,'
    '"spawnTypes":[["player","string(maxLength=16)"]],'
    '"rpcs":[["player.move","test.move_input@1","any","host","exclude"]],'
    '"fields":[["player.health","int(min=0,max=100)"],'
    '["player.name","string(maxLength=16)"]]}';

/// The SHA-256 digest of [_canonicalTestSchema], computed independently.
const _testSchemaFingerprint =
    'bcc7a53aac40acc7037edfd75ff506661197e24f24b3d9651eca1bb4842f0ef9';

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
      );
      final schema = builder.build();

      expect(rpc.caller, RpcCaller.owner);
      expect(rpc.target, RpcTarget.authority);
      expect(rpc.local, RpcLocal.include);
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

    test('keeps a separate namespace for each kind of registration', () {
      final schema =
          (ProtocolSchemaBuilder()
                ..addRpc(const RpcId('ping'), const BoolCodec())
                ..addField(const FieldId('ping'), const IntCodec()))
              .build();

      expect(schema.rpc(const RpcId('ping'))?.codec, isA<BoolCodec>());
      expect(schema.field(const FieldId('ping'))?.codec, isA<IntCodec>());
      expect(schema.spawnType(const SpawnTypeId('ping')), isNull);
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
