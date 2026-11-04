import 'package:flutter_test/flutter_test.dart';
import 'package:maratus_chat/chat_controller.dart';
import 'package:maratus_chat/network_lab.dart';
import 'package:maratus_flame/maratus_flame.dart';

import 'game_test_helpers.dart';

/// The resources that must return to the same counts after reconnecting.
String _resources(SessionDiagnostics diagnostics) =>
    'entities ${diagnostics.entities}, '
    'replicated ${diagnostics.replicatedEntities}, '
    'attachments ${diagnostics.attachments}, '
    'synchronizers ${diagnostics.synchronizers}, '
    'RPC bindings ${diagnostics.rpcBindings}, '
    'spawn bindings ${diagnostics.spawnBindings}, '
    'pending RPCs ${diagnostics.pendingRpcs}, '
    'peers ${diagnostics.peers.length}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ManualClock clock;
  late NetworkLab lab;
  late ChatController visible;

  /// Runs 20 ms frames for [duration], calling [each] after every frame.
  /// Games paused by a stall skip their updates.
  Future<void> frames(Duration duration, {void Function()? each}) async {
    const frame = Duration(milliseconds: 20);
    for (var elapsed = Duration.zero; elapsed < duration; elapsed += frame) {
      clock.advance(frame);
      for (final participant in [lab.host, lab.peer, visible]) {
        final game = participant.game;
        await prepareChatGame(game);
        if (!game.paused) game.update(frame.inMicroseconds / 1e6);
      }
      each?.call();
    }
  }

  void rejoin() =>
      visible.joinPeer(lab.connect(), description: 'Joining the lab again');

  Iterable<InterpolationState?> smoothing() =>
      visible.game.avatars.map((avatar) => avatar.smoothingState);

  setUp(() async {
    clock = ManualClock();
    lab = NetworkLab(clock: clock);
    visible = ChatController(clock: clock, hostingSupported: false);
    await lab.start();
    visible.joinPeer(lab.connect(), description: 'Joining the lab');
    await frames(const Duration(seconds: 1));
    expect(lab.peer.state, SessionState.ready);
    expect(visible.state, SessionState.ready);
  });

  tearDown(() {
    visible.dispose();
    lab.dispose();
  });

  test('the visible client smooths the avatars the host moves', () async {
    await frames(const Duration(milliseconds: 500));

    expect(visible.game.avatars, hasLength(3));
    expect(smoothing(), everyElement(InterpolationState.interpolating));
    expect(
      lab.host.game.avatars.map((avatar) => avatar.smoothingState),
      everyElement(isNull),
    );
    final summary = visible.game.diagnostics.value;
    expect(summary.first, startsWith('Peer 1 · RTT '));
    expect(summary, contains(startsWith('Out ')));
    expect(summary.last, 'Smoothing: 3 interpolating');
  });

  test('a latency spike raises the round trip, then recovers', () async {
    lab.run(NetworkScenario.latencySpike, rejoin: rejoin);
    final shown = <InterpolationState?>{};
    await frames(
      const Duration(seconds: 2),
      each: () => shown.addAll(smoothing()),
    );

    final duringSpike = visible.diagnostics.peers.single.roundTripTime!;
    expect(duringSpike, greaterThanOrEqualTo(NetworkLab.spikeLatency * 2));
    // Presentation ran out of samples until it estimated the new latency.
    expect(shown, contains(InterpolationState.holding));

    await frames(const Duration(seconds: 4));
    expect(
      visible.diagnostics.peers.single.roundTripTime,
      lessThan(const Duration(milliseconds: 150)),
    );
    expect(smoothing(), everyElement(InterpolationState.interpolating));
    expect(visible.state, SessionState.ready);
  });

  test('a host stall holds presentation, then catches up', () async {
    lab.run(NetworkScenario.hostStall, rejoin: rejoin);
    await frames(const Duration(seconds: 1));

    expect(lab.host.game.paused, isTrue);
    expect(smoothing(), everyElement(InterpolationState.holding));

    await frames(const Duration(seconds: 2));
    expect(lab.host.game.paused, isFalse);
    expect(smoothing(), everyElement(InterpolationState.interpolating));
    expect(visible.state, SessionState.ready);
  });

  test('a client stall makes the host hold and coalesce its state', () async {
    lab.run(NetworkScenario.clientStall, rejoin: rejoin);
    await frames(const Duration(seconds: 2));

    PeerDiagnostics atHost(PeerId? peer) =>
        lab.host.diagnostics.peers.singleWhere((view) => view.peer == peer);
    final stalled = atHost(lab.peer.localPeer);
    expect(lab.peer.game.paused, isTrue);
    // One entry for each of the three avatars, the latest values only.
    expect(stalled.heldState.messages, 3);
    expect(stalled.coalescedStates, greaterThan(0));
    // The state threshold, plus at most one outstanding ping.
    expect(stalled.outgoing.messages, lessThanOrEqualTo(33));
    expect(atHost(visible.localPeer).heldState.messages, 0);

    await frames(const Duration(seconds: 3));
    expect(lab.peer.game.paused, isFalse);
    expect(lab.host.diagnostics.heldState.messages, 0);
    expect(lab.peer.state, SessionState.ready);
    expect(lab.peer.game.avatars, hasLength(3));
  });

  test('dropping and rejoining returns resources to their baseline', () async {
    final host = _resources(lab.host.diagnostics);
    final client = _resources(visible.diagnostics);
    expect(lab.network.links, hasLength(2));

    for (var cycle = 0; cycle < 5; cycle++) {
      final previous = visible.localPeer;
      lab.run(NetworkScenario.dropAndRejoin, rejoin: rejoin);
      await frames(const Duration(milliseconds: 500));
      expect(visible.state, SessionState.disconnected);
      expect(lab.host.game.avatars, hasLength(2));

      await frames(const Duration(seconds: 2));
      expect(visible.state, SessionState.ready);
      expect(visible.localPeer, isNot(previous));
      expect(_resources(lab.host.diagnostics), host, reason: 'cycle $cycle');
      expect(_resources(visible.diagnostics), client, reason: 'cycle $cycle');
      expect(lab.network.links, hasLength(2));
      expect(visible.game.avatars, hasLength(3));
    }
  });

  test('disposing the lab releases its timers and links', () async {
    lab.run(NetworkScenario.latencySpike, rejoin: rejoin);
    await frames(const Duration(milliseconds: 100));

    visible.dispose();
    lab.dispose();

    expect(clock.pendingTimerCount, 0);
    expect(lab.network.links, isEmpty);
  });
}
