import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:maratus_flame/maratus_flame.dart';

import 'chat_game.dart';
import 'chat_protocol.dart';

/// Opens a host transport; injectable so controller tests need no sockets.
typedef HostPeerFactory = Future<MultiplayerPeer> Function(int port);

/// Starts a client transport; injectable so tests can use an in-memory peer.
typedef ClientPeerFactory = MultiplayerPeer Function(Uri uri);

/// Owns one example session and its bounded activity log.
///
/// The [game] advances the session through its multiplayer scope. The widget
/// renders that game and calls [dispose] when the controller goes away.
final class ChatController extends ChangeNotifier {
  /// Uses WebSockets by default, or the supplied transport factories in tests.
  ///
  /// [stateBackpressure] configures when the session holds state for a
  /// congested connection; see [MultiplayerSession.stateBackpressure].
  ChatController({
    HostPeerFactory? bindHost,
    ClientPeerFactory? connectClient,
    bool? hostingSupported,
    this.clock = const SystemClock(),
    QueueLimits stateBackpressure = const QueueLimits(
      maxMessages: 256,
      maxBytes: 1024 * 1024,
    ),
  }) : _bindHost = bindHost ?? _bindWebSocketHost,
       _connectClient = connectClient ?? WebSocketClient.connect,
       canHost = hostingSupported ?? WebSocketHost.isSupported {
    _session = MultiplayerSession(
      schema: _protocol.schema,
      clock: clock,
      stateBackpressure: stateBackpressure,
    );
    game = ChatGame(
      onFrame: _afterGameFrame,
      onRemoved: disconnect,
      clock: clock,
    );
  }

  /// The clock that times the session and its diagnostics.
  final MonotonicClock clock;

  static Future<MultiplayerPeer> _bindWebSocketHost(int port) =>
      WebSocketHost.bind(address: '0.0.0.0', port: port);

  final HostPeerFactory _bindHost;
  final ClientPeerFactory _connectClient;
  final _protocol = ChatProtocol();
  late final MultiplayerSession _session;

  /// The Flame game displayed by the example's GameWidget.
  late final ChatGame game;
  final _activity = <String>[];
  NetworkEntity? _entity;
  var _starting = false;
  var _generation = 0;
  var _disposed = false;
  var _activityVersion = 0;
  var _publishedActivityVersion = 0;
  var _publishedCanSend = false;
  var _notificationPending = false;

  /// Whether this platform can listen for incoming WebSocket connections.
  final bool canHost;

  /// The current session state.
  SessionState get state => _session.state;

  /// The identity assigned to this participant, once accepted.
  PeerId? get localPeer => _session.localPeer;

  /// How many remote peers have finished joining.
  int get readyPeers => _session.peers.where(_session.isReady).length;

  /// A new snapshot of the session's network diagnostics.
  SessionDiagnostics get diagnostics => _session.diagnostics;

  /// Whether a host socket is being bound asynchronously.
  bool get starting => _starting;

  /// Whether another host or join attempt can begin.
  bool get canStart =>
      !_disposed && !_starting && state == SessionState.disconnected;

  /// Whether this participant can send a chat message.
  bool get canSend =>
      !_disposed &&
      game.chatComponent?.isNetworkReady == true &&
      _entity?.state == EntityState.ready &&
      (state == SessionState.hosting || state == SessionState.ready);

  /// Whether avatars that other participants simulate are shown
  /// interpolated between samples.
  bool get smoothing => game.smoothing;

  set smoothing(bool value) {
    if (game.smoothing == value) return;
    game.smoothing = value;
    _notify();
  }

  /// The most recent activity, including received messages and failures.
  List<String> get activity => List.unmodifiable(_activity);

  /// Binds a native host on all interfaces at the supplied port.
  Future<void> host(String portText) async {
    if (!canStart) return;
    final port = int.tryParse(portText);
    if (!canHost || port == null || port < 1 || port > 65535) {
      _append(
        canHost
            ? 'Enter a port from 1 to 65535.'
            : 'Browsers can join a native host.',
      );
      _notify();
      return;
    }
    final generation = ++_generation;
    _starting = true;
    _append('Opening host on port $port...');
    _notify();
    MultiplayerPeer? peer;
    try {
      peer = await _bindHost(port);
      if (_disposed || generation != _generation) {
        peer.close();
        return;
      }
      _session.host(peer);
      _bindEntity();
      _protocol.spawnAvatar(_session, PeerId.host);
      _append('Listening on ws://0.0.0.0:$port/netcode');
      _drainEvents();
    } catch (error) {
      peer?.close();
      if (!_disposed && generation == _generation) {
        _session.close();
        _append('Could not host: $error');
        _drainEvents();
      }
    } finally {
      if (!_disposed && generation == _generation) {
        _starting = false;
        _notify();
      }
    }
  }

  /// Starts joining a native host at a ws:// or wss:// URL.
  void join(String address) {
    if (!canStart) return;
    final uri = Uri.tryParse(address.trim());
    if (uri == null ||
        !const {'ws', 'wss'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      _append('Enter a ws:// or wss:// host URL.');
      _notify();
      return;
    }
    _join(() => _connectClient(uri), 'Joining $uri');
  }

  /// Starts joining a host through a client [peer] that is already
  /// connecting, such as a simulated link, logging [description].
  ///
  /// Closes [peer] if another session is active.
  void joinPeer(MultiplayerPeer peer, {required String description}) {
    if (!canStart) {
      peer.close();
      return;
    }
    _join(() => peer, description);
  }

  void _join(MultiplayerPeer Function() connect, String description) {
    MultiplayerPeer? peer;
    try {
      peer = connect();
      _session.join(peer);
      _bindEntity();
      _append(description);
      _drainEvents();
    } catch (error) {
      peer?.close();
      _session.close();
      _append('Could not join: $error');
      _drainEvents();
    }
    _notify();
  }

  void _bindEntity() {
    final entity = _entity = _protocol.register(_session);
    game.installSession(
      session: _session,
      entity: entity,
      protocol: _protocol,
      onMessage: (sender, text) => _append('Peer ${sender.value}: $text'),
    );
  }

  void _afterGameFrame() {
    if (_disposed) return;
    _drainEvents();
    if (state == SessionState.disconnected && !_starting) {
      _entity = null;
      game.clearSession();
    }
    if (_activityVersion != _publishedActivityVersion ||
        canSend != _publishedCanSend) {
      _notify();
    }
  }

  /// Sends validated text; the sender sees it only when its handler executes.
  bool send(String input) {
    final text = input.trim();
    final entity = _entity;
    if (!canSend || entity == null || text.isEmpty) return false;
    if (text.length > ChatProtocol.messageLimit) {
      _append('Message is too long; use fewer characters.');
      _notify();
      return false;
    }
    final accepted = _session.callRpc(entity, _protocol.message, text);
    if (!accepted) _append('Message was not queued.');
    _drainEvents();
    _notify();
    return accepted;
  }

  /// Closes the current session or cancels a pending host bind.
  void disconnect() {
    if (_disposed) return;
    _generation++;
    _starting = false;
    _entity = null;
    game.clearSession();
    _session.close();
    _drainEvents();
    _notify();
  }

  void _notify() {
    if (_disposed || _notificationPending) return;
    // GameWidget can issue its first update from layout. Defer changes to the
    // surrounding Flutter controls until that frame is finished.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _notificationPending = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _notificationPending = false;
        if (!_disposed) _publish();
      });
    } else {
      _publish();
    }
  }

  void _publish() {
    _publishedActivityVersion = _activityVersion;
    _publishedCanSend = canSend;
    notifyListeners();
  }

  void _drainEvents() {
    for (var event = _session.poll(); event != null; event = _session.poll()) {
      _protocol.spawnJoinedAvatar(_session, event);
      _append(describeEvent(event));
    }
  }

  void _append(String text) {
    _activity.add(text);
    _activityVersion++;
    if (_activity.length > 100) _activity.removeAt(0);
  }

  /// Closes the session and the game. Repeated disposal has no effect.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    game.dispose();
    _session.close();
    super.dispose();
  }
}
