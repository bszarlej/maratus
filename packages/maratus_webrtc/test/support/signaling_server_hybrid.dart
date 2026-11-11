import 'package:maratus_webrtc/signaling_server.dart';
import 'package:stream_channel/stream_channel.dart';

/// Runs a signaling server for browser tests and reports its port.
Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final server = await SignalingServer.bind(port: 0);
  channel.sink.add(server.port);
  await channel.stream.drain<void>();
  await server.close();
}
