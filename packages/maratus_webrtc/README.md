<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg">
    <img src="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg" alt="Maratus logo" width="300">
  </picture>
</p>

# maratus_webrtc

WebRTC data channels for [maratus](https://pub.dev/packages/maratus). This optional
transport supports hosting and joining from browsers, standalone Dart, and
native Flutter applications. It provides encrypted connections, reliable and
unreliable delivery, and independent channels without depending on Flutter.

## Installation

```sh
dart pub add maratus maratus_webrtc
```

Requires Dart `>=3.11.0 <4.0.0`. Browsers use their built-in WebRTC. Native
builds require C and C++ compilers: the build hook compiles and bundles
libdatachannel 0.24.6 and its included dependencies. No separate native-library
installation or runtime download is needed.

| Target | Build requirements |
| ------ | ------------------ |
| Browser | No native compiler |
| Windows | Visual Studio or Build Tools with **Desktop development with C++** |
| macOS | Xcode command-line tools |
| Linux | Clang and C++ standard library headers |
| Android | Flutter with Dart 3.11 or newer, Android SDK and NDK |
| iOS | Flutter with Dart 3.11 or newer, Xcode on macOS |

[CI](https://github.com/bszarlej/maratus/blob/master/.github/workflows/webrtc.yaml) is configured to run native transport
tests on Windows, macOS, and Linux with Dart 3.11.0 and stable, plus Chrome
tests compiled with `dart2js` and `dart2wasm`. Browser tests include connections
between Chrome and native peers. Android and iOS jobs check release builds and
native-library packaging; they do not run mobile transport tests.

## Signaling

Peers need a signaling service to exchange connection offers, answers, and
network candidates. The package includes a WebSocket signaling server with
rooms. Run it in a standalone Dart process or a native host:

```dart
import 'package:maratus_webrtc/signaling_server.dart';

Future<void> main() async {
  await SignalingServer.bind(address: '0.0.0.0', port: 8080);
}
```

The server accepts connections at `/signaling` by default. Its library uses
`dart:io` and cannot run in a browser. For deployment, expose it over `wss:`
through a TLS reverse proxy, including when the game is served over HTTPS.

Signaling carries negotiation messages only. Game traffic uses the WebRTC
connection, directly or through a TURN relay. Each client's signaling channel
closes after negotiation; the host keeps its room open for new clients.

To use an existing lobby service, implement `HostSignaling` and
`SignalingChannel`. They exchange ordered, opaque text messages between a host
and each client.

## Connect a session

Import the core and transport APIs:

```dart
import 'package:maratus/maratus.dart';
import 'package:maratus_webrtc/maratus_webrtc.dart';
```

Create a `MultiplayerSession` named `session` using your game's shared protocol
schema. See the [core guide](https://pub.dev/packages/maratus) for schema and session setup.

The host creates a room and shares its name with joining players:

```dart
final signaling = await WebSocketHostSignaling.connect(
  Uri.parse('wss://example.com/signaling'),
);
final peer = WebRtcHost(signaling: signaling);
session.host(peer);
print('Room: ${signaling.room}');
```

On each client, pass the shared room name as `roomName`:

```dart
final peer = WebRtcClient.connect(
  WebSocketSignalingChannel.join(
    Uri.parse('wss://example.com/signaling'),
    room: roomName,
  ),
);
session.join(peer);
```

Replace the example URL with your signaling service. A room name permits a
client to request a connection; use session admission control to validate
joining players.

Call `session.update()` from the game loop to process connection events and
messages. Client connection work is asynchronous. See
[session lifecycle](https://pub.dev/packages/maratus#session-lifecycle) for connection state
and failure handling. In Flame, `MultiplayerScope` handles session updates.

## STUN and TURN

Peers on the same network can connect without ICE servers, provided the
network permits direct traffic. Across networks, configure STUN to discover
public addresses and TURN to relay traffic when a direct path is unavailable:

```dart
const iceServers = [
  IceServer(['stun:stun.example.com:3478']),
  IceServer(
    ['turn:turn.example.com:3478'],
    username: 'user',
    credential: 'secret',
  ),
];
final peer = WebRtcHost(signaling: signaling, iceServers: iceServers);
```

Supply your server URLs and credentials, and pass `iceServers` to
`WebRtcClient.connect` as well. Native peers support STUN and TURN over UDP
only: they skip `stuns:`, `turns:`, and TURN URLs requesting `transport=tcp`.
Browser support for ICE server transports depends on the browser.

## Delivery and limits

WebRTC supports `DeliveryMode.reliable`, `unreliableOrdered`, and `unreliable`.
Set delivery mode and channel on RPCs and synchronized fields as described in
the [delivery guide](https://pub.dev/packages/maratus#delivery).

| Setting | Default | Constraint |
| ------- | ------- | ---------- |
| `channelCount` | `1` | 1–64 channels, numbered from zero; must match on both peers |
| `maxConnections` (host) | `64` | Includes negotiating clients and unpolled lifecycle events |
| `incomingLimits`, `outgoingLimits` | 1,024 messages and 4 MiB each | Per connection, configurable with `QueueLimits` |
| Unreliable payload size | 1,000 bytes maximum | Applies to both unreliable modes |
| `connectTimeout` | 15 seconds | Bounds connection negotiation |
| `closeTimeout` | Two seconds | Bounds connection draining during shutdown |

Ordering is independent across channels and delivery modes. Reliable payloads
can exceed the unreliable limit, subject to the configured queue limits.

Queue overflow closes the affected connection with `CloseReason.overflow`.
Incoming unreliable messages that do not fit are dropped instead. Reliable
outgoing messages count toward the limit until the receiver polls them and its
acknowledgement arrives; this is not a gameplay acknowledgement. Browsers also
impose send-buffer limits. When using `PeerConnection` directly, check the
boolean result of `send()`.

Close the session and await transport cleanup before exiting:

```dart
session.close();
await peer.done;
```

Closing discards pending local events and allows accepted reliable sends to
drain up to `closeTimeout`. Timeout or connection loss can prevent delivery;
unreliable messages may be discarded.

## Deployment

WebRTC encrypts connections with DTLS. This implementation does not renegotiate
connections when their network path changes; a failed connection must be
replaced. Its framing is specific to maratus and does not interoperate with
other WebRTC applications.

Configure the containing native application's network permissions for its
target:

- [Flutter networking setup](https://docs.flutter.dev/cookbook/networking/fetch-data)
- [Android local-network access](https://developer.android.com/privacy-and-security/local-network-permission)
- [Apple local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [macOS network entitlements](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client)

## License

[MIT](LICENSE). Bundled native sources retain their upstream licenses:
libdatachannel and libjuice under MPL-2.0, usrsctp under BSD-3-Clause, plog under
MIT, and Mbed TLS under Apache-2.0. See [native/UPSTREAM.md](native/UPSTREAM.md)
for source provenance and license files.
