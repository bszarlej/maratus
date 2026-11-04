@TestOn('browser')
library;

import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

import '../support/web_socket_test_schema.dart';

const _testUrl = String.fromEnvironment('MARATUS_TEST_URL');

Future<void> _until(
  bool Function() condition, {
  void Function()? update,
  required String description,
}) async {
  final elapsed = Stopwatch()..start();
  while (true) {
    update?.call();
    if (condition()) return;
    if (elapsed.elapsed > const Duration(seconds: 15)) {
      fail('Timed out waiting for $description.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  runWebSocketBrowserTests(_testUrl);
}

/// Registers browser checks against the harness's ephemeral native host.
void runWebSocketBrowserTests(String testUrl) {
  group(
    'browser WebSocket transport',
    () {
      WebSocketClient client(Uri uri) {
        final peer = WebSocketClient.connect(uri);
        addTearDown(() async {
          peer.close();
          await peer.done;
        });
        return peer;
      }

      test('browsers report that hosting is unsupported', () async {
        expect(WebSocketHost.isSupported, isFalse);
        await expectLater(WebSocketHost.bind(port: 0), throwsUnsupportedError);
        final peer = client(Uri.parse(testUrl));
        expect(peer.capabilities.canHost, isFalse);
        expect(peer.capabilities.deliveryModes, {DeliveryMode.reliable});
        expect(peer.capabilities.channelCount, 1);
      });

      test(
        'a rejected path reports connectFailed without an open event',
        () async {
          final peer = client(Uri.parse(testUrl).replace(path: '/not-netcode'));
          final events = <PeerEvent>[];
          await _until(
            () => events.any((event) => event is ConnectionClosed),
            update: () {
              for (
                var event = peer.poll();
                event != null;
                event = peer.poll()
              ) {
                events.add(event);
              }
            },
            description: 'the browser connection failure',
          );
          expect(events, hasLength(1));
          expect(
            (events.single as ConnectionClosed).reason,
            CloseReason.connectFailed,
          );
        },
      );

      test(
        'closing while connecting releases resources and discards events',
        () async {
          final peer = client(Uri.parse(testUrl));
          peer.close();
          await peer.done;
          expect(peer.isClosed, isTrue);
          expect(peer.poll(), isNull);
          peer.close();
          expect(peer.poll(), isNull);
        },
      );

      test(
        'two clients exchange authenticated RPCs and observe host shutdown',
        () async {
          final protocol = WebSocketTestSchema();
          final first = MultiplayerSession(schema: protocol.schema)
            ..join(client(Uri.parse(testUrl)));
          final second = MultiplayerSession(schema: protocol.schema)
            ..join(client(Uri.parse(testUrl)));
          addTearDown(first.close);
          addTearDown(second.close);
          final firstMessages =
              <({PeerId sender, PeerId target, String text})>[];
          final secondMessages =
              <({PeerId sender, PeerId target, String text})>[];
          final firstEntity = protocol.bind(
            first,
            onEcho: (context, text) => firstMessages.add((
              sender: context.sender,
              target: context.target,
              text: text,
            )),
          );
          final secondEntity = protocol.bind(
            second,
            onEcho: (context, text) => secondMessages.add((
              sender: context.sender,
              target: context.target,
              text: text,
            )),
          );
          void update() {
            first.update();
            second.update();
          }

          await _until(
            () =>
                first.state == SessionState.ready &&
                second.state == SessionState.ready,
            update: update,
            description: 'both browser sessions to become ready',
          );
          final firstId = first.localPeer!;
          final secondId = second.localPeer!;
          expect(firstId, isNot(PeerId.host));
          expect(secondId, isNot(firstId));
          expect(first.epoch, second.epoch);
          expect(
            first.callRpc(firstEntity, protocol.echo, 'first browser'),
            isTrue,
          );
          expect(
            second.callRpc(secondEntity, protocol.echo, 'second browser'),
            isTrue,
          );
          // A sender's echo comes from the host, not from optimistic local dispatch.
          expect(firstMessages, isEmpty);
          expect(secondMessages, isEmpty);
          await _until(
            () => firstMessages.length >= 2 && secondMessages.length >= 2,
            update: update,
            description: 'both host-routed broadcasts',
          );
          for (final (messages, target) in [
            (firstMessages, firstId),
            (secondMessages, secondId),
          ]) {
            expect(
              messages,
              unorderedEquals([
                (sender: firstId, target: target, text: 'first browser'),
                (sender: secondId, target: target, text: 'second browser'),
              ]),
            );
          }

          expect(first.callRpc(firstEntity, protocol.stop, true), isTrue);
          await _until(
            () =>
                first.state == SessionState.disconnected &&
                second.state == SessionState.disconnected,
            update: update,
            description: 'clean native host shutdown',
          );
          expect(first.disconnectReason, DisconnectReason.remoteClosed);
          expect(second.disconnectReason, DisconnectReason.remoteClosed);
          expect(firstMessages, hasLength(2));
          expect(secondMessages, hasLength(2));
        },
      );
    },
    skip: testUrl.isEmpty
        ? 'Run dart run tool/test_web_socket_browser.dart to start the native fixture.'
        : false,
  );
}
