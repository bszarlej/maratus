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
import '../protocol/static_entity.dart';
import '../protocol/sync_field.dart';
import '../protocol/value_codec.dart';
import '../protocol/wire_codec.dart';
import '../transport/multiplayer_peer.dart';
import 'admission.dart';
import 'clock.dart';
import 'entity_registry.dart';
import 'session_events.dart';

part 'rpc_dispatcher.dart';
part 'entity_attachment.dart';
part 'session_diagnostics.dart';
part '../replication/interpolation.dart';
part '../replication/spawn_replicator.dart';
part '../replication/state_replicator.dart';

/// How long a session waits for each stage of joining, and optionally for
/// an accepted peer that has gone quiet.
final class SessionTimeouts {
  /// Creates timeouts for the [handshake], the [bootstrap], and an optional
  /// [idle] connection.
  const SessionTimeouts({
    this.handshake = const Duration(seconds: 10),
    this.bootstrap = const Duration(seconds: 30),
    this.idle,
  });

  /// How long a client may take from starting to join until the host
  /// accepts it, and how long a host waits for a new connection's hello and
  /// the decision of its [MultiplayerSession.onJoinRequest] handler, from
  /// the update that handles the connection.
  final Duration handshake;

  /// How long a client may take, once accepted, to become ready: to receive
  /// the host's baseline and install its entities, for example while their
  /// components load.
  final Duration bootstrap;

  /// How long a session waits for any message from an accepted peer before
  /// dropping it with [DisconnectReason.timeout], or `null`, the default,
  /// to wait as long as its transport stays open.
  ///
  /// Each peer pings the other at its [MultiplayerSession.pingInterval], so
  /// an updating peer is never idle. This detects a peer that stopped
  /// updating, or whose connection broke without closing. A host that
  /// pauses for longer loses its clients. Requires a ping interval shorter
  /// than this timeout.
  final Duration? idle;
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
/// same fingerprint, and admits the client only while [admitting] and if its
/// [onJoinRequest] handler, if any, agrees. It then welcomes the client with
/// a [PeerId] and a connection generation; until then, nothing replicated
/// reaches the client. Every later message on that connection carries the
/// generation, and messages that carry another one are dropped as stale.
/// The host attributes each message to the connection it arrived on, never
/// to an identity that the message claims.
///
/// Each time a session starts hosting, it chooses a new [epoch], and its
/// peer IDs and entity IDs start over. A client that joins again, even the
/// same host, gets a new peer ID and generation, and starts from an empty
/// [registry].
///
/// Once a connection is accepted, each side pings the other at
/// [pingInterval] to measure the round trip, which [diagnostics] reports
/// with the session's traffic, queues, and resources. With
/// [SessionTimeouts.idle], a peer that sends nothing for that long is
/// dropped.
///
/// Replicated changes are ordered by a single [revision] that the host
/// advances. The host welcomes a client with the revision of its baseline,
/// and the client applies later changes only in increasing revision order.
/// A joining client keeps applying them while it installs the baseline, and
/// reports ready, with the latest revision it applied, once every entity of
/// the baseline is ready.
///
/// The schema's static entities exist on every peer, with the same IDs, as
/// soon as it starts hosting or joining; [staticEntity] returns them. The
/// host creates replicated entities with [spawn] and removes them with
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
  /// All [timeouts] must be positive, as must all [pendingRpcLimits],
  /// [stateBackpressure], and a [pingInterval], or an [ArgumentError] is
  /// thrown. An idle timeout also requires a shorter [pingInterval].
  MultiplayerSession({
    required ProtocolSchema schema,
    MonotonicClock clock = const SystemClock(),
    this.timeouts = const SessionTimeouts(),
    this.pendingRpcLimits = const PendingRpcLimits(),
    this.pingInterval = const Duration(seconds: 1),
    this.stateBackpressure = const QueueLimits(
      maxMessages: 256,
      maxBytes: 1024 * 1024,
    ),
    Random? random,
    SessionMessageHandler? onMessage,
  }) : _schema = schema,
       _codec = ProtocolCodec(schema),
       _clock = clock,
       _random = random ?? Random(),
       _onMessage = onMessage {
    final idle = timeouts.idle;
    if (timeouts.handshake <= Duration.zero ||
        timeouts.bootstrap <= Duration.zero ||
        (idle != null && idle <= Duration.zero)) {
      throw ArgumentError.value(timeouts, 'timeouts', 'must be positive');
    }
    final ping = pingInterval;
    if (ping != null && ping <= Duration.zero) {
      throw ArgumentError.value(ping, 'pingInterval', 'must be positive');
    }
    if (idle != null && (ping == null || ping >= idle)) {
      throw ArgumentError.value(
        ping,
        'pingInterval',
        'must be shorter than the idle timeout',
      );
    }
    if (stateBackpressure.maxMessages <= 0 || stateBackpressure.maxBytes <= 0) {
      throw ArgumentError.value(
        stateBackpressure,
        'stateBackpressure',
        'limits must be positive',
      );
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

  /// How often this session pings each accepted peer to measure the round
  /// trip, or `null` to send no pings.
  ///
  /// The first ping follows one interval after the peer is accepted, and a
  /// session waits for each answer before sending the next ping. A session
  /// always answers the other side's pings.
  final Duration? pingInterval;

  /// The outgoing queue depth at which a connection is congested, so that
  /// state for it waits in the session instead of its transport.
  ///
  /// Synchronized state is replaceable: while a connection's
  /// [PeerConnection.outgoing] queue reaches either limit, as when its peer
  /// stops polling, newer state for an entity replaces state that has not
  /// been sent, keeping one waiting entry per entity. Waiting state is sent
  /// in order once the queue drains, and before any other message to that
  /// peer, so state never overtakes spawning, despawning, or RPCs. Other
  /// messages are not replaceable and still close a connection whose
  /// transport queue overflows.
  final QueueLimits stateBackpressure;

  /// Decides whether this host admits each client that asks to join, or
  /// `null`, the default, to admit every client while [admitting].
  ///
  /// The host calls it during [update], once a client's hello arrives with
  /// the same schema fingerprint, with the client's validated join request
  /// and the peer ID that the client gets if admitted. Until the decision,
  /// the client receives nothing from the session, and the host neither
  /// lists it in [peers] nor reports it: [PeerJoined] follows admission. A
  /// decision that the handler completes later takes effect at the next
  /// [update]. The handshake timeout covers the decision, so a client that
  /// is still undecided when it expires is turned away with
  /// [DisconnectReason.timeout].
  ///
  /// A rejected client disconnects with [DisconnectReason.rejected] and the
  /// reason given to [Admission.reject] as its [rejectionReason]. A handler
  /// that throws, or whose future fails, rejects the client without a reason
  /// and reports [AdmissionFailed].
  AdmissionHandler? onJoinRequest;

  /// Whether this host admits new clients, `true` by default.
  ///
  /// While `false`, the host turns away each client whose hello arrives with
  /// [DisconnectReason.notAdmitting], without calling [onJoinRequest], for
  /// example once a match has started. Clients whose request is already
  /// being decided are unaffected; a handler can check this flag itself,
  /// for example after awaiting a backend.
  bool admitting = true;

  /// The number of accepted local RPCs awaiting attachment readiness/update.
  int get pendingRpcCount => _attachments.pendingCount;

  /// The encoded delivery-envelope bytes retained by pending local RPCs.
  int get pendingRpcBytes => _attachments.pendingBytes;

  /// The networked entities of the current session.
  final registry = EntityRegistry();

  /// The static entities of the current session, by declaration.
  final _staticEntities = <StaticEntity, NetworkEntity>{};

  final _events = Queue<SessionEvent>();
  final _remotes = <PeerConnection, _Remote>{};
  final _peers = <PeerId, _Remote>{};
  MultiplayerPeer? _peer;
  var _isHost = false;
  var _state = SessionState.disconnected;
  DisconnectReason? _disconnectReason;
  String? _rejectionReason;
  PeerId? _localPeer;
  int? _epoch;
  int? _lastEpoch;
  var _revision = 0;
  var _nextClient = 2;
  var _nextGeneration = 1;
  Duration? _joinDeadline;

  /// The wire value of a joining client's request, sent with its hello.
  Object? _joinRequest;
  var _staleMessages = 0;
  var _obsoleteMessages = 0;
  var _updating = false;
  final _sent = _Traffic();
  final _received = _Traffic();
  var _coalescedStates = 0;

  /// The state of this session.
  SessionState get state => _state;

  /// Whether this session hosts, or last hosted, rather than joined.
  bool get isHost => _isHost;

  /// Why this session disconnected, or `null` if it is not disconnected or
  /// has never started.
  DisconnectReason? get disconnectReason => _disconnectReason;

  /// For a client that the host rejected, with [DisconnectReason.rejected],
  /// the reason that the host gave, if any; otherwise `null`.
  String? get rejectionReason => _rejectionReason;

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

  /// A new snapshot of this session's resources, traffic, and peer
  /// connections, including their queues and round trips.
  SessionDiagnostics get diagnostics => SessionDiagnostics._(
    entities: registry.entities.length,
    replicatedEntities: _spawns._records.length,
    attachments: _attachments._attached.values
        .where((attachment) => !attachment.isDisposed)
        .length,
    synchronizers: _states._synchronizers.values
        .where((synchronizer) => !synchronizer.isDisposed)
        .length,
    rpcBindings: _rpcDispatcher._bindings.values
        .where((binding) => !binding.isDisposed)
        .length,
    spawnBindings: _spawns._bindings.values
        .where((binding) => !binding.isDisposed)
        .length,
    pendingRpcs: (
      messages: _attachments.pendingCount,
      bytes: _attachments.pendingBytes,
    ),
    pendingBaselineEntities: _spawns.pendingBaselineCount,
    pendingConnections: _remotes.length - _peers.length,
    staleMessages: _staleMessages,
    obsoleteMessages: _obsoleteMessages,
    sent: TrafficCounts._(_sent),
    received: TrafficCounts._(_received),
    heldState: _peers.values.fold<QueueDepth>(
      (messages: 0, bytes: 0),
      (total, remote) => (
        messages: total.messages + remote.held.length,
        bytes: total.bytes + remote.heldBytes,
      ),
    ),
    coalescedStates: _coalescedStates,
    peers: List.unmodifiable([
      for (final MapEntry(key: peer, value: remote) in _peers.entries)
        PeerDiagnostics._(
          peer: peer,
          isReady: remote.state == _RemoteState.ready,
          incoming: remote.connection.incoming,
          outgoing: remote.connection.outgoing,
          roundTripTime: remote.roundTripTime,
          smoothedRoundTripTime: remote.smoothedRoundTripTime,
          lastReceivedAt: remote.lastReceivedAt,
          sent: TrafficCounts._(remote.sent),
          received: TrafficCounts._(remote.received),
          heldState: (messages: remote.held.length, bytes: remote.heldBytes),
          coalescedStates: remote.coalescedStates,
        ),
    ]),
  );

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

  /// Starts joining the host that [peer] connects to, asking to be admitted
  /// with [request].
  ///
  /// The session takes over [peer] and closes it when it disconnects.
  /// [request] is the data for the host's [onJoinRequest] handler, such as a
  /// player name or an access token, encoded with the join request codec
  /// that the schema sets with [ProtocolSchemaBuilder.setJoinRequest]. It
  /// must be `null` if the schema sets none.
  ///
  /// Throws an [ArgumentError] if [peer] is a host peer, or if [request] is
  /// invalid for the codec, cannot make a codec and wire round trip, or is
  /// given without a codec. Throws a [StateError] if the session is not
  /// disconnected.
  void join(MultiplayerPeer peer, {Object? request}) {
    if (peer.isHost) {
      throw ArgumentError.value(peer, 'peer', 'must be a client peer');
    }
    final wire = _encodeJoinRequest(request);
    _start(peer, isHost: false);
    _joinRequest = wire;
    _joinDeadline = _clock.now + timeouts.handshake;
    _setState(SessionState.connecting);
  }

  /// Encodes a joining client's [request] as the wire value of its hello,
  /// with its own copy of the data.
  ///
  /// Throws an [ArgumentError] unless [request] makes a round trip through
  /// the schema's join request codec within the wire limits, or if the schema
  /// sets no codec and [request] is not `null`.
  Object? _encodeJoinRequest(Object? request) {
    final entry = _schema.joinRequest;
    if (entry == null) {
      if (request == null) return null;
      throw ArgumentError.value(
        request,
        'request',
        'requires a join request codec in the schema',
      );
    }
    final bytes = _codec.encode(
      MessageEnvelope(
        HelloMessage(
          fingerprint: _schema.fingerprint,
          request: entry.encode(request),
        ),
      ),
    );
    try {
      final hello = _codec.decode(bytes).message as HelloMessage;
      entry.decode(hello.request);
      return hello.request;
    } on ProtocolException catch (error) {
      throw ArgumentError('The join request cannot be decoded: $error');
    }
  }

  /// Takes the peer's events, advances the handshake, and enforces
  /// [timeouts].
  ///
  /// Received spawn, despawn, and state records are applied as their events
  /// are handled. A host then applies the admission decisions completed
  /// since the previous update. Ready synchronizers then receive the latest
  /// values of the entities this peer does not write, before queued RPCs for
  /// attached entities run. A joining client then reports ready if every
  /// entity of its baseline is ready, and pings that are due are sent.
  /// Deadlines are checked last, at this update boundary, so a queued reply,
  /// a completed decision, or a completed installation takes precedence even
  /// when this method runs after the deadline.
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
      _applyAdmissions();
      if (_peer != peer) return;
      _states.apply();
      if (_peer != peer) return;
      _attachments.flush();
      if (_peer != peer) return;
      _install();
      if (_peer != peer) return;
      _drainHeld();
      if (_peer != peer) return;
      _ping();
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
  /// sends it to the host, which relays it. State for a congested peer waits,
  /// replaced by newer values, as [stateBackpressure] describes. Failures
  /// are reported as [PropertySyncFailed] events. Has no effect unless
  /// hosting or ready. Throws a [StateError] if called recursively, during
  /// [update], or from an RPC or spawn handler.
  void captureState() {
    _checkNotRunning();
    if (_state != SessionState.hosting && _state != SessionState.ready) return;
    _states.capture();
    _drainHeld();
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

  /// The entity of the static [entity] declared in the schema, in the current
  /// session.
  ///
  /// Each session registers the schema's static entities when it starts
  /// hosting or joining, before it handles any message, so they exist on
  /// every peer with the same IDs. The host owns them and is their
  /// authority. Like any entity, each starts pending until an attachment or
  /// [EntityRegistry.markReady] makes it ready. Static entities are not
  /// spawned, so [despawn] does not remove them; they are removed when the
  /// session disconnects, and the next session registers them again.
  ///
  /// Throws an [ArgumentError] for a foreign [entity] handle, and a
  /// [StateError] while the session is disconnected.
  NetworkEntity staticEntity(StaticEntity entity) {
    if (!identical(_schema.staticEntityDefinition(entity.id), entity)) {
      throw ArgumentError.value(
        entity,
        'entity',
        'must belong to the session schema',
      );
    }
    return _staticEntities[entity] ??
        (throw StateError('The session is disconnected.'));
  }

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

  /// Throws a [StateError] if no replication revision is left for another
  /// change, before the change is made.
  void _checkRevisionsLeft() {
    if (_revision == IntCodec.maxSafe) {
      throw StateError('No replication revisions are left in this session.');
    }
  }

  /// Sends a spawn or despawn [message] with a new revision to every joined
  /// client, then removes the clients whose transports refused it.
  ///
  /// Each client's held state is sent first, so the message follows it. The
  /// revision is taken afterward, so it exceeds the revisions of that state.
  /// Removal waits until every client has been offered the message, so the
  /// cleanup of a departure never interleaves with it.
  void _replicate(ProtocolMessage message) {
    final refused = <_Remote>[];
    final remotes = _peers.values.toList();
    for (final remote in remotes) {
      if (!_flush(remote, all: true)) refused.add(remote);
    }
    final revision = _nextRevision();
    for (final remote in remotes) {
      if (refused.contains(remote)) continue;
      if (!_transmit(remote, message, revision: revision)) refused.add(remote);
    }
    refused.forEach(_refused);
  }

  /// Sends a state [message] about [entity], whose fields encode as [fields],
  /// to every joined client except [except], with a new revision.
  ///
  /// Clients with held state or a congested connection hold the message
  /// instead; see [stateBackpressure].
  void _replicateState(
    NetworkEntity entity,
    StateMessage message,
    Map<FieldId, Uint8List> fields, {
    _Remote? except,
  }) {
    final revision = _nextRevision();
    final refused = <_Remote>[];
    for (final remote in _peers.values.toList()) {
      if (identical(remote, except)) continue;
      if (remote.held.isNotEmpty || _congested(remote)) {
        _hold(remote, entity, message, fields);
      } else if (!_transmit(remote, message, revision: revision)) {
        refused.add(remote);
      }
    }
    refused.forEach(_refused);
  }

  /// Sends a state [message] about [entity] from a client to the host
  /// [remote], or holds it if the connection is congested. Returns `false`
  /// if the transport refused it, which removes [remote].
  bool _sendState(
    _Remote remote,
    NetworkEntity entity,
    StateMessage message,
    Map<FieldId, Uint8List> fields,
  ) {
    if (remote.held.isNotEmpty || _congested(remote)) {
      _hold(remote, entity, message, fields);
      return true;
    }
    if (_transmit(remote, message)) return true;
    _refused(remote);
    return false;
  }

  /// Whether [remote]'s outgoing queue reached [stateBackpressure].
  bool _congested(_Remote remote) =>
      !stateBackpressure.accepts(remote.connection.outgoing, 0);

  /// Holds state [message] for [remote], replacing the held values of the
  /// same fields of [entity] and moving its entry behind the others.
  void _hold(
    _Remote remote,
    NetworkEntity entity,
    StateMessage message,
    Map<FieldId, Uint8List> fields,
  ) {
    final previous = remote.held.remove(entity.id);
    if (previous != null) {
      remote.coalescedStates++;
      _coalescedStates++;
    }
    // Only an authority's samples and their relays are held, and they all
    // carry a sample time.
    remote.held[entity.id] = _HeldState(entity, {
      ...?previous?.fields,
      ...fields,
    }, message.sampledAt!);
  }

  /// Sends [remote]'s held state, oldest entry first: all of it, or as long
  /// as its connection is not congested. A host gives each message a new
  /// revision, which keeps its revisions increasing for that client.
  ///
  /// State for entities removed in the meantime is dropped. Returns `false`
  /// if the transport refused a message; the caller then removes [remote]
  /// with [_refused].
  bool _flush(_Remote remote, {required bool all}) {
    while (remote.held.isNotEmpty && (all || !_congested(remote))) {
      final id = remote.held.keys.first;
      final held = remote.held.remove(id)!;
      final entity = held.entity;
      if (!identical(registry[id], entity) ||
          entity.state == EntityState.removed) {
        continue;
      }
      for (final message in _states._messages(
        entity,
        held.fields,
        sampledAt: held.sampledAt,
      )) {
        final revision = _isHost ? _nextRevision() : 0;
        if (!_transmit(remote, message, revision: revision)) return false;
      }
    }
    return true;
  }

  /// Sends the held state of every peer whose connection is no longer
  /// congested.
  void _drainHeld() {
    for (final remote in _peers.values.toList()) {
      if (remote.held.isEmpty || _flush(remote, all: false)) continue;
      _refused(remote);
      if (_peer == null) return;
    }
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
    _rejectionReason = null;
    _joinRequest = null;
    _revision = 0;
    _nextClient = 2;
    _nextGeneration = 1;
    _staleMessages = 0;
    _obsoleteMessages = 0;
    _sent.clear();
    _received.clear();
    _coalescedStates = 0;
    _rpcDispatcher.clear();
    _spawns.clear();
    _states.clear();
    registry.clear();
    _staticEntities.clear();
    // Every peer of the session takes the same IDs for the static entities,
    // before handling any message that could refer to them.
    for (final entity in _schema.staticEntities) {
      _staticEntities[entity] = registry.create(
        owner: PeerId.host,
        authority: PeerId.host,
      );
    }
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
    if (!_send(
      remote,
      HelloMessage(fingerprint: _schema.fingerprint, request: _joinRequest),
    )) {
      return;
    }
    _joinRequest = null;
    _setState(SessionState.handshaking);
  }

  void _receive(_Remote remote, Uint8List bytes) {
    final MessageEnvelope envelope;
    try {
      envelope = _codec.decode(bytes);
    } on ProtocolException catch (error) {
      _count(remote.received, _received, null, bytes.length);
      _drop(
        remote,
        error.code == ProtocolErrorCode.unsupportedVersion
            ? DisconnectReason.versionMismatch
            : DisconnectReason.protocolViolation,
        notify: true,
      );
      return;
    }
    _count(remote.received, _received, envelope.message.kind, bytes.length);
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
    if (remote.peer != null) remote.lastReceivedAt = _clock.now;
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
      case (
        _RemoteState.synchronizing || _RemoteState.ready,
        PingMessage(:final sequence),
      ):
        _answer(remote, sequence);
      case (
        _RemoteState.synchronizing || _RemoteState.ready,
        PongMessage(:final sequence),
      ):
        _pong(remote, sequence);
      case (
        _RemoteState.handshaking,
        HelloMessage(:final fingerprint, :final request),
      ):
        if (fingerprint == _schema.fingerprint) {
          _requestAdmission(remote, request);
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
      // A client sends only state that it sampled, with its sample time.
      case (_RemoteState.ready, StateMessage(sampledAt: _?)):
        _states.receive(remote.peer!, envelope, origin: remote);
      default:
        _drop(remote, DisconnectReason.protocolViolation, notify: true);
    }
  }

  /// Validates a hello before consulting application code. A reserved ID
  /// stays separate from membership until the decision is applied.
  void _requestAdmission(_Remote remote, Object? wire) {
    final Object? data;
    try {
      final entry = _schema.joinRequest;
      if (entry == null && wire != null) {
        throw const ProtocolException(
          ProtocolErrorCode.invalidValue,
          'The schema does not accept join request data.',
        );
      }
      data = entry?.decode(wire);
    } on ProtocolException {
      _drop(remote, DisconnectReason.protocolViolation, notify: true);
      return;
    }
    if (!admitting) {
      _drop(remote, DisconnectReason.notAdmitting, notify: true);
      return;
    }
    final peer = PeerId(_nextClient++);
    remote
      ..candidate = peer
      ..state = _RemoteState.admitting;
    final handler = onJoinRequest;
    if (handler == null) {
      _welcome(remote);
      return;
    }
    final FutureOr<Admission> result;
    try {
      result = handler(JoinRequest(peer: peer, data: data));
    } on Object catch (error, stackTrace) {
      _failAdmission(remote, error, stackTrace);
      _applyAdmission(remote);
      return;
    }
    if (result is Future<Admission>) {
      unawaited(
        result.then<void>(
          (decision) => _recordAdmission(remote, decision),
          onError: (Object error, StackTrace stackTrace) =>
              _failAdmission(remote, error, stackTrace),
        ),
      );
    } else {
      _recordAdmission(remote, result);
      _applyAdmission(remote);
    }
  }

  bool _awaitingAdmission(_Remote remote) =>
      identical(_remotes[remote.connection], remote) &&
      remote.state == _RemoteState.admitting;

  void _recordAdmission(_Remote remote, Admission decision) {
    if (_awaitingAdmission(remote)) remote.admission = decision;
  }

  void _failAdmission(_Remote remote, Object error, StackTrace stackTrace) {
    if (!_awaitingAdmission(remote)) return;
    remote
      ..admission = Admission.reject()
      ..admissionFailure = AdmissionFailed(
        peer: remote.candidate!,
        error: error,
        stackTrace: stackTrace,
      );
  }

  /// Future callbacks only store their result; membership and events change
  /// at an update boundary, after queued disconnects have been handled.
  void _applyAdmissions() {
    for (final remote in _remotes.values.toList()) {
      _applyAdmission(remote);
    }
  }

  void _applyAdmission(_Remote remote) {
    final decision = remote.admission;
    if (decision == null || !_awaitingAdmission(remote)) return;
    remote.admission = null;
    if (remote.admissionFailure case final failure?) {
      remote.admissionFailure = null;
      _emit(failure);
    }
    if (decision.isAdmitted) {
      _welcome(remote);
    } else {
      _drop(
        remote,
        DisconnectReason.rejected,
        notify: true,
        detail: decision.reason,
      );
    }
  }

  void _welcome(_Remote remote) {
    final peer = remote.candidate!;
    remote
      ..peer = peer
      ..generation = _nextGeneration++
      ..baseline = _revision
      ..state = _RemoteState.synchronizing
      ..deadline = _clock.now + timeouts.bootstrap;
    _accepted(remote);
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
      case (_, GoodbyeMessage(:final reason, :final detail)):
        _drop(remote, _goodbyeReason(reason), detail: detail);
      case (!= _RemoteState.handshaking, PingMessage(:final sequence)):
        _answer(remote, sequence);
      case (!= _RemoteState.handshaking, PongMessage(:final sequence)):
        _pong(remote, sequence);
      case (_RemoteState.handshaking, WelcomeMessage(:final peer, :final epoch))
          when envelope.generation > 0:
        remote
          ..peer = PeerId.host
          ..generation = envelope.generation
          ..state = _RemoteState.synchronizing
          ..deadline = _clock.now + timeouts.bootstrap;
        _accepted(remote);
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

  /// Starts measuring round trips and idle time for [remote], which was
  /// just accepted.
  void _accepted(_Remote remote) {
    final now = _clock.now;
    remote.lastReceivedAt = now;
    if (pingInterval case final interval?) remote.nextPingAt = now + interval;
  }

  /// Sends a ping to each accepted peer that is due one and has answered
  /// the previous ping.
  ///
  /// Pings and their answers carry no game state, so a refused one leaves
  /// the connection to its transport: a refusing transport reports the
  /// connection closed, after any queued messages that say why.
  void _ping() {
    final now = _clock.now;
    for (final remote in _peers.values.toList()) {
      final due = remote.nextPingAt;
      if (due == null || remote.pingSentAt != null || now < due) continue;
      final sequence = remote.nextPingSequence++;
      if (!_transmit(remote, PingMessage(sequence))) continue;
      remote
        ..pingSequence = sequence
        ..pingSentAt = now;
    }
  }

  /// Answers the ping with [sequence] that [remote] sent.
  ///
  /// As with [_ping], a refusal is left to the transport, so a goodbye
  /// queued after the ping still gives the reason for closing.
  void _answer(_Remote remote, int sequence) =>
      _transmit(remote, PongMessage(sequence));

  /// Records the round trip of the ping that [remote] answered with
  /// [sequence], which must be the outstanding one.
  void _pong(_Remote remote, int sequence) {
    final sentAt = remote.pingSentAt;
    if (sentAt == null || sequence != remote.pingSequence) {
      _drop(remote, DisconnectReason.protocolViolation, notify: true);
      return;
    }
    final roundTrip = _clock.now - sentAt;
    final smoothed = remote.smoothedRoundTripTime;
    remote
      ..pingSentAt = null
      ..pingSequence = null
      ..roundTripTime = roundTrip
      ..smoothedRoundTripTime = smoothed == null
          ? roundTrip
          : smoothed + (roundTrip - smoothed) ~/ 8
      ..nextPingAt = pingInterval == null ? null : sentAt + pingInterval!;
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
    final idle = timeouts.idle;
    for (final remote in _remotes.values.toList()) {
      final deadline = remote.deadline;
      final lastReceivedAt = remote.lastReceivedAt;
      if ((deadline != null && now >= deadline) ||
          (idle != null &&
              lastReceivedAt != null &&
              now - lastReceivedAt >= idle)) {
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
    String? detail,
  }) {
    if (_remotes[remote.connection] != remote) return;
    // State held for a peer that is leaving is never sent.
    remote.held.clear();
    final goodbye = notify ? _goodbyeFor(reason) : null;
    if (goodbye != null &&
        !_send(remote, GoodbyeMessage(goodbye, detail: detail))) {
      return;
    }
    remote.connection.close();
    if (!_isHost) {
      _disconnect(reason, detail: detail);
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

  void _disconnect(DisconnectReason reason, {String? detail}) {
    final peer = _peer;
    if (peer == null) return;
    _peer = null;
    peer.close();
    _remotes.clear();
    _peers.clear();
    _localPeer = null;
    _epoch = null;
    _joinDeadline = null;
    _joinRequest = null;
    _rejectionReason = reason == DisconnectReason.rejected ? detail : null;
    _rpcDispatcher.clear();
    _states.clear();
    final ended = _spawns.end();
    registry.clear();
    _staticEntities.clear();
    _setState(SessionState.disconnected, reason);
    // Handlers run last: they may start another session.
    _spawns.release(ended);
  }

  /// Sends [message] to [remote], removing it if the transport refuses.
  ///
  /// State held for [remote] is sent first, so the message follows it.
  bool _send(_Remote remote, ProtocolMessage message, {int revision = 0}) {
    final accepted =
        _flush(remote, all: true) &&
        _transmit(remote, message, revision: revision);
    if (!accepted) _refused(remote);
    return accepted;
  }

  /// Offers [message] to [remote]'s transport, returning whether it was
  /// accepted. A caller must remove a refusing [remote] with [_refused].
  bool _transmit(_Remote remote, ProtocolMessage message, {int revision = 0}) {
    final bytes = _codec.encode(
      MessageEnvelope(
        message,
        generation: remote.generation,
        revision: revision,
      ),
    );
    if (!remote.connection.send(bytes)) return false;
    _count(remote.sent, _sent, message.kind, bytes.length);
    return true;
  }

  /// Counts a message of [kind] and [size] bytes for a peer and the session.
  static void _count(
    _Traffic peer,
    _Traffic session,
    MessageKind? kind,
    int size,
  ) {
    peer.add(kind, size);
    session.add(kind, size);
  }

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
        GoodbyeReason.rejected => DisconnectReason.rejected,
        GoodbyeReason.notAdmitting => DisconnectReason.notAdmitting,
        GoodbyeReason.versionMismatch => DisconnectReason.versionMismatch,
        GoodbyeReason.schemaMismatch => DisconnectReason.schemaMismatch,
        GoodbyeReason.timeout => DisconnectReason.timeout,
        GoodbyeReason.bootstrapFailed => DisconnectReason.bootstrapFailed,
        GoodbyeReason.protocolViolation => DisconnectReason.protocolViolation,
      };

  static GoodbyeReason? _goodbyeFor(DisconnectReason reason) =>
      switch (reason) {
        DisconnectReason.kicked => GoodbyeReason.kicked,
        DisconnectReason.rejected => GoodbyeReason.rejected,
        DisconnectReason.notAdmitting => GoodbyeReason.notAdmitting,
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
  admitting,
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

  /// Reserved while admission is pending, without making this a member.
  PeerId? candidate;
  Admission? admission;
  AdmissionFailed? admissionFailure;
  var generation = 0;

  /// The revision of the baseline that the host welcomed a client with.
  var baseline = 0;
  var state = _RemoteState.handshaking;
  Duration? deadline;

  /// When this side last handled a message from the remote, once accepted.
  Duration? lastReceivedAt;

  /// When the next ping is due, once accepted and if pings are enabled.
  Duration? nextPingAt;
  var nextPingSequence = 0;

  /// The sequence and send time of the ping awaiting its pong, if any.
  int? pingSequence;
  Duration? pingSentAt;
  Duration? roundTripTime;
  Duration? smoothedRoundTripTime;
  final sent = _Traffic();
  final received = _Traffic();

  /// The state waiting for this connection to drain, by entity, in the
  /// order to send it.
  final held = <EntityId, _HeldState>{};
  var coalescedStates = 0;

  /// The encoded size of the held field values.
  int get heldBytes => held.values.fold(
    0,
    (total, state) =>
        total +
        state.fields.values.fold(0, (fields, bytes) => fields + bytes.length),
  );
}

/// State waiting to be sent to a congested connection: the latest values of
/// some fields of [entity], as its authority sampled them at [sampledAt].
final class _HeldState {
  const _HeldState(this.entity, this.fields, this.sampledAt);

  final NetworkEntity entity;

  /// The canonical encodings of the field values.
  final Map<FieldId, Uint8List> fields;
  final Duration sampledAt;
}
