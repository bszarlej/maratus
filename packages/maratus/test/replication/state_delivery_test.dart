import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

const _interval = Duration(milliseconds: 50);

NetworkEntity _register(MultiplayerSession session) => session.registry
    .register(const EntityId(1), owner: PeerId.host, authority: PeerId.host);

final class _Schema {
  _Schema({bool staticEntity = false}) {
    final builder = ProtocolSchemaBuilder();
    if (staticEntity) {
      board = builder.addStaticEntity(const StaticEntityId('test.board'));
    }
    for (final (id, mode, channel) in [
      ('health', DeliveryMode.reliable, 0),
      ('score', DeliveryMode.reliable, 0),
      ('x', DeliveryMode.unreliable, 1),
      ('y', DeliveryMode.unreliable, 1),
      ('aim', DeliveryMode.unreliableOrdered, 2),
      ('name', DeliveryMode.reliable, 3),
    ]) {
      fields[id] = builder.addField(
        FieldId('test.$id'),
        const IntCodec(),
        deliveryMode: mode,
        channel: channel,
      );
    }
    schema = builder.build();
  }

  final fields = <String, SyncField<int>>{};
  StaticEntity? board;
  late final ProtocolSchema schema;
}

final class _RecordingPeer implements MultiplayerPeer {
  _RecordingPeer(
    this.peer,
    ProtocolSchema schema, {
    this.maximumUnreliableBytes,
  }) : codec = ProtocolCodec(schema);

  final MultiplayerPeer peer;
  final ProtocolCodec codec;
  final int? maximumUnreliableBytes;
  final received = <(StateMessage, DeliveryMode, int)>[];

  @override
  bool get isHost => peer.isHost;

  @override
  TransportCapabilities get capabilities => TransportCapabilities(
    canHost: peer.capabilities.canHost,
    deliveryModes: peer.capabilities.deliveryModes,
    channelCount: peer.capabilities.channelCount,
    maxUnreliableMessageBytes: maximumUnreliableBytes,
  );

  @override
  PeerEvent? poll() {
    final event = peer.poll();
    if (event case MessageReceived(
      :final message,
      :final mode,
      :final channel,
    )) {
      for (final envelope in codec.decodePacket(message)) {
        if (envelope.message case final StateMessage state) {
          received.add((state, mode, channel));
        }
      }
    }
    return event;
  }

  @override
  void close() => peer.close();
}

final class _Model {
  _Model(MultiplayerSession session, NetworkEntity entity, _Schema schema) {
    attachment = session.attachEntity(
      entity,
      isReady: () => true,
      isValid: () => true,
    );
    synchronizer = attachment.synchronize([
      for (final MapEntry(key: id, value: field) in schema.fields.entries)
        field.property(
          get: () => values[id] ?? 0,
          set: (value) => values[id] = value,
          mode: field.deliveryMode == DeliveryMode.reliable
              ? SyncMode.onChange
              : SyncMode.always,
        ),
    ], interval: _interval);
  }

  final values = <String, int>{};
  late final EntityAttachment attachment;
  late final MultiplayerSynchronizer synchronizer;
}

final class _Harness {
  _Harness() {
    network = InMemoryNetwork(
      clock: clock,
      deliveryModes: DeliveryMode.values.toSet(),
      channelCount: 4,
    );
    host = MultiplayerSession(schema: schema.schema, clock: clock)
      ..host(network.host());
    addTearDown(host.close);
  }

  final schema = _Schema();
  final clock = ManualClock();
  late final InMemoryNetwork network;
  late final MultiplayerSession host;
  final clients = <MultiplayerSession>[];
  final peers = <_RecordingPeer>[];
  final joining = <_Joining>[];

  /// Connects a client that the host welcomes but that never reports ready.
  _Joining startJoining() {
    final client = _Joining(network.connect(), schema.schema);
    joining.add(client);
    addTearDown(client.peer.close);
    return client;
  }

  MultiplayerSession join() {
    final peer = _RecordingPeer(network.connect(), schema.schema);
    final client = MultiplayerSession(schema: schema.schema, clock: clock)
      ..join(peer);
    clients.add(client);
    peers.add(peer);
    addTearDown(client.close);
    return client;
  }

  void run() {
    for (var i = 0; i < 8; i++) {
      clock.advance(Duration.zero);
      host.update();
      for (final client in clients) {
        client.update();
      }
      for (final client in joining) {
        client.update();
      }
    }
  }
}

/// A client that speaks the protocol directly and stays synchronizing on
/// the host, recording the state the host sends it.
final class _Joining {
  _Joining(this.peer, ProtocolSchema schema) : codec = ProtocolCodec(schema);

  final InMemoryClient peer;
  final ProtocolCodec codec;
  final states = <({StateMessage message, int revision, int channel})>[];

  void update() {
    for (var event = peer.poll(); event != null; event = peer.poll()) {
      switch (event) {
        case ConnectionOpened(:final connection):
          connection.send(
            codec.encode(
              MessageEnvelope(
                HelloMessage(fingerprint: codec.schema.fingerprint),
                generation: 0,
              ),
            ),
          );
        case MessageReceived(:final message, :final channel):
          for (final envelope in codec.decodePacket(message)) {
            if (envelope.message case final StateMessage state) {
              states.add((
                message: state,
                revision: envelope.revision,
                channel: channel,
              ));
            }
          }
        case ConnectionClosed():
          break;
      }
    }
  }
}

final class _RawHost {
  _RawHost() {
    final network = InMemoryNetwork(
      clock: clock,
      deliveryModes: DeliveryMode.values.toSet(),
      channelCount: 4,
    );
    peer = network.host();
    codec = ProtocolCodec(schema.schema);
    client = MultiplayerSession(
      schema: schema.schema,
      clock: clock,
      onMessage: (_, envelope) {
        if (envelope.message case final StateMessage state) observed.add(state);
      },
    )..join(network.connect());
    addTearDown(client.close);
    addTearDown(peer.close);
    run();
    send(const WelcomeMessage(peer: PeerId(2), epoch: 1));
    send(const SyncedMessage());
    run();
    entity = client.staticEntity(schema.board!);
    model = _Model(client, entity, schema);
  }

  final clock = ManualClock();
  final schema = _Schema(staticEntity: true);
  final observed = <StateMessage>[];
  late final InMemoryHost peer;
  late final ProtocolCodec codec;
  late final MultiplayerSession client;
  late final NetworkEntity entity;
  late final _Model model;
  late PeerConnection connection;

  void run() {
    for (var i = 0; i < 8; i++) {
      clock.advance(Duration.zero);
      for (var event = peer.poll(); event != null; event = peer.poll()) {
        if (event case ConnectionOpened(:final connection)) {
          this.connection = connection;
        }
      }
      client.update();
    }
  }

  void send(
    ProtocolMessage message, {
    int revision = 0,
    DeliveryMode mode = DeliveryMode.reliable,
    int channel = 0,
  }) => connection.send(
    codec.encode(MessageEnvelope(message, generation: 5, revision: revision)),
    mode: mode,
    channel: channel,
  );

  void state(Map<String, int> values, int sequence, {int revision = 0}) => send(
    StateMessage(
      entity: entity.id,
      values: {
        for (final MapEntry(key: field, :value) in values.entries)
          schema.fields[field]!.id: value,
      },
      sampledAt: Duration(microseconds: sequence),
      sequence: sequence,
    ),
    revision: revision,
    mode: DeliveryMode.unreliable,
    channel: 1,
  );
}

final class _RawClient {
  _RawClient() {
    final network = InMemoryNetwork(
      clock: clock,
      deliveryModes: DeliveryMode.values.toSet(),
      channelCount: 4,
    );
    codec = ProtocolCodec(schema.schema);
    host = MultiplayerSession(schema: schema.schema, clock: clock)
      ..host(network.host());
    peer = network.connect();
    addTearDown(host.close);
    addTearDown(peer.close);
    entity = host.staticEntity(schema.board!);
    model = _Model(host, entity, schema);
    run();
    send(HelloMessage(fingerprint: schema.schema.fingerprint));
    run();
    send(const ReadyMessage(), revision: baseline);
    run();
    expect(host.isReady(id), isTrue);
  }

  final schema = _Schema(staticEntity: true);
  final clock = ManualClock();
  late final ProtocolCodec codec;
  late final MultiplayerSession host;
  late final InMemoryClient peer;
  late final NetworkEntity entity;
  late final _Model model;
  late PeerConnection connection;
  late PeerId id;
  var generation = 0;
  var baseline = 0;
  var transferRevision = 0;

  void run() {
    for (var i = 0; i < 8; i++) {
      clock.advance(Duration.zero);
      host.update();
      for (var event = peer.poll(); event != null; event = peer.poll()) {
        switch (event) {
          case ConnectionOpened(:final connection):
            this.connection = connection;
          case MessageReceived(:final message):
            final envelope = codec.decode(message);
            switch (envelope.message) {
              case WelcomeMessage(:final peer):
                id = peer;
                generation = envelope.generation;
                baseline = envelope.revision;
              case AuthorityMessage():
                transferRevision = envelope.revision;
              default:
                break;
            }
          case ConnectionClosed():
            break;
        }
      }
    }
  }

  void send(
    ProtocolMessage message, {
    int revision = 0,
    DeliveryMode mode = DeliveryMode.reliable,
    int channel = 0,
  }) => connection.send(
    codec.encode(
      MessageEnvelope(message, generation: generation, revision: revision),
    ),
    mode: mode,
    channel: channel,
  );

  void state(String name, int value, int sequence) {
    final field = schema.fields[name]!;
    send(
      StateMessage(
        entity: entity.id,
        values: {field.id: value},
        sampledAt: Duration.zero,
        sequence: sequence,
      ),
      revision: transferRevision,
      mode: field.deliveryMode,
      channel: field.channel,
    );
  }

  void acknowledge() =>
      send(AuthorityAckMessage(entity: entity.id), revision: transferRevision);
}

void main() {
  for (final mode in [
    DeliveryMode.unreliable,
    DeliveryMode.unreliableOrdered,
  ]) {
    test('$mode fields require recurring samples', () {
      final harness = _Harness();
      final entity = _register(harness.host);
      final field = harness.schema.fields.values.firstWhere(
        (field) => field.deliveryMode == mode,
      );
      final attachment = harness.host.attachEntity(
        entity,
        isReady: () => true,
        isValid: () => true,
      );

      expect(
        () => attachment.synchronize([field.property(get: () => 1)]),
        throwsArgumentError,
      );
      expect(
        attachment.synchronize([
          field.property(get: () => 1, mode: SyncMode.always),
        ]).isDisposed,
        isFalse,
      );
    });
  }

  test('fields share a frame only with the same mode and channel', () {
    final harness = _Harness();
    final client = harness.join();
    harness.run();
    final source = _Model(
      harness.host,
      _register(harness.host),
      harness.schema,
    );
    final target = _Model(client, _register(client), harness.schema);
    for (final id in harness.schema.fields.keys) {
      source.values[id] = source.values.length + 1;
    }

    harness.host.captureState();
    harness.run();

    expect(target.values, source.values);
    expect(harness.peers.single.received, hasLength(4));
    final grouped = {
      for (final (message, mode, channel) in harness.peers.single.received)
        (mode, channel): message.values.keys.map((id) => id.value).toSet(),
    };
    expect(grouped, {
      (DeliveryMode.reliable, 0): {'test.health', 'test.score'},
      (DeliveryMode.unreliable, 1): {'test.x', 'test.y'},
      (DeliveryMode.unreliableOrdered, 2): {'test.aim'},
      (DeliveryMode.reliable, 3): {'test.name'},
    });
  });

  test('late join retains unreliable fields in a reliable baseline', () {
    final harness = _Harness();
    final entity = _register(harness.host);
    final source = _Model(harness.host, entity, harness.schema)
      ..values['x'] = 42;
    harness.host.captureState();
    final client = harness.join();
    final target = _Model(client, _register(client), harness.schema);
    harness.network.dropNextUnreliable(count: 10);

    harness.run();

    expect(target.values['x'], source.values['x']);
    // The baseline is reliable regardless of each field's lane, so one
    // message carries every field.
    final (message, mode, channel) = harness.peers.single.received.single;
    expect(mode, DeliveryMode.reliable);
    expect(channel, 0);
    expect(message.sequence, isNull);
    expect(
      message.values.keys,
      unorderedEquals([
        for (final field in harness.schema.fields.values) field.id,
      ]),
    );
  });

  test('clients still joining share one revision for each sample', () {
    final harness = _Harness();
    final client = harness.join();
    final joining = [harness.startJoining(), harness.startJoining()];
    harness.run();
    expect(client.state, SessionState.ready);
    final source = _Model(
      harness.host,
      _register(harness.host),
      harness.schema,
    );
    final target = _Model(client, _register(client), harness.schema);
    harness.host.captureState();
    harness.run();
    final revision = harness.host.revision;
    final clientRevision = client.revision;
    for (final client in joining) {
      client.states.clear();
    }
    harness.peers.single.received.clear();

    harness.clock.advance(_interval);
    source.values['x'] = 5;
    harness.host.captureState();
    harness.run();

    // Only the always fields are due: x and y share a message on channel 1,
    // and aim has one on channel 2.
    expect(harness.host.revision, revision + 2);
    for (final client in joining) {
      expect(
        [for (final state in client.states) (state.revision, state.channel)],
        [(revision + 1, 0), (revision + 2, 0)],
      );
    }
    expect(harness.peers.single.received, hasLength(2));
    for (final (message, _, _) in harness.peers.single.received) {
      expect(message.sequence, isNotNull);
    }
    expect(target.values['x'], 5);
    expect(client.revision, clientRevision);
  });

  for (final id in ['x', 'aim']) {
    test('$id recovers a lost sample when its value remains unchanged', () {
      final harness = _Harness();
      final client = harness.join();
      harness.run();
      final source = _Model(
        harness.host,
        _register(harness.host),
        harness.schema,
      );
      final target = _Model(client, _register(client), harness.schema);
      harness.host.captureState();
      harness.run();
      expect(target.values[id], 0);
      harness.clock.advance(_interval);
      source.values[id] = 10;
      source.values['health'] = 20;
      harness.network.dropNextUnreliable(
        channel: harness.schema.fields[id]!.channel,
        fromHost: true,
      );

      harness.host.captureState();
      harness.run();

      expect(target.values[id], 0);
      expect(target.values['health'], 20);
      harness.clock.advance(_interval);
      harness.host.captureState();
      harness.run();

      expect(target.values[id], 10);
      expect(client.state, SessionState.ready);
    });
  }

  test('state sequences reject old values independently for each field', () {
    final harness = _RawHost();
    harness.state({'x': 30}, 3);
    harness.run();
    harness.state({'x': 20, 'y': 20}, 2);
    harness.run();
    harness.state({'x': 10, 'y': 10}, 1);
    harness.run();
    harness.state({'x': 99, 'y': 99}, 2);
    harness.run();

    expect(harness.model.values, {'x': 30, 'y': 20});
    expect(harness.observed, hasLength(2));
    expect(harness.client.revision, 0);
  });

  test('unreliable size limits split fields and isolate oversized values', () {
    final builder = ProtocolSchemaBuilder();
    final fields = [
      for (final name in ['a', 'b', 'c'])
        builder.addField(
          FieldId('test.$name'),
          const StringCodec(maxLength: 2000),
          deliveryMode: DeliveryMode.unreliable,
          channel: 1,
        ),
    ];
    final schema = builder.build();
    final maximum = ProtocolCodec(schema)
        .encode(
          MessageEnvelope(
            StateMessage(
              entity: const EntityId(1),
              values: {fields.first.id: 'a' * 150},
              sampledAt: Duration.zero,
              sequence: IntCodec.maxSafe,
            ),
            generation: IntCodec.maxSafe,
            revision: IntCodec.maxSafe,
          ),
        )
        .length;
    final clock = ManualClock();
    final network = InMemoryNetwork(
      clock: clock,
      deliveryModes: DeliveryMode.values.toSet(),
      channelCount: 2,
    );
    final host = MultiplayerSession(schema: schema, clock: clock)
      ..host(
        _RecordingPeer(network.host(), schema, maximumUnreliableBytes: maximum),
      );
    final peer = _RecordingPeer(
      network.connect(),
      schema,
      maximumUnreliableBytes: maximum,
    );
    final client = MultiplayerSession(schema: schema, clock: clock)..join(peer);
    addTearDown(host.close);
    addTearDown(client.close);
    void run() {
      for (var i = 0; i < 8; i++) {
        clock.advance(Duration.zero);
        host.update();
        client.update();
      }
    }

    run();
    final values = ['a' * 150, 'b' * 150, 'c' * 1000];
    final source = host
        .attachEntity(_register(host), isReady: () => true, isValid: () => true)
        .synchronize([
          for (var i = 0; i < fields.length; i++)
            fields[i].property(get: () => values[i], mode: SyncMode.always),
        ]);
    final received = <FieldId, String>{};
    client
        .attachEntity(
          _register(client),
          isReady: () => true,
          isValid: () => true,
        )
        .synchronize([
          for (final field in fields)
            field.property(
              get: () => '',
              set: (value) => received[field.id] = value,
              mode: SyncMode.always,
            ),
        ]);

    host.captureState();
    run();

    expect(received, {fields[0].id: values[0], fields[1].id: values[1]});
    expect(peer.received, hasLength(2));
    expect(source.snapshot(fields.last), isNull);
    final failures = [
      for (var event = host.poll(); event != null; event = host.poll())
        if (event is PropertySyncFailed) event,
    ];
    expect(failures, hasLength(1));
    expect(failures.single.field, fields.last.id);
    expect(failures.single.error, isA<ArgumentError>());
  });

  test('authority changes reset field sequence history', () {
    final harness = _RawHost();
    harness.state({'x': 30}, 30);
    harness.run();
    harness.send(
      AuthorityMessage(entity: harness.entity.id, authority: const PeerId(3)),
      revision: 1,
    );
    harness.run();
    harness.state({'x': 1}, 1, revision: 1);
    harness.run();
    harness.state({'x': 99}, 99);
    harness.run();

    expect(harness.model.values['x'], 1);
    expect(harness.client.revision, 1);
    expect(harness.observed, hasLength(2));
  });

  test('reliable field on another channel waits for its authority ack', () {
    final harness = _RawClient();
    harness.host.transferAuthority(harness.entity, harness.id);
    harness.run();
    harness.state('name', 10, 1);
    harness.run();
    expect(harness.model.values['name'], isNull);

    harness.acknowledge();
    harness.run();

    expect(harness.model.values['name'], 10);
    expect(harness.host.isReady(harness.id), isTrue);
  });

  test(
    'unreliable field overtaking its authority ack needs a later sample',
    () {
      final harness = _RawClient();
      harness.host.transferAuthority(harness.entity, harness.id);
      harness.run();
      harness.state('x', 10, 1);
      harness.run();
      expect(harness.model.values['x'], isNull);
      harness.acknowledge();
      harness.run();
      expect(harness.model.values['x'], isNull);

      harness.state('x', 10, 2);
      harness.run();

      expect(harness.model.values['x'], 10);
      expect(harness.host.isReady(harness.id), isTrue);
    },
  );
}
