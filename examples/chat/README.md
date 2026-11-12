<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../assets/maratus-mark-on-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="../../assets/maratus-mark-on-light.svg">
  <img src="../../assets/maratus-mark-on-light.svg" alt="Maratus logo" width="80">
</picture>

# WebSocket chat example

This example combines typed chat RPCs, replicated avatars, and synchronized
movement with Flame. It includes Windows and web runners, a standalone Dart
host, and an in-memory network simulation.

Requires Dart `>=3.11.0 <4.0.0` and Flutter `>=3.41.0`. Use Chrome for the web
runner or install Flutter's Windows build tools for the desktop runner.

## Run a host and browser clients

From the repository root:

```sh
flutter pub get
cd examples/chat
```

Start the Dart host:

```sh
dart run bin/host.dart 8080
```

In another terminal, from `examples/chat`:

```sh
flutter run -d chrome
```

Enter `ws://localhost:8080/netcode` and select **Join**. Open the app's URL in a
second browser tab and join the same host. Once both clients show `ready`, send
a message from either tab. Each client gets an avatar; disconnecting removes
it, and rejoining creates a new one.

The command-line host uses the pure-Dart core and leaves avatars stationary.
Use the Windows app as host, or select **Simulate**, to see synchronized movement.

## Host from Windows

From `examples/chat`, with Flutter's Windows build tools installed:

```sh
flutter run -d windows
```

Stop the command-line host first if it uses the same port, then select **Host**.
The default port is `8080`. Other clients can join through
`ws://localhost:8080/netcode` on the same machine, or the host's LAN address,
such as `ws://192.168.1.20:8080/netcode`, on another device. Allow the port through
the host's firewall. An HTTPS-served browser app needs a `wss://` endpoint.

To use the Windows app as a client, enter the host URL and select **Join**.

The checked-in runners support Windows and web. On macOS or Linux, generate
the corresponding runner with `flutter create --platforms=macos .` or
`flutter create --platforms=linux .`.

## Simulate network conditions

Select **Simulate** while disconnected to run a host and two clients in memory.
Try **Latency spike**, **Host stall**, **Client stall**, and **Drop and rejoin**.
Enable **Diagnostics** to inspect latency, traffic, and queues; toggle
**Smoothing** to compare raw and interpolated movement.

## Explore the code

- [chat_protocol.dart](lib/chat_protocol.dart): shared RPCs, spawn types, and fields.
- [chat_game.dart](lib/chat_game.dart): networked Flame components and avatars.
- [chat_controller.dart](lib/chat_controller.dart): hosting, joining, and session cleanup.
- [host.dart](bin/host.dart): standalone Dart host.
- [network_lab.dart](lib/network_lab.dart): simulated network scenarios.
