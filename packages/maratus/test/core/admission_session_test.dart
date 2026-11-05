import 'dart:async';

import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

const _firstClient = PeerId(2);
const _secondClient = PeerId(3);

List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

/// Mutable decoded values let the tests observe ownership of request data.
final class _RequestCodec extends ValueCodec<List<int>> {
  const _RequestCodec();

  static const _list = ListCodec(IntCodec(min: 0, max: 9), maxLength: 4);

  @override
  String get descriptor => 'test.join_request@1';

  @override
  Object? encode(List<int> value) => _list.encode(value);

  @override
  List<int> decode(Object? wire) => _list.decode(wire).toList();
}

final class _Schema {
  _Schema({bool withRequest = true}) {
    final builder = ProtocolSchemaBuilder();
    avatar = builder.addSpawnType(
      const SpawnTypeId('avatar'),
      const StringCodec(),
    );
    health = builder.addField(const FieldId('avatar.health'), const IntCodec());
    announce = builder.addRpc(
      const RpcId('avatar.announce'),
      const IntCodec(),
      target: RpcTarget.all,
      local: RpcLocal.include,
    );
    if (withRequest) builder.setJoinRequest(const _RequestCodec());
    schema = builder.build();
  }

  late final SpawnType<String> avatar;
  late final SyncField<int> health;
  late final Rpc<int> announce;
  late final ProtocolSchema schema;
}

final class _Harness {
  _Harness({bool withRequest = true, this.timeouts = const SessionTimeouts()})
    : definitions = _Schema(withRequest: withRequest) {
    network = InMemoryNetwork(clock: clock);
    host = session()..host(network.host());
    _drain(host);
  }

  final clock = ManualClock();
  final _Schema definitions;
  final SessionTimeouts timeouts;
  late final InMemoryNetwork network;
  late final MultiplayerSession host;
  final _updates = <void Function()>[];

  ProtocolSchema get schema => definitions.schema;

  MultiplayerSession session({ProtocolSchema? schema}) {
    final session = MultiplayerSession(
      schema: schema ?? this.schema,
      clock: clock,
      timeouts: timeouts,
    );
    addTearDown(session.close);
    _updates.add(session.update);
    return session;
  }

  MultiplayerSession join({Object? request = const <int>[1]}) =>
      session()..join(network.connect(), request: request);

  _RawClient rawClient() {
    final raw = _RawClient(network.connect(), schema);
    addTearDown(raw.peer.close);
    _updates.add(raw.update);
    return raw;
  }

  void run({int rounds = 6}) {
    for (var i = 0; i < rounds; i++) {
      clock.advance(Duration.zero);
      for (final update in _updates) {
        update();
      }
    }
  }
}

/// A client that exposes all host traffic before a welcome is accepted.
final class _RawClient {
  _RawClient(this.peer, this.schema) : codec = ProtocolCodec(schema);

  final InMemoryClient peer;
  final ProtocolSchema schema;
  final ProtocolCodec codec;
  PeerConnection? connection;
  final received = <ProtocolMessage>[];

  void update() {
    for (var event = peer.poll(); event != null; event = peer.poll()) {
      switch (event) {
        case ConnectionOpened(:final connection):
          this.connection = connection;
        case MessageReceived(:final message):
          received.add(codec.decode(message).message);
        case ConnectionClosed():
          break;
      }
    }
  }

  void hello({String? fingerprint, Object? request = const <int>[1]}) =>
      connection!.send(
        codec.encode(
          MessageEnvelope(
            HelloMessage(
              fingerprint: fingerprint ?? schema.fingerprint,
              request: request,
            ),
          ),
        ),
      );
}

void main() {
  group('admission decisions', () {
    test('default admission preserves joining without a request codec', () {
      final harness = _Harness(withRequest: false);
      final client = harness.join(request: null);

      harness.run();

      expect(client.state, SessionState.ready);
      expect(client.rejectionReason, isNull);
      expect(harness.host.peers, [_firstClient]);
      expect(_drain(harness.host), [
        const PeerJoined(_firstClient),
        const PeerReady(_firstClient),
      ]);
    });

    test('a handler receives null data without a request codec', () {
      final harness = _Harness(withRequest: false);
      JoinRequest? received;
      harness.host.onJoinRequest = (request) {
        received = request;
        return const Admission.admit();
      };
      final client = harness.join(request: null);

      harness.run();

      expect(received!.data, isNull);
      expect(received!.peer, client.localPeer);
      expect(client.state, SessionState.ready);
    });

    test(
      'requests are snapshotted and decoded independently for each client',
      () {
        final harness = _Harness();
        final input = [1, 2];
        final requests = <JoinRequest>[];
        harness.host.onJoinRequest = (request) {
          requests.add(request);
          expect(request.data, [1, 2]);
          (request.data! as List<int>)[0] = 9;
          return const Admission.admit();
        };
        final first = harness.join(request: input);
        final second = harness.join(request: input);
        input[0] = 3;

        harness.run();

        expect(first.state, SessionState.ready);
        expect(second.state, SessionState.ready);
        expect(requests.map((request) => request.peer), [
          first.localPeer,
          second.localPeer,
        ]);
        expect(requests[0].data, isNot(same(requests[1].data)));
        expect(input, [3, 2]);
      },
    );

    test('rejection returns a reason without exposing replicated entities', () {
      final harness = _Harness();
      harness.host
        ..spawn(harness.definitions.avatar, 'private')
        ..onJoinRequest = (_) => Admission.reject('The room is full.');
      final client = harness.join();

      harness.run();

      expect(client.state, SessionState.disconnected);
      expect(client.disconnectReason, DisconnectReason.rejected);
      expect(client.rejectionReason, 'The room is full.');
      expect(client.localPeer, isNull);
      expect(client.registry.entities, isEmpty);
      expect(harness.host.peers, isEmpty);
      expect(_drain(harness.host), isEmpty);
      expect(
        _drain(
          client,
        ).whereType<SessionStateChanged>().map((event) => event.state),
        [
          SessionState.connecting,
          SessionState.handshaking,
          SessionState.disconnected,
        ],
      );
    });

    test('rejected identities stay reserved for the rest of the session', () {
      final harness = _Harness();
      final requestedPeers = <PeerId>[];
      harness.host.onJoinRequest = (request) {
        requestedPeers.add(request.peer);
        return requestedPeers.length == 1
            ? Admission.reject()
            : const Admission.admit();
      };
      final rejected = harness.join();
      harness.run();
      final accepted = harness.join();

      harness.run();

      expect(rejected.disconnectReason, DisconnectReason.rejected);
      expect(rejected.rejectionReason, isNull);
      expect(requestedPeers, [_firstClient, _secondClient]);
      expect(accepted.localPeer, _secondClient);
      expect(harness.host.peers, [_secondClient]);
      expect(_drain(harness.host), [
        const PeerJoined(_secondClient),
        const PeerReady(_secondClient),
      ]);
    });

    test(
      'a capacity policy observes earlier admissions in the same update',
      () {
        final harness = _Harness();
        harness.host.onJoinRequest = (_) => harness.host.peers.isEmpty
            ? const Admission.admit()
            : Admission.reject('The room is full.');
        final first = harness.join();
        final second = harness.join();

        harness.run();

        expect(first.state, SessionState.ready);
        expect(second.disconnectReason, DisconnectReason.rejected);
        expect(second.rejectionReason, 'The room is full.');
        expect(harness.host.peers, [first.localPeer]);
        expect(_drain(harness.host), [
          PeerJoined(first.localPeer!),
          PeerReady(first.localPeer!),
        ]);
      },
    );

    test(
      'a thrown handler rejects only its client and reports the failure',
      () {
        final harness = _Harness();
        final error = StateError('backend unavailable');
        var calls = 0;
        harness.host.onJoinRequest = (_) {
          if (calls++ == 0) throw error;
          return const Admission.admit();
        };
        final rejected = harness.join();
        final admitted = harness.join();

        harness.run();

        final events = _drain(harness.host);
        final failure = events.whereType<AdmissionFailed>().single;
        expect(failure.peer, _firstClient);
        expect(failure.error, same(error));
        expect(failure.stackTrace, isA<StackTrace>());
        expect(events.whereType<PeerLeft>(), isEmpty);
        expect(events.whereType<PeerJoined>().single.peer, admitted.localPeer);
        expect(rejected.disconnectReason, DisconnectReason.rejected);
        expect(rejected.rejectionReason, isNull);
        expect(admitted.state, SessionState.ready);
      },
    );
  });

  group('handler lifecycle changes', () {
    for (final throwsAfterRestart in [false, true]) {
      test(
        'a handler that restarts the host then ${throwsAfterRestart ? 'throws' : 'returns'} cannot affect the new session',
        () {
          final harness = _Harness();
          harness.host.onJoinRequest = (_) {
            harness.host
              ..close()
              ..host(harness.network.host());
            if (throwsAfterRestart) throw StateError('previous session');
            return const Admission.admit();
          };
          final oldClient = harness.join();

          harness.run();

          expect(oldClient.disconnectReason, DisconnectReason.remoteClosed);
          expect(harness.host.state, SessionState.hosting);
          expect(harness.host.peers, isEmpty);
          expect(_drain(harness.host), [
            const SessionStateChanged(
              SessionState.disconnected,
              DisconnectReason.closed,
            ),
            const SessionStateChanged(SessionState.hosting),
          ]);

          harness.host.onJoinRequest = null;
          final newClient = harness.join();
          harness.run();

          expect(newClient.state, SessionState.ready);
          expect(newClient.localPeer, _firstClient);
        },
      );
    }
  });

  group('pending admission', () {
    test('withholds static entity state and RPCs until admission', () async {
      final builder = ProtocolSchemaBuilder();
      final board = builder.addStaticEntity(const StaticEntityId('board'));
      final scoreField = builder.addField(
        const FieldId('board.score'),
        const IntCodec(),
      );
      final announce = builder.addRpc(
        const RpcId('board.announce'),
        const IntCodec(),
        target: RpcTarget.all,
        local: RpcLocal.include,
      );
      builder.setJoinRequest(const StringCodec());
      final schema = builder.build();
      final clock = ManualClock();
      final network = InMemoryNetwork(clock: clock);
      final host = MultiplayerSession(schema: schema, clock: clock)
        ..host(network.host());
      final completion = Completer<Admission>();
      host.onJoinRequest = (_) => completion.future;
      final client = MultiplayerSession(schema: schema, clock: clock)
        ..join(network.connect(), request: 'Ada');
      addTearDown(host.close);
      addTearDown(client.close);
      final hostBoard = host.staticEntity(board);
      final clientBoard = client.staticEntity(board);
      var hostScore = 7;
      var clientScore = 0;
      final hostCalls = <int>[];
      final clientCalls = <int>[];
      host.attachEntity(hostBoard, isReady: () => true, isValid: () => true)
        ..synchronize([scoreField.property(get: () => hostScore)])
        ..bindRpc(announce, (_, value) => hostCalls.add(value));
      client.attachEntity(clientBoard, isReady: () => true, isValid: () => true)
        ..synchronize([
          scoreField.property(
            get: () => clientScore,
            set: (value) => clientScore = value,
          ),
        ])
        ..bindRpc(announce, (_, value) => clientCalls.add(value));

      void run() {
        for (var i = 0; i < 6; i++) {
          clock.advance(Duration.zero);
          host.update();
          client.update();
        }
      }

      run();
      host.captureState();
      hostScore = 11;
      clock.advance(const Duration(seconds: 1));
      host.captureState();
      expect(host.callRpc(hostBoard, announce, 1), isTrue);
      run();

      expect(client.state, SessionState.handshaking);
      expect(clientBoard.id, hostBoard.id);
      expect(clientScore, 0);
      expect(hostCalls, [1]);
      expect(clientCalls, isEmpty);
      expect(host.diagnostics.sent.messages, 0);
      expect(client.diagnostics.received.messages, 0);
      expect(host.peers, isEmpty);

      completion.complete(const Admission.admit());
      await Future<void>.value();
      run();

      expect(client.state, SessionState.ready);
      expect(clientScore, 11);
      expect(clientCalls, isEmpty);
      expect(client.diagnostics.received[MessageKind.state].messages, 1);
      expect(client.diagnostics.received[MessageKind.spawn].messages, 0);

      expect(host.callRpc(hostBoard, announce, 2), isTrue);
      run();

      expect(clientCalls, [2]);
    });

    test(
      'receives no traffic and takes its baseline only after admission',
      () async {
        final harness = _Harness();
        final completion = Completer<Admission>();
        harness.host.onJoinRequest = (_) => completion.future;
        final removed = harness.host.spawn(harness.definitions.avatar, 'old');
        final raw = harness.rawClient();
        harness.run();
        raw.hello();
        harness.run();
        harness.host.despawn(removed);
        final current = harness.host.spawn(
          harness.definitions.avatar,
          'current',
        );
        var health = 42;
        final announcements = <int>[];
        final attachment = harness.host.attachEntity(
          current,
          isReady: () => true,
          isValid: () => true,
        );
        attachment.synchronize([
          harness.definitions.health.property(
            get: () => health,
            set: (value) => health = value,
          ),
        ]);
        attachment.bindRpc(
          harness.definitions.announce,
          (_, value) => announcements.add(value),
        );
        harness.run();
        harness.host.captureState();
        health = 17;
        harness.clock.advance(const Duration(seconds: 2));
        harness.host.captureState();
        expect(
          harness.host.callRpc(current, harness.definitions.announce, 7),
          isTrue,
        );
        harness.run();

        expect(raw.received, isEmpty);
        expect(announcements, [7]);
        expect(harness.host.peers, isEmpty);
        expect(harness.host.diagnostics.pendingConnections, 1);
        expect(_drain(harness.host), isEmpty);

        completion.complete(const Admission.admit());
        await Future<void>.value();

        expect(harness.host.peers, isEmpty);
        expect(_drain(harness.host), isEmpty);
        raw.update();
        expect(raw.received, isEmpty);

        harness.run();

        expect(raw.received.map((message) => message.kind), [
          MessageKind.welcome,
          MessageKind.spawn,
          MessageKind.state,
          MessageKind.synced,
        ]);
        expect(raw.received.whereType<SpawnMessage>().single.data, 'current');
        expect(raw.received.whereType<StateMessage>().single.values, {
          harness.definitions.health.id: 17,
        });
        expect(harness.host.peers, [_firstClient]);
        expect(_drain(harness.host), [const PeerJoined(_firstClient)]);
      },
    );

    test(
      'concurrent decisions preserve identities when completed out of order',
      () async {
        final harness = _Harness();
        final decisions = <PeerId, Completer<Admission>>{};
        harness.host.onJoinRequest = (request) {
          final decision = Completer<Admission>();
          decisions[request.peer] = decision;
          return decision.future;
        };
        final first = harness.join();
        final second = harness.join();
        harness.run();
        expect(decisions.keys, [_firstClient, _secondClient]);

        decisions[_secondClient]!.complete(const Admission.admit());
        await Future<void>.value();
        harness.run();

        expect(first.state, SessionState.handshaking);
        expect(second.state, SessionState.ready);
        expect(second.localPeer, _secondClient);
        expect(harness.host.peers, [_secondClient]);

        decisions[_firstClient]!.complete(const Admission.admit());
        await Future<void>.value();
        harness.run();

        expect(first.state, SessionState.ready);
        expect(first.localPeer, _firstClient);
        expect(
          harness.host.peers,
          unorderedEquals([_firstClient, _secondClient]),
        );
      },
    );

    test('async rejection is applied only at an update boundary', () async {
      final harness = _Harness();
      final completion = Completer<Admission>();
      harness.host.onJoinRequest = (_) => completion.future;
      final client = harness.join();
      harness.run();

      completion.complete(Admission.reject('Not on the guest list.'));
      await Future<void>.value();
      client.update();
      expect(client.state, SessionState.handshaking);
      expect(client.rejectionReason, isNull);
      expect(_drain(harness.host), isEmpty);

      harness.run();

      expect(client.disconnectReason, DisconnectReason.rejected);
      expect(client.rejectionReason, 'Not on the guest list.');
      expect(_drain(harness.host), isEmpty);
    });

    test('async failure is contained and reported only on update', () async {
      final harness = _Harness();
      final completion = Completer<Admission>();
      final error = StateError('token lookup failed');
      final stackTrace = StackTrace.current;
      harness.host.onJoinRequest = (_) => completion.future;
      final client = harness.join();
      harness.run();

      completion.completeError(error, stackTrace);
      await Future<void>.value();
      expect(_drain(harness.host), isEmpty);
      expect(client.state, SessionState.handshaking);

      harness.run();

      final events = _drain(harness.host);
      final failure = events.whereType<AdmissionFailed>().single;
      expect(events, hasLength(1));
      expect(failure.peer, _firstClient);
      expect(failure.error, same(error));
      expect(failure.stackTrace, same(stackTrace));
      expect(client.disconnectReason, DisconnectReason.rejected);
      expect(client.rejectionReason, isNull);
      expect(harness.host.peers, isEmpty);
    });

    test('handshake timeout includes the pending decision', () async {
      final harness = _Harness(
        timeouts: const SessionTimeouts(handshake: Duration(seconds: 3)),
      );
      final completion = Completer<Admission>();
      harness.host.onJoinRequest = (_) => completion.future;
      final client = harness.join();
      harness.run();

      harness.clock.advance(const Duration(seconds: 3));
      harness.run();

      expect(client.disconnectReason, DisconnectReason.timeout);
      expect(harness.host.diagnostics.pendingConnections, 0);
      expect(harness.host.peers, isEmpty);
      expect(_drain(harness.host), isEmpty);

      completion.complete(const Admission.admit());
      await Future<void>.value();
      harness.run();

      expect(harness.host.peers, isEmpty);
      expect(_drain(harness.host), isEmpty);
      expect(client.disconnectReason, DisconnectReason.timeout);
    });

    test(
      'a queued disconnect takes precedence over a completed decision',
      () async {
        final harness = _Harness();
        final completion = Completer<Admission>();
        harness.host.onJoinRequest = (_) => completion.future;
        final client = harness.join();
        harness.run();

        completion.complete(const Admission.admit());
        await Future<void>.value();
        client.close();
        harness.run();

        expect(harness.host.peers, isEmpty);
        expect(harness.host.diagnostics.pendingConnections, 0);
        expect(_drain(harness.host), isEmpty);
      },
    );

    for (final fails in [false, true]) {
      test(
        'ignores ${fails ? 'failed' : 'successful'} decisions after client disconnect',
        () async {
          final harness = _Harness();
          final completion = Completer<Admission>();
          harness.host.onJoinRequest = (_) => completion.future;
          final client = harness.join();
          harness.run();
          client.close();
          harness.run();
          expect(harness.host.peers, isEmpty);
          expect(_drain(harness.host), isEmpty);

          if (fails) {
            completion.completeError(
              StateError('client left'),
              StackTrace.current,
            );
          } else {
            completion.complete(const Admission.admit());
          }
          await Future<void>.value();
          harness.run();

          expect(harness.host.peers, isEmpty);
          expect(_drain(harness.host), isEmpty);
          expect(harness.host.state, SessionState.hosting);
        },
      );

      test(
        'ignores ${fails ? 'failed' : 'successful'} decisions from an earlier session',
        () async {
          final harness = _Harness();
          final oldDecision = Completer<Admission>();
          harness.host.onJoinRequest = (_) => oldDecision.future;
          harness.join();
          harness.run();
          harness.host
            ..close()
            ..host(harness.network.host());
          _drain(harness.host);

          final newDecision = Completer<Admission>();
          harness.host.onJoinRequest = (_) => newDecision.future;
          final newClient = harness.join();
          harness.run();
          if (fails) {
            oldDecision.completeError(
              StateError('old session'),
              StackTrace.current,
            );
          } else {
            oldDecision.complete(const Admission.admit());
          }
          await Future<void>.value();
          harness.run();

          expect(newClient.state, SessionState.handshaking);
          expect(harness.host.peers, isEmpty);
          expect(_drain(harness.host), isEmpty);

          newDecision.complete(const Admission.admit());
          await Future<void>.value();
          harness.run();

          expect(newClient.state, SessionState.ready);
          expect(newClient.localPeer, _firstClient);
          expect(harness.host.peers, [_firstClient]);
        },
      );
    }
  });

  group('admission gate', () {
    test(
      'rejects new requests without invoking the handler and can reopen',
      () {
        final harness = _Harness();
        var calls = 0;
        harness.host
          ..admitting = false
          ..onJoinRequest = (_) {
            calls++;
            return const Admission.admit();
          };
        final rejected = harness.join();
        harness.run();

        expect(rejected.disconnectReason, DisconnectReason.notAdmitting);
        expect(rejected.rejectionReason, isNull);
        expect(calls, 0);
        expect(harness.host.peers, isEmpty);
        expect(_drain(harness.host), isEmpty);

        harness.host.admitting = true;
        final accepted = harness.join();
        harness.run();

        expect(calls, 1);
        expect(accepted.state, SessionState.ready);
      },
    );

    test(
      'closing the gate leaves accepted peers and pending decisions alone',
      () async {
        final harness = _Harness();
        final accepted = harness.join();
        harness.run();
        _drain(harness.host);
        final completion = Completer<Admission>();
        var calls = 0;
        harness.host.onJoinRequest = (_) {
          calls++;
          return completion.future;
        };
        final pending = harness.join();
        harness.run();

        harness.host.admitting = false;
        final rejected = harness.join();
        harness.run();
        expect(rejected.disconnectReason, DisconnectReason.notAdmitting);
        expect(calls, 1);
        expect(accepted.state, SessionState.ready);
        expect(pending.state, SessionState.handshaking);

        completion.complete(const Admission.admit());
        await Future<void>.value();
        harness.run();

        expect(pending.state, SessionState.ready);
        expect(accepted.state, SessionState.ready);
        expect(harness.host.peers, [accepted.localPeer, pending.localPeer]);
        expect(_drain(harness.host), [
          PeerJoined(pending.localPeer!),
          PeerReady(pending.localPeer!),
        ]);
      },
    );
  });

  group('request validation', () {
    test(
      'schema mismatch is rejected before request decoding and admission',
      () {
        final harness = _Harness();
        var calls = 0;
        harness.host.onJoinRequest = (_) {
          calls++;
          return const Admission.admit();
        };
        final raw = harness.rawClient();
        harness.run();
        raw.hello(
          fingerprint: _Schema(withRequest: false).schema.fingerprint,
          request: 'invalid for the host codec',
        );

        harness.run();

        expect(calls, 0);
        expect(raw.received, [
          isA<GoodbyeMessage>().having(
            (message) => message.reason,
            'reason',
            GoodbyeReason.schemaMismatch,
          ),
        ]);
        expect(_drain(harness.host), isEmpty);
      },
    );

    for (final request in <Object?>[
      null,
      'wrong type',
      [10],
      [1, 2, 3, 4, 5],
    ]) {
      test('malformed request $request never reaches admission', () {
        final harness = _Harness();
        var calls = 0;
        harness.host.onJoinRequest = (_) {
          calls++;
          return const Admission.admit();
        };
        final raw = harness.rawClient();
        harness.run();
        raw.hello(request: request);

        harness.run();

        expect(calls, 0);
        expect(raw.received, [
          isA<GoodbyeMessage>().having(
            (message) => message.reason,
            'reason',
            GoodbyeReason.protocolViolation,
          ),
        ]);
        expect(harness.host.peers, isEmpty);
        expect(_drain(harness.host), isEmpty);
      });
    }

    test('a request is forbidden when the schema sets no codec', () {
      final harness = _Harness(withRequest: false);
      var calls = 0;
      harness.host.onJoinRequest = (_) {
        calls++;
        return const Admission.admit();
      };
      final raw = harness.rawClient();
      harness.run();
      raw.hello(request: 'unexpected');

      harness.run();

      expect(calls, 0);
      expect(
        raw.received.whereType<GoodbyeMessage>().single.reason,
        GoodbyeReason.protocolViolation,
      );
      expect(harness.host.peers, isEmpty);
    });

    test(
      'invalid local data leaves the session and transport available to join',
      () {
        final harness = _Harness();
        final client = harness.session();
        final transport = harness.network.connect();

        expect(
          () => client.join(transport, request: 'wrong type'),
          throwsArgumentError,
        );
        expect(client.state, SessionState.disconnected);
        expect(_drain(client), isEmpty);

        client.join(transport, request: [1]);
        harness.run();

        expect(client.state, SessionState.ready);
      },
    );
  });

  group('rejection reason lifecycle', () {
    test('clears the reason when a rejected session joins again', () {
      final harness = _Harness();
      harness.host.onJoinRequest = (_) => Admission.reject('Try again.');
      final client = harness.join();
      harness.run();
      expect(client.rejectionReason, 'Try again.');

      harness.host.onJoinRequest = null;
      client.join(harness.network.connect(), request: [1]);
      expect(client.rejectionReason, isNull);
      harness.run();
      expect(client.state, SessionState.ready);

      client.close();
      expect(client.disconnectReason, DisconnectReason.closed);
      expect(client.rejectionReason, isNull);
    });

    test('clears the reason when a rejected session starts hosting', () {
      final harness = _Harness();
      harness.host.onJoinRequest = (_) => Admission.reject('Denied.');
      final client = harness.join();
      harness.run();
      expect(client.rejectionReason, 'Denied.');

      client.host(InMemoryNetwork(clock: harness.clock).host());

      expect(client.state, SessionState.hosting);
      expect(client.disconnectReason, isNull);
      expect(client.rejectionReason, isNull);
    });
  });
}
