import 'package:maratus_webrtc/src/ice_server.dart';
import 'package:test/test.dart';

void main() {
  test('STUN and TURN servers with credentials are accepted', () {
    validateIceServers(const [
      IceServer(['stun:stun.example.com:3478', 'stuns:stun.example.com']),
      IceServer(
        ['turn:turn.example.com:3478', 'turns:turn.example.com:5349'],
        username: 'user',
        credential: 'secret',
      ),
    ]);
  });

  final invalid = <String, IceServer>{
    'no URLs': const IceServer([]),
    'an HTTP URL': const IceServer(['https://stun.example.com']),
    'a URL without a host': const IceServer(['stun:']),
    'a URL without a scheme': const IceServer(['stun.example.com']),
    'a NUL character': const IceServer(['stun:stun.example.com\u0000']),
    'a TURN server without credentials': const IceServer([
      'turn:turn.example.com',
    ]),
    'a TURN server without a password': const IceServer([
      'turns:turn.example.com',
    ], username: 'user'),
  };
  for (final MapEntry(key: name, value: server) in invalid.entries) {
    test('servers with $name are rejected', () {
      expect(() => validateIceServers([server]), throwsArgumentError);
    });
  }
}
