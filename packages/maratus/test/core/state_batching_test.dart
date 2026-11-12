import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:maratus/src/protocol/state_batch_codec.dart';
import 'package:test/test.dart';

const _interval = Duration(milliseconds: 50);

typedef _Packet = ({
  Uint8List bytes,
  DeliveryMode mode,
  int channel,
  List<MessageEnvelope> messages,
});

final class _RecordingPeer implements MultiplayerPeer {
  _RecordingPeer(this.peer, ProtocolSchema schema)
    : codec = ProtocolCodec(schema);

  final MultiplayerPeer peer;
  final ProtocolCodec codec;
  final packets = <_Packet>[];
  final connections = <PeerConnection>[];

  List<_Packet> get statePackets => packets
      .where(
        (packet) =>
            packet.messages.isNotEmpty &&
            packet.messages.first.message is StateMessage,
      )
      .toList();

  @override
  bool get isHost => peer.isHost;

  @override
  TransportCapabilities get capabilities => peer.capabilities;

  @override
  PeerEvent? poll() {
    final event = peer.poll();
    if (event case ConnectionOpened(:final connection)) {
      connections.add(connection);
    }
    if (event case MessageReceived(
      :final message,
      :final mode,
      :final channel,
    )) {
      List<MessageEnvelope> messages;
      try {
        messages = codec.decodePacket(message);
      } on ProtocolException {
        messages = [];
      }
      packets.add((
        bytes: Uint8List.fromList(message),
        mode: mode,
        channel: channel,
        messages: messages,
      ));
    }
    return event;
  }

  @override
  void close() => peer.close();
}

final class _Model {
  _Model(
    MultiplayerSession session,
    int id,
    List<SyncField<int>> fields, {
    PeerId authority = PeerId.host,
  }) {
    final entity = session.registry.register(
      EntityId(id),
      owner: PeerId.host,
      authority: authority,
    );
    session
        .attachEntity(entity, isReady: () => true, isValid: () => true)
        .synchronize([
          for (final field in fields)
            field.property(
              get: () => values[field.id] ?? 0,
              set: (value) => values[field.id] = value,
              mode: field.deliveryMode == DeliveryMode.reliable
                  ? SyncMode.onChange
                  : SyncMode.always,
            ),
        ], interval: _interval);
  }

  final values = <FieldId, int>{};
}

final class _Harness {
  _Harness({
    this.entityCount = 4,
    this.authority = PeerId.host,
    List<(DeliveryMode, int)> lanes = const [(DeliveryMode.unreliable, 1)],
    int? maxUnreliableMessageBytes,
    QueueLimits hostOutgoingLimits = const QueueLimits(),
  }) {
    final builder = ProtocolSchemaBuilder();
    for (var i = 0; i < lanes.length; i++) {
      final (mode, channel) = lanes[i];
      fields.add(
        builder.addField(
          FieldId('test.value.field$i'),
          const IntCodec(),
          deliveryMode: mode,
          channel: channel,
        ),
      );
    }
    schema = builder.build();
    network = InMemoryNetwork(
      clock: clock,
      deliveryModes: DeliveryMode.values.toSet(),
      channelCount: 4,
      maxUnreliableMessageBytes: maxUnreliableMessageBytes,
    );
    hostPeer = _RecordingPeer(
      network.host(outgoingLimits: hostOutgoingLimits),
      schema,
    );
    host = MultiplayerSession(schema: schema, clock: clock, pingInterval: null)
      ..host(hostPeer);
    addTearDown(host.close);
    sources = [
      for (var i = 1; i <= entityCount; i++)
        _Model(host, i, fields, authority: authority),
    ];
  }

  final int entityCount;
  final PeerId authority;
  final fields = <SyncField<int>>[];
  final clock = ManualClock();
  late final ProtocolSchema schema;
  late final InMemoryNetwork network;
  late final MultiplayerSession host;
  late final _RecordingPeer hostPeer;
  late final List<_Model> sources;
  late final MultiplayerSession client;
  late final _RecordingPeer peer;
  late final List<_Model> targets;
  final observed = <StateMessage>[];

  void join() {
    peer = _RecordingPeer(network.connect(), schema);
    client = MultiplayerSession(
      schema: schema,
      clock: clock,
      pingInterval: null,
      onMessage: (_, envelope) {
        if (envelope.message case final StateMessage state) observed.add(state);
      },
    )..join(peer);
    addTearDown(client.close);
    targets = [
      for (var i = 1; i <= entityCount; i++)
        _Model(client, i, fields, authority: authority),
    ];
    settle();
    expect(client.state, SessionState.ready);
  }

  void settle() {
    for (var i = 0; i < 8; i++) {
      clock.advance(Duration.zero);
      host.update();
      client.update();
    }
  }

  void setValues(int start) {
    for (var i = 0; i < sources.length; i++) {
      for (final field in fields) {
        sources[i].values[field.id] = start + i;
      }
    }
  }

  void capture() {
    host.captureState();
    settle();
  }

  void expectValues(int start) {
    expect(
      [for (final model in targets) model.values],
      [
        for (var i = 0; i < targets.length; i++)
          {for (final field in fields) field.id: start + i},
      ],
    );
  }
}

void main() {
  test('one packet updates several entities and counts actual wire bytes', () {
    final harness = _Harness()..join();
    harness.peer.packets.clear();
    final sentBefore = harness.host.diagnostics.sent;
    final receivedBefore = harness.client.diagnostics.received;

    harness.setValues(10);
    harness.capture();

    harness.expectValues(10);
    final packet = harness.peer.statePackets.single;
    expect(packet.bytes.first, 78);
    expect(packet.messages, hasLength(harness.entityCount));
    expect(packet.mode, DeliveryMode.unreliable);
    expect(packet.channel, 1);
    final standaloneBytes = packet.messages.fold<int>(
      0,
      (sum, message) => sum + harness.peer.codec.encode(message).length,
    );
    expect(packet.bytes.length, lessThan(standaloneBytes));
    final sent = harness.host.diagnostics.sent;
    final received = harness.client.diagnostics.received;
    expect(sent.messages - sentBefore.messages, harness.entityCount);
    expect(received.messages - receivedBefore.messages, harness.entityCount);
    expect(sent.bytes - sentBefore.bytes, packet.bytes.length);
    expect(received.bytes - receivedBefore.bytes, packet.bytes.length);
    expect(
      sent[MessageKind.state].bytes - sentBefore[MessageKind.state].bytes,
      packet.bytes.length,
    );
  });

  for (final mode in [
    DeliveryMode.unreliable,
    DeliveryMode.unreliableOrdered,
  ]) {
    test(
      '$mode batches recover from loss and reject reordered old samples',
      () {
        final harness = _Harness(lanes: [(mode, 1)])..join();
        harness.setValues(10);
        harness.capture();
        harness.expectValues(10);

        harness.clock.advance(_interval);
        harness.setValues(20);
        harness.network.dropNextUnreliable(fromHost: true, channel: 1);
        harness.capture();
        harness.expectValues(10);

        harness.clock.advance(_interval);
        harness.capture();
        harness.expectValues(20);

        harness.clock.advance(_interval);
        harness.setValues(30);
        harness.network.delayNextUnreliable(
          const Duration(milliseconds: 200),
          fromHost: true,
          channel: 1,
        );
        harness.capture();
        harness.expectValues(20);

        harness.clock.advance(_interval);
        harness.setValues(40);
        harness.capture();
        harness.expectValues(40);
        harness.clock.advance(const Duration(milliseconds: 200));
        harness.settle();
        harness.expectValues(40);
        expect(harness.client.state, SessionState.ready);
        expect(
          harness.peer.statePackets.every(
            (packet) => packet.messages.length == harness.entityCount,
          ),
          isTrue,
        );
      },
    );
  }

  test('splits state batches at the transport datagram size limit', () {
    const maximum = 90;
    final harness = _Harness(
      entityCount: 12,
      maxUnreliableMessageBytes: maximum,
    )..join();
    harness.peer.packets.clear();
    harness.setValues(10);
    harness.capture();

    harness.expectValues(10);
    final packets = harness.peer.statePackets;
    expect(packets.length, greaterThan(1));
    expect(packets.any((packet) => packet.messages.length > 1), isTrue);
    expect(
      packets.fold<int>(0, (count, packet) => count + packet.messages.length),
      harness.entityCount,
    );
    for (final packet in packets) {
      expect(packet.bytes.length, lessThanOrEqualTo(maximum));
    }
  });

  test('packets preserve each field delivery mode and channel', () {
    final harness = _Harness(
      lanes: [
        (DeliveryMode.reliable, 0),
        (DeliveryMode.unreliable, 1),
        (DeliveryMode.unreliable, 2),
        (DeliveryMode.unreliableOrdered, 3),
      ],
    )..join();
    harness.peer.packets.clear();
    harness.setValues(10);
    harness.capture();

    harness.expectValues(10);
    final fields = {for (final field in harness.fields) field.id: field};
    final packets = harness.peer.statePackets;
    expect(
      {for (final packet in packets) (packet.mode, packet.channel)},
      {
        (DeliveryMode.reliable, 0),
        (DeliveryMode.unreliable, 1),
        (DeliveryMode.unreliable, 2),
        (DeliveryMode.unreliableOrdered, 3),
      },
    );
    for (final packet in packets) {
      for (final envelope in packet.messages) {
        final state = envelope.message as StateMessage;
        for (final id in state.values.keys) {
          expect(fields[id]!.deliveryMode, packet.mode);
          expect(fields[id]!.channel, packet.channel);
        }
      }
    }
  });

  test('late join receives its reliable batch before the synced marker', () {
    final harness = _Harness()..setValues(10);
    harness.host.captureState();
    harness.network.dropNextUnreliable(count: 10);
    harness.join();

    harness.expectValues(10);
    final packet = harness.peer.statePackets.single;
    expect(packet.messages, hasLength(harness.entityCount));
    expect(packet.bytes.first, 78);
    expect(packet.mode, DeliveryMode.reliable);
    expect(packet.channel, 0);
    final packets = harness.peer.packets;
    final welcome = packets.indexWhere(
      (packet) =>
          packet.messages.length == 1 &&
          packet.messages.single.message is WelcomeMessage,
    );
    final synced = packets.indexWhere(
      (packet) =>
          packet.messages.length == 1 &&
          packet.messages.single.message is SyncedMessage,
    );
    expect(welcome, lessThan(packets.indexOf(packet)));
    expect(synced, greaterThan(packets.indexOf(packet)));
  });

  test('client batches reach the host and are batched again for relay', () {
    final harness = _Harness(authority: const PeerId(2))..join();
    expect(harness.client.localPeer, harness.authority);
    final observerPeer = _RecordingPeer(
      harness.network.connect(),
      harness.schema,
    );
    final observer = MultiplayerSession(
      schema: harness.schema,
      clock: harness.clock,
      pingInterval: null,
    )..join(observerPeer);
    addTearDown(observer.close);
    final models = [
      for (var i = 1; i <= harness.entityCount; i++)
        _Model(observer, i, harness.fields, authority: harness.authority),
    ];
    void settle() {
      for (var i = 0; i < 8; i++) {
        harness.clock.advance(Duration.zero);
        harness.host.update();
        harness.client.update();
        observer.update();
      }
    }

    settle();
    expect(observer.state, SessionState.ready);
    observerPeer.packets.clear();
    harness.hostPeer.packets.clear();
    for (var i = 0; i < harness.targets.length; i++) {
      harness.targets[i].values[harness.fields.single.id] = 50 + i;
    }
    harness.client.captureState();
    settle();

    expect(
      harness.hostPeer.statePackets.single.messages,
      hasLength(harness.entityCount),
    );
    expect(
      observerPeer.statePackets.single.messages,
      hasLength(harness.entityCount),
    );
    expect(
      [for (final model in harness.sources) model.values],
      [for (final model in harness.targets) model.values],
    );
    expect(
      [for (final model in models) model.values],
      [for (final model in harness.targets) model.values],
    );
  });

  test(
    'refusal during final flush drops the peer and clears pending state',
    () {
      final harness = _Harness(
        hostOutgoingLimits: const QueueLimits(maxBytes: 50),
      )..join();
      harness.setValues(10);
      harness.capture();

      expect(harness.host.diagnostics.peers, isEmpty);
      expect(harness.client.state, SessionState.disconnected);
      expect(harness.host.diagnostics.sent[MessageKind.state].messages, 0);
      expect(harness.host.diagnostics.heldState, (messages: 0, bytes: 0));
      expect(harness.hostPeer.connections.single.outgoing, (
        messages: 0,
        bytes: 0,
      ));
      harness.clock.advance(_interval);
      expect(harness.capture, returnsNormally);
    },
  );

  test(
    'an invalid later child prevents dispatch of every child in the batch',
    () {
      final harness = _Harness()..join();
      final generation = harness.peer.packets
          .expand((packet) => packet.messages)
          .firstWhere((envelope) => envelope.message is WelcomeMessage)
          .generation;
      final children = [
        for (var i = 1; i <= 2; i++)
          harness.peer.codec.encode(
            MessageEnvelope(
              StateMessage(
                entity: EntityId(i),
                values: {harness.fields.single.id: 99},
                sampledAt: Duration.zero,
                sequence: 1,
              ),
              generation: generation,
            ),
          ),
      ];
      // Truncate a varint in the second child's body, leaving framing valid.
      children.last[children.last.length - 1] = 128;
      final packet = const StateBatchCodec().encode(children);
      harness.hostPeer.connections.single.send(
        packet,
        mode: DeliveryMode.unreliable,
        channel: 1,
      );
      harness.settle();

      expect(harness.observed, isEmpty);
      expect(harness.targets.every((model) => model.values.isEmpty), isTrue);
      expect(harness.client.state, SessionState.disconnected);
    },
  );

  test('stale generation ignores a mixed-lane batch without disconnecting', () {
    final harness = _Harness(
      lanes: [(DeliveryMode.unreliable, 1), (DeliveryMode.reliable, 0)],
    )..join();
    final generation = harness.peer.packets
        .expand((packet) => packet.messages)
        .firstWhere((envelope) => envelope.message is WelcomeMessage)
        .generation;
    final staleBefore = harness.client.diagnostics.staleMessages;
    final packet = const StateBatchCodec().encode([
      for (var i = 0; i < harness.fields.length; i++)
        harness.peer.codec.encode(
          MessageEnvelope(
            StateMessage(
              entity: EntityId(i + 1),
              values: {harness.fields[i].id: 99},
              sampledAt: Duration.zero,
              sequence: 1,
            ),
            generation: generation + 1,
          ),
        ),
    ]);
    harness.hostPeer.connections.single.send(
      packet,
      mode: DeliveryMode.unreliable,
      channel: 1,
    );
    harness.settle();

    expect(harness.observed, isEmpty);
    expect(harness.targets.every((model) => model.values.isEmpty), isTrue);
    expect(harness.client.state, SessionState.ready);
    expect(
      harness.client.diagnostics.staleMessages - staleBefore,
      harness.fields.length,
    );
  });

  test(
    'a later child on the wrong lane prevents dispatch of the whole batch',
    () {
      final harness = _Harness(
        lanes: [(DeliveryMode.unreliable, 1), (DeliveryMode.reliable, 0)],
      )..join();
      final generation = harness.peer.packets
          .expand((packet) => packet.messages)
          .firstWhere((envelope) => envelope.message is WelcomeMessage)
          .generation;
      final packet = const StateBatchCodec().encode([
        for (var i = 0; i < harness.fields.length; i++)
          harness.peer.codec.encode(
            MessageEnvelope(
              StateMessage(
                entity: EntityId(i + 1),
                values: {harness.fields[i].id: 99},
                sampledAt: Duration.zero,
                sequence: 1,
              ),
              generation: generation,
            ),
          ),
      ]);
      harness.hostPeer.connections.single.send(
        packet,
        mode: DeliveryMode.unreliable,
        channel: 1,
      );
      harness.settle();

      expect(harness.observed, isEmpty);
      expect(harness.targets.every((model) => model.values.isEmpty), isTrue);
      expect(harness.client.state, SessionState.disconnected);
    },
  );
}
