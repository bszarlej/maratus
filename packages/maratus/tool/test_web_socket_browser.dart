import 'dart:async';
import 'dart:io';

import 'package:maratus/maratus.dart';

import '../test/support/web_socket_test_schema.dart';

/// Runs browser transport tests against an ephemeral native loopback host.
///
/// Run from the package root with `dart run tool/test_web_socket_browser.dart`.
/// Set CHROME_EXECUTABLE when Chrome is not installed in its default location.
/// The transport checks use Dart's browser runner without a Flutter engine.
Future<void> main() async {
  final host = await WebSocketHost.bind(port: 0);
  final protocol = WebSocketTestSchema();
  final session = MultiplayerSession(schema: protocol.schema)..host(host);
  final received = <({PeerId sender, String text})>[];
  PeerId? stoppedBy;
  final failure = Completer<void>();
  protocol.bind(
    session,
    onEcho: (context, text) =>
        received.add((sender: context.sender, text: text)),
    onStop: (context, stop) {
      if (!stop || stoppedBy != null) {
        throw StateError('Unexpected fixture shutdown request.');
      }
      stoppedBy = context.sender;
      scheduleMicrotask(session.close);
    },
  );
  final updates = Timer.periodic(const Duration(milliseconds: 4), (_) {
    try {
      session.update();
      for (var event = session.poll(); event != null; event = session.poll()) {
        if (event is RpcRejected || event is RpcHandlerFailed) {
          throw StateError(
            'The native browser fixture rejected an RPC: $event',
          );
        }
      }
    } on Object catch (error, stack) {
      if (!failure.isCompleted) failure.completeError(error, stack);
    }
  });
  final root = File.fromUri(Platform.script).parent.parent;
  final scratch = Directory.fromUri(root.uri.resolve('.dart_tool/'));
  Directory? generated;
  File? entrypoint;
  Process? child;
  var childExited = false;
  Future<void>? output;
  Future<void>? errors;
  try {
    await scratch.create(recursive: true);
    generated = await scratch.createTemp('web_socket_browser_');
    entrypoint = File.fromUri(generated.uri.resolve('browser_test.dart'));
    final url = 'ws://127.0.0.1:${host.port}/netcode';
    // Pass the ephemeral endpoint through an ignored entrypoint. This keeps the
    // runner portable without relying on package:test's internal compiler flags.
    await entrypoint.writeAsString('''
@TestOn('browser')
library;
import 'package:test/test.dart';
import '../../test/transport/web_socket_browser_test.dart' as suite;
void main() => suite.runWebSocketBrowserTests('$url');
''');
    stdout.writeln('Native WebSocket test host: $url');
    child = await Process.start(Platform.resolvedExecutable, [
      'test',
      '--platform',
      'chrome',
      entrypoint.path,
    ], workingDirectory: root.path);
    output = stdout.addStream(child.stdout);
    errors = stderr.addStream(child.stderr);
    final childExit = child.exitCode.then((code) {
      childExited = true;
      return code;
    });
    final result = await Future.any<int>([
      childExit,
      failure.future.then((_) => 1),
    ]).timeout(const Duration(minutes: 5));
    await Future.wait([output, errors]);
    if (result != 0) {
      exitCode = result;
      return;
    }
    final senders = received.map((message) => message.sender).toSet();
    final texts = received.map((message) => message.text).toSet();
    if (received.length != 2 ||
        senders.length != 2 ||
        senders.contains(PeerId.host) ||
        !texts.containsAll({'first browser', 'second browser'}) ||
        !senders.contains(stoppedBy) ||
        session.state != SessionState.disconnected) {
      throw StateError(
        'Native fixture did not observe both browser senders and shutdown: $received',
      );
    }
    stdout.writeln(
      'Verified both authenticated browser senders and clean host shutdown.',
    );
  } finally {
    updates.cancel();
    session.close();
    try {
      await host.done;
      if (child != null && !childExited) {
        await _stopChild(child);
      }
      await Future.wait<void>([
        ?output,
        ?errors,
      ]).timeout(const Duration(seconds: 5), onTimeout: () => <void>[]);
    } finally {
      if (entrypoint != null && await entrypoint.exists()) {
        await entrypoint.delete();
      }
      if (generated != null) await generated.delete();
    }
  }
}

Future<void> _stopChild(Process child) async {
  if (Platform.isWindows) {
    // End only this test process and its Chrome descendants.
    await Process.run('taskkill', [
      '/PID',
      '${child.pid}',
      '/T',
      '/F',
    ]).timeout(const Duration(seconds: 10));
  } else {
    child.kill();
  }
  try {
    await child.exitCode.timeout(const Duration(seconds: 5));
  } on TimeoutException {
    child.kill(
      Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill,
    );
    await child.exitCode.timeout(const Duration(seconds: 5));
  }
}
