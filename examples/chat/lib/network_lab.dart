import 'dart:async';

import 'package:maratus_flame/maratus_flame.dart';

import 'chat_controller.dart';

/// A network condition that a [NetworkLab] reproduces on its clock.
enum NetworkScenario {
  /// The visible client's link slows to [NetworkLab.spikeLatency] for three
  /// seconds.
  latencySpike('Latency spike'),

  /// The simulated host stops updating for two seconds.
  hostStall('Host stall'),

  /// The second simulated client stops updating for four seconds.
  clientStall('Client stall'),

  /// The visible client's link fails, and the client joins again a second
  /// later.
  dropAndRejoin('Drop and rejoin');

  const NetworkScenario(this.label);

  /// The name of the scenario's control.
  final String label;
}

/// A simulated host and a second client, in this process, joined by
/// in-memory links whose latency and failures are under control.
///
/// The visible client joins over its own link from [connect]. Each
/// participant is a [ChatController] whose game runs as usual, so the host
/// simulates avatar movement and clients smooth it. Scenarios are scheduled
/// on [clock]: a test that advances a [ManualClock] replays them exactly.
final class NetworkLab {
  /// Creates a lab whose links and scenarios follow [clock].
  NetworkLab({required this.clock})
    : network = InMemoryNetwork(clock: clock, latency: baseLatency) {
    host = ChatController(
      clock: clock,
      hostingSupported: true,
      bindHost: (_) async => network.host(),
      // A low threshold shows a stalled client's held state within a second.
      stateBackpressure: const QueueLimits(maxMessages: 32),
    );
    peer = ChatController(
      clock: clock,
      hostingSupported: false,
      connectClient: (_) => network.connect(),
    );
  }

  /// The latency of every link while no scenario changes it.
  static const baseLatency = Duration(milliseconds: 30);

  /// The latency of the visible client's link during a latency spike.
  static const spikeLatency = Duration(milliseconds: 300);

  /// The clock of the links, sessions, and scenarios.
  final MonotonicClock clock;

  /// The network that joins the participants.
  final InMemoryNetwork network;

  /// The simulated host.
  late final ChatController host;

  /// The second simulated client.
  late final ChatController peer;

  final _timers = <Timer>{};
  InMemoryLink? _link;
  var _disposed = false;

  /// Starts hosting, then joins the second client.
  Future<void> start() async {
    await host.host('1');
    if (!_disposed) peer.join('ws://lab/netcode');
  }

  /// Creates the visible client's transport over a new link.
  MultiplayerPeer connect() {
    final client = network.connect();
    _link = client.link;
    return client;
  }

  /// Reproduces [scenario]. [rejoin] makes the visible client join again.
  void run(NetworkScenario scenario, {required void Function() rejoin}) {
    if (_disposed) return;
    switch (scenario) {
      case NetworkScenario.latencySpike:
        _link?.latency = spikeLatency;
        _after(const Duration(seconds: 3), () => _link?.latency = baseLatency);
      case NetworkScenario.hostStall:
        _stall(host, const Duration(seconds: 2));
      case NetworkScenario.clientStall:
        _stall(peer, const Duration(seconds: 4));
      case NetworkScenario.dropAndRejoin:
        _link?.disconnect();
        _after(const Duration(seconds: 1), rejoin);
    }
  }

  /// Stops [participant]'s game, and with it its session updates, for
  /// [duration].
  void _stall(ChatController participant, Duration duration) {
    participant.game.pauseEngine();
    _after(duration, participant.game.resumeEngine);
  }

  void _after(Duration delay, void Function() action) {
    late final Timer timer;
    timer = clock.schedule(delay, () {
      _timers.remove(timer);
      if (!_disposed) action();
    });
    _timers.add(timer);
  }

  /// Cancels scenarios and closes the simulated participants.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    host.dispose();
    peer.dispose();
  }
}
