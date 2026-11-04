import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

List<SessionEvent> _events(MultiplayerSession session) => [
  for (var event = session.poll(); event != null; event = session.poll()) event,
];

void main() {
  test('public API supports a host and two clients through reconnect', () {
    final clock = ManualClock();
    final network = InMemoryNetwork(clock: clock);
    final builder = ProtocolSchemaBuilder()
      ..addSpawnType(const SpawnTypeId('player'), const StringCodec());
    final health = builder.addField(
      const FieldId('player.health'),
      const IntCodec(min: 0),
    );
    final move = builder.addRpc(
      const RpcId('player.move'),
      const IntCodec(min: -1, max: 1),
      caller: RpcCaller.owner,
    );
    final schema = builder.build();
    final hostMessages = <(PeerId, int)>[];
    final clientMessages = <(PeerId, MessageEnvelope)>[];
    final host = MultiplayerSession(schema: schema, clock: clock)
      ..host(network.host());
    final first = MultiplayerSession(
      schema: schema,
      clock: clock,
      onMessage: (sender, envelope) => clientMessages.add((sender, envelope)),
    )..join(network.connect());
    final second = MultiplayerSession(schema: schema, clock: clock)
      ..join(network.connect());
    addTearDown(host.close);
    addTearDown(first.close);
    addTearDown(second.close);

    void updateAll() {
      for (var i = 0; i < 6; i++) {
        clock.advance(Duration.zero);
        host.update();
        first.update();
        second.update();
      }
    }

    expect(first.state, SessionState.connecting);
    updateAll();
    expect(host.localPeer, PeerId.host);
    expect(host.state, SessionState.hosting);
    expect(first.state, SessionState.ready);
    expect(second.state, SessionState.ready);
    expect(first.epoch, host.epoch);
    expect(second.epoch, host.epoch);
    expect(first.localPeer, isNot(second.localPeer));
    final firstId = first.localPeer!;
    final secondId = second.localPeer!;
    final firstGeneration = first.generation;
    expect(host.peers, [firstId, secondId]);
    expect(host.isReady(firstId), isTrue);
    expect(host.isReady(secondId), isTrue);
    expect(_events(first), const [
      SessionStateChanged(SessionState.connecting),
      SessionStateChanged(SessionState.handshaking),
      SessionStateChanged(SessionState.synchronizing),
      SessionStateChanged(SessionState.ready),
    ]);
    expect(
      _events(host),
      containsAllInOrder([
        const SessionStateChanged(SessionState.hosting),
        PeerJoined(firstId),
        PeerJoined(secondId),
        PeerReady(firstId),
        PeerReady(secondId),
      ]),
    );

    final entity = host.registry.create(owner: firstId, authority: PeerId.host);
    expect(entity.state, EntityState.pending);
    expect(host.registry.markReady(entity.id), isTrue);
    expect(entity.state, EntityState.ready);
    expect(host.registry.ownedBy(firstId), [entity]);
    expect(first.registry.entities, isEmpty);
    var hostHealth = 80;
    final hostAttachment = host.attachEntity(
      entity,
      isReady: () => true,
      isValid: () => true,
    );
    hostAttachment
      ..bindRpc(
        move,
        (context, payload) => hostMessages.add((context.sender, payload)),
      )
      ..synchronize([health.property(get: () => hostHealth)]);

    final replica = first.registry.register(
      entity.id,
      owner: firstId,
      authority: PeerId.host,
    );
    var replicaHealth = 0;
    first
        .attachEntity(replica, isReady: () => true, isValid: () => true)
        .synchronize([
          health.property(
            get: () => replicaHealth,
            set: (value) => replicaHealth = value,
          ),
        ]);
    final inputAccepted = first.callRpc(replica, move, 1);
    expect(inputAccepted, isTrue);
    host.captureState();
    final revision = host.revision;
    updateAll();
    expect(hostMessages, hasLength(1));
    expect(hostMessages.single.$1, firstId);
    expect(hostMessages.single.$2, 1);
    expect(replicaHealth, 80);
    expect(clientMessages, hasLength(1));
    expect(clientMessages.single.$1, PeerId.host);
    expect(clientMessages.single.$2.message, isA<StateMessage>());
    expect(first.revision, revision);

    expect(host.kick(secondId), isTrue);
    updateAll();
    expect(second.state, SessionState.disconnected);
    expect(second.disconnectReason, DisconnectReason.kicked);
    expect(
      _events(host),
      contains(PeerLeft(secondId, DisconnectReason.kicked)),
    );

    first.close();
    expect(first.state, SessionState.disconnected);
    expect(first.disconnectReason, DisconnectReason.closed);
    expect(first.registry.entities, isEmpty);
    expect(replica.state, EntityState.removed);
    updateAll();
    first.join(network.connect());
    expect(first.registry.entities, isEmpty);
    expect(replica.state, EntityState.removed);
    updateAll();
    expect(first.state, SessionState.ready);
    expect(first.localPeer, isNot(firstId));
    expect(first.generation, isNot(firstGeneration));
    expect(first.epoch, host.epoch);
    expect(first.revision, revision);

    host.close();
    expect(host.state, SessionState.disconnected);
    updateAll();
    expect(first.state, SessionState.disconnected);
    expect(first.disconnectReason, DisconnectReason.remoteClosed);
  });
}
