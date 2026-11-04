import 'dart:async';
import 'dart:io';

import 'package:maratus/maratus.dart';
import 'package:maratus_chat/chat_protocol.dart';

/// Runs a native host for browser clients without a desktop Flutter build.
Future<void> main(List<String> arguments) async {
  final port = arguments.isEmpty ? 8080 : int.tryParse(arguments.first);
  if (arguments.length > 1 || port == null || port < 0 || port > 65535) {
    stderr.writeln('Usage: dart run bin/host.dart [port: 0..65535]');
    exitCode = 64;
    return;
  }
  final host = await WebSocketHost.bind(address: '0.0.0.0', port: port);
  final protocol = ChatProtocol();
  final session = MultiplayerSession(schema: protocol.schema)..host(host);
  protocol.bind(session, (sender, text) {
    stdout.writeln('Peer ${sender.value}: $text');
  });
  final updates = Timer.periodic(const Duration(milliseconds: 16), (_) {
    session.update();
    for (var event = session.poll(); event != null; event = session.poll()) {
      // A dedicated host has no avatar of its own; each client gets one.
      protocol.spawnJoinedAvatar(session, event);
      stdout.writeln(describeEvent(event));
    }
  });
  final interrupted = Completer<void>();
  final signal = ProcessSignal.sigint.watch().listen((_) {
    if (!interrupted.isCompleted) interrupted.complete();
  });
  stdout.writeln('Listening on ws://localhost:${host.port}/netcode');
  stdout.writeln('Press Ctrl+C to stop.');
  try {
    await Future.any<void>([host.done, interrupted.future]);
  } finally {
    updates.cancel();
    await signal.cancel();
    session.close();
    await host.done;
  }
}
