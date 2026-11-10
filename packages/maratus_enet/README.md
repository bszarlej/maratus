# maratus_enet

Native ENet over UDP for [maratus](https://pub.dev/packages/maratus), with
reliable and unreliable delivery, independent channels, and bounded queues.
The package implements `MultiplayerPeer` as an optional transport for the core
package. It has no Flutter dependency and can run in a standalone Dart host or
a native Flutter application.

## Install

```sh
dart pub add maratus maratus_enet
```

```dart
import 'package:maratus/maratus.dart';
import 'package:maratus_enet/maratus_enet.dart';
```

In a Flame game, import `maratus_flame` for the core and Flame APIs alongside
`maratus_enet` for the transport.

Requires Dart `>=3.11.0 <4.0.0` and a native C compiler. A Dart build hook
compiles the bundled ENet 1.3.18 sources; no separately installed ENet library
or runtime download is needed.

| Platform | Compiler setup | Support |
| -------- | -------------- | ------- |
| Windows | Visual Studio or Build Tools with **Desktop development with C++** | Native host and client; CI configured. |
| macOS | Xcode command-line tools (`xcode-select --install`) | Native host and client; CI configured. |
| Linux | A C toolchain, such as `build-essential` on Ubuntu | Native host and client; CI configured. |
| Android | Flutter with the Android SDK and NDK | Release packaging verified for ARMv7, ARM64, and x64; device behavior unverified. |
| iOS | Flutter with Xcode on macOS | Native host and client intended; build CI configured, device behavior unverified. |
| Browser | — | Unsupported; use the core WebSocket client. |

CI is configured to test the ENet package in a Dart-only workspace on Windows,
macOS, and Linux, using Dart 3.11.0 and stable.

Android release compilation and packaging have been checked with Flutter 3.47.7
and Dart 3.13.5. Build-only CI jobs also compile temporary Android and iOS apps;
iOS compilation and mobile device behavior have not yet been verified locally.

The build hook selects ENet's Windows or Unix backend and the target compiler.
Android and iOS compatibility is expected from that native code path and
[Flutter's build-hook support](https://docs.flutter.dev/interop/bind-native-code);
mobile device validation is still required. Use a Flutter SDK containing Dart
3.11 or newer. Native libraries are built and bundled with the app automatically.

## Application permissions

The containing application must configure its platform permissions:

- **Android:** declare `android.permission.INTERNET` in
  `android/app/src/main/AndroidManifest.xml`, including release builds. See
  [Flutter's networking setup](https://docs.flutter.dev/cookbook/networking/fetch-data).
  For LAN connections on Android 17 or later when targeting API 37 or higher,
  also declare and request `android.permission.ACCESS_LOCAL_NETWORK` before
  connecting. Apps targeting API 36 or lower should follow the existing
  `INTERNET` permission behavior instead. See
  [Android's local-network requirements](https://developer.android.com/privacy-and-security/local-network-permission).
- **iOS and macOS apps:** add `NSLocalNetworkUsageDescription` to `Info.plist`
  when connecting over a LAN. The operating system can block traffic while
  permission is pending or denied; allow retrying a connection after permission
  is granted. See
  [Apple's local-network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
- **Sandboxed macOS apps:** enable both `com.apple.security.network.client`
  and `com.apple.security.network.server` in the app's debug/profile and release
  entitlements. UDP needs permission to send and receive for both hosting and
  joining. See
  [Apple's network entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client).

## Connect a session

Create each `MultiplayerSession` with your application's shared protocol schema,
then supply an ENet peer:

```dart
final hostPeer = await EnetHost.bind(
  address: '0.0.0.0',
  port: 7777,
);
hostSession.host(hostPeer);

final clientPeer = EnetClient.connect('192.168.1.10', port: 7777);
clientSession.join(clientPeer);
```

Continue updating both sessions from their game loops, as with WebSockets.
The client constructor returns immediately; resolving the host and connecting
happen asynchronously. Failed or timed-out connections report
`ConnectionClosed` with `CloseReason.connectFailed` through polling.

`EnetHost.bind` defaults to `127.0.0.1:7777`, which accepts local clients only.
Bind `0.0.0.0` to accept IPv4 LAN connections and connect to the host's reachable
address. Port zero selects an available port, exposed by `hostPeer.port`.
Connections currently use IPv4. The host defaults to at most 64 connections.

Sessions support delivery modes and channels per RPC and synchronized field:

```dart
final move = builder.addRpc(
  const RpcId('player.move'),
  const IntCodec(min: -1, max: 1),
  deliveryMode: DeliveryMode.unreliableOrdered,
  channel: 1,
);
```

Configure both peers with `channelCount: 2` for this example. Synchronized
fields accept the same settings and require `SyncMode.always` when unreliable,
so later samples recover lost values. Defaults remain reliable channel zero;
initial snapshots and session control always use that reliable lane. See the
[core delivery guide](../maratus/README.md#choose-delivery-per-rpc-and-field)
for ordering, size limits, and deterministic testing.

## Transport messages and channels

When using the transport directly, drain `peer.poll()` in your update loop.
`ConnectionOpened` exposes a `PeerConnection`; use it to send bytes:

```dart
connection.send(
  Uint8List.fromList([1, 2, 3]),
  mode: DeliveryMode.unreliableOrdered,
  channel: 1,
);
```

Import `dart:typed_data` for `Uint8List`. Configure both peers with
`channelCount: 2` for this example. `channelCount` defaults to one and accepts
1–85 logical channels, numbered from zero. `MessageReceived` includes the
received `mode` and `channel` as well as the payload.

| Delivery mode | Guarantee while connected |
| ------------- | ------------------------- |
| `reliable` | Each accepted message arrives once, in send order within its channel. |
| `unreliableOrdered` | Messages may be lost; late messages are discarded after a newer one arrives. |
| `unreliable` | Messages may be lost or arrive out of order. |

Each logical channel uses three native ENet channels, one per delivery mode.
Reliable traffic therefore does not impose its ordering on unreliable traffic,
and different logical channels have independent ordering. There is no global
ordering guarantee across modes or channels. Unsupported channels throw
`UnsupportedError` when sending.

Unreliable payloads are limited to 1,000 bytes to keep datagrams small. ENet can
still fragment packets or transmit them reliably internally; the public delivery
guarantees remain those described above. Reliable payloads can be larger,
subject to the configured queue limits.

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
messages release their outgoing credit when ENet sends or drops them. Read
`connection.incoming` and `connection.outgoing` for current queue depths.
Consumption acknowledgements have a separate bounded control queue, limited
to `outgoingLimits.maxMessages` packets of ten bytes each per connection.

Closing a peer discards its pending events immediately. Native connections
then have up to `closeTimeout` (two seconds by default) to drain before their
resources are released. Await `done` when shutting down a process or a test:

```dart
clientPeer.close();
hostPeer.close();
await Future.wait([clientPeer.done, hostPeer.done]);
```

## Current scope

This transport requires a directly reachable UDP host. Encryption/DTLS,
authentication at the transport layer, NAT traversal, relays, and compression
are not provided. The maratus framing includes queue-consumption
acknowledgements; it is not wire-compatible with Godot or arbitrary ENet
applications.

## License

[MIT](LICENSE). The bundled ENet sources retain their
[upstream MIT license](native/enet-1.3.18/LICENSE).
