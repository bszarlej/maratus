import '../protocol/identifiers.dart';

/// The state of a session.
///
/// A host moves from [disconnected] to [hosting]. A client moves through
/// [connecting], [handshaking], and [synchronizing] to [ready]. Either can
/// return to [disconnected] from any state, with a [DisconnectReason].
enum SessionState {
  /// Neither hosting nor connected. The initial and final state.
  disconnected,

  /// Hosting a session that clients can join.
  hosting,

  /// Opening the connection to the host.
  connecting,

  /// Connected, and waiting for the host to check the schema and decide
  /// whether to admit the client.
  handshaking,

  /// Accepted by the host, and installing its baseline of entities and
  /// state. Gameplay messages are not exchanged yet.
  synchronizing,

  /// Taking part in gameplay.
  ready,
}

/// Why a session disconnected, or why a peer left a session.
enum DisconnectReason {
  /// This side closed the session.
  closed,

  /// The other side closed the connection: the host shut down, or a client
  /// left.
  remoteClosed,

  /// The host removed the client.
  kicked,

  /// The host decided not to admit the client. The client's
  /// `MultiplayerSession.rejectionReason` tells why, if the host said.
  rejected,

  /// The host was not admitting new clients, for example because a match
  /// had started.
  notAdmitting,

  /// The peers use different protocol versions.
  versionMismatch,

  /// The peers registered different schemas.
  schemaMismatch,

  /// A stage of joining took longer than its timeout.
  timeout,

  /// A joining client could not install the host's baseline, because the
  /// spawn handler of one of its entities failed.
  bootstrapFailed,

  /// A peer sent data that violates the protocol.
  protocolViolation,

  /// The transport failed: the connection could not be established, broke,
  /// or exceeded its queue limits.
  transportError,
}

/// A change in a session, reported in the order it happened.
sealed class SessionEvent {
  const SessionEvent();
}

/// Why an otherwise well-formed RPC could not be dispatched.
enum RpcRejection {
  /// The addressed entity does not belong to this session's registry.
  unknownEntity,

  /// The addressed entity is pending or removed.
  entityNotReady,

  /// The method is not registered in the session schema.
  unknownMethod,

  /// The authenticated caller does not satisfy the RPC's caller policy.
  notAllowed,

  /// The selected destination is unknown, unready, or outside the RPC's route.
  invalidTarget,

  /// No live handler is bound to this entity and method at the destination.
  missingHandler,

  /// The payload cannot be encoded for delivery within the wire limits.
  invalidPayload,

  /// The pending attachment queue has reached its message or byte limit.
  pendingQueueFull,

  /// An attached entity did not handle the call before its readiness deadline.
  readinessTimeout,
}

/// A validated RPC was rejected by its host or destination.
///
/// This event is local diagnostics, not an acknowledgement to the caller.
final class RpcRejected extends SessionEvent {
  /// Reports the rejected call and its [reason].
  const RpcRejected({
    required this.entity,
    required this.rpc,
    required this.sender,
    required this.reason,
    this.target,
  });

  /// The addressed entity.
  final EntityId entity;

  /// The requested method.
  final RpcId rpc;

  /// The original caller authenticated by the host.
  final PeerId sender;

  /// The selected destination, if the rejection concerns a specific peer.
  final PeerId? target;

  /// Why the call could not be dispatched.
  final RpcRejection reason;
}

/// A synchronous or asynchronous RPC handler failed after dispatch.
///
/// Other calls continue to be dispatched. Failures completing after the
/// session ends are consumed without adding events to a new session.
final class RpcHandlerFailed extends SessionEvent {
  /// Reports a handler [error] and its original [stackTrace].
  const RpcHandlerFailed({
    required this.entity,
    required this.rpc,
    required this.sender,
    required this.target,
    required this.error,
    required this.stackTrace,
  });

  /// The addressed entity.
  final EntityId entity;

  /// The invoked method.
  final RpcId rpc;

  /// The original caller authenticated by the host.
  final PeerId sender;

  /// The peer executing the handler.
  final PeerId target;

  /// The error thrown by the handler.
  final Object error;

  /// The stack trace captured at the failure.
  final StackTrace stackTrace;
}

/// A spawn or despawn handler threw while creating or releasing the local
/// representation of an entity.
///
/// The replicated entity is unaffected, and the session keeps applying later
/// spawn and despawn records. A joining client cannot install an incomplete
/// baseline, though: if the spawn handler of a baseline entity that is not
/// ready yet throws, the client then leaves with
/// [DisconnectReason.bootstrapFailed].
final class SpawnHandlerFailed extends SessionEvent {
  /// Reports a handler [error] for [entity] and its original [stackTrace].
  const SpawnHandlerFailed({
    required this.entity,
    required this.type,
    required this.error,
    required this.stackTrace,
  });

  /// The entity whose handler failed.
  final EntityId entity;

  /// The spawn type of [entity].
  final SpawnTypeId type;

  /// The error thrown by the handler.
  final Object error;

  /// The stack trace captured at the failure.
  final StackTrace stackTrace;
}

/// A host's admission handler threw, or its future completed with an error.
///
/// The host rejects that client without a reason. Failures completing after
/// the session ends are consumed without adding events to a new session.
final class AdmissionFailed extends SessionEvent {
  /// Reports a handler [error] for the client that would have joined as
  /// [peer], and its original [stackTrace].
  const AdmissionFailed({
    required this.peer,
    required this.error,
    required this.stackTrace,
  });

  /// The ID that the client would have had.
  final PeerId peer;

  /// The error that the handler threw or completed with.
  final Object error;

  /// The stack trace captured at the failure.
  final StackTrace stackTrace;
}

/// Why a well-formed state message was ignored.
enum StateRejection {
  /// The entity is not registered on the receiving peer.
  unknownEntity,

  /// The message sets an authority-written field, and the sender is not the
  /// entity's authority, or the receiving peer is.
  notAuthority,

  /// The message sets an owner-written field, and the sender is not the
  /// entity's owner, or the receiving peer is.
  notOwner,
}

/// A state message was ignored, so it changed nothing.
///
/// This event is local diagnostics; the sender is not told. Updates for an
/// entity that was already removed are ignored without an event.
final class StateRejected extends SessionEvent {
  /// Reports that [sender]'s state for [entity] was ignored for [reason].
  const StateRejected({
    required this.entity,
    required this.sender,
    required this.reason,
  });

  /// The entity whose state was sent.
  final EntityId entity;

  /// The sender authenticated by the receiving connection: a client on a
  /// host, and the host on a client.
  final PeerId sender;

  /// Why the message was ignored.
  final StateRejection reason;
}

/// A synchronized property could not be sampled, encoded, or applied.
///
/// The other properties of the entity are still synchronized.
final class PropertySyncFailed extends SessionEvent {
  /// Reports an [error] for [field] of [entity], with its [stackTrace].
  const PropertySyncFailed({
    required this.entity,
    required this.field,
    required this.error,
    required this.stackTrace,
  });

  /// The entity whose property failed.
  final EntityId entity;

  /// The field of the property.
  final FieldId field;

  /// The error thrown by the getter, codec, or setter.
  final Object error;

  /// The stack trace captured at the failure.
  final StackTrace stackTrace;
}

/// The authority of [entity] moved from [previous] to [authority] on this
/// peer.
///
/// Every peer reports a transfer as it applies it: the host when it
/// transfers the entity, and each client as the transfer arrives in
/// revision order, or in its baseline if the entity's authority changed
/// before it joined.
final class AuthorityChanged extends SessionEvent {
  /// Creates an event reporting that [entity]'s authority moved from
  /// [previous] to [authority].
  const AuthorityChanged({
    required this.entity,
    required this.previous,
    required this.authority,
  });

  /// The entity whose authority changed.
  final EntityId entity;

  /// The entity's authority before the transfer.
  final PeerId previous;

  /// The entity's new authority.
  final PeerId authority;

  @override
  bool operator ==(Object other) =>
      other is AuthorityChanged &&
      other.entity == entity &&
      other.previous == previous &&
      other.authority == authority;

  @override
  int get hashCode =>
      Object.hash(AuthorityChanged, entity, previous, authority);

  @override
  String toString() =>
      'AuthorityChanged(${entity.value}, '
      '${previous.value} -> ${authority.value})';
}

/// The session moved to [state].
final class SessionStateChanged extends SessionEvent {
  /// Creates an event reporting a move to [state], for [reason] if the
  /// session disconnected.
  const SessionStateChanged(this.state, [this.reason]);

  /// The new state of the session.
  final SessionState state;

  /// Why the session disconnected, or `null` if [state] is not
  /// [SessionState.disconnected].
  final DisconnectReason? reason;

  @override
  bool operator ==(Object other) =>
      other is SessionStateChanged &&
      other.state == state &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(state, reason);

  @override
  String toString() =>
      'SessionStateChanged(${state.name}'
      '${reason == null ? '' : ', ${reason!.name}'})';
}

/// The host accepted a client as [peer], which now synchronizes.
///
/// The host reports it when it admits the client. Every other client reports
/// it in revision order, before it receives any entity that [peer] owns, and
/// a joining client reports the clients that joined before it while it
/// synchronizes. A client does not report itself or the host.
final class PeerJoined extends SessionEvent {
  /// Creates an event reporting that [peer] joined.
  const PeerJoined(this.peer);

  /// The client that joined.
  final PeerId peer;

  @override
  bool operator ==(Object other) => other is PeerJoined && other.peer == peer;

  @override
  int get hashCode => Object.hash(PeerJoined, peer);

  @override
  String toString() => 'PeerJoined(${peer.value})';
}

/// The client [peer] finished synchronizing and takes part in gameplay.
///
/// The host reports it when the client reports ready, and every other client
/// once the host tells it, after [PeerJoined] for [peer].
final class PeerReady extends SessionEvent {
  /// Creates an event reporting that [peer] is ready.
  const PeerReady(this.peer);

  /// The client that became ready.
  final PeerId peer;

  @override
  bool operator ==(Object other) => other is PeerReady && other.peer == peer;

  @override
  int get hashCode => Object.hash(PeerReady, peer);

  @override
  String toString() => 'PeerReady(${peer.value})';
}

/// The client [peer], which had joined, left the session for [reason].
///
/// The host reports it when the client leaves, and every other client once
/// the host tells it, before the host's reaction such as despawning the
/// client's entities. Other clients report [DisconnectReason.remoteClosed]
/// for a client that closed its connection; for a client that was kicked,
/// timed out, failed to install its baseline, violated the protocol, or
/// lost its connection, they report the same reason as the host. A client
/// that disconnects itself, or whose host closes the session, reports no
/// [PeerLeft] for the other clients.
final class PeerLeft extends SessionEvent {
  /// Creates an event reporting that [peer] left for [reason].
  const PeerLeft(this.peer, this.reason);

  /// The client that left.
  final PeerId peer;

  /// Why the client left.
  final DisconnectReason reason;

  @override
  bool operator ==(Object other) =>
      other is PeerLeft && other.peer == peer && other.reason == reason;

  @override
  int get hashCode => Object.hash(PeerLeft, peer, reason);

  @override
  String toString() => 'PeerLeft(${peer.value}, ${reason.name})';
}
