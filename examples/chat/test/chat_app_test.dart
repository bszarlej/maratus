import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maratus_chat/chat_controller.dart';
import 'package:maratus_chat/main.dart';
import 'package:maratus_flame/maratus_flame.dart';

import 'game_test_helpers.dart';

void main() {
  testWidgets('removing the game cancels a pending host bind', (tester) async {
    final clock = ManualClock();
    final network = InMemoryNetwork(clock: clock);
    final pending = Completer<MultiplayerPeer>();
    final controller = ChatController(
      hostingSupported: true,
      bindHost: (_) => pending.future,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(ChatApp(controller: controller));
    await tester.pump();
    await tester.tap(find.text('Host'));
    expect(controller.starting, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(controller.starting, isFalse);
    final abandoned = network.host();
    pending.complete(abandoned);
    await tester.pump();
    expect(abandoned.isClosed, isTrue);
    expect(controller.state, SessionState.disconnected);
  });

  testWidgets('browser joins, enables messages when ready, and disconnects', (
    tester,
  ) async {
    final clock = ManualClock();
    final network = InMemoryNetwork(clock: clock);
    final host = ChatController(
      hostingSupported: true,
      bindHost: (_) async => network.host(),
    );
    final client = ChatController(
      hostingSupported: false,
      connectClient: (_) => network.connect(),
    );
    addTearDown(host.dispose);
    addTearDown(client.dispose);
    await host.host('8080');
    await tester.runAsync(() => prepareChatGame(host.game));
    await tester.pumpWidget(ChatApp(controller: client));
    await tester.pump();
    expect(find.byKey(const Key('chatGame')), findsOneWidget);
    expect(find.text('Host'), findsNothing);
    expect(
      find.text('Run a native host, then join it from this browser.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Send'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('Join'));
    for (var i = 0; i < 12; i++) {
      clock.advance(Duration.zero);
      host.game.update(1 / 60);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(client.state, SessionState.ready);
    expect(find.textContaining('Status: ready'), findsOneWidget);
    expect(client.game.avatars.map((avatar) => avatar.label), ['P1', 'You']);
    await tester.enterText(
      find.byKey(const Key('messageInput')),
      'Hello from the UI',
    );
    await tester.tap(find.text('Send'));
    for (var i = 0; i < 4; i++) {
      clock.advance(Duration.zero);
      host.game.update(1 / 60);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      host.activity,
      contains('Peer ${client.localPeer!.value}: Hello from the UI'),
    );
    expect(find.textContaining('Hello from the UI'), findsOneWidget);
    expect(client.game.chatComponent!.messageCount, 1);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('messageInput')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.tap(find.text('Disconnect'));
    await tester.pump();
    expect(client.canStart, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('native host controls fit a narrow window', (tester) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final clock = ManualClock();
    final network = InMemoryNetwork(clock: clock);
    final controller = ChatController(
      hostingSupported: true,
      bindHost: (_) async => network.host(),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(ChatApp(controller: controller));
    await tester.tap(find.text('Host'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.textContaining('Status: hosting'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('emoji counter and Send use the protocol message limit', (
    tester,
  ) async {
    final clock = ManualClock();
    final network = InMemoryNetwork(clock: clock);
    final controller = ChatController(
      hostingSupported: true,
      bindHost: (_) async => network.host(),
    );
    addTearDown(controller.dispose);
    await controller.host('8080');
    await tester.pumpWidget(ChatApp(controller: controller));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final input = find.byKey(const Key('messageInput'));
    final send = find.widgetWithText(FilledButton, 'Send');

    final tooLong = '😀' * 121;
    await tester.enterText(input, tooLong);
    await tester.pump();

    expect(find.text('242 / 240'), findsOneWidget);
    expect(find.text('Message is too long.'), findsOneWidget);
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    expect(tester.widget<TextField>(input).controller!.text, tooLong);

    final accepted = '😀' * 120;
    await tester.enterText(input, accepted);
    await tester.pump();

    expect(find.text('240 / 240'), findsOneWidget);
    expect(find.text('Message is too long.'), findsNothing);
    expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
    await tester.tap(send);
    await tester.pump();
    expect(controller.activity, contains('Peer 1: $accepted'));
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
