<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../assets/maratus-mark-on-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="../../assets/maratus-mark-on-light.svg">
  <img src="../../assets/maratus-mark-on-light.svg" alt="Maratus logo" width="80">
</picture>

# WebSocket chat example

Host or join a chat session, see replicated avatars, and try latency spikes,
stalls, and disconnects. Windows can host or join; browsers join a native host.

## Run it

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

Join `ws://localhost:8080/netcode`. Open a second browser tab, join the same
host, and send a message once both show `ready`. Each participant gets an
avatar. Disconnecting removes it; rejoining creates a new one.

The command-line host runs without Flutter and leaves avatars stationary.
Use the Windows app as host to see synchronized avatar movement.

## Host from Windows

From `examples/chat`, with Flutter's Windows build tools installed:

```sh
flutter run -d windows
```

Select **Host**, or enter a host URL and select **Join**. Other devices on the
same network use the host's LAN address, such as
`ws://192.168.1.20:8080/netcode`. Allow the port through the host's firewall.
An HTTPS-served browser app needs a `wss://` endpoint.

The checked-in runners support Windows and web. On macOS or Linux, generate
the corresponding runner with `flutter create --platforms=macos .` or
`flutter create --platforms=linux .`.

## Try simulated network problems

Select **Simulate** to run an in-memory session without a separate server.
Try **Latency spike**, **Host stall**, **Client stall**, and **Drop and rejoin**.
Enable **Diagnostics** to inspect latency, traffic, and queues; toggle
**Smoothing** to compare raw and interpolated movement.

## Explore the code

- [chat_protocol.dart](lib/chat_protocol.dart): shared RPCs, spawn types, and fields.
- [chat_game.dart](lib/chat_game.dart): networked Flame components and avatars.
- [host.dart](bin/host.dart): standalone Dart host.
- [network_lab.dart](lib/network_lab.dart): simulated network scenarios.

Documentation website coming soon.
