import 'dart:async';

import 'package:maratus/maratus.dart';
import 'package:maratus_webrtc/maratus_webrtc.dart';
import 'package:maratus_webrtc/signaling_server.dart';
import 'package:stream_channel/stream_channel.dart';

/// Runs a native WebRTC peer for browser interoperability tests.
///
/// As `host`, it opens a room on its own signaling server and reports the
/// server's port and the room. As `client`, it reports the port and joins
/// the room the browser sends back. Either way it echoes every message on
/// the mode and channel it arrived on, and reports opened and closed
/// connections, until the browser closes the channel.
Future<void> hybridMain(StreamChannel<Object?> channel, Object? role) async {
  final server = await SignalingServer.bind(port: 0);
  final uri = Uri.parse('ws://127.0.0.1:${server.port}/signaling');
  final commands = StreamIterator(channel.stream);
  final MultiplayerPeer peer;
  if (role == 'host') {
    final signaling = await WebSocketHostSignaling.connect(uri);
    peer = WebRtcHost(signaling: signaling, channelCount: 2);
    channel.sink.add({'port': server.port, 'room': signaling.room});
  } else {
    channel.sink.add({'port': server.port});
    if (!await commands.moveNext()) return;
    final room = commands.current! as String;
    peer = WebRtcClient.connect(
      WebSocketSignalingChannel.join(uri, room: room),
      channelCount: 2,
    );
  }
  final updates = Timer.periodic(const Duration(milliseconds: 2), (_) {
    for (var event = peer.poll(); event != null; event = peer.poll()) {
      switch (event) {
        case ConnectionOpened():
          channel.sink.add('opened');
        case MessageReceived(:final connection, :final message):
          connection.send(message, mode: event.mode, channel: event.channel);
        case ConnectionClosed(:final reason):
          channel.sink.add({'closed': reason.name});
      }
    }
  });
  while (await commands.moveNext()) {}
  updates.cancel();
  peer.close();
  await server.close();
}
