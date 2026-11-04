import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

const _entityId = EntityId(7);
const _owner = PeerId(2);
const _authority = PeerId(3);
const _rpcId = RpcId('player.action');

List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

final class _Invocation {
  const _Invocation(this.context, this.payload);

  final RpcContext context;
  final int payload;
}

final class _FaultyForwardCodec extends ValueCodec<int> {
  const _FaultyForwardCodec();

  static const _value = IntCodec(min: 0, max: 10);

  @override
  String get descriptor => 'test.faulty_forward@1';

  @override
  Object? encode(int value) {
    if (value == 5) throw StateError('Cannot encode this decoded payload.');
    return _value.encode(value);
  }

  @override
  int decode(Object? wire) => _value.decode(wire);
}

final class _MutableListCodec extends ValueCodec<List<int>> {
  const _MutableListCodec();

  static const _list = ListCodec(IntCodec());

  @override
  String get descriptor => 'test.mutable_list@1';

  @override
  Object? encode(List<int> value) => _list.encode(value);

  @override
  List<int> decode(Object? wire) => _list.decode(wire).toList();
}

final class _Harness {
  _Harness({
    RpcCaller caller = RpcCaller.anyPeer,
    RpcTarget target = RpcTarget.host,
    RpcLocal local = RpcLocal.exclude,
    ValueCodec<int> codec = const IntCodec(min: 0, max: 10),
    bool ready = true,
    bool bind = true,
    QueueLimits hostOutgoingLimits = const QueueLimits(),
    QueueLimits clientOutgoingLimits = const QueueLimits(),
  }) {
    final builder = ProtocolSchemaBuilder();
    rpc = builder.addRpc(
      _rpcId,
      codec,
      caller: caller,
      target: target,
      local: local,
    );
    schema = builder.build();
    network = InMemoryNetwork(clock: clock);
    host = _session()..host(network.host(outgoingLimits: hostOutgoingLimits));
    first = _session()
      ..join(network.connect(outgoingLimits: clientOutgoingLimits));
    second = _session()..join(network.connect());
    run();
    expect(first.localPeer, _owner);
    expect(second.localPeer, _authority);
    for (final session in sessions) {
      final entity = session.registry.register(
        _entityId,
        owner: _owner,
        authority: _authority,
      );
      if (ready) session.registry.markReady(entity.id);
      if (bind) {
        bindings[session] = session.bindRpc(entity, rpc, (context, payload) {
          invocations.add(_Invocation(context, payload));
        });
      }
      _drain(session);
      addTearDown(session.close);
    }
  }

  final clock = ManualClock();
  late final InMemoryNetwork network;
  late final ProtocolSchema schema;
  late final Rpc<int> rpc;
  late final MultiplayerSession host;
  late final MultiplayerSession first;
  late final MultiplayerSession second;
  final invocations = <_Invocation>[];
  final messages = <MessageEnvelope>[];
  final bindings = <MultiplayerSession, RpcBinding>{};
  final _updates = <void Function()>[];

  List<MultiplayerSession> get sessions => [host, first, second];

  NetworkEntity entity(MultiplayerSession session) =>
      session.registry[_entityId]!;

  MultiplayerSession _session() {
    final session = MultiplayerSession(
      schema: schema,
      clock: clock,
      onMessage: (_, envelope) => messages.add(envelope),
    );
    _updates.add(session.update);
    return session;
  }

  void run() {
    for (var i = 0; i < 8; i++) {
      clock.advance(Duration.zero);
      for (final update in _updates) {
        update();
      }
    }
  }

  _RawClient rawClient({bool ready = true}) {
    final raw = _RawClient(network.connect(), schema);
    _updates.add(raw.update);
    run();
    raw.send(HelloMessage(fingerprint: schema.fingerprint));
    run();
    if (ready) {
      raw.send(const ReadyMessage());
      run();
    }
    _drain(host);
    return raw;
  }
}

final class _RawClient {
  _RawClient(this.peer, ProtocolSchema schema) : codec = ProtocolCodec(schema);

  final InMemoryClient peer;
  final ProtocolCodec codec;
  PeerConnection? connection;
  PeerId? id;
  var generation = 0;
  final received = <ProtocolMessage>[];

  void update() {
    for (var event = peer.poll(); event != null; event = peer.poll()) {
      switch (event) {
        case ConnectionOpened(:final connection):
          this.connection = connection;
        case MessageReceived(:final message):
          final envelope = codec.decode(message);
          if (envelope.message case WelcomeMessage(:final peer)) {
            id = peer;
            generation = envelope.generation;
          }
          received.add(envelope.message);
        case ConnectionClosed():
          break;
      }
    }
  }

  void send(ProtocolMessage message) => connection!.send(
    codec.encode(MessageEnvelope(message, generation: generation)),
  );

  void sendBody(Map<String, Object?> body, {String kind = 'rpc'}) =>
      connection!.send(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'v': ProtocolCodec.version,
              'k': kind,
              'g': generation,
              'r': 0,
              'b': body,
            }),
          ),
        ),
      );
}

final class _RawHostHarness {
  _RawHostHarness({
    RpcCaller caller = RpcCaller.anyPeer,
    RpcTarget target = RpcTarget.all,
    RpcLocal local = RpcLocal.include,
  }) {
    final builder = ProtocolSchemaBuilder();
    rpc = builder.addRpc(
      _rpcId,
      const IntCodec(min: 0, max: 10),
      caller: caller,
      target: target,
      local: local,
    );
    final schema = builder.build();
    codec = ProtocolCodec(schema);
    final network = InMemoryNetwork(clock: clock);
    host = network.host();
    client = MultiplayerSession(schema: schema, clock: clock)
      ..join(network.connect());
    addTearDown(client.close);
    run();
    send(const WelcomeMessage(peer: _owner, epoch: 20));
    send(const SyncedMessage());
    run();
    entity = client.registry.register(
      _entityId,
      owner: _owner,
      authority: _authority,
    );
    client.registry.markReady(entity.id);
    client.bindRpc(entity, rpc, (context, value) {
      invocations.add(_Invocation(context, value));
    });
    _drain(client);
  }

  final clock = ManualClock();
  late final Rpc<int> rpc;
  late final ProtocolCodec codec;
  late final InMemoryHost host;
  late final MultiplayerSession client;
  late final NetworkEntity entity;
  PeerConnection? connection;
  final invocations = <_Invocation>[];

  void run() {
    for (var i = 0; i < 8; i++) {
      clock.advance(Duration.zero);
      for (var event = host.poll(); event != null; event = host.poll()) {
        if (event case ConnectionOpened(:final connection)) {
          this.connection = connection;
        }
      }
      client.update();
    }
  }

  void send(ProtocolMessage message) =>
      connection!.send(codec.encode(MessageEnvelope(message, generation: 5)));
}

void main() {
  group('RPC caller permissions', () {
    test(
      'owner calls reach host; another client is rejected without leaving',
      () {
        final harness = _Harness(caller: RpcCaller.owner);

        expect(
          harness.first.callRpc(harness.entity(harness.first), harness.rpc, 4),
          isTrue,
        );
        expect(harness.invocations, isEmpty);
        harness.run();
        final invocation = harness.invocations.single;
        expect(invocation.payload, 4);
        expect(invocation.context.sender, _owner);
        expect(invocation.context.target, PeerId.host);

        expect(
          harness.second.callRpc(
            harness.entity(harness.second),
            harness.rpc,
            5,
          ),
          isTrue,
        );
        harness.run();
        expect(harness.invocations, hasLength(1));
        final rejected = _drain(harness.host).whereType<RpcRejected>().single;
        expect(rejected.reason, RpcRejection.notAllowed);
        expect(rejected.entity, _entityId);
        expect(rejected.rpc, _rpcId);
        expect(rejected.sender, _authority);
        expect(harness.second.state, SessionState.ready);
        expect(harness.messages, isEmpty);
      },
    );

    for (final policy in [RpcCaller.authority, RpcCaller.host]) {
      test('${policy.name} permission is independent of target ownership', () {
        final harness = _Harness(
          caller: policy,
          target: RpcTarget.owner,
          local: RpcLocal.include,
        );
        final caller = policy == RpcCaller.authority
            ? harness.second
            : harness.host;
        expect(caller.callRpc(harness.entity(caller), harness.rpc, 1), isTrue);
        harness.run();
        expect(harness.invocations.single.context.target, _owner);
        expect(harness.invocations.single.context.sender, caller.localPeer);

        harness.first.callRpc(harness.entity(harness.first), harness.rpc, 2);
        harness.run();
        expect(harness.invocations, hasLength(1));
        expect(
          _drain(harness.host).whereType<RpcRejected>().single.reason,
          RpcRejection.notAllowed,
        );
      });
    }
  });

  group('RPC routing', () {
    for (final (target, expected) in [
      (RpcTarget.host, [PeerId.host]),
      (RpcTarget.owner, [_owner]),
      (RpcTarget.authority, [_authority]),
      (RpcTarget.all, [PeerId.host, _owner, _authority]),
      (RpcTarget.peer, [_authority]),
    ]) {
      test('${target.name} receives exactly once with original sender', () {
        final harness = _Harness(target: target, local: RpcLocal.include);
        expect(
          harness.first.callRpc(
            harness.entity(harness.first),
            harness.rpc,
            3,
            peer: target == RpcTarget.peer ? _authority : null,
          ),
          isTrue,
        );
        expect(harness.invocations, isEmpty);
        harness.run();
        expect(
          harness.invocations.map((call) => call.context.target),
          unorderedEquals(expected),
        );
        for (final call in harness.invocations) {
          expect(call.context.sender, _owner);
          expect(call.context.owner, _owner);
          expect(call.context.authority, _authority);
          expect(call.context.entity, _entityId);
          expect(call.context.rpc, _rpcId);
          expect(call.context.epoch, harness.host.epoch);
          expect(call.payload, 3);
        }
        expect(harness.messages, isEmpty);
      });
    }

    test('all excludes only the original caller', () {
      final harness = _Harness(target: RpcTarget.all);
      harness.first.callRpc(harness.entity(harness.first), harness.rpc, 1);
      harness.run();
      expect(
        harness.invocations.map((call) => call.context.target),
        unorderedEquals([PeerId.host, _authority]),
      );
    });

    test(
      'a client excluded from its own owner target does not run locally',
      () {
        final harness = _Harness(target: RpcTarget.owner);
        expect(
          harness.first.callRpc(harness.entity(harness.first), harness.rpc, 1),
          isTrue,
        );
        harness.run();
        expect(harness.invocations, isEmpty);
        expect(harness.first.state, SessionState.ready);
      },
    );

    test('all omits peers still synchronizing', () {
      final harness = _Harness(target: RpcTarget.all, local: RpcLocal.include);
      final raw = harness.rawClient(ready: false);
      harness.host.callRpc(harness.entity(harness.host), harness.rpc, 1);
      harness.run();
      expect(
        harness.invocations.map((call) => call.context.target),
        unorderedEquals([PeerId.host, _owner, _authority]),
      );
      expect(raw.received.whereType<RpcDeliveryMessage>(), isEmpty);
    });

    test('targeting an owner that disconnected rejects the call', () {
      final harness = _Harness(target: RpcTarget.owner);
      harness.first.close();
      harness.run();
      _drain(harness.host);
      expect(
        harness.host.callRpc(harness.entity(harness.host), harness.rpc, 1),
        isFalse,
      );
      final rejected = _drain(harness.host).whereType<RpcRejected>().single;
      expect(rejected.reason, RpcRejection.invalidTarget);
      expect(rejected.target, _owner);
      expect(harness.invocations, isEmpty);
    });

    test(
      'client reports transport rejection when its outgoing queue fills',
      () {
        final harness = _Harness(
          clientOutgoingLimits: const QueueLimits(maxMessages: 1),
        );
        final entity = harness.entity(harness.first);
        expect(harness.first.callRpc(entity, harness.rpc, 1), isTrue);
        expect(harness.first.callRpc(entity, harness.rpc, 2), isFalse);
        expect(harness.first.disconnectReason, DisconnectReason.transportError);
        harness.run();
        expect(harness.invocations.single.payload, 1);
      },
    );

    test('host still dispatches locally if a broadcast transport fails', () {
      final harness = _Harness(
        target: RpcTarget.all,
        local: RpcLocal.include,
        hostOutgoingLimits: const QueueLimits(maxMessages: 2),
      );
      final entity = harness.entity(harness.host);
      expect(harness.host.callRpc(entity, harness.rpc, 1), isTrue);
      expect(harness.host.callRpc(entity, harness.rpc, 2), isTrue);
      expect(harness.host.callRpc(entity, harness.rpc, 3), isFalse);
      expect(harness.invocations.map((call) => call.payload), [1, 2, 3]);
      expect(harness.host.state, SessionState.hosting);
      harness.run();
      expect(harness.invocations, hasLength(7));
      expect(
        harness.invocations
            .where((call) => call.context.target != PeerId.host)
            .map((call) => call.payload),
        unorderedEquals([1, 2, 1, 2]),
      );
    });

    test(
      'host local inclusion invokes once and exclusion has no recipient',
      () {
        final included = _Harness(local: RpcLocal.include);
        expect(
          included.host.callRpc(
            included.entity(included.host),
            included.rpc,
            1,
          ),
          isTrue,
        );
        included.run();
        expect(included.invocations, hasLength(1));
        expect(included.invocations.single.context.sender, PeerId.host);
        expect(included.invocations.single.context.target, PeerId.host);

        final excluded = _Harness();
        expect(
          excluded.host.callRpc(
            excluded.entity(excluded.host),
            excluded.rpc,
            1,
          ),
          isFalse,
        );
        excluded.run();
        expect(excluded.invocations, isEmpty);
      },
    );

    test('host applies payload codec before invoking a local handler', () {
      final harness = _Harness(local: RpcLocal.include);
      expect(
        () =>
            harness.host.callRpc(harness.entity(harness.host), harness.rpc, 11),
        throwsArgumentError,
      );
      expect(harness.invocations, isEmpty);
      expect(
        () => harness.first.callRpc(
          harness.entity(harness.first),
          harness.rpc,
          -1,
        ),
        throwsArgumentError,
      );
      harness.run();
      expect(harness.invocations, isEmpty);
    });

    test(
      'local mutation leaves broadcast recipients and caller data intact',
      () {
        final builder = ProtocolSchemaBuilder();
        final rpc = builder.addRpc(
          _rpcId,
          const _MutableListCodec(),
          target: RpcTarget.all,
          local: RpcLocal.include,
        );
        final schema = builder.build();
        final clock = ManualClock();
        final network = InMemoryNetwork(clock: clock);
        final host = MultiplayerSession(schema: schema, clock: clock)
          ..host(network.host());
        final first = MultiplayerSession(schema: schema, clock: clock)
          ..join(network.connect());
        final second = MultiplayerSession(schema: schema, clock: clock)
          ..join(network.connect());
        final sessions = [host, first, second];
        final received = <PeerId, List<int>>{};

        void run() {
          for (var i = 0; i < 8; i++) {
            clock.advance(Duration.zero);
            for (final session in sessions) {
              session.update();
            }
          }
        }

        run();
        for (final session in sessions) {
          addTearDown(session.close);
          final entity = session.registry.register(
            _entityId,
            owner: PeerId.host,
            authority: PeerId.host,
          );
          session.registry.markReady(entity.id);
          session.bindRpc(entity, rpc, (context, payload) {
            if (context.target == PeerId.host) payload.add(99);
            received[context.target] = payload;
          });
        }

        final original = [1, 2];
        expect(host.callRpc(host.registry[_entityId]!, rpc, original), isTrue);
        run();
        expect(received[PeerId.host], [1, 2, 99]);
        expect(received[first.localPeer], [1, 2]);
        expect(received[second.localPeer], [1, 2]);
        expect(original, [1, 2]);
      },
    );

    test('context remains a snapshot after entity removal and session end', () {
      final harness = _Harness(local: RpcLocal.include);
      harness.host.callRpc(harness.entity(harness.host), harness.rpc, 1);
      final context = harness.invocations.single.context;
      final epoch = harness.host.epoch;
      harness.host.registry.remove(_entityId);
      harness.host.close();
      expect(context.entity, _entityId);
      expect(context.rpc, _rpcId);
      expect(context.sender, PeerId.host);
      expect(context.target, PeerId.host);
      expect(context.owner, _owner);
      expect(context.authority, _authority);
      expect(context.epoch, epoch);
    });

    test('explicit target must exist and be ready', () {
      final harness = _Harness(target: RpcTarget.peer);
      expect(
        harness.host.callRpc(
          harness.entity(harness.host),
          harness.rpc,
          1,
          peer: const PeerId(999),
        ),
        isFalse,
      );
      final raw = harness.rawClient(ready: false);
      expect(
        harness.host.callRpc(
          harness.entity(harness.host),
          harness.rpc,
          1,
          peer: raw.id,
        ),
        isFalse,
      );
      expect(
        _drain(harness.host).whereType<RpcRejected>().single.reason,
        RpcRejection.invalidTarget,
      );
      expect(harness.invocations, isEmpty);
    });

    test(
      'peer targets require an explicit peer and other targets reject it',
      () {
        final explicit = _Harness(target: RpcTarget.peer);
        expect(
          explicit.host.callRpc(
            explicit.entity(explicit.host),
            explicit.rpc,
            1,
          ),
          isFalse,
        );
        expect(
          _drain(explicit.host).whereType<RpcRejected>().single.reason,
          RpcRejection.invalidTarget,
        );
        final hostTarget = _Harness(local: RpcLocal.include);
        expect(
          hostTarget.host.callRpc(
            hostTarget.entity(hostTarget.host),
            hostTarget.rpc,
            1,
            peer: _owner,
          ),
          isFalse,
        );
        expect(
          _drain(hostTarget.host).whereType<RpcRejected>().single.reason,
          RpcRejection.invalidTarget,
        );
      },
    );
  });

  group('RPC entity and binding lifecycle', () {
    test('pending entities can bind but cannot invoke until ready', () {
      final harness = _Harness(ready: false, local: RpcLocal.include);
      expect(
        harness.host.callRpc(harness.entity(harness.host), harness.rpc, 1),
        isFalse,
      );
      expect(
        _drain(harness.host).whereType<RpcRejected>().single.reason,
        RpcRejection.entityNotReady,
      );
      harness.host.registry.markReady(_entityId);
      expect(
        harness.host.callRpc(harness.entity(harness.host), harness.rpc, 2),
        isTrue,
      );
      expect(harness.invocations.single.payload, 2);
    });

    for (final removed in [false, true]) {
      test('host rejects remote ${removed ? 'removed' : 'pending'} entity', () {
        final harness = _Harness(ready: removed);
        if (removed) {
          harness.host.registry.remove(_entityId);
        } else {
          harness.first.registry.markReady(_entityId);
        }
        harness.first.callRpc(harness.entity(harness.first), harness.rpc, 1);
        harness.run();
        expect(harness.invocations, isEmpty);
        expect(_drain(harness.host).whereType<RpcRejected>(), hasLength(1));
        expect(harness.first.state, SessionState.ready);
      });
    }

    test('local calls reject foreign entity objects despite matching IDs', () {
      final harness = _Harness(local: RpcLocal.include);
      expect(
        harness.host.callRpc(harness.entity(harness.first), harness.rpc, 1),
        isFalse,
      );
      expect(harness.invocations, isEmpty);
      expect(
        () => harness.host.bindRpc(
          harness.entity(harness.first),
          harness.rpc,
          (_, _) {},
        ),
        throwsArgumentError,
      );
    });

    test('missing or disposed handler rejects without disconnecting', () {
      final harness = _Harness();
      final binding = harness.bindings[harness.host]!;
      expect(binding.isDisposed, isFalse);
      binding.dispose();
      binding.dispose();
      expect(binding.isDisposed, isTrue);
      harness.first.callRpc(harness.entity(harness.first), harness.rpc, 1);
      harness.run();
      expect(harness.invocations, isEmpty);
      expect(
        _drain(harness.host).whereType<RpcRejected>().single.reason,
        RpcRejection.missingHandler,
      );
      expect(harness.first.state, SessionState.ready);

      harness.host.bindRpc(harness.entity(harness.host), harness.rpc, (
        context,
        payload,
      ) {
        harness.invocations.add(_Invocation(context, payload));
      });
      binding.dispose();
      harness.first.callRpc(harness.entity(harness.first), harness.rpc, 2);
      harness.run();
      expect(harness.invocations.single.payload, 2);
    });

    test('recipient rejects a missing handler after host accepts delivery', () {
      final harness = _Harness(target: RpcTarget.owner);
      harness.bindings[harness.first]!.dispose();
      expect(
        harness.host.callRpc(harness.entity(harness.host), harness.rpc, 1),
        isTrue,
      );
      harness.run();
      expect(harness.invocations, isEmpty);
      final rejected = _drain(harness.first).whereType<RpcRejected>().single;
      expect(rejected.reason, RpcRejection.missingHandler);
      expect(rejected.target, _owner);
      expect(rejected.sender, PeerId.host);
      expect(harness.first.state, SessionState.ready);
    });

    test('recipient rejects a delivery after its entity is removed', () {
      final harness = _Harness(target: RpcTarget.authority);
      harness.host.callRpc(harness.entity(harness.host), harness.rpc, 1);
      harness.second.registry.remove(_entityId);
      harness.run();
      expect(harness.invocations, isEmpty);
      expect(
        _drain(harness.second).whereType<RpcRejected>().single.reason,
        RpcRejection.entityNotReady,
      );
      expect(harness.bindings[harness.second]!.isDisposed, isTrue);
    });

    test('duplicate binding and binding removed entities are errors', () {
      final harness = _Harness();
      expect(
        () => harness.host.bindRpc(
          harness.entity(harness.host),
          harness.rpc,
          (_, _) {},
        ),
        throwsStateError,
      );
      harness.host.registry.remove(_entityId);
      expect(
        () => harness.host.bindRpc(
          harness.entity(harness.host),
          harness.rpc,
          (_, _) {},
        ),
        throwsArgumentError,
      );
    });

    test('session restart invalidates bindings and old entity handles', () {
      final harness = _Harness(local: RpcLocal.include);
      final oldEntity = harness.entity(harness.host);
      final oldBinding = harness.bindings[harness.host]!;
      harness.host.close();
      expect(oldBinding.isDisposed, isTrue);
      final network = InMemoryNetwork(clock: harness.clock);
      harness.host.host(network.host());
      final replacement = harness.host.registry.register(
        _entityId,
        owner: PeerId.host,
        authority: PeerId.host,
      );
      harness.host.registry.markReady(_entityId);
      expect(harness.host.callRpc(oldEntity, harness.rpc, 1), isFalse);
      expect(harness.host.callRpc(replacement, harness.rpc, 1), isFalse);
      harness.host.bindRpc(replacement, harness.rpc, (context, payload) {
        harness.invocations.add(_Invocation(context, payload));
      });
      oldBinding.dispose();
      expect(harness.host.callRpc(replacement, harness.rpc, 2), isTrue);
      expect(harness.invocations.single.payload, 2);
    });
  });

  group('RPC schema and protocol boundaries', () {
    test('a foreign handle cannot replace canonical permissions', () {
      final harness = _Harness(caller: RpcCaller.owner);
      const impostor = Rpc<int>(
        id: _rpcId,
        codec: IntCodec(min: 0, max: 10),
        local: RpcLocal.include,
      );
      expect(
        () => harness.host.callRpc(harness.entity(harness.host), impostor, 1),
        throwsArgumentError,
      );
      expect(
        () => harness.host.bindRpc(
          harness.entity(harness.host),
          impostor,
          (_, _) {},
        ),
        throwsArgumentError,
      );
      expect(harness.invocations, isEmpty);
    });

    test('RPC policy differences reject the handshake', () {
      final harness = _Harness(caller: RpcCaller.owner);
      final builder = ProtocolSchemaBuilder();
      builder.addRpc(_rpcId, const IntCodec(min: 0, max: 10));
      final client = MultiplayerSession(
        schema: builder.build(),
        clock: harness.clock,
      )..join(harness.network.connect());
      addTearDown(client.close);
      for (var i = 0; i < 8; i++) {
        harness.run();
        client.update();
      }
      expect(client.disconnectReason, DisconnectReason.schemaMismatch);
    });

    test('unknown entity request is rejected while connection stays ready', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      raw.send(
        const RpcMessage(entity: EntityId(999), rpc: _rpcId, payload: 1),
      );
      harness.run();
      final rejected = _drain(harness.host).whereType<RpcRejected>().single;
      expect(rejected.reason, RpcRejection.unknownEntity);
      expect(rejected.sender, raw.id);
      expect(harness.host.isReady(raw.id!), isTrue);
      expect(harness.invocations, isEmpty);
    });

    for (final (name, body) in <(String, Map<String, Object?>)>[
      ('unknown method', {'e': 7, 'm': 'unknown.method', 'p': 1}),
      ('invalid payload', {'e': 7, 'm': 'player.action', 'p': 99}),
      ('forged sender', {'e': 7, 'm': 'player.action', 'p': 1, 's': 2}),
    ]) {
      test('$name is a protocol violation and never invokes a handler', () {
        final harness = _Harness();
        final raw = harness.rawClient();
        raw.sendBody(body);
        harness.run();
        expect(
          _drain(harness.host),
          contains(PeerLeft(raw.id!, DisconnectReason.protocolViolation)),
        );
        expect(harness.invocations, isEmpty);
        expect(harness.messages, isEmpty);
      });
    }

    test('a client cannot forge a trusted delivery', () {
      final harness = _Harness(target: RpcTarget.all);
      final raw = harness.rawClient();
      raw.send(
        const RpcDeliveryMessage(
          entity: _entityId,
          rpc: _rpcId,
          payload: 1,
          sender: _owner,
          target: PeerId.host,
        ),
      );
      harness.run();
      expect(
        _drain(harness.host),
        contains(PeerLeft(raw.id!, DisconnectReason.protocolViolation)),
      );
      expect(harness.invocations, isEmpty);
    });

    test('a client refuses request messages from the host', () {
      final harness = _RawHostHarness();
      harness.send(
        const RpcMessage(entity: _entityId, rpc: _rpcId, payload: 1),
      );
      harness.run();
      expect(
        harness.client.disconnectReason,
        DisconnectReason.protocolViolation,
      );
      expect(harness.invocations, isEmpty);
    });

    test('client validates delivery caller against its canonical schema', () {
      final harness = _RawHostHarness(caller: RpcCaller.owner);
      harness.send(
        const RpcDeliveryMessage(
          entity: _entityId,
          rpc: _rpcId,
          payload: 1,
          sender: _authority,
          target: _owner,
        ),
      );
      harness.run();
      expect(harness.invocations, isEmpty);
      expect(
        _drain(harness.client).whereType<RpcRejected>().single.reason,
        RpcRejection.notAllowed,
      );
    });

    test('client rejects deliveries addressed to another peer', () {
      final harness = _RawHostHarness();
      harness.send(
        const RpcDeliveryMessage(
          entity: _entityId,
          rpc: _rpcId,
          payload: 1,
          sender: PeerId.host,
          target: _authority,
        ),
      );
      harness.run();
      expect(harness.invocations, isEmpty);
      final rejected = _drain(harness.client).whereType<RpcRejected>().single;
      expect(rejected.reason, RpcRejection.invalidTarget);
      expect(rejected.target, _authority);
    });

    for (final (target, local, sender) in [
      (RpcTarget.host, RpcLocal.include, PeerId.host),
      (RpcTarget.authority, RpcLocal.include, PeerId.host),
      (RpcTarget.all, RpcLocal.exclude, _owner),
    ]) {
      test('client enforces ${target.name}/${local.name} delivery route', () {
        final harness = _RawHostHarness(target: target, local: local);
        harness.send(
          RpcDeliveryMessage(
            entity: _entityId,
            rpc: _rpcId,
            payload: 1,
            sender: sender,
            target: _owner,
          ),
        );
        harness.run();
        expect(harness.invocations, isEmpty);
        expect(
          _drain(harness.client).whereType<RpcRejected>().single.reason,
          RpcRejection.invalidTarget,
        );
      });
    }

    test('unready sessions do not accept invocation', () {
      final harness = _Harness();
      final entity = harness.entity(harness.first);
      harness.first.close();
      expect(
        () => harness.first.callRpc(entity, harness.rpc, 1),
        throwsStateError,
      );
    });
  });

  group('RPC handler failures', () {
    for (final local in [true, false]) {
      test(
        '${local ? 'local' : 'remote'} handler cannot recursively update session',
        () {
          final harness = _Harness(bind: false, local: RpcLocal.include);
          var calls = 0;
          harness.host.bindRpc(harness.entity(harness.host), harness.rpc, (
            _,
            _,
          ) {
            calls++;
            if (calls == 1) harness.host.update();
          });
          final caller = local ? harness.host : harness.first;
          final entity = harness.entity(caller);
          expect(caller.callRpc(entity, harness.rpc, 1), isTrue);
          expect(caller.callRpc(entity, harness.rpc, 2), isTrue);
          harness.run();

          final failure = _drain(
            harness.host,
          ).whereType<RpcHandlerFailed>().single;
          expect(failure.error, isA<StateError>());
          expect(failure.sender, caller.localPeer);
          expect(calls, 2);
          expect(harness.host.state, SessionState.hosting);
          expect(harness.first.state, SessionState.ready);
        },
      );
    }

    test(
      'forwarding codec failure rejects only that call and keeps routing',
      () {
        final harness = _Harness(
          codec: const _FaultyForwardCodec(),
          target: RpcTarget.owner,
        );
        final raw = harness.rawClient();
        raw.sendBody({'e': 7, 'm': _rpcId.value, 'p': 5});
        raw.sendBody({'e': 7, 'm': _rpcId.value, 'p': 2});
        harness.run();

        final rejected = _drain(harness.host).whereType<RpcRejected>().single;
        expect(rejected.reason, RpcRejection.invalidPayload);
        expect(rejected.sender, raw.id);
        expect(rejected.target, _owner);
        expect(harness.invocations.single.payload, 2);
        expect(harness.invocations.single.context.sender, raw.id);
        expect(harness.host.isReady(raw.id!), isTrue);
        expect(harness.first.state, SessionState.ready);
      },
    );

    test(
      'synchronous exception is reported and later calls still dispatch',
      () {
        final harness = _Harness(bind: false, local: RpcLocal.include);
        final error = StateError('handler failed');
        var calls = 0;
        harness.host.bindRpc(harness.entity(harness.host), harness.rpc, (_, _) {
          calls++;
          if (calls == 1) throw error;
        });
        expect(
          harness.host.callRpc(harness.entity(harness.host), harness.rpc, 1),
          isTrue,
        );
        final failure = _drain(
          harness.host,
        ).whereType<RpcHandlerFailed>().single;
        expect(failure.entity, _entityId);
        expect(failure.rpc, _rpcId);
        expect(failure.sender, PeerId.host);
        expect(failure.target, PeerId.host);
        expect(failure.error, same(error));
        expect(failure.stackTrace, isA<StackTrace>());
        expect(
          harness.host.callRpc(harness.entity(harness.host), harness.rpc, 2),
          isTrue,
        );
        expect(calls, 2);
        expect(harness.host.state, SessionState.hosting);
      },
    );

    test(
      'async failure is contained while following calls make progress',
      () async {
        final harness = _Harness(bind: false);
        final completion = Completer<void>();
        final error = StateError('async handler failed');
        var calls = 0;
        harness.host.bindRpc(harness.entity(harness.host), harness.rpc, (_, _) {
          calls++;
          return calls == 1 ? completion.future : null;
        });
        harness.first.callRpc(harness.entity(harness.first), harness.rpc, 1);
        harness.first.callRpc(harness.entity(harness.first), harness.rpc, 2);
        harness.run();
        expect(calls, 2);
        expect(_drain(harness.host).whereType<RpcHandlerFailed>(), isEmpty);
        completion.completeError(error, StackTrace.current);
        await Future<void>.value();
        final failure = _drain(
          harness.host,
        ).whereType<RpcHandlerFailed>().single;
        expect(failure.error, same(error));
        expect(failure.sender, _owner);
        expect(harness.host.isReady(_owner), isTrue);
      },
    );

    test(
      'completion from an ended session cannot report into its restart',
      () async {
        final harness = _Harness(bind: false, local: RpcLocal.include);
        final completion = Completer<void>();
        harness.host.bindRpc(
          harness.entity(harness.host),
          harness.rpc,
          (_, _) => completion.future,
        );
        harness.host.callRpc(harness.entity(harness.host), harness.rpc, 1);
        harness.host.close();
        final network = InMemoryNetwork(clock: harness.clock);
        harness.host.host(network.host());
        _drain(harness.host);
        completion.completeError(
          StateError('previous session'),
          StackTrace.current,
        );
        await Future<void>.value();
        expect(_drain(harness.host).whereType<RpcHandlerFailed>(), isEmpty);
        expect(harness.host.state, SessionState.hosting);
      },
    );
  });
}
