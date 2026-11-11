/// A STUN or TURN server that helps peers find a network path to each other.
///
/// Peers on the same network connect without any servers. Peers behind
/// different routers usually need a STUN server to discover their public
/// addresses, and a TURN server relays their traffic when no direct path
/// exists.
final class IceServer {
  /// Describes a server reachable at any of [urls], such as
  /// `stun:stun.example.com:3478` or `turn:turn.example.com:3478`.
  ///
  /// TURN servers require a [username] and [credential].
  const IceServer(this.urls, {this.username, this.credential});

  /// The server's `stun:`, `stuns:`, `turn:`, or `turns:` URLs.
  final List<String> urls;

  /// The user name for a TURN server.
  final String? username;

  /// The password for a TURN server.
  final String? credential;
}

const _schemes = {'stun', 'stuns', 'turn', 'turns'};

/// Throws an [ArgumentError] if [servers] contains an entry WebRTC rejects.
void validateIceServers(List<IceServer> servers) {
  for (final server in servers) {
    if (server.urls.isEmpty) {
      throw ArgumentError.value(server.urls, 'urls', 'must not be empty');
    }
    for (final url in server.urls) {
      final separator = url.indexOf(':');
      final scheme = separator < 0 ? '' : url.substring(0, separator);
      if (!_schemes.contains(scheme) ||
          separator == url.length - 1 ||
          url.contains('\u0000')) {
        throw ArgumentError.value(
          url,
          'urls',
          'must be a stun:, stuns:, turn:, or turns: URL',
        );
      }
      if (scheme.startsWith('turn') &&
          (server.username == null || server.credential == null)) {
        throw ArgumentError.value(
          url,
          'urls',
          'TURN servers require a username and credential',
        );
      }
    }
  }
}
