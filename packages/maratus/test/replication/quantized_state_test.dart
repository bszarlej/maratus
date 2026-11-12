import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

void main() {
  test('quantized onChange fields skip motion within the same grid step', () {
    final clock = ManualClock();
    final network = InMemoryNetwork(clock: clock);
    final builder = ProtocolSchemaBuilder();
    final position = builder.addField(
      const FieldId('position.x'),
      QuantizedDoubleCodec(min: -100, max: 100, step: 0.25),
    );
    final schema = builder.build();
    final host = MultiplayerSession(schema: schema, clock: clock)
      ..host(network.host());
    final client = MultiplayerSession(schema: schema, clock: clock)
      ..join(network.connect());
    addTearDown(host.close);
    addTearDown(client.close);

    void deliver() {
      for (var i = 0; i < 6; i++) {
        clock.advance(Duration.zero);
        host.update();
        client.update();
      }
    }

    deliver();
    expect(client.state, SessionState.ready);
    final authority = host.registry.register(
      const EntityId(1),
      owner: PeerId.host,
      authority: PeerId.host,
    );
    final replica = client.registry.register(
      const EntityId(1),
      owner: PeerId.host,
      authority: PeerId.host,
    );
    var local = 1.01;
    final received = <double>[];
    host
        .attachEntity(authority, isReady: () => true, isValid: () => true)
        .synchronize([position.property(get: () => local)]);
    client
        .attachEntity(replica, isReady: () => true, isValid: () => true)
        .synchronize([position.property(get: () => 0, set: received.add)]);

    void capture() {
      clock.advance(const Duration(milliseconds: 100));
      host.captureState();
      deliver();
    }

    capture();
    expect(received, [1.0]);
    final revision = host.revision;

    local = 1.12;
    capture();
    expect(received, [1.0]);
    expect(host.revision, revision);
    expect(local, 1.12);

    local = 1.13;
    capture();
    expect(received, [1.0, 1.25]);
    expect(host.revision, greaterThan(revision));

    final joiner = MultiplayerSession(schema: schema, clock: clock)
      ..join(network.connect());
    addTearDown(joiner.close);
    final lateEntity = joiner.registry.register(
      const EntityId(1),
      owner: PeerId.host,
      authority: PeerId.host,
    );
    final lateValues = <double>[];
    joiner
        .attachEntity(lateEntity, isReady: () => true, isValid: () => true)
        .synchronize([position.property(get: () => 0, set: lateValues.add)]);
    for (var i = 0; i < 8; i++) {
      clock.advance(Duration.zero);
      host.update();
      client.update();
      joiner.update();
    }
    expect(joiner.state, SessionState.ready);
    expect(lateValues, [1.25]);
  });
}
