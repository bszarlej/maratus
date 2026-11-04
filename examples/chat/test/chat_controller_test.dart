import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maratus_chat/chat_controller.dart';
import 'package:maratus_flame/maratus_flame.dart';

import 'game_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ManualClock clock;
  late InMemoryNetwork network;
  late List<ChatController> controllers;

  ChatController controller({bool canHost = true}) {
    final value = ChatController(
      hostingSupported: canHost,
      clock: clock,
      bindHost: (_) async => network.host(),
      connectClient: (_) => network.connect(),
    );
    controllers.add(value);
    return value;
  }

  Future<void> pump() async {
    for (var i = 0; i < 12; i++) {
      clock.advance(Duration.zero);
      for (final controller in controllers) {
        await prepareChatGame(controller.game);
        controller.game.update(1 / 60);
      }
    }
  }

  setUp(() {
    clock = ManualClock();
    network = InMemoryNetwork(clock: clock);
    controllers = [];
  });

  tearDown(() {
    for (final controller in controllers) {
      controller.dispose();
    }
  });

  test(
    'all ready peers receive typed messages with the original sender',
    () async {
      final host = controller();
      final first = controller(canHost: false);
      final second = controller(canHost: false);
      await host.host('8080');
      first.join('ws://localhost:8080/netcode');
      second.join('ws://localhost:8080/netcode');
      expect(first.canSend, isFalse);
      expect(first.send('too early'), isFalse);
      await pump();

      expect(host.state, SessionState.hosting);
      expect(first.state, SessionState.ready);
      expect(second.state, SessionState.ready);
      expect(host.readyPeers, 2);
      expect(first.readyPeers, 1);
      final received = 'Peer ${first.localPeer!.value}: Hello from a client';
      expect(first.send('  Hello from a client  '), isTrue);
      expect(first.activity, isNot(contains(received)));
      await pump();
      for (final peer in controllers) {
        expect(peer.activity.where((entry) => entry == received), hasLength(1));
        expect(peer.game.chatComponent!.messageCount, 1);
        expect(peer.game.chatComponent!.lastMessage, received);
      }

      expect(host.send('Hello from the host'), isTrue);
      await pump();
      for (final peer in controllers) {
        expect(peer.activity, contains('Peer 1: Hello from the host'));
      }
    },
  );

  test('participants see matching avatars that leave with them', () async {
    final host = controller();
    final first = controller(canHost: false);
    await host.host('8080');
    first.join('ws://localhost:8080/netcode');
    await pump();
    final joiner = controller(canHost: false);
    joiner.join('ws://localhost:8080/netcode');
    await pump();

    List<String> avatars(ChatController peer) => [
      for (final avatar in peer.game.avatars)
        '${avatar.owner.value}:${avatar.colorIndex}@${avatar.position.x}',
    ];
    expect(avatars(host), ['1:0@14.0', '2:1@90.0', '3:2@166.0']);
    for (final peer in controllers) {
      expect(avatars(peer), avatars(host));
      final own = peer.game.avatars.where((avatar) => avatar.isLocal).single;
      expect(own.owner, peer.localPeer);
      expect(own.label, 'You');
      expect(own.isNetworkReady, isTrue);
    }

    first.disconnect();
    await pump();
    expect(avatars(host), ['1:0@14.0', '3:2@90.0']);
    expect(avatars(joiner), avatars(host));
    expect(first.game.avatars, isEmpty);
  });

  test('host movement synchronizes and clients do not simulate it', () async {
    final host = controller();
    final client = controller(canHost: false);
    await host.host('8080');
    client.join('ws://localhost:8080/netcode');
    // Show received offsets as they arrive, without interpolation.
    client.smoothing = false;
    await pump();
    final previous = host.game.avatars.first.verticalOffset;

    clock.advance(const Duration(milliseconds: 50));
    host.game.update(0.25);
    final expected = [
      for (final avatar in host.game.avatars) avatar.verticalOffset,
    ];
    expect(expected.first, isNot(previous));
    clock.advance(Duration.zero);
    client.game.update(0);
    expect([
      for (final avatar in client.game.avatars) avatar.verticalOffset,
    ], expected);
    for (var i = 0; i < expected.length; i++) {
      expect(
        client.game.avatars[i].position.y,
        closeTo(160 - 34 + expected[i], 0.00001),
      );
    }

    client.game.update(1);
    expect([
      for (final avatar in client.game.avatars) avatar.verticalOffset,
    ], expected);
    // Frame count alone does not trigger another 50 ms network sample.
    host.game.update(0.25);
    clock.advance(Duration.zero);
    client.game.update(0);
    expect([
      for (final avatar in client.game.avatars) avatar.verticalOffset,
    ], expected);

    clock.advance(const Duration(milliseconds: 50));
    host.game.update(0);
    clock.advance(Duration.zero);
    client.game.update(0);
    expect(
      [for (final avatar in client.game.avatars) avatar.verticalOffset],
      [for (final avatar in host.game.avatars) avatar.verticalOffset],
    );
  });

  test('clients smooth avatar movement between samples', () async {
    final host = controller();
    final client = controller(canHost: false);
    await host.host('8080');
    client.join('ws://localhost:8080/netcode');
    await pump();

    /// Runs [count] 10 ms frames and counts those in which the client's
    /// view of the host's avatar moved.
    int movingFrames(int count) {
      var moved = 0;
      var previous = client.game.avatars.first.position.y;
      for (var i = 0; i < count; i++) {
        clock.advance(const Duration(milliseconds: 10));
        host.game.update(0.01);
        client.game.update(0.01);
        final y = client.game.avatars.first.position.y;
        if (y != previous) moved++;
        previous = y;
      }
      return moved;
    }

    movingFrames(30);
    // The host samples every 50 ms: smoothed positions move every frame,
    // received ones only when a sample arrives.
    expect(movingFrames(20), greaterThanOrEqualTo(18));
    expect(
      client.game.avatars.first.smoothingState,
      InterpolationState.interpolating,
    );
    expect(host.game.avatars.first.smoothingState, isNull);

    client.smoothing = false;
    expect(movingFrames(20), lessThanOrEqualTo(5));
    expect(client.game.avatars.first.smoothingState, isNull);
  });

  test(
    'disconnect and rejoin install fresh bindings and report host shutdown',
    () async {
      final host = controller();
      final client = controller();
      await host.host('8080');
      client.join('ws://localhost:8080/netcode');
      await pump();
      final oldId = client.localPeer;
      client.disconnect();
      await pump();
      expect(client.canStart, isTrue);
      expect(host.readyPeers, 0);
      client.join('ws://localhost:8080/netcode');
      await pump();
      expect(client.localPeer, isNot(oldId));
      expect(client.send('back again'), isTrue);
      await pump();
      expect(
        host.activity,
        contains('Peer ${client.localPeer!.value}: back again'),
      );

      host.disconnect();
      await pump();
      expect(client.state, SessionState.disconnected);
      expect(client.canSend, isFalse);
      expect(client.activity.last, 'Session: disconnected (remoteClosed)');
    },
  );

  test('a cancelled pending bind cannot replace a later join', () async {
    final host = controller();
    await host.host('8080');
    final pending = Completer<MultiplayerPeer>();
    final client = ChatController(
      hostingSupported: true,
      bindHost: (_) => pending.future,
      connectClient: (_) => network.connect(),
    );
    controllers.add(client);
    final opening = client.host('8081');
    expect(client.starting, isTrue);
    client.disconnect();
    client.join('ws://localhost:8080/netcode');
    final abandoned = InMemoryNetwork(clock: clock).host();
    pending.complete(abandoned);
    await opening;
    await pump();

    expect(abandoned.isClosed, isTrue);
    expect(client.state, SessionState.ready);
    expect(client.starting, isFalse);
    expect(client.send('joined instead'), isTrue);
    await pump();
    expect(
      host.activity,
      contains('Peer ${client.localPeer!.value}: joined instead'),
    );
  });

  test(
    'disposing during bind closes its eventual peer without notifying',
    () async {
      final pending = Completer<MultiplayerPeer>();
      final client = ChatController(
        hostingSupported: true,
        bindHost: (_) => pending.future,
      );
      var notifications = 0;
      client.addListener(() => notifications++);
      final opening = client.host('8080');
      client.dispose();
      final countAtDisposal = notifications;
      final abandoned = network.host();
      pending.complete(abandoned);
      await opening;
      expect(abandoned.isClosed, isTrue);
      expect(notifications, countAtDisposal);
    },
  );

  test('invalid input and bind failure leave the controls available', () async {
    var binds = 0;
    var connections = 0;
    final client = ChatController(
      hostingSupported: true,
      bindHost: (_) async {
        binds++;
        throw StateError('port in use');
      },
      connectClient: (_) {
        connections++;
        return network.connect();
      },
    );
    controllers.add(client);
    await client.host('0');
    await client.host('65536');
    client.join('https://localhost:8080');
    client.join('ws:///netcode');
    expect(binds, 0);
    expect(connections, 0);
    await client.host('8080');
    expect(binds, 1);
    expect(client.canStart, isTrue);
    expect(client.activity, contains(contains('port in use')));
  });

  test('connection failure is visible and joining can be retried', () async {
    final client = controller();
    client.join('ws://localhost:8080/netcode');
    await pump();
    expect(client.state, SessionState.disconnected);
    expect(client.activity.last, 'Session: disconnected (transportError)');
    expect(client.canStart, isTrue);
  });

  test(
    'log stays bounded and duplicate messages still notify listeners',
    () async {
      final host = controller();
      await host.host('8080');
      await pump();
      expect(host.send(''), isFalse);
      expect(host.send('x' * 241), isFalse);
      for (var i = 0; i < 110; i++) {
        expect(host.send('message $i'), isTrue);
        await pump();
      }
      expect(host.activity, hasLength(100));
      expect(host.activity.first, 'Peer 1: message 10');
      expect(host.activity.last, 'Peer 1: message 109');
      expect(() => host.activity.add('cannot mutate'), throwsUnsupportedError);
      var notifications = 0;
      host.addListener(() => notifications++);
      host.send('same');
      await pump();
      final afterFirst = notifications;
      host.send('same');
      await pump();
      expect(afterFirst, greaterThan(0));
      expect(notifications, greaterThan(afterFirst));
    },
  );

  test('host RPC delivery waits for the mounted component update', () async {
    final host = controller();
    await host.host('8080');
    expect(host.canSend, isFalse);
    await pump();
    final component = host.game.chatComponent!;
    expect(component.isMounted, isTrue);
    expect(host.send('next frame'), isTrue);
    expect(component.messageCount, 0);
    host.game.update(1 / 60);
    expect(component.messageCount, 1);
    expect(component.capturedMessageCount, 1);
    expect(component.lastMessage, 'Peer 1: next frame');
  });

  test('restarting before the game loads abandons the old scope', () async {
    final host = controller();
    await host.host('8080');
    final abandoned = host.game.chatComponent!;
    host.disconnect();
    await host.host('8080');
    await pump();
    expect(host.canSend, isTrue);
    expect(abandoned.isMounted, isFalse);
    expect(host.send('fresh scope'), isTrue);
    await pump();
    expect(abandoned.messageCount, 0);
    expect(host.game.chatComponent!.messageCount, 1);
  });

  test('a removed component never handles later messages', () async {
    final host = controller();
    await host.host('8080');
    await pump();
    final oldComponent = host.game.chatComponent!;
    expect(host.send('discard on removal'), isTrue);
    oldComponent.removeFromParent();
    await pump();
    expect(oldComponent.messageCount, 0);
    expect(host.canSend, isFalse);

    host.disconnect();
    await host.host('8080');
    await pump();
    final replacement = host.game.chatComponent!;
    expect(replacement, isNot(same(oldComponent)));
    expect(host.send('new component'), isTrue);
    await pump();
    expect(replacement.messageCount, 1);
    expect(oldComponent.messageCount, 0);
  });
}
