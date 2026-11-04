import 'package:maratus/src/core/entity_registry.dart';
import 'package:maratus/src/protocol/identifiers.dart';
import 'package:maratus/src/protocol/value_codec.dart';
import 'package:test/test.dart';

const _client = PeerId(2);

void main() {
  late EntityRegistry registry;

  setUp(() => registry = EntityRegistry());

  group('creating', () {
    test('assigns increasing IDs to pending entities', () {
      final first = registry.create(owner: _client, authority: PeerId.host);
      final second = registry.create(owner: PeerId.host, authority: _client);

      expect(first.id, const EntityId(1));
      expect(second.id, const EntityId(2));
      expect(first.state, EntityState.pending);
      expect(first.owner, _client);
      expect(first.authority, PeerId.host);
      expect(second.owner, PeerId.host);
      expect(second.authority, _client);
      expect(registry[const EntityId(2)], same(second));
    });

    test('skips IDs that were registered explicitly', () {
      registry.register(
        const EntityId(5),
        owner: PeerId.host,
        authority: PeerId.host,
      );

      final created = registry.create(owner: _client, authority: PeerId.host);

      expect(created.id, const EntityId(6));
    });

    test('rejects creation after exhausting the valid ID range', () {
      final last = registry.register(
        const EntityId(IntCodec.maxSafe),
        owner: _client,
        authority: PeerId.host,
      );
      registry.remove(last.id);

      expect(
        () => registry.create(owner: _client, authority: PeerId.host),
        throwsStateError,
      );
      expect(registry[last.id], same(last));
      expect(registry.entities, isEmpty);
    });

    test('invalid peer metadata does not consume an entity ID', () {
      expect(
        () => registry.create(owner: const PeerId(0), authority: PeerId.host),
        throwsArgumentError,
      );

      expect(
        registry.create(owner: _client, authority: PeerId.host).id,
        const EntityId(1),
      );
    });
  });

  group('registering', () {
    test('keeps the given ID', () {
      final entity = registry.register(
        const EntityId(42),
        owner: _client,
        authority: PeerId.host,
      );

      expect(entity.id, const EntityId(42));
      expect(entity.state, EntityState.pending);
      expect(registry[const EntityId(42)], same(entity));
      expect(registry[const EntityId(41)], isNull);
    });

    test('rejects IDs outside the valid range', () {
      for (final id in [0, -1, 9007199254740992]) {
        expect(
          () => registry.register(
            EntityId(id),
            owner: PeerId.host,
            authority: PeerId.host,
          ),
          throwsArgumentError,
          reason: '$id',
        );
      }
      expect(registry.entities, isEmpty);
    });

    test('rejects invalid owner and authority without reserving the ID', () {
      for (final value in [0, -1, IntCodec.maxSafe + 1]) {
        for (final invalidOwner in [true, false]) {
          expect(
            () => registry.register(
              const EntityId(42),
              owner: invalidOwner ? PeerId(value) : PeerId.host,
              authority: invalidOwner ? PeerId.host : PeerId(value),
            ),
            throwsArgumentError,
            reason: '${invalidOwner ? 'owner' : 'authority'} $value',
          );
        }
      }
      expect(registry.entities, isEmpty);
      expect(registry[const EntityId(42)], isNull);
      expect(
        registry.create(owner: _client, authority: PeerId.host).id,
        const EntityId(1),
      );
    });

    test('accepts the largest valid owner and authority IDs', () {
      final entity = registry.register(
        const EntityId(42),
        owner: const PeerId(IntCodec.maxSafe),
        authority: const PeerId(IntCodec.maxSafe),
      );

      expect(entity.owner, const PeerId(IntCodec.maxSafe));
      expect(entity.authority, const PeerId(IntCodec.maxSafe));
    });

    test('never reuses an ID, even after its entity is removed', () {
      final removed = registry.create(owner: _client, authority: PeerId.host);
      registry.remove(removed.id);

      expect(
        () => registry.register(
          removed.id,
          owner: PeerId.host,
          authority: PeerId.host,
        ),
        throwsArgumentError,
      );
      expect(
        registry.create(owner: _client, authority: PeerId.host).id,
        isNot(removed.id),
      );
      expect(registry[removed.id], same(removed));
      expect(removed.state, EntityState.removed);
    });
  });

  group('lifecycle', () {
    test('moves entities from pending to ready to removed', () {
      final entity = registry.create(owner: _client, authority: PeerId.host);

      expect(registry.markReady(entity.id), isTrue);
      expect(entity.state, EntityState.ready);

      registry.remove(entity.id);
      expect(entity.state, EntityState.removed);
    });

    test('keeps an entity removed while it was pending', () {
      final entity = registry.create(owner: _client, authority: PeerId.host);
      registry.remove(entity.id);

      expect(registry.markReady(entity.id), isFalse);
      expect(entity.state, EntityState.removed);
    });

    test('ignores repeated removal', () {
      final entity = registry.create(owner: _client, authority: PeerId.host);

      registry
        ..remove(entity.id)
        ..remove(entity.id);

      expect(entity.state, EntityState.removed);
    });

    test('rejects marking an entity ready twice', () {
      final entity = registry.create(owner: _client, authority: PeerId.host);
      registry.markReady(entity.id);

      expect(() => registry.markReady(entity.id), throwsStateError);
    });

    test('rejects unregistered IDs', () {
      expect(() => registry.markReady(const EntityId(1)), throwsArgumentError);
      expect(() => registry.remove(const EntityId(1)), throwsArgumentError);
    });
  });

  group('queries', () {
    test('list entities that have not been removed, in order', () {
      final a = registry.create(owner: _client, authority: PeerId.host);
      final b = registry.create(owner: PeerId.host, authority: PeerId.host);
      final c = registry.create(owner: _client, authority: PeerId.host);
      registry.markReady(c.id);
      registry.remove(b.id);

      expect(registry.entities, [a, c]);
    });

    test('find the entities a peer owns', () {
      final a = registry.create(owner: _client, authority: PeerId.host);
      registry.create(owner: PeerId.host, authority: _client);
      final c = registry.create(owner: _client, authority: PeerId.host);
      final d = registry.create(owner: _client, authority: PeerId.host);
      registry.remove(d.id);

      expect(registry.ownedBy(_client), [a, c]);
      expect(registry.ownedBy(const PeerId(3)), isEmpty);
    });
  });

  test('clearing forgets every entity and restarts IDs', () {
    final entity = registry.create(owner: _client, authority: PeerId.host);
    registry.remove(entity.id);

    registry.clear();

    expect(registry.entities, isEmpty);
    expect(registry[entity.id], isNull);
    expect(
      registry.create(owner: _client, authority: PeerId.host).id,
      const EntityId(1),
    );
  });

  test('clearing invalidates retained pending and ready entity references', () {
    final pending = registry.create(owner: _client, authority: PeerId.host);
    final ready = registry.create(owner: _client, authority: PeerId.host);
    registry.markReady(ready.id);

    registry.clear();
    final replacement = registry.create(
      owner: PeerId.host,
      authority: PeerId.host,
    );
    registry.markReady(replacement.id);

    expect(replacement.id, pending.id);
    expect(replacement.state, EntityState.ready);
    expect(pending.state, EntityState.removed);
    expect(ready.state, EntityState.removed);
    expect(registry.entities, [replacement]);
  });
}
