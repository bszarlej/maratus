<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg">
    <img src="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg" alt="Maratus logo" width="300">
  </picture>
</p>

<p align="center">
  <a title="Pub" href="https://pub.dev/packages/maratus_enet" ><img alt="pub version" src="https://img.shields.io/pub/v/maratus_enet.svg"></a>
</p>

# maratus_enet

ENet over UDP for [maratus](https://pub.dev/packages/maratus). This optional transport
provides reliable and unreliable delivery with independent channels. It runs
in standalone Dart hosts and native Flutter applications without depending on
Flutter. Browsers are not supported.

## Installation

```sh
dart pub add maratus maratus_enet
```

Requires Dart `>=3.11.0 <4.0.0` and a native C compiler. The build hook compiles
and bundles ENet 1.3.18 from the included sources; no separate ENet installation
or runtime download is needed.

| Target | Build requirements |
| ------ | ------------------ |
| Windows | Visual Studio or Build Tools with **Desktop development with C++** |
| macOS | Xcode command-line tools |
| Linux | A C toolchain, such as `build-essential` on Ubuntu |
| Android | Flutter with Dart 3.11 or newer, Android SDK and NDK |
| iOS | Flutter with Dart 3.11 or newer, Xcode on macOS |

[CI](https://github.com/bszarlej/maratus/blob/master/.github/workflows/enet.yaml) is configured to run native transport
tests on Windows, macOS, and Linux with Dart 3.11.0 and stable. Android and iOS
jobs check release builds and native-library packaging; they do not run mobile
transport tests.

## Connect a session

Import the core and transport APIs:

```dart
import 'package:maratus/maratus.dart';
import 'package:maratus_enet/maratus_enet.dart';
```

Create a `MultiplayerSession` named `session` using your game's shared protocol
schema, then choose one of the following. See the
[core guide](https://pub.dev/packages/maratus) for schema and session setup.

Host:

```dart
final peer = await EnetHost.bind(address: '0.0.0.0', port: 7777);
session.host(peer);
```

Client:

```dart
final peer = EnetClient.connect('192.168.1.10', port: 7777);
session.join(peer);
```

Use the host's reachable IPv4 address in the client. The default bind address
is `127.0.0.1`, which accepts local clients only. Port zero selects an available
port, exposed by `peer.port` on the host.

Call `session.update()` from the game loop to process connection events and
messages. Client connection work is asynchronous and uses a ten-second
`connectTimeout` by default. See
[session lifecycle](https://pub.dev/packages/maratus#session-lifecycle) for connection state
and failure handling. In Flame, `MultiplayerScope` handles session updates.

## Delivery and limits

ENet supports `DeliveryMode.reliable`, `unreliableOrdered`, and `unreliable`.
Set delivery mode and channel on RPCs and synchronized fields as described in
the [delivery guide](https://pub.dev/packages/maratus#delivery).

| Setting | Default | Constraint |
| ------- | ------- | ---------- |
| `channelCount` | `1` | 1–85 channels, numbered from zero; must match on both peers |
| `maxConnections` (host) | `64` | Includes connections with unpolled lifecycle events |
| `incomingLimits`, `outgoingLimits` | 1,024 messages and 4 MiB each | Per connection, configurable with `QueueLimits` |
| Unreliable payload size | 1,000 bytes maximum | Applies to both unreliable modes |
| `closeTimeout` | Two seconds | Bounds connection draining during shutdown |

Ordering is independent across channels and delivery modes. Reliable payloads
can exceed the unreliable limit, subject to the configured queue limits.

Queue overflow closes the affected connection with `CloseReason.overflow`.
Incoming unreliable messages that do not fit are dropped instead. Reliable
outgoing messages count toward the limit until the receiver polls them and its
acknowledgement arrives; this is not a gameplay acknowledgement. When using
`PeerConnection` directly, check the boolean result of `send()`.

Close the session and await transport cleanup before exiting:

```dart
session.close();
await peer.done;
```

Closing discards pending local events and allows accepted sends to drain up to
`closeTimeout`. Timeout or connection loss can prevent delivery.

## Deployment

The host must be reachable over IPv4 UDP. This transport does not provide
encryption, transport authentication, NAT traversal, relays, or compression.
Use session admission control to validate joining players. The package's
framing is specific to maratus and does not interoperate with Godot or other
ENet applications.

Configure the containing application's network permissions for its target:

- [Flutter networking setup](https://docs.flutter.dev/cookbook/networking/fetch-data)
- [Android local-network access](https://developer.android.com/privacy-and-security/local-network-permission)
- [Apple local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [macOS network entitlements](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client)

## License

[MIT](LICENSE). The bundled ENet sources retain their
[upstream MIT license](native/enet-1.3.18/LICENSE).
