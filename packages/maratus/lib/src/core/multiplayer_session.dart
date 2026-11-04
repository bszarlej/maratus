import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import '../protocol/identifiers.dart';
import '../protocol/messages.dart';
import '../protocol/protocol_codec.dart';
import '../protocol/protocol_exception.dart';
import '../protocol/rpc.dart';
import '../protocol/schema.dart';
import '../protocol/spawn_type.dart';
import '../protocol/sync_field.dart';
import '../protocol/value_codec.dart';
import '../protocol/wire_codec.dart';
import '../transport/multiplayer_peer.dart';
import 'clock.dart';
import 'entity_registry.dart';
import 'session_events.dart';

part 'rpc_dispatcher.dart';
part 'entity_attachment.dart';
part '../replication/spawn_replicator.dart';
part '../replication/state_replicator.dart';

/// How long a session waits for each stage of joining.
final class SessionTimeouts {
  /// Creates timeouts for the [handshake] and the [bootstrap].
  const SessionTimeouts({
    this.handshake = const Duration(seconds: 10),
    this.bootstrap = const Duration(seconds: 30),
  });

  /// How long a client may take from starting to join until the host
  /// accepts it, and how long a host waits for a new connection's hello,
  /// from the update that handles the connection.
  final Duration handshake;

  /// How long a client may take, once accepted, to become ready: to receive
  /// the host's baseline and install its entities, for example while their
  /// components load.
  final Duration bootstrap;
}

/// Observes a state message after the session accepted it, with its sender.
///
/// The session itself applies state to [MultiplayerSynchronizer]s; a handler
/// only observes it, for example to count replication traffic. Spawn and
/// despawn records reach [MultiplayerSession.bindSpawn] handlers, and RPCs
/// [MultiplayerSession.bindRpc] handlers.
typedef SessionMessageHandler =
    void Function(PeerId sender, MessageEnvelope envelope);

/// One multiplayer session: a host and the clients connected to it.
///
/// A session runs over a [MultiplayerPeer]: [host] hosts on a host peer, and
/// [join] joins a host through a client peer. Transport events are handled in
/// [update], which runs the handshake and enforces [timeouts]. Local actions
/// such as [close] take effect immediately. Changes are
/// reported as [SessionEvent]s, taken with [poll].
///
/// The host accepts a client's hello only if the client's schema has the
/// same fingerprint, and then assigns it a [PeerId] and a connection
/// generation. Every later message on that connection carries the
/// generation, and messages that carry another one are dropped as stale.
/// The host attributes each message to the connection it arrived on, never
/// to an identity that the message claims.
///
/// Each time a session starts hosting, it chooses a new [epoch], and its
/// peer IDs and entity IDs start over. A client that joins again, even the
/// same host, gets a new peer ID and generation, and starts from an empty
/// [registry].
///
/// Replicated changes are ordered by a single [revision] that the host
/// advances. The host welcomes a client with the revision of its baseline,
/// and the client applies later changes only in increasing revision order.
/// A joining client keeps applying them while it installs the baseline, and
/// reports ready, with the latest revision it applied, once every entity of
/// the baseline is ready.
///
/// The host creates replicated entities with [spawn] and removes them with
/// [despawn]; each peer creates their local representation through
/// [bindSpawn] handlers. Each entity's authority sends its synchronized
/// properties when [captureState] runs, and the host relays them, so only
/// the authority writes them. A joining client receives the live entities
/// and their latest values in its baseline, and every later change after it.
final class MultiplayerSession {
  /// Creates a session for the messages of [schema], timed by [clock].
  ///
  /// [random] chooses epochs. State messages that the session accepts are
  /// also passed to [onMessage]; RPCs use [bindRpc], spawned entities
  /// [bindSpawn], and synchronized properties [EntityAttachment.synchronize].
  /// Both [timeouts] must be positive, as must all [pendingRpcLimits], or an
  /// [ArgumentError] is thrown.
  MultiplayerSession({
    required ProtocolSchema schema,
    MonotonicClock clock = const SystemClock(),
    this.timeouts = const SessionTimeouts(),
    this.pendingRpcLimits = const PendingRpcLimits(),
    Random? random,
    SessionMessageHandler? onMessage,
  }) : _schema = schema,
       _codec = ProtocolCodec(schema),
       _clock = clock,
       _random = random ?? Random(),
       _onMessage = onMessage {
    if (timeouts.handshake <= Duration.zero ||
        timeouts.bootstrap <= Duration.zero) {
      throw ArgumentError.value(timeouts, 'timeouts', 'must be positive');
    }
    if (pendingRpcLimits.maxMessages <= 0 ||
        pendingRpcLimits.maxBytes <= 0 ||
        pendingRpcLimits.maxAge <= Duration.zero) {
      throw ArgumentError.value(
        pendingRpcLimits,
        'pendingRpcLimits',
        'limits must be positive',
      );
    }
  }

  final ProtocolSchema _schema;
  final ProtocolCodec _codec;
  final MonotonicClock _clock;
  final Random _random;
  final SessionMessageHandler? _onMessage;
  late final _rpcDispatcher = _RpcDispatcher(this);
  late final _attachments = _EntityAttachments(this);
  late final _spawns = _SpawnReplicator(this);
  late final _states = _StateReplicator(this);

  /// How long this session waits for each stage of joining.
  final SessionTimeouts timeouts;

  /// Bounds local RPCs waiting for an attached entity's update boundary.
  final PendingRpcLimits pendingRpcLimits;

  /// The number of accepted local RPCs awaiting attachment readiness/update.
  int get pendingRpcCount => _attachments.pendingCount;

  /// The encoded delivery-envelope bytes retained by pending local RPCs.
  int get pendingRpcBytes => _attachments.pendingBytes;

  /// The networked entities of the current session.
  final registry = EntityRegistry();

  final _events = Queue<SessionEvent>();
  final _remotes = <PeerConnection, _Remote>{};
  final _peers = <PeerId, _Remote>{};
  MultiplayerPeer? _peer;
  var _isHost = false;
  var _state = SessionState.disconnected;
  DisconnectReason? _disconnectReason;
  PeerId? _localPeer;
  int? _epoch;
  int? _lastEpoch;
  var _revision = 0;
  var _nextClient = 2;
  var _nextGeneration = 1;
  Duration? _joinDeadline;
  var _staleMessages = 0;
  var _obsoleteMessages = 0;
  var _updating = false;

  /// The state of this session.
  SessionState get state => _state;

  /// Whether this session hosts, or last hosted, rather than joined.
  bool get isHost => _isHost;

  /// Why this session disconnected, or `null` if it is not disconnected or
  /// has never started.
  DisconnectReason? get disconnectReason => _disconnectReason;

  /// The ID of this peer: [PeerId.host] while hosting, and the ID the host
  /// assigned while joined. `null` otherwise.
  PeerId? get localPeer => _localPeer;

  /// Identifies the host's session: chosen when hosting starts, and learned
  /// from the host when joined. `null` otherwise.
  int? get epoch => _epoch;

  /// For a joined client, the generation of its connection to the host;
  /// otherwise `null`.
  int? get generation => _isHost ? null : _peers[PeerId.host]?.generation;

  /// The replication revision: on a host, the latest one it assigned; on a
  /// client, the latest one it applied.
  int get revision => _revision;

  /// The peers this session exchanges messages with: on a host, the clients
  /// it accepted; on a client, the host once it accepted this client.
  List<PeerId> get peers => List.unmodifiable(_peers.keys);

  /// Whether [peer] takes part in gameplay: on a host, whether the client
  /// reported ready; on a client, whether [peer] is the host and this
  /// client is ready.
  bool isReady(PeerId peer) => _peers[peer]?.state == _RemoteState.ready;

  /// The number of messages dropped because they carried the generation of
  /// another connection.
  int get staleMessageCount => _staleMessages;

  /// The number of replicated messages dropped because their revision was
  /// not newer than the client's.
  int get obsoleteMessageCount => _obsoleteMessages;

  /// While a client synchronizes, the number of live entities from its
  /// baseline that are not ready yet; otherwise zero.
  ///
  /// The client reports ready once the whole baseline has arrived and this
  /// count is zero, so it can serve as loading progress.
  int get pendingBaselineCount => _spawns.pendingBaselineCount;

  /// Starts hosting a new session on [peer], with a new [epoch].
  ///
  /// The session takes over [peer] and closes it when it disconnects.
  /// Throws an [ArgumentError] if [peer] is not a host peer, and a
  /// [StateError] if the session is not disconnected.
  void host(MultiplayerPeer peer) {
    if (!peer.isHost) {
      throw ArgumentError.value(peer, 'peer', 'must be a host peer');
    }
    _start(peer, isHost: true);
    int epoch;
    do {
      epoch = 1 + _random.nextInt(0xffffffff);
    } while (epoch == _lastEpoch);
    _epoch = _lastEpoch = epoch;
    _localPeer = PeerId.host;
    _setState(SessionState.hosting);
  }

  /// Starts joining the host that [peer] connects to.
  ///
  /// The session takes over [peer] and closes it when it disconnects.
  /// Throws an [ArgumentError] if [peer] is a host peer, and a [StateError]
  /// if the session is not disconnected.
  void join(MultiplayerPeer peer) {
    if (peer.isHost) {
      throw ArgumentError.value(peer, 'peer', 'must be a client peer');
    }
    _start(peer, isHost: false);
    _joinDeadline = _clock.now + timeouts.handshake;
    _setState(SessionState.connecting);
  }

  /// Takes the peer's events, advances the handshake, and enforces
  /// [timeouts].
  ///
  /// Received spawn, despawn, and state records are applied as their events
  /// are handled. Ready synchronizers then receive the latest values of the
  /// entities this peer does not write, before queued RPCs for attached
  /// entities run. A joining client then reports ready if every entity of
  /// its baseline is ready. Deadlines are checked last, at this update
  /// boundary, so a queued reply or a completed installation takes
  /// precedence even when this method runs after the deadline.
  /// Has no effect while the session is disconnected.
  /// Throws a [StateError] if called recursively, during [captureState], or
  /// from an RPC or spawn handler, including a handler invoked by a local
  /// [callRpc] or [spawn].
  void update() {
    _checkNotRunning();
    final peer = _peer;
    if (peer == null) return;
    _updating = true;
    try {
      _rpcDispatcher.prune();
      _attachments.reconcile();
      for (var event = peer.poll(); event != null; event = peer.poll()) {
        _handle(event);
        if (_peer != peer) return;
      }
      _states.apply();
      if (_peer != peer) return;
      _attachments.flush();
      if (_peer != peer) return;
      _install();
      if (_peer != peer) return;
      _enforceDeadlines();
    } finally {
      _updating = false;
    }
  }

  /// Samples the synchronized properties of the entities this peer is the
  /// authority for, and sends the fields that are due.
  ///
  /// Call this after gameplay has updated those properties, as
  /// `MultiplayerScope` does after `captureNetworkState`. Each
  /// [MultiplayerSynchronizer] samples at most once per interval of the
  /// session's clock, however often this runs, and only while its attachment
  /// is ready. A host sends each change to every joined client; a client
  /// sends it to the host, which relays it. Failures are reported as
  /// [PropertySyncFailed] events. Has no effect unless hosting or ready.
  /// Throws a [StateError] if called recursively, during [update], or from an
  /// RPC or spawn handler.
  void captureState() {
    _checkNotRunning();
    if (_state != SessionState.hosting && _state != SessionState.ready) return;
    _states.capture();
  }

  void _checkNotRunning() {
    if (_updating ||
        _states.isCapturing ||
        _rpcDispatcher.isInvoking ||
        _spawns.isInvoking) {
      throw StateError('A session update or handler is already running.');
    }
  }

  /// Removes and returns the oldest pending event, or returns `null` if
  /// there is none.
  SessionEvent? poll() => _events.isEmpty ? null : _events.removeFirst();

  /// Attaches an entity to a local lifecycle whose readiness may be delayed.
  ///
  /// The predicates are checked during [update] and before dispatch. They must
  /// synchronously report whether this attachment still belongs to its local
  /// lifecycle and whether it may handle RPCs. A false [isValid] disposes the
  /// attachment permanently; false [isReady] retains accepted calls within
  /// [pendingRpcLimits]. Readiness marks a pending registry entity ready.
  ///
  /// Bind handlers through the returned attachment. All its local calls run
  /// during [update], including calls to an already ready entity from the host.
  /// An entity may have one live attachment and no existing unmanaged bindings.
  /// Throws [ArgumentError] for a foreign or removed entity, and [StateError]
  /// for a duplicate attachment or conflicting unmanaged bindings.
  EntityAttachment attachEntity(
    NetworkEntity entity, {
    required bool Function() isReady,
    required bool Function() isValid,
  }) => _attachments.attach(entity, isReady: isReady, isValid: isValid);

  /// Binds [handler] to a registered [rpc] on this registry's [entity].
  ///
  /// A pending entity may be bound before it is ready. Calls run only while
  /// the entity is ready and the returned binding has not been disposed.
  /// Duplicate live bindings throw a [StateError]; foreign handles or
  /// entities throw an [ArgumentError]. Disconnecting disposes all bindings.
  /// Attached entities must instead use [EntityAttachment.bindRpc].
  RpcBinding bindRpc<T>(
    NetworkEntity entity,
    Rpc<T> rpc,
    RpcHandler<T> handler,
  ) => _rpcDispatcher.bind(entity, rpc, handler);

  /// Invokes [rpc] on [entity], optionally selecting [peer] for [RpcTarget.peer].
  ///
  /// Clients enqueue a request to the host. The host validates permission,
  /// chooses ready destinations, and dispatches locally or enqueues deliveries.
  /// A caller executes only if selected and [Rpc.local] is [RpcLocal.include].
  ///
  /// Returns local queue/dispatch acceptance, not a remote acknowledgement or
  /// gameplay result. On a host, all selected deliveries must be accepted;
  /// a broadcast may partially enqueue before returning false. No selected
  /// destinations returns false. Rejections and handler errors are reported
  /// by [RpcRejected] and [RpcHandlerFailed] events.
  ///
  /// Throws [StateError] unless hosting or ready, and [ArgumentError] for a
  /// foreign RPC handle or payload that cannot make a codec/wire round trip.
  /// Unattached local host handlers run during this call. Attached handlers
  /// always run in [update], after their lifecycle reports ready. A pending
  /// attached entity may accept calls before its component is ready.
  bool callRpc<T>(
    NetworkEntity entity,
    Rpc<T> rpc,
    T payload, {
    PeerId? peer,
  }) => _rpcDispatcher.call(entity, rpc, payload, peer: peer);

  /// Spawns a replicated entity of [type], built from [data], on every peer.
  ///
  /// Only a hosting session spawns entities. It allocates the entity ID and
  /// a replication revision, sends the spawn record to every joined client,
  /// including clients that are still synchronizing, and then calls the
  /// handler bound to [type] with [bindSpawn], if any. Clients that join
  /// later receive the entity in their baseline. The returned entity starts
  /// pending; an attachment or [EntityRegistry.markReady] makes it ready.
  ///
  /// [owner] controls the entity's input and must be the host or a joined
  /// client. [authority] is fixed for the entity's lifetime and must be the
  /// host or [owner]. A [parent] must be a replicated entity of this
  /// session; despawning it also despawns this entity. [onOwnerLeft] decides
  /// what happens to the entity when a client [owner] leaves.
  ///
  /// Throws a [StateError] unless hosting, and an [ArgumentError] for a
  /// foreign [type] handle, invalid metadata, or [data] that cannot make a
  /// codec and wire round trip. Nothing is spawned when it throws.
  NetworkEntity spawn<T>(
    SpawnType<T> type,
    T data, {
    PeerId owner = PeerId.host,
    PeerId authority = PeerId.host,
    NetworkEntity? parent,
    OwnerLeftPolicy onOwnerLeft = OwnerLeftPolicy.keep,
  }) => _spawns.spawn(
    type,
    data,
    owner: owner,
    authority: authority,
    parent: parent,
    onOwnerLeft: onOwnerLeft,
  );

  /// Despawns the replicated [entity] and its descendants on every peer.
  ///
  /// Only a hosting session despawns entities. It sends a single despawn
  /// record, with a new replication revision, to every joined client, then
  /// calls the bound despawn handlers, children before their parents.
  /// Returns `false`, sending nothing, if this session's [entity] was already
  /// removed, so reacting to a despawn cannot echo another one.
  ///
  /// Throws a [StateError] unless hosting, and an [ArgumentError] for an
  /// entity of another registry, or a live one that was not spawned.
  bool despawn(NetworkEntity entity) => _spawns.despawn(entity);

  /// Binds handlers that create and release the local representation of
  /// replicated entities of [type], such as their components.
  ///
  /// [onSpawn] runs at once for each live entity of [type], in spawn order,
  /// then for each one spawned while the binding is live: on the host inside
  /// [spawn], and on a client during [update], as the spawn record is
  /// applied. A handler can therefore attach an entity before RPCs that
  /// arrive in the same update are dispatched. [onDespawn] runs when one of
  /// those entities is despawned, including by its owner's departure or the
  /// end of the session. Each handler receives its own copy of the
  /// construction data. Handler exceptions are reported as
  /// [SpawnHandlerFailed] events.
  ///
  /// A joining client reports ready only once the entities of its baseline
  /// are ready, so [onSpawn] must attach them, as a component does, or mark
  /// them ready. If [onSpawn] throws for a baseline entity that is not ready
  /// yet, the client leaves with [DisconnectReason.bootstrapFailed].
  ///
  /// A type has at most one live binding. Bindings survive session restarts
  /// until they are disposed. Throws an [ArgumentError] for a foreign [type]
  /// handle and a [StateError] if [type] already has a live binding.
  SpawnBinding bindSpawn<T>(
    SpawnType<T> type, {
    required SpawnHandler<T> onSpawn,
    DespawnHandler? onDespawn,
  }) => _spawns.bind(type, onSpawn: onSpawn, onDespawn: onDespawn);

  /// Advances the replication [revision] for a new replicated change, and
  /// returns it.
  ///
  /// Throws a [StateError] if all wire-safe revision numbers have been used.
  int _nextRevision() {
    if (_revision == IntCodec.maxSafe) {
      throw StateError('No replication revisions are left in this session.');
    }
    return ++_revision;
  }

  /// Sends a replication [message] at [revision] to every joined client
  /// except [except], then removes the clients whose transports refused it.
  ///
  /// Removal waits until every client has been offered the message, so the
  /// cleanup of a departure never interleaves with it.
  void _replicate(ProtocolMessage message, int revision, {_Remote? except}) {
    final refused = <_Remote>[];
    for (final remote in _peers.values.toList()) {
      if (identical(remote, except)) continue;
      if (!_transmit(remote, message, revision: revision)) refused.add(remote);
    }
    refused.forEach(_refused);
  }

  /// Removes the client [peer], telling it that it was kicked.
  ///
  /// Returns whether [peer] was a client of this host.
  bool kick(PeerId peer) {
    final remote = _isHost ? _peers[peer] : null;
    if (remote == null) return false;
    _drop(remote, DisconnectReason.kicked, notify: true);
    return true;
  }

  /// Closes the session and its peer.
  ///
  /// A host removes every client, without despawning their entities for
  /// each other first. Closing a disconnected session has no effect.
  void close() {
    if (_peer == null) return;
    if (_isHost) {
      for (final remote in _remotes.values.toList()) {
        _drop(remote, DisconnectReason.closed, release: false);
      }
    }
    _disconnect(DisconnectReason.closed);
  }

  void _start(MultiplayerPeer peer, {required bool isHost}) {
    if (_state != SessionState.disconnected) {
      throw StateError('The session is already ${_state.name}.');
    }
    _peer = peer;
    _isHost = isHost;
    _revision = 0;
    _nextClient = 2;
    _nextGeneration = 1;
    _staleMessages = 0;
    _obsoleteMessages = 0;
    _rpcDispatcher.clear();
    _spawns.clear();
    _states.clear();
    registry.clear();
  }

  void _handle(PeerEvent event) {
    switch (event) {
      case ConnectionOpened(:final connection):
        _opened(connection);
      case MessageReceived(:final connection, :final message):
        final remote = _remotes[connection];
        if (remote != null) _receive(remote, message);
      case ConnectionClosed(:final connection, :final reason):
        final remote = _remotes[connection];
        if (remote != null) {
          _drop(remote, _closeReason(reason));
        } else if (!_isHost) {
          // The connection to the host closed before it opened.
          _disconnect(_closeReason(reason));
        }
    }
  }

  void _opened(PeerConnection connection) {
    if (_isHost) {
      _remotes[connection] = _Remote(
        connection,
        deadline: _clock.now + timeouts.handshake,
      );
      return;
    }
    final remote = _remotes[connection] = _Remote(
      connection,
      deadline: _joinDeadline,
    );
    if (!_send(remote, HelloMessage(fingerprint: _schema.fingerprint))) return;
    _setState(SessionState.handshaking);
  }

  void _receive(_Remote remote, Uint8List bytes) {
    final MessageEnvelope envelope;
    try {
      envelope = _codec.decode(bytes);
    } on ProtocolException catch (error) {
      _drop(
        remote,
        error.code == ProtocolErrorCode.unsupportedVersion
            ? DisconnectReason.versionMismatch
            : DisconnectReason.protocolViolation,
        notify: true,
      );
      return;
    }
    // A welcome assigns the connection's generation, which every other
    // message must carry.
    final assigning =
        !_isHost &&
        remote.state == _RemoteState.handshaking &&
        envelope.message is WelcomeMessage;
    if (!assigning && envelope.generation != remote.generation) {
      _staleMessages++;
      return;
    }
    if (_isHost) {
      _receiveFromClient(remote, envelope);
    } else {
      _receiveFromHost(remote, envelope);
    }
  }

  void _receiveFromClient(_Remote remote, MessageEnvelope envelope) {
    switch ((remote.state, envelope.message)) {
      case (_, GoodbyeMessage(:final reason)):
        _drop(remote, _goodbyeReason(reason));
      case (_RemoteState.handshaking, HelloMessage(:final fingerprint)):
        if (fingerprint == _schema.fingerprint) {
          _welcome(remote);
        } else {
          _drop(remote, DisconnectReason.schemaMismatch, notify: true);
        }
      case (_RemoteState.synchronizing, ReadyMessage())
          when envelope.revision >= remote.baseline &&
              envelope.revision <= _revision:
        // The client acknowledges the latest revision it applied: its
        // baseline, or a later change sent while it installed the baseline.
        remote
          ..state = _RemoteState.ready
          ..deadline = null;
        _emit(PeerReady(remote.peer!));
      case (_RemoteState.ready, RpcMessage message):
        _rpcDispatcher.route(remote.peer!, message);
      case (_RemoteState.ready, StateMessage()):
        _states.receive(remote.peer!, envelope, origin: remote);
      default:
        _drop(remote, DisconnectReason.protocolViolation, notify: true);
    }
  }

  void _welcome(_Remote remote) {
    final peer = PeerId(_nextClient++);
    remote
      ..peer = peer
      ..generation = _nextGeneration++
      ..baseline = _revision
      ..state = _RemoteState.synchronizing
      ..deadline = _clock.now + timeouts.bootstrap;
    _peers[peer] = remote;
    _emit(PeerJoined(peer));
    // The baseline holds the live entities, then their latest values.
    if (!_send(
          remote,
          WelcomeMessage(peer: peer, epoch: _epoch!),
          revision: _revision,
        ) ||
        !_spawns.sendBaseline(remote) ||
        !_states.sendBaseline(remote)) {
      return;
    }
    _send(remote, const SyncedMessage(), revision: _revision);
  }

  void _receiveFromHost(_Remote remote, MessageEnvelope envelope) {
    switch ((remote.state, envelope.message)) {
      case (_, GoodbyeMessage(:final reason)):
        _drop(remote, _goodbyeReason(reason));
      case (_RemoteState.handshaking, WelcomeMessage(:final peer, :final epoch))
          when envelope.generation > 0:
        remote
          ..peer = PeerId.host
          ..generation = envelope.generation
          ..state = _RemoteState.synchronizing
          ..deadline = _clock.now + timeouts.bootstrap;
        _peers[PeerId.host] = remote;
        _localPeer = peer;
        _epoch = epoch;
        _revision = envelope.revision;
        _setState(SessionState.synchronizing);
      case (_RemoteState.synchronizing, SpawnMessage message)
          when envelope.revision == _revision:
        // A baseline record: an entity that existed when the host welcomed
        // this client.
        if (!_spawns.applySpawn(message, baseline: true)) {
          _drop(remote, DisconnectReason.protocolViolation, notify: true);
        }
      case (_RemoteState.synchronizing, StateMessage())
          when envelope.revision == _revision:
        // Baseline values of an entity.
        _states.receive(PeerId.host, envelope);
      case (_RemoteState.synchronizing, SyncedMessage())
          when envelope.revision == _revision:
        // The whole baseline arrived. Later changes keep arriving while its
        // entities are installed; [_install] reports ready afterward.
        remote.state = _RemoteState.installing;
      case (
        _RemoteState.installing || _RemoteState.ready,
        SpawnMessage() || DespawnMessage() || StateMessage(),
      ):
        if (envelope.revision <= _revision) {
          _obsoleteMessages++;
          return;
        }
        _revision = envelope.revision;
        final consistent = switch (envelope.message) {
          SpawnMessage message => _spawns.applySpawn(message),
          DespawnMessage message => _spawns.applyDespawn(message),
          _ => true,
        };
        if (!consistent) {
          _drop(remote, DisconnectReason.protocolViolation, notify: true);
        } else if (envelope.message is StateMessage) {
          _states.receive(PeerId.host, envelope);
        }
      case (_RemoteState.ready, RpcDeliveryMessage message):
        _rpcDispatcher.deliver(message);
      default:
        _drop(remote, DisconnectReason.protocolViolation, notify: true);
    }
  }

  /// Reports a joining client ready once every live entity of its baseline
  /// is ready, acknowledging the latest revision it applied, or leaves if
  /// the baseline cannot be installed.
  void _install() {
    final remote = _isHost ? null : _peers[PeerId.host];
    if (remote == null || remote.state != _RemoteState.installing) return;
    if (_spawns.baselineFailed) {
      _drop(remote, DisconnectReason.bootstrapFailed, notify: true);
      return;
    }
    // Count entities whose attachments became ready during this update, such
    // as those attached by spawn handlers. Their synchronizers have already
    // received the latest values.
    _attachments.reconcile();
    if (!identical(_peers[PeerId.host], remote) ||
        _spawns.pendingBaselineCount != 0 ||
        !_send(remote, const ReadyMessage(), revision: _revision)) {
      return;
    }
    remote
      ..state = _RemoteState.ready
      ..deadline = null;
    _setState(SessionState.ready);
  }

  void _enforceDeadlines() {
    final now = _clock.now;
    if (!_isHost && _remotes.isEmpty) {
      // Still connecting.
      final deadline = _joinDeadline;
      if (deadline != null && now >= deadline) {
        _disconnect(DisconnectReason.timeout);
      }
      return;
    }
    for (final remote in _remotes.values.toList()) {
      final deadline = remote.deadline;
      if (deadline != null && now >= deadline) {
        _drop(remote, DisconnectReason.timeout, notify: true);
        if (_peer == null) return;
      }
    }
  }

  /// Ends the connection to [remote] for [reason], first telling it why if
  /// [notify] is set and the reason can be stated in a goodbye.
  ///
  /// On a client, this disconnects the session. On a host, it then applies
  /// the departed client's [OwnerLeftPolicy] to its entities, unless
  /// [release] is false because the whole session is closing.
  void _drop(
    _Remote remote,
    DisconnectReason reason, {
    bool notify = false,
    bool release = true,
  }) {
    if (_remotes[remote.connection] != remote) return;
    final goodbye = notify ? _goodbyeFor(reason) : null;
    if (goodbye != null && !_send(remote, GoodbyeMessage(goodbye))) return;
    remote.connection.close();
    if (!_isHost) {
      _disconnect(reason);
      return;
    }
    _remotes.remove(remote.connection);
    final peer = remote.peer;
    if (peer != null) {
      _peers.remove(peer);
      _emit(PeerLeft(peer, reason));
      if (release) _spawns.peerLeft(peer);
    }
  }

  void _disconnect(DisconnectReason reason) {
    final peer = _peer;
    if (peer == null) return;
    _peer = null;
    peer.close();
    _remotes.clear();
    _peers.clear();
    _localPeer = null;
    _epoch = null;
    _joinDeadline = null;
    _rpcDispatcher.clear();
    _states.clear();
    final ended = _spawns.end();
    registry.clear();
    _setState(SessionState.disconnected, reason);
    // Handlers run last: they may start another session.
    _spawns.release(ended);
  }

  /// Sends [message] to [remote], removing it if the transport refuses.
  bool _send(_Remote remote, ProtocolMessage message, {int revision = 0}) {
    final accepted = _transmit(remote, message, revision: revision);
    if (!accepted) _refused(remote);
    return accepted;
  }

  /// Offers [message] to [remote]'s transport, returning whether it was
  /// accepted. A caller must remove a refusing [remote] with [_refused].
  bool _transmit(_Remote remote, ProtocolMessage message, {int revision = 0}) =>
      remote.connection.send(
        _codec.encode(
          MessageEnvelope(
            message,
            generation: remote.generation,
            revision: revision,
          ),
        ),
      );

  /// Removes [remote] after its transport refused a message.
  void _refused(_Remote remote) {
    final reason = remote.connection.closeReason;
    _drop(
      remote,
      reason == null ? DisconnectReason.transportError : _closeReason(reason),
    );
  }

  void _setState(SessionState state, [DisconnectReason? reason]) {
    _state = state;
    _disconnectReason = reason;
    _emit(SessionStateChanged(state, reason));
  }

  void _emit(SessionEvent event) => _events.add(event);

  static DisconnectReason _closeReason(CloseReason reason) => switch (reason) {
    CloseReason.local => DisconnectReason.closed,
    CloseReason.remote => DisconnectReason.remoteClosed,
    CloseReason.connectFailed ||
    CloseReason.lost ||
    CloseReason.overflow => DisconnectReason.transportError,
  };

  static DisconnectReason _goodbyeReason(GoodbyeReason reason) =>
      switch (reason) {
        GoodbyeReason.kicked => DisconnectReason.kicked,
        GoodbyeReason.versionMismatch => DisconnectReason.versionMismatch,
        GoodbyeReason.schemaMismatch => DisconnectReason.schemaMismatch,
        GoodbyeReason.timeout => DisconnectReason.timeout,
        GoodbyeReason.bootstrapFailed => DisconnectReason.bootstrapFailed,
        GoodbyeReason.protocolViolation => DisconnectReason.protocolViolation,
      };

  static GoodbyeReason? _goodbyeFor(DisconnectReason reason) =>
      switch (reason) {
        DisconnectReason.kicked => GoodbyeReason.kicked,
        DisconnectReason.versionMismatch => GoodbyeReason.versionMismatch,
        DisconnectReason.schemaMismatch => GoodbyeReason.schemaMismatch,
        DisconnectReason.timeout => GoodbyeReason.timeout,
        DisconnectReason.bootstrapFailed => GoodbyeReason.bootstrapFailed,
        DisconnectReason.protocolViolation => GoodbyeReason.protocolViolation,
        DisconnectReason.closed ||
        DisconnectReason.remoteClosed ||
        DisconnectReason.transportError => null,
      };
}

enum _RemoteState {
  handshaking,
  synchronizing,

  /// On a client, the host's state once the baseline has arrived, while the
  /// client installs its entities.
  installing,
  ready,
}

/// The other end of a connection: a client on a host, or the host on a
/// client.
final class _Remote {
  _Remote(this.connection, {required this.deadline});

  final PeerConnection connection;
  PeerId? peer;
  var generation = 0;

  /// The revision of the baseline that the host welcomed a client with.
  var baseline = 0;
  var state = _RemoteState.handshaking;
  Duration? deadline;
}
