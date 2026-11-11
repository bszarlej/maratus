# maratus_webrtc

WebRTC data channels for [maratus](https://pub.dev/packages/maratus), with
browser hosting, reliable and unreliable delivery, independent channels, and
bounded queues. The package implements `MultiplayerPeer` as an optional
transport for the core package. It has no Flutter dependency: the same API
runs in browsers, native Flutter apps, and standalone Dart hosts, and peers on
different platforms can connect to each other.

## Install

```sh
dart pub add maratus maratus_webrtc
```

```dart
import 'package:maratus/maratus.dart';
import 'package:maratus_webrtc/maratus_webrtc.dart';
```

In a Flame game, import `maratus_flame` for the core and Flame APIs alongside
`maratus_webrtc` for the transport.

Requires Dart `>=3.11.0 <4.0.0`. Browsers use their built-in WebRTC. On native
platforms, a Dart build hook compiles the bundled
[libdatachannel](https://github.com/paullouisageneau/libdatachannel) 0.24.6
with Mbed TLS, usrsctp, and libjuice, so a C and C++ compiler is required, but
no separately installed library or runtime download is. The first build for
each target architecture takes a few minutes; later builds reuse the result.

| Platform | Compiler setup | Support |
| -------- | -------------- | ------- |
| Browser | — | Host and client through the browser's `RTCPeerConnection`; tested in Chrome. |
| Windows | Visual Studio or Build Tools with **Desktop development with C++** | Native host and client; CI configured. |
| macOS | Xcode command-line tools (`xcode-select --install`) | Native host and client; CI configured. |
| Linux | Clang with C++ standard library headers, such as `clang` and `libstdc++-12-dev` on Ubuntu | Native host and client; CI configured. |
| Android | Flutter with the Android SDK and NDK | Release packaging verified for ARMv7, ARM64, and x64; device behavior unverified. |
| iOS | Flutter with Xcode on macOS | Native host and client intended; build CI configured, device behavior unverified. |

CI is configured to test the native transport in a Dart-only workspace on
Windows, macOS, and Linux, using Dart 3.11.0 and stable, and to test browser
peers in Chrome, including connections between Chrome and native peers.
Build-only CI jobs also compile temporary Android and iOS apps.

Native libraries are built and bundled with the app automatically. Use a
Flutter SDK containing Dart 3.11 or newer.

## Application permissions

The containing application must configure its platform permissions:

- **Android:** declare `android.permission.INTERNET` in
  `android/app/src/main/AndroidManifest.xml`, including release builds. See
  [Flutter's networking setup](https://docs.flutter.dev/cookbook/networking/fetch-data).
  For LAN connections on Android 17 or later when targeting API 37 or higher,
  also declare and request `android.permission.ACCESS_LOCAL_NETWORK` before
  connecting. See
  [Android's local-network requirements](https://developer.android.com/privacy-and-security/local-network-permission).
- **iOS and macOS apps:** add `NSLocalNetworkUsageDescription` to `Info.plist`
  when connecting over a LAN, and allow retrying a connection after permission
  is granted. See
  [Apple's local-network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
- **Sandboxed macOS apps:** enable both `com.apple.security.network.client`
  and `com.apple.security.network.server` in the app's entitlements. WebRTC
  sends and receives UDP for both hosting and joining. See
  [Apple's network entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client).

## Signaling

Before two WebRTC peers can connect directly, they exchange a connection
offer, an answer, and network candidates through some other channel. This
exchange is called signaling. Each client's negotiation channel closes once
the peers are connected; the host keeps its WebSocket open to accept new
clients. Game traffic travels over the WebRTC connection, directly or through
a TURN relay, rather than through the signaling server.

The package includes a small WebSocket signaling server with rooms. Run it in a
standalone Dart process, or inside a native host:

```dart
import 'package:maratus_webrtc/signaling_server.dart';

final server = await SignalingServer.bind(address: '0.0.0.0', port: 8080);
```

`package:maratus_webrtc/signaling_server.dart` uses `dart:io`, so it runs on
native platforms only. Browsers require `wss:` URLs on pages served over HTTPS;
terminate TLS at a reverse proxy in front of the server.

A host opens a room and shares its name with the players who should join:

```dart
final signaling = await WebSocketHostSignaling.connect(
  Uri.parse('wss://example.com/signaling'),
);
print('Room: ${signaling.room}');
```

The server generates a short room name unless the host requests one with
`room:`. Anyone who knows a room's name can ask its host to connect, so treat
room names like invitations and use the session's admission control to decide
whom to accept.

Other signaling, such as an existing lobby service, can be used by
implementing `HostSignaling` and `SignalingChannel`. They deliver opaque text
messages between the host and each client, in order.

## Connect a session

Create each `MultiplayerSession` with your application's shared protocol schema,
then supply a WebRTC peer:

```dart
final hostPeer = WebRtcHost(signaling: signaling);
hostSession.host(hostPeer);

final clientPeer = WebRtcClient.connect(
  WebSocketSignalingChannel.join(
    Uri.parse('wss://example.com/signaling'),
    room: room,
  ),
);
clientSession.join(clientPeer);
```

Continue updating both sessions from their game loops. The client constructor
returns immediately; signaling and connecting happen asynchronously. A refused,
failed, or timed-out connection reports `ConnectionClosed` with
`CloseReason.connectFailed` through polling. Negotiation must finish within
`connectTimeout`, 15 seconds by default. The host defaults to at most 64
connections, including clients that are still negotiating.

Browsers can host as well as join, so a whole session can run in browsers with
only the signaling server outside them.

## Reaching peers on other networks

Peers on the same network can connect without STUN or TURN servers; signaling
is still required. Peers behind different routers usually need a STUN server
to discover their public addresses, and a TURN server relays their traffic
when no direct path exists:

```dart
const iceServers = [
  IceServer(['stun:stun.example.com:3478']),
  IceServer(
    ['turn:turn.example.com:3478'],
    username: 'user',
    credential: 'secret',
  ),
];
final hostPeer = WebRtcHost(signaling: signaling, iceServers: iceServers);
```

Pass the same servers to `WebRtcClient.connect`. TURN servers require a user
name and credential. Native peers use STUN and TURN over UDP only: they skip
`stuns:`, `turns:`, and TURN URLs requesting `transport=tcp`. Browser support
for ICE server transports depends on the browser.

## Delivery modes and channels

Sessions support delivery modes and channels per RPC and synchronized field:

```dart
final move = builder.addRpc(
  const RpcId('player.move'),
  const IntCodec(min: -1, max: 1),
  deliveryMode: DeliveryMode.unreliableOrdered,
  channel: 1,
);
```

Configure both peers with `channelCount: 2` for this example. `channelCount`
defaults to one and accepts 1–64 logical channels; a host refuses clients
whose channel count differs. Synchronized fields accept the same settings and
require `SyncMode.always` when unreliable, so later samples recover lost
values. See the
[core delivery guide](../maratus/README.md#choose-delivery-per-rpc-and-field)
for ordering, size limits, and deterministic testing.

| Delivery mode | Guarantee while connected |
| ------------- | ------------------------- |
| `reliable` | Each accepted message arrives once, in send order within its channel. |
| `unreliableOrdered` | Messages may be lost; late messages are discarded after a newer one arrives. |
| `unreliable` | Messages may be lost or arrive out of order. |

Each logical channel uses two data channels: a reliable ordered one, and an
unordered one without retransmissions that carries both unreliable modes.
Ordered unreliable messages are therefore never held back behind a lost one.
Different logical channels have independent ordering, and there is no global
ordering across modes or channels.

Unreliable payloads are limited to 1,000 bytes so that each fits in one packet.
Reliable payloads can be larger, subject to the queue limits; they are split
into 16 KiB payload chunks.

## Queues and shutdown

Both peer constructors accept `incomingLimits` and `outgoingLimits` as
`QueueLimits`. Defaults are 1,024 messages and 4 MiB in each direction, per
connection. Exceeding either limit closes that connection with
`CloseReason.overflow`; check the boolean result of `connection.send`. A
received unreliable message that does not fit the incoming queue is discarded
instead, as if the network had lost it.

Reliable outgoing messages count toward the limit until the receiver polls
them and its acknowledgement arrives. This bounds traffic when a receiver
stops consuming messages; it is not a gameplay acknowledgement. Unreliable
messages release their outgoing credit once WebRTC has sent them. Browsers
also impose their own send-buffer limits; increasing queue limits can exceed
those limits.

Closing a connection attempts to drain its accepted reliable messages before
the remote peer reports `CloseReason.remote`. Draining is bounded by
`closeTimeout` (two seconds by default); timeout or connection failure can
prevent delivery, and unreliable messages may be discarded. Closing a peer
discards its pending events immediately while its connections drain. Await
`done` when shutting down a process or a test:

```dart
clientPeer.close();
hostPeer.close();
await Future.wait([clientPeer.done, hostPeer.done]);
```

## Current scope

WebRTC encrypts every connection with DTLS. Connections are not renegotiated,
so a connection whose network path changes, for example when a phone switches
networks, closes as lost. The maratus framing includes queue-consumption
acknowledgements; it does not interoperate with other WebRTC applications.

## License

[MIT](LICENSE). The bundled native sources retain their upstream licenses:
libdatachannel and libjuice under MPL-2.0, usrsctp under BSD-3-Clause, plog
under MIT, and Mbed TLS under Apache-2.0. See
[native/UPSTREAM.md](native/UPSTREAM.md) for their origins.
