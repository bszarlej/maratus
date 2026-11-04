import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

final class _MutableListCodec extends ValueCodec<List<int>> {
  const _MutableListCodec();

  @override
  String get descriptor => 'test.attachment_mutable_list@1';

  @override
  Object? encode(List<int> value) => const ListCodec(IntCodec()).encode(value);

  @override
  List<int> decode(Object? wire) =>
      const ListCodec(IntCodec()).decode(wire).toList();
}

final class _Fixture {
  _Fixture({
    PendingRpcLimits limits = const PendingRpcLimits(),
    RpcCaller caller = RpcCaller.anyPeer,
    RpcTarget target = RpcTarget.host,
    PeerId owner = PeerId.host,
    bool attach = true,
    bool bind = true,
  }) {
    final builder = ProtocolSchemaBuilder();
    rpc = builder.addRpc(
      const RpcId('attached.action'),
      const IntCodec(min: 0, max: 1000),
      caller: caller,
      target: target,
      local: RpcLocal.include,
    );
    schema = builder.build();
    network = InMemoryNetwork(clock: clock);
    host = MultiplayerSession(
      schema: schema,
      clock: clock,
      pendingRpcLimits: limits,
    )..host(network.host());
    entity = host.registry.create(owner: owner, authority: PeerId.host);
    if (attach) {
      attachment = host.attachEntity(
        entity,
        isReady: () => ready,
        isValid: () => valid,
      );
      if (bind) binding = attachment!.bindRpc(rpc, record);
    }
    _drain(host);
    addTearDown(host.close);
  }

  final clock = ManualClock();
  late final Rpc<int> rpc;
  late final ProtocolSchema schema;
  late final InMemoryNetwork network;
  late final MultiplayerSession host;
  late final NetworkEntity entity;
  EntityAttachment? attachment;
  RpcBinding? binding;
  var ready = false;
  var valid = true;
  final received = <int>[];
  final contexts = <RpcContext>[];

  void record(RpcContext context, int value) {
    received.add(value);
    contexts.add(context);
  }

  bool call(int value, {PeerId? peer}) =>
      host.callRpc(entity, rpc, value, peer: peer);

  List<RpcRejection> rejections() => _drain(
    host,
  ).whereType<RpcRejected>().map((event) => event.reason).toList();

  MultiplayerSession join() {
    final client = MultiplayerSession(schema: schema, clock: clock)
      ..join(network.connect());
    client.registry.register(
      entity.id,
      owner: entity.owner,
      authority: entity.authority,
    );
    for (var i = 0; i < 8; i++) {
      clock.advance(Duration.zero);
      host.update();
      client.update();
    }
    expect(client.state, SessionState.ready);
    addTearDown(client.close);
    _drain(host);
    return client;
  }
}

void main() {
  group('entity attachments', () {
    test('host-local calls defer until an update observes readiness', () {
      final f = _Fixture();
      expect(f.call(1), isTrue);
      expect(f.host.pendingRpcCount, 1);
      expect(f.host.pendingRpcBytes, greaterThan(0));
      f.host.update();
      expect(f.received, isEmpty);
      expect(f.entity.state, EntityState.pending);
      f.ready = true;
      expect(f.received, isEmpty);
      f.host.update();
      expect(f.received, [1]);
      expect(f.entity.state, EntityState.ready);
      expect(f.host.pendingRpcCount, 0);
      expect(f.host.pendingRpcBytes, 0);
      expect(f.contexts.single.sender, PeerId.host);
      expect(f.contexts.single.epoch, f.host.epoch);
    });

    test('ready attachments still defer host-local calls to update', () {
      final f = _Fixture()..ready = true;
      f.host.update();
      expect(f.call(1), isTrue);
      expect(f.received, isEmpty);
      f.host.update();
      expect(f.received, [1]);
    });

    test('remote requests queue before a host attachment becomes ready', () {
      final f = _Fixture();
      final client = f.join();
      final entity = client.registry[f.entity.id]!;
      client.registry.markReady(entity.id);
      expect(client.callRpc(entity, f.rpc, 7), isTrue);
      f.clock.advance(Duration.zero);
      f.host.update();
      expect(f.host.pendingRpcCount, 1);
      expect(f.received, isEmpty);
      f.ready = true;
      f.host.update();
      expect(f.received, [7]);
      expect(f.contexts.single.sender, client.localPeer);
    });

    test('deliveries queue on a pending client attachment', () {
      final f = _Fixture(target: RpcTarget.all)..ready = true;
      final client = f.join();
      final entity = client.registry[f.entity.id]!;
      var ready = false;
      final received = <int>[];
      client
          .attachEntity(entity, isReady: () => ready, isValid: () => true)
          .bindRpc(f.rpc, (_, value) => received.add(value));
      expect(f.call(8), isTrue);
      f.clock.advance(Duration.zero);
      client.update();
      expect(received, isEmpty);
      expect(client.pendingRpcCount, 1);
      ready = true;
      client.update();
      expect(received, [8]);
      expect(entity.state, EntityState.ready);
    });

    test('pending attached clients may enqueue outgoing requests', () {
      final f = _Fixture();
      final client = f.join();
      final entity = client.registry[f.entity.id]!;
      client.attachEntity(entity, isReady: () => false, isValid: () => true);
      expect(client.callRpc(entity, f.rpc, 9), isTrue);
      f.clock.advance(Duration.zero);
      f.host.update();
      expect(f.host.pendingRpcCount, 1);
      expect(client.pendingRpcCount, 0);
      f.ready = true;
      f.host.update();
      expect(f.received, [9]);
    });

    test('remote permission checks precede pending-host queue admission', () {
      final f = _Fixture(caller: RpcCaller.host);
      final client = f.join();
      final entity = client.registry[f.entity.id]!;
      client.registry.markReady(entity.id);
      expect(client.callRpc(entity, f.rpc, 1), isTrue);
      f.clock.advance(Duration.zero);
      f.host.update();
      expect(f.host.pendingRpcCount, 0);
      expect(f.rejections(), [RpcRejection.notAllowed]);
      expect(client.state, SessionState.ready);
    });

    test('queued payloads are snapshots independent of caller mutation', () {
      final builder = ProtocolSchemaBuilder();
      final rpc = builder.addRpc(
        const RpcId('snapshot'),
        const _MutableListCodec(),
        local: RpcLocal.include,
      );
      final clock = ManualClock();
      final session = MultiplayerSession(schema: builder.build(), clock: clock)
        ..host(InMemoryNetwork(clock: clock).host());
      addTearDown(session.close);
      final entity = session.registry.create(
        owner: PeerId.host,
        authority: PeerId.host,
      );
      final received = <List<int>>[];
      session
          .attachEntity(entity, isReady: () => true, isValid: () => true)
          .bindRpc(rpc, (_, value) {
            received.add([...value]);
            value.add(100);
          });
      final payload = [1];
      expect(session.callRpc(entity, rpc, payload), isTrue);
      payload.add(2);
      expect(session.callRpc(entity, rpc, payload), isTrue);
      payload.add(3);
      session.update();
      expect(received, [
        [1],
        [1, 2],
      ]);
      expect(payload, [1, 2, 3]);
    });

    test('unattached pending entities retain immediate rejection', () {
      final f = _Fixture(attach: false);
      f.host.bindRpc(f.entity, f.rpc, f.record);
      expect(f.call(1), isFalse);
      expect(f.rejections(), [RpcRejection.entityNotReady]);
      expect(f.host.pendingRpcCount, 0);
      f.host.registry.markReady(f.entity.id);
      expect(f.call(2), isTrue);
      expect(f.received, [2]);
    });

    test(
      'duplicate attachments and unmanaged binding conflicts are rejected',
      () {
        final f = _Fixture();
        expect(
          () => f.host.attachEntity(
            f.entity,
            isReady: () => true,
            isValid: () => true,
          ),
          throwsStateError,
        );
        expect(
          () => f.host.bindRpc(f.entity, f.rpc, f.record),
          throwsStateError,
        );
        f.attachment!.dispose();
        final unmanaged = f.host.bindRpc(f.entity, f.rpc, f.record);
        expect(
          () => f.host.attachEntity(
            f.entity,
            isReady: () => true,
            isValid: () => true,
          ),
          throwsStateError,
        );
        unmanaged.dispose();
        final replacement = f.host.attachEntity(
          f.entity,
          isReady: () => true,
          isValid: () => true,
        );
        expect(replacement.isDisposed, isFalse);
      },
    );

    test('foreign and removed entities cannot be attached', () {
      final f = _Fixture(attach: false);
      final foreign = EntityRegistry().create(
        owner: PeerId.host,
        authority: PeerId.host,
      );
      for (final entity in [foreign, f.entity]) {
        if (identical(entity, f.entity)) f.host.registry.remove(entity.id);
        expect(
          () => f.host.attachEntity(
            entity,
            isReady: () => true,
            isValid: () => true,
          ),
          throwsArgumentError,
        );
      }
    });

    test(
      'disposed attachments reject new bindings and discard queued calls',
      () {
        final f = _Fixture();
        f.call(1);
        f.attachment!.dispose();
        f.attachment!.dispose();
        expect(f.attachment!.isDisposed, isTrue);
        expect(f.binding!.isDisposed, isTrue);
        expect(f.host.pendingRpcCount, 0);
        expect(f.host.pendingRpcBytes, 0);
        expect(() => f.attachment!.bindRpc(f.rpc, f.record), throwsStateError);
        expect(f.entity.state, EntityState.pending);
      },
    );

    test('replacement attachment cannot receive previous attachment calls', () {
      final f = _Fixture();
      f.call(1);
      f.attachment!.dispose();
      f.host
          .attachEntity(f.entity, isReady: () => true, isValid: () => true)
          .bindRpc(f.rpc, f.record);
      f.call(2);
      f.host.update();
      expect(f.received, [2]);
      expect(f.host.pendingRpcCount, 0);
    });

    test('disposing a binding discards calls before handler replacement', () {
      final f = _Fixture()..ready = true;
      f.call(1);
      f.binding!.dispose();
      expect(f.host.pendingRpcCount, 0);
      expect(f.host.pendingRpcBytes, 0);
      f.attachment!.bindRpc(f.rpc, f.record);
      f.call(2);
      f.host.update();
      expect(f.received, [2]);
    });

    test('invalidation discards queued calls and all owned bindings', () {
      final f = _Fixture();
      f.call(1);
      f.valid = false;
      f.ready = true;
      f.host.update();
      expect(f.attachment!.isDisposed, isTrue);
      expect(f.binding!.isDisposed, isTrue);
      expect(f.received, isEmpty);
      expect(f.host.pendingRpcCount, 0);
      expect(f.host.pendingRpcBytes, 0);
    });

    test('removal or registry replacement cannot revive queued calls', () {
      for (final clear in [false, true]) {
        final f = _Fixture();
        f.call(1);
        if (clear) {
          f.host.registry.clear();
          f.host.registry.register(
            f.entity.id,
            owner: PeerId.host,
            authority: PeerId.host,
          );
        } else {
          f.host.registry.remove(f.entity.id);
        }
        f.ready = true;
        f.host.update();
        expect(f.attachment!.isDisposed, isTrue);
        expect(f.received, isEmpty);
        expect(f.host.pendingRpcCount, 0);
      }
    });

    test('session shutdown disposes attachments and restart starts empty', () {
      final f = _Fixture();
      f.call(1);
      f.host.close();
      expect(f.attachment!.isDisposed, isTrue);
      expect(f.binding!.isDisposed, isTrue);
      expect(f.host.pendingRpcCount, 0);
      expect(f.host.pendingRpcBytes, 0);
      f.host.host(InMemoryNetwork(clock: f.clock).host());
      final replacement = f.host.registry.create(
        owner: PeerId.host,
        authority: PeerId.host,
      );
      expect(replacement.id, f.entity.id);
      f.host
          .attachEntity(replacement, isReady: () => true, isValid: () => true)
          .bindRpc(f.rpc, f.record);
      f.host.update();
      expect(f.received, isEmpty);
    });

    test('missing handlers reject before consuming pending capacity', () {
      final f = _Fixture(bind: false);
      expect(f.call(1), isFalse);
      expect(f.rejections(), [RpcRejection.missingHandler]);
      expect(f.host.pendingRpcCount, 0);
    });

    test('permission and target policies are checked before enqueue', () {
      final ownerOnly = _Fixture(
        caller: RpcCaller.owner,
        owner: const PeerId(2),
      );
      expect(ownerOnly.call(1), isFalse);
      expect(ownerOnly.rejections(), [RpcRejection.notAllowed]);
      expect(ownerOnly.host.pendingRpcCount, 0);
      final f = _Fixture(target: RpcTarget.peer);
      expect(f.call(1), isFalse);
      expect(f.call(1, peer: const PeerId(9)), isFalse);
      expect(f.rejections(), [
        RpcRejection.invalidTarget,
        RpcRejection.invalidTarget,
      ]);
      expect(f.host.pendingRpcCount, 0);
    });

    test('invalid payloads cannot occupy pending capacity', () {
      final f = _Fixture();
      expect(() => f.call(1001), throwsArgumentError);
      expect(f.host.pendingRpcCount, 0);
      expect(f.host.pendingRpcBytes, 0);
    });

    test('readiness is checked again before each queued invocation', () {
      final f = _Fixture(bind: false)..ready = true;
      f.attachment!.bindRpc(f.rpc, (context, value) {
        f.record(context, value);
        f.ready = false;
      });
      f.call(1);
      f.call(2);
      f.host.update();
      expect(f.received, [1]);
      expect(f.host.pendingRpcCount, 1);
      expect(f.entity.state, EntityState.ready);
      f.host.update();
      expect(f.received, [1]);
      f.ready = true;
      f.host.update();
      expect(f.received, [1, 2]);
    });

    test('handler disposal prevents later queued calls in the same update', () {
      final f = _Fixture(bind: false)..ready = true;
      f.attachment!.bindRpc(f.rpc, (context, value) {
        f.record(context, value);
        f.attachment!.dispose();
      });
      f.call(1);
      f.call(2);
      f.host.update();
      expect(f.received, [1]);
      expect(f.host.pendingRpcCount, 0);
      expect(f.host.pendingRpcBytes, 0);
    });

    test(
      'handler invalidation prevents later queued calls in the same update',
      () {
        final f = _Fixture(bind: false)..ready = true;
        f.attachment!.bindRpc(f.rpc, (context, value) {
          f.record(context, value);
          f.valid = false;
        });
        f.call(1);
        f.call(2);
        f.host.update();
        expect(f.received, [1]);
        expect(f.host.pendingRpcCount, 0);
        expect(f.attachment!.isDisposed, isTrue);
      },
    );

    test('recursive attached calls wait for a later update', () {
      final f = _Fixture(bind: false)..ready = true;
      f.attachment!.bindRpc(f.rpc, (context, value) {
        f.record(context, value);
        if (value < 3) expect(f.call(value + 1), isTrue);
      });
      f.call(1);
      f.host.update();
      expect(f.received, [1]);
      expect(f.host.pendingRpcCount, 1);
      f.host.update();
      expect(f.received, [1, 2]);
      f.host.update();
      expect(f.received, [1, 2, 3]);
      expect(f.host.pendingRpcCount, 0);
    });

    test('shutdown in a handler discards the remaining queue', () {
      final f = _Fixture(bind: false)..ready = true;
      f.attachment!.bindRpc(f.rpc, (context, value) {
        f.record(context, value);
        f.host.close();
      });
      f.call(1);
      f.call(2);
      f.host.update();
      expect(f.received, [1]);
      expect(f.host.pendingRpcCount, 0);
      expect(f.host.state, SessionState.disconnected);
    });
  });

  group('pending RPC bounds', () {
    test('limits must be positive', () {
      for (final limits in [
        const PendingRpcLimits(maxMessages: 0),
        const PendingRpcLimits(maxBytes: 0),
        const PendingRpcLimits(maxAge: Duration.zero),
      ]) {
        expect(
          () => MultiplayerSession(
            schema: ProtocolSchemaBuilder().build(),
            pendingRpcLimits: limits,
          ),
          throwsArgumentError,
        );
      }
    });

    test('count is global and rejects newest while preserving older calls', () {
      final f = _Fixture(limits: const PendingRpcLimits(maxMessages: 2));
      final other = f.host.registry.create(
        owner: PeerId.host,
        authority: PeerId.host,
      );
      f.host
          .attachEntity(other, isReady: () => true, isValid: () => true)
          .bindRpc(f.rpc, f.record);
      expect(f.call(1), isTrue);
      expect(f.host.callRpc(other, f.rpc, 2), isTrue);
      expect(f.call(3), isFalse);
      expect(f.rejections(), [RpcRejection.pendingQueueFull]);
      expect(f.host.pendingRpcCount, 2);
      f.host.update();
      expect(f.received, [2]);
      expect(f.host.pendingRpcCount, 1);
      f.ready = true;
      f.host.update();
      expect(f.received, [2, 1]);
    });

    test('byte limits measure full normalized delivery envelopes', () {
      final reference = _Fixture();
      final size = ProtocolCodec(reference.schema)
          .encode(
            MessageEnvelope(
              RpcDeliveryMessage(
                entity: reference.entity.id,
                rpc: reference.rpc.id,
                payload: 1,
                sender: PeerId.host,
                target: PeerId.host,
              ),
            ),
          )
          .length;
      final f = _Fixture(limits: PendingRpcLimits(maxBytes: size));
      expect(f.call(1), isTrue);
      expect(f.host.pendingRpcBytes, size);
      expect(f.call(2), isFalse);
      expect(f.rejections(), [RpcRejection.pendingQueueFull]);
      f.ready = true;
      f.host.update();
      expect(f.host.pendingRpcBytes, 0);
      expect(f.call(2), isTrue);
      final tooSmall = _Fixture(limits: PendingRpcLimits(maxBytes: size - 1));
      expect(tooSmall.call(1), isFalse);
      expect(tooSmall.host.pendingRpcCount, 0);
    });

    test('pending calls expire at the age limit while still loading', () {
      final f = _Fixture(
        limits: const PendingRpcLimits(maxAge: Duration(seconds: 1)),
      );
      f.call(1);
      f.clock.advance(const Duration(milliseconds: 999));
      f.host.update();
      expect(f.host.pendingRpcCount, 1);
      f.clock.advance(const Duration(milliseconds: 1));
      f.host.update();
      expect(f.host.pendingRpcCount, 0);
      expect(f.host.pendingRpcBytes, 0);
      expect(f.rejections(), [RpcRejection.readinessTimeout]);
      f.ready = true;
      f.host.update();
      expect(f.received, isEmpty);
    });

    test('readiness at the deadline does not revive an expired call', () {
      final f = _Fixture(
        limits: const PendingRpcLimits(maxAge: Duration(seconds: 1)),
      );
      f.call(1);
      f.clock.advance(const Duration(seconds: 1));
      f.ready = true;
      f.host.update();
      expect(f.received, isEmpty);
      expect(f.rejections(), [RpcRejection.readinessTimeout]);
    });
  });
}
