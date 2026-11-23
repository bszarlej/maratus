import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

const _tick = Duration(milliseconds: 50);

List<SessionEvent> _drain(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

/// Moves one unit per tick in the direction of the input.
double _walk(double position, int input) => position + input;

/// The registrations shared by every session of a test: an avatar whose
/// owner aims and moves it, and whose authority keeps a score.
final class _Schema {
  _Schema() {
    final builder = ProtocolSchemaBuilder();
    avatar = builder.addSpawnType(
      const SpawnTypeId('test.avatar'),
      const BoolCodec(),
    );
    position = builder.addField(
      const FieldId('test.position'),
      const DoubleCodec(min: -1000, max: 1000),
    );
    score = builder.addField(
      const FieldId('test.score'),
      const IntCodec(min: 0, max: 1000),
    );
    aim = builder.addField(
      const FieldId('test.aim'),
      const IntCodec(min: -9, max: 9),
      writer: FieldWriter.owner,
    );
    move = builder.addInput(
      const InputId('test.move'),
      const IntCodec(min: -1, max: 1),
      tick: _tick,
    );
    nudge = builder.addInput(
      const InputId('test.nudge'),
      const IntCodec(min: -1, max: 1),
      tick: _tick,
      deliveryMode: DeliveryMode.unreliable,
      channel: 1,
    );
    fire = builder.addRpc(
      const RpcId('test.fire'),
      const IntCodec(min: 0, max: 9),
      caller: RpcCaller.owner,
    );
    notify = builder.addRpc(
      const RpcId('test.notify'),
      const IntCodec(min: 0, max: 9),
      caller: RpcCaller.host,
      target: RpcTarget.owner,
    );
    board = builder.addStaticEntity(const StaticEntityId('test.board'));
    schema = builder.build();
  }

  late final SpawnType<bool> avatar;
  late final SyncField<double> position;
  late final SyncField<int> score;
  late final SyncField<int> aim;
  late final InputStream<int> move;
  late final InputStream<int> nudge;
  late final Rpc<int> fire;
  late final Rpc<int> notify;
  late final StaticEntity board;
  late final ProtocolSchema schema;
}

/// One peer's copy of an avatar: its owner writes [aim] and predicts its
/// position from its inputs, and its authority writes [score].
final class _Avatar {
  _Avatar(this.session, this.entity, _Schema schema) {
    attachment = session.attachEntity(
      entity,
      isReady: () => true,
      isValid: () => true,
    );
    prediction = attachment.predict(
      state: schema.position,
      input: schema.move,
      initial: 0,
      step: _walk,
    );
    synchronizer = attachment.synchronize([
      prediction.property(),
      schema.score.property(get: () => score, set: (value) => score = value),
      schema.aim.property(get: () => aim, set: (value) => aim = value),
    ], interval: _tick);
    attachment
      ..bindRpc(schema.fire, (context, value) => fired.add(context.sender))
      ..bindRpc(schema.notify, (_, value) => notified.add(value));
  }

  final MultiplayerSession session;
  final NetworkEntity entity;
  late final EntityAttachment attachment;
  late final Predictor<double, int> prediction;
  late final MultiplayerSynchronizer synchronizer;
  var score = 0;
  var aim = 0;

  /// The input that the owner applies each frame while it [drives].
  var input = 0;

  /// Whether this peer advances the prediction each frame it owns the
  /// avatar.
  var drives = false;

  /// The senders of the fire RPCs that this peer handled.
  final fired = <PeerId>[];

  /// The payloads of the notify RPCs that this peer handled.
  final notified = <int>[];

  bool get owns => entity.owner == session.localPeer;
}

/// A host and the clients that join it over an in-memory network, each
/// with an avatar for every spawned entity.
final class _Harness {
  _Harness() {
    network = InMemoryNetwork(
      clock: clock,
      deliveryModes: DeliveryMode.values.toSet(),
      channelCount: 2,
    );
    host = _session()..host(network.host());
  }

  final clock = ManualClock();
  final schema = _Schema();
  late final InMemoryNetwork network;
  late final MultiplayerSession host;
  final sessions = <MultiplayerSession>[];
  final _raw = <_RawClient>[];
  final _avatars = <MultiplayerSession, Map<EntityId, _Avatar>>{};

  MultiplayerSession _session() {
    final session = MultiplayerSession(schema: schema.schema, clock: clock);
    addTearDown(session.close);
    sessions.add(session);
    session.bindSpawn(
      schema.avatar,
      onSpawn: (context) => (_avatars[session] ??= {})[context.entity.id] =
          _Avatar(session, context.entity, schema),
      onDespawn: (entity) => _avatars[session]?.remove(entity.id),
    );
    return session;
  }

  /// Starts joining a new client without waiting for it.
  MultiplayerSession startJoin() => _session()..join(network.connect());

  /// Joins a new client and runs frames until it is ready.
  MultiplayerSession join() {
    final session = startJoin();
    until(
      () =>
          session.state == SessionState.ready &&
          host.isReady(session.localPeer!),
    );
    return session;
  }

  /// Joins a client that speaks the protocol directly and reports ready.
  _RawClient rawClient() {
    final client = _RawClient(network.connect(), ProtocolCodec(schema.schema));
    _raw.add(client);
    until(() => client.connection != null);
    client.send(HelloMessage(fingerprint: schema.schema.fingerprint));
    until(() => client.id != null);
    client.ready();
    until(() => host.isReady(client.id!));
    return client;
  }

  /// Spawns an avatar owned by [owner] and runs frames until every
  /// connected session has it.
  NetworkEntity spawn(
    PeerId owner, {
    PeerId authority = PeerId.host,
    NetworkEntity? parent,
    OwnerLeftPolicy onOwnerLeft = OwnerLeftPolicy.keep,
    bool publicVisibility = true,
  }) {
    final entity = host.spawn(
      schema.avatar,
      true,
      owner: owner,
      authority: authority,
      parent: parent,
      onOwnerLeft: onOwnerLeft,
      publicVisibility: publicVisibility,
    );
    frames(2);
    return entity;
  }

  /// [session]'s avatar of [entity].
  _Avatar avatar(MultiplayerSession session, NetworkEntity entity) =>
      _avatars[session]![entity.id]!;

  /// Whether [session] has an avatar of [entity].
  bool has(MultiplayerSession session, NetworkEntity entity) =>
      _avatars[session]?.containsKey(entity.id) ?? false;

  /// [session]'s copy of [entity].
  NetworkEntity on(MultiplayerSession session, NetworkEntity entity) =>
      session.registry[entity.id]!;

  /// The connected sessions.
  Iterable<MultiplayerSession> get live =>
      sessions.where((session) => session.state != SessionState.disconnected);

  /// Runs one frame: the clock advances, every session that is not
  /// [stalled] updates, each owner that drives its avatar advances its
  /// prediction, and every session that is not [stalled] captures state.
  void frame({Set<MultiplayerSession> stalled = const {}}) {
    clock.advance(_tick);
    for (final client in _raw) {
      client.update();
    }
    for (final session in sessions) {
      if (!stalled.contains(session)) session.update();
    }
    for (final session in sessions) {
      if (stalled.contains(session)) continue;
      for (final avatar in [...?_avatars[session]?.values]) {
        if (avatar.drives && avatar.owns) {
          avatar.prediction.advance(avatar.input, _tick);
        }
      }
    }
    for (final session in sessions) {
      if (!stalled.contains(session)) session.captureState();
    }
  }

  void frames(int count, {Set<MultiplayerSession> stalled = const {}}) {
    for (var i = 0; i < count; i++) {
      frame(stalled: stalled);
    }
  }

  /// Runs frames until [done] holds, failing after [limit] frames.
  void until(bool Function() done, {int limit = 200}) {
    for (var i = 0; i < limit; i++) {
      if (done()) return;
      frame();
    }
    if (!done()) fail('The condition did not hold within $limit frames.');
  }

  /// Expects every connected session to agree on [entity]'s owner and
  /// authority and on its replicated state, after the owner stopped
  /// driving and the inputs settled.
  void expectAgreement(
    NetworkEntity entity, {
    required PeerId owner,
    PeerId authority = PeerId.host,
  }) {
    frames(20);
    final reference = avatar(host, entity);
    expect(entity.owner, owner);
    expect(entity.authority, authority);
    for (final session in live) {
      final reason = 'on peer ${session.localPeer?.value}';
      final copy = on(session, entity);
      final avatar = this.avatar(session, entity);
      expect(copy.owner, owner, reason: reason);
      expect(copy.authority, authority, reason: reason);
      expect(
        avatar.prediction.state,
        reference.prediction.state,
        reason: reason,
      );
      expect(avatar.score, reference.score, reason: reason);
      expect(avatar.aim, reference.aim, reason: reason);
      expect(avatar.prediction.pendingInputs, 0, reason: reason);
    }
  }
}

/// A client that speaks the protocol directly, to send what a session would
/// not.
final class _RawClient {
  _RawClient(this.peer, this.codec);

  final InMemoryClient peer;
  final ProtocolCodec codec;
  PeerConnection? connection;
  PeerId? id;
  var generation = 0;
  var baseline = 0;
  var closed = false;
  final received = <MessageEnvelope>[];

  void update() {
    for (var event = peer.poll(); event != null; event = peer.poll()) {
      switch (event) {
        case ConnectionOpened(:final connection):
          this.connection = connection;
        case MessageReceived(:final message):
          for (final envelope in codec.decodePacket(message)) {
            if (envelope.message case WelcomeMessage(:final peer)) {
              id = peer;
              generation = envelope.generation;
              baseline = envelope.revision;
            }
            received.add(envelope);
          }
        case ConnectionClosed():
          closed = true;
      }
    }
  }

  /// The revision of the latest ownership transfer that this client
  /// received.
  int get transferRevision => received
      .lastWhere((envelope) => envelope.message is OwnershipMessage)
      .revision;

  void send(
    ProtocolMessage message, {
    int revision = 0,
    DeliveryMode mode = DeliveryMode.reliable,
    int channel = 0,
  }) => connection!.send(
    codec.encode(
      MessageEnvelope(message, generation: generation, revision: revision),
    ),
    mode: mode,
    channel: channel,
  );

  void ready() => send(const ReadyMessage(), revision: baseline);

  void sendAim(NetworkEntity entity, int aim, {int revision = 0}) => send(
    StateMessage(
      entity: entity.id,
      values: {const FieldId('test.aim'): aim},
      sampledAt: Duration.zero,
    ),
    revision: revision,
  );

  void sendInputs(NetworkEntity entity, int sequence, List<int> values) => send(
    InputMessage(
      entity: entity.id,
      input: const InputId('test.move'),
      sequence: sequence,
      values: values,
    ),
  );
}

void main() {
  group('transferOwnership', () {
    test("moves an entity's owner on every peer", () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      final avatar = harness.spawn(first.localPeer!);
      harness.sessions.forEach(_drain);

      expect(harness.host.transferOwnership(avatar, second.localPeer!), isTrue);
      harness.frames(2);

      for (final session in harness.sessions) {
        expect(harness.on(session, avatar).owner, second.localPeer);
        expect(harness.on(session, avatar).authority, PeerId.host);
        expect(_drain(session).whereType<OwnerChanged>(), [
          OwnerChanged(
            entity: avatar.id,
            previous: first.localPeer!,
            owner: second.localPeer!,
          ),
        ]);
      }
      expect(harness.host.registry.ownedBy(second.localPeer!), [avatar]);
      expect(harness.host.registry.ownedBy(first.localPeer!), isEmpty);
      expect(
        harness.host.transferOwnership(avatar, second.localPeer!),
        isFalse,
      );
      harness.frames(2);
      for (final session in harness.sessions) {
        expect(_drain(session).whereType<OwnerChanged>(), isEmpty);
      }
    });

    test('moves the ownership of a static entity', () {
      final harness = _Harness();
      final client = harness.join();
      final board = harness.host.staticEntity(harness.schema.board);
      harness.sessions.forEach(_drain);

      harness.host.transferOwnership(board, client.localPeer!);
      harness.frames(2);

      expect(client.staticEntity(harness.schema.board).owner, client.localPeer);
      expect(_drain(client).whereType<OwnerChanged>(), [
        OwnerChanged(
          entity: board.id,
          previous: PeerId.host,
          owner: client.localPeer!,
        ),
      ]);
    });

    test('hands the entity to the host', () {
      final harness = _Harness();
      final client = harness.join();
      final avatar = harness.spawn(client.localPeer!);
      harness.avatar(client, avatar)
        ..drives = true
        ..input = 1;
      harness.frames(5);
      harness.avatar(client, avatar).drives = false;
      harness.frames(5);

      harness.host.transferOwnership(avatar, PeerId.host);
      harness.frames(2);
      harness.avatar(harness.host, avatar)
        ..drives = true
        ..input = -1;
      harness.frames(3);
      harness.avatar(harness.host, avatar).drives = false;

      harness.expectAgreement(avatar, owner: PeerId.host);
      expect(harness.avatar(harness.host, avatar).prediction.state, 2);
    });

    test('validates its caller, entity, and owner', () {
      final harness = _Harness();
      final client = harness.join();
      final avatar = harness.spawn(client.localPeer!);

      expect(
        () => client.transferOwnership(
          harness.on(client, avatar),
          client.localPeer!,
        ),
        throwsStateError,
      );
      expect(
        () => harness.host.transferOwnership(avatar, const PeerId(99)),
        throwsArgumentError,
      );
      final pending = harness.startJoin();
      harness.frame();
      expect(pending.state, isNot(SessionState.ready));
      expect(
        () => harness.host.transferOwnership(avatar, const PeerId(3)),
        throwsArgumentError,
      );
      final foreign = EntityRegistry().create(
        owner: PeerId.host,
        authority: PeerId.host,
      );
      expect(
        () => harness.host.transferOwnership(foreign, PeerId.host),
        throwsArgumentError,
      );
      harness.host.addVisibilityFilter((entity, peer) {
        expect(
          () => harness.host.transferOwnership(avatar, PeerId.host),
          throwsStateError,
        );
        return true;
      });
      harness.host.updateVisibility();
      harness.host.despawn(avatar);
      expect(
        () => harness.host.transferOwnership(avatar, PeerId.host),
        throwsArgumentError,
      );
    });

    test('moves the owner-written fields to the new owner', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      final avatar = harness.spawn(first.localPeer!);
      harness.avatar(first, avatar).aim = 3;
      harness.frames(3);
      expect(harness.avatar(second, avatar).aim, 3);

      harness.host.transferOwnership(avatar, second.localPeer!);
      harness.frames(2);
      // The new owner continues from the values it received.
      harness.expectAgreement(avatar, owner: second.localPeer!);
      expect(harness.avatar(harness.host, avatar).aim, 3);

      harness.avatar(second, avatar).aim = -2;
      // The previous owner's local changes no longer replicate.
      harness.avatar(first, avatar).aim = 7;
      harness.frames(3);
      expect(harness.avatar(harness.host, avatar).aim, -2);
      expect(harness.avatar(first, avatar).aim, -2);
      for (final session in harness.sessions) {
        expect(_drain(session).whereType<StateRejected>(), isEmpty);
      }
    });

    test('the new owner applies the latest owner-written values before '
        'sampling its own', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      final avatar = harness.spawn(first.localPeer!);
      harness.avatar(first, avatar).aim = 3;
      harness.frames(3);
      // A local change that the replicated value would have replaced.
      harness.avatar(second, avatar).aim = 8;

      harness.host.transferOwnership(avatar, second.localPeer!);

      harness.expectAgreement(avatar, owner: second.localPeer!);
      expect(harness.avatar(harness.host, avatar).aim, 3);
    });

    test('drops inputs on another lane that the previous owner sent before '
        'the transfer', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      final client = harness.join();
      final avatar = harness.spawn(raw.id!);
      harness.host.transferOwnership(avatar, client.localPeer!);
      harness.frames(2);
      raw.send(
        OwnershipAckMessage(entity: avatar.id),
        revision: raw.transferRevision,
      );
      harness.frames(2);
      harness.sessions.forEach(_drain);

      raw.send(
        InputMessage(
          entity: avatar.id,
          input: harness.schema.nudge.id,
          sequence: 1,
          values: const [1],
        ),
        revision: raw.transferRevision - 1,
        mode: DeliveryMode.unreliable,
        channel: 1,
      );
      harness.frames(2);

      expect(_drain(harness.host), isEmpty);
    });

    test('drops owner-written state that the previous owner sent before '
        'the transfer', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      final avatar = harness.spawn(first.localPeer!);
      harness.frames(2);
      harness.sessions.forEach(_drain);

      harness.avatar(first, avatar).aim = 5;
      harness.frame(stalled: {harness.host});
      harness.host.transferOwnership(avatar, second.localPeer!);

      harness.expectAgreement(avatar, owner: second.localPeer!);
      expect(harness.avatar(harness.host, avatar).aim, 0);
      // The previous owner returns to the value the host accepted.
      expect(harness.avatar(first, avatar).aim, 0);
      expect(_drain(harness.host).whereType<StateRejected>(), isEmpty);
    });

    test('rejects owner-written state and inputs sent after the previous '
        'owner applied the transfer', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      final client = harness.join();
      final avatar = harness.spawn(raw.id!);
      harness.sessions.forEach(_drain);

      harness.host.transferOwnership(avatar, client.localPeer!);
      harness.frames(2);
      harness.sessions.forEach(_drain);
      // Before it acknowledges the transfer, the host drops what it sends.
      raw
        ..sendAim(avatar, 4, revision: raw.transferRevision - 1)
        ..sendInputs(avatar, 1, [1, 1]);
      harness.frames(2);
      expect(_drain(harness.host), isEmpty);

      raw
        ..send(
          OwnershipAckMessage(entity: avatar.id),
          revision: raw.transferRevision,
        )
        ..sendAim(avatar, 4, revision: raw.transferRevision)
        ..sendInputs(avatar, 3, [1]);
      harness.frames(2);
      expect(_drain(harness.host), [
        isA<StateRejected>()
            .having((e) => e.entity, 'entity', avatar.id)
            .having((e) => e.sender, 'sender', raw.id)
            .having((e) => e.reason, 'reason', StateRejection.notOwner),
        isA<InputRejected>()
            .having((e) => e.entity, 'entity', avatar.id)
            .having((e) => e.sender, 'sender', raw.id)
            .having((e) => e.reason, 'reason', InputRejection.notOwner),
      ]);
      expect(harness.avatar(harness.host, avatar).aim, 0);
      expect(harness.avatar(harness.host, avatar).prediction.state, 0);
    });

    test('restarts the input stream with the new owner', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      final avatar = harness.spawn(first.localPeer!);
      harness.avatar(first, avatar)
        ..drives = true
        ..input = 1;
      harness.frames(6);
      harness.sessions.forEach(_drain);

      // The previous owner's inputs of this frame are still in transit.
      harness.frame(stalled: {harness.host});
      final applied = harness.avatar(harness.host, avatar).prediction.state;
      harness.host.transferOwnership(avatar, second.localPeer!);
      harness.avatar(first, avatar).drives = false;
      harness.frames(2);
      expect(harness.avatar(first, avatar).prediction.pendingInputs, 0);

      harness.avatar(second, avatar)
        ..drives = true
        ..input = -1;
      harness.frames(4);
      harness.avatar(second, avatar).drives = false;

      harness.expectAgreement(avatar, owner: second.localPeer!);
      // The host applied none of the previous owner's late inputs, and every
      // input of the new owner once.
      expect(
        harness.avatar(harness.host, avatar).prediction.state,
        applied - 4,
      );
      expect(_drain(harness.host).whereType<InputRejected>(), isEmpty);
    });

    test('keeps prediction running while the new owner drives', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      final avatar = harness.spawn(first.localPeer!);
      harness.avatar(first, avatar)
        ..drives = true
        ..input = 1;
      harness.avatar(second, avatar)
        ..drives = true
        ..input = 1;
      harness.frames(4);

      harness.host.transferOwnership(avatar, second.localPeer!);
      harness.frames(10);
      final predicted = harness.avatar(second, avatar).prediction.state;
      harness.avatar(second, avatar).drives = false;

      harness.expectAgreement(avatar, owner: second.localPeer!);
      // The new owner's prediction ran ahead of the host's state and the
      // host confirmed it.
      expect(harness.avatar(harness.host, avatar).prediction.state, predicted);
    });

    test('routes owner RPCs to and from the new owner', () {
      final harness = _Harness();
      final first = harness.join();
      final second = harness.join();
      final avatar = harness.spawn(first.localPeer!);
      harness.sessions.forEach(_drain);

      // An owner RPC in transit arrives after the transfer.
      first.callRpc(harness.on(first, avatar), harness.schema.fire, 1);
      harness.host.transferOwnership(avatar, second.localPeer!);
      harness.frames(2);
      expect(harness.avatar(harness.host, avatar).fired, isEmpty);
      expect(
        _drain(harness.host).whereType<RpcRejected>().single.reason,
        RpcRejection.notAllowed,
      );

      second.callRpc(harness.on(second, avatar), harness.schema.fire, 2);
      first.callRpc(harness.on(first, avatar), harness.schema.fire, 3);
      harness.host.callRpc(avatar, harness.schema.notify, 4);
      harness.frames(2);

      expect(harness.avatar(harness.host, avatar).fired, [second.localPeer]);
      expect(harness.avatar(second, avatar).notified, [4]);
      expect(harness.avatar(first, avatar).notified, isEmpty);
    });

    group('with the authority', () {
      test('hands over a client-authoritative entity in one change', () {
        final harness = _Harness();
        final first = harness.join();
        final second = harness.join();
        final observer = harness.rawClient();
        final avatar = harness.spawn(
          first.localPeer!,
          authority: first.localPeer!,
        );
        harness.avatar(first, avatar)
          ..drives = true
          ..input = 1
          ..score = 7;
        harness.frames(4);
        harness.avatar(first, avatar).drives = false;
        harness.frames(2);
        observer.received.clear();
        harness.sessions.forEach(_drain);

        expect(
          harness.host.transferOwnership(
            avatar,
            second.localPeer!,
            withAuthority: true,
          ),
          isTrue,
        );
        harness.frames(2);

        expect(
          observer.received
              .map((envelope) => envelope.message)
              .where(
                (message) =>
                    message is AuthorityMessage || message is OwnershipMessage,
              ),
          [
            isA<OwnershipMessage>()
                .having((m) => m.owner, 'owner', second.localPeer)
                .having((m) => m.authority, 'authority', second.localPeer),
          ],
        );
        for (final session in harness.sessions) {
          expect(
            _drain(session).where(
              (event) => event is AuthorityChanged || event is OwnerChanged,
            ),
            [
              AuthorityChanged(
                entity: avatar.id,
                previous: first.localPeer!,
                authority: second.localPeer!,
              ),
              OwnerChanged(
                entity: avatar.id,
                previous: first.localPeer!,
                owner: second.localPeer!,
              ),
            ],
          );
        }
        harness.avatar(second, avatar)
          ..drives = true
          ..input = -1;
        harness.frames(2);
        harness.avatar(second, avatar)
          ..drives = false
          ..score = 9;

        harness.expectAgreement(
          avatar,
          owner: second.localPeer!,
          authority: second.localPeer!,
        );
        expect(harness.avatar(harness.host, avatar).prediction.state, 2);
        expect(harness.avatar(first, avatar).score, 9);
      });

      test('transfers only the authority of an entity that the peer owns', () {
        final harness = _Harness();
        final client = harness.join();
        final avatar = harness.spawn(client.localPeer!);
        harness.sessions.forEach(_drain);

        expect(
          harness.host.transferOwnership(
            avatar,
            client.localPeer!,
            withAuthority: true,
          ),
          isTrue,
        );
        harness.frames(2);

        expect(_drain(client), [
          AuthorityChanged(
            entity: avatar.id,
            previous: PeerId.host,
            authority: client.localPeer!,
          ),
        ]);
        expect(
          harness.host.transferOwnership(
            avatar,
            client.localPeer!,
            withAuthority: true,
          ),
          isFalse,
        );
      });

      test('without it, leaves the authority with the previous owner', () {
        final harness = _Harness();
        final first = harness.join();
        final second = harness.join();
        final avatar = harness.spawn(
          first.localPeer!,
          authority: first.localPeer!,
        );

        harness.host.transferOwnership(avatar, second.localPeer!);
        harness.frames(2);

        for (final session in harness.sessions) {
          expect(harness.on(session, avatar).owner, second.localPeer);
          expect(harness.on(session, avatar).authority, first.localPeer);
        }
      });
    });

    group('with late joiners', () {
      test('a client that joins later receives the current owner', () {
        final harness = _Harness();
        final first = harness.join();
        final second = harness.join();
        final avatar = harness.spawn(first.localPeer!);
        final board = harness.host.staticEntity(harness.schema.board);
        harness.host
          ..transferOwnership(avatar, second.localPeer!)
          ..transferOwnership(board, first.localPeer!);
        harness.frames(2);

        final late = harness.join();

        expect(harness.on(late, avatar).owner, second.localPeer);
        expect(late.staticEntity(harness.schema.board).owner, first.localPeer);
        expect(_drain(late).whereType<OwnerChanged>(), [
          OwnerChanged(
            entity: board.id,
            previous: PeerId.host,
            owner: first.localPeer!,
          ),
        ]);
        harness.expectAgreement(avatar, owner: second.localPeer!);
      });

      test('a client that is joining applies a transfer made meanwhile', () {
        final harness = _Harness();
        final first = harness.join();
        final second = harness.join();
        final avatar = harness.spawn(first.localPeer!);

        final late = harness.startJoin();
        harness.frame();
        expect(late.state, isNot(SessionState.ready));
        harness.host.transferOwnership(avatar, second.localPeer!);
        harness.until(() => late.state == SessionState.ready);

        harness.avatar(second, avatar)
          ..drives = true
          ..input = 1;
        harness.frames(3);
        harness.avatar(second, avatar).drives = false;
        harness.expectAgreement(avatar, owner: second.localPeer!);
        expect(harness.avatar(late, avatar).prediction.state, 3);
      });

      test('the new owner may be a client that joined after the spawn', () {
        final harness = _Harness();
        final first = harness.join();
        final avatar = harness.spawn(first.localPeer!);
        final late = harness.join();

        harness.host.transferOwnership(avatar, late.localPeer!);
        harness.frames(2);
        harness.avatar(late, avatar)
          ..drives = true
          ..input = 1;
        harness.frames(2);
        harness.avatar(late, avatar).drives = false;

        harness.expectAgreement(avatar, owner: late.localPeer!);
      });
    });

    group('when a peer leaves', () {
      test('a reconnecting client reclaims a kept entity', () {
        final harness = _Harness();
        final first = harness.join();
        final avatar = harness.spawn(first.localPeer!);
        harness.avatar(first, avatar)
          ..drives = true
          ..input = 1;
        harness.frames(3);
        first.close();
        harness.frames(2);
        expect(avatar.owner, first.localPeer ?? avatar.owner);

        final returning = harness.join();
        harness.host.transferOwnership(avatar, returning.localPeer!);
        harness.frames(2);
        harness.avatar(returning, avatar)
          ..drives = true
          ..input = -1;
        harness.frames(2);
        harness.avatar(returning, avatar).drives = false;

        harness.expectAgreement(avatar, owner: returning.localPeer!);
        expect(harness.avatar(harness.host, avatar).prediction.state, 1);
      });

      test('a previous owner that leaves does not affect the transfer', () {
        final harness = _Harness();
        final first = harness.join();
        final second = harness.join();
        final avatar = harness.spawn(
          first.localPeer!,
          onOwnerLeft: OwnerLeftPolicy.despawn,
        );

        harness.host.transferOwnership(avatar, second.localPeer!);
        first.close();
        harness.frames(2);

        expect(harness.has(harness.host, avatar), isTrue);
        harness.expectAgreement(avatar, owner: second.localPeer!);
      });

      for (final policy in OwnerLeftPolicy.values) {
        test('a new owner that leaves before applying the transfer leaves '
            'as the owner, with ${policy.name}', () {
          final harness = _Harness();
          final first = harness.join();
          final second = harness.join();
          final third = harness.join();
          final avatar = harness.spawn(first.localPeer!, onOwnerLeft: policy);
          final peer = second.localPeer!;

          harness.host.transferOwnership(avatar, peer);
          harness.frame(stalled: {second});
          second.close();
          harness.frames(2);

          expect(
            harness.has(harness.host, avatar),
            policy == OwnerLeftPolicy.keep,
          );
          for (final session in [harness.host, first, third]) {
            expect(
              harness.has(session, avatar),
              policy == OwnerLeftPolicy.keep,
            );
            if (policy == OwnerLeftPolicy.keep) {
              expect(harness.on(session, avatar).owner, peer);
            }
          }
          if (policy == OwnerLeftPolicy.keep) {
            harness.host.transferOwnership(avatar, third.localPeer!);
            harness.expectAgreement(avatar, owner: third.localPeer!);
          }
        });
      }
    });

    group('visibility', () {
      test('shows the entity to its new owner, and hides it from the '
          'previous one as its visibility decides', () {
        final harness = _Harness();
        final first = harness.join();
        final second = harness.join();
        final avatar = harness.spawn(first.localPeer!, publicVisibility: false);
        expect(harness.has(second, avatar), isFalse);

        harness.host.transferOwnership(avatar, second.localPeer!);
        harness.frames(2);

        expect(harness.has(second, avatar), isTrue);
        expect(harness.on(second, avatar).owner, second.localPeer);
        expect(harness.has(first, avatar), isFalse);
        expect(harness.host.isVisibleTo(avatar, first.localPeer!), isFalse);
        expect(harness.host.isVisibleTo(avatar, second.localPeer!), isTrue);
      });

      test('leaves the owners of its children unchanged', () {
        final harness = _Harness();
        final first = harness.join();
        final second = harness.join();
        final avatar = harness.spawn(first.localPeer!);
        final child = harness.spawn(first.localPeer!, parent: avatar);

        harness.host.transferOwnership(avatar, second.localPeer!);
        harness.frames(2);

        for (final session in harness.sessions) {
          expect(harness.on(session, avatar).owner, second.localPeer);
          expect(harness.on(session, child).owner, first.localPeer);
        }
      });
    });

    test('drops a client that acknowledges a revision not yet assigned', () {
      final harness = _Harness();
      final raw = harness.rawClient();
      final avatar = harness.spawn(raw.id!);
      harness.sessions.forEach(_drain);

      raw.send(
        OwnershipAckMessage(entity: avatar.id),
        revision: harness.host.revision + 1,
      );
      harness.frames(2);

      expect(_drain(harness.host), [
        PeerLeft(raw.id!, DisconnectReason.protocolViolation),
      ]);
    });
  });
}
