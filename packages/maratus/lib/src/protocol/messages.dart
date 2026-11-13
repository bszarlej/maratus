import 'identifiers.dart';

/// The kinds of protocol messages.
enum MessageKind {
  /// A [HelloMessage].
  hello('hello'),

  /// A [WelcomeMessage].
  welcome('welcome'),

  /// A [SyncedMessage].
  synced('synced'),

  /// A [ReadyMessage].
  ready('ready'),

  /// A [GoodbyeMessage].
  goodbye('goodbye'),

  /// A [PingMessage].
  ping('ping'),

  /// A [PongMessage].
  pong('pong'),

  /// A [PeerJoinedMessage].
  peerJoined('peer_joined'),

  /// A [PeerReadyMessage].
  peerReady('peer_ready'),

  /// A [PeerLeftMessage].
  peerLeft('peer_left'),

  /// A [SpawnMessage].
  spawn('spawn'),

  /// A [DespawnMessage].
  despawn('despawn'),

  /// An [AuthorityMessage].
  authority('authority'),

  /// An [AuthorityAckMessage].
  authorityAck('authority_ack'),

  /// An [RpcMessage].
  rpc('rpc'),

  /// An [RpcDeliveryMessage].
  rpcDelivery('rpc_delivery'),

  /// A [StateMessage].
  state('state'),

  /// An [InputMessage].
  input('input');

  const MessageKind(this.code);

  /// The stable code that identifies this kind on the wire.
  final String code;
}

/// A [ProtocolMessage] with the metadata that accompanies it on the wire.
final class MessageEnvelope {
  /// Creates an envelope for [message].
  const MessageEnvelope(this.message, {this.generation = 0, this.revision = 0});

  /// The enclosed message.
  final ProtocolMessage message;

  /// The connection generation the message belongs to.
  ///
  /// A client's hello uses zero. The host assigns a positive generation
  /// when accepting the client, and every later message on that connection
  /// carries it. The protocol layer validates a non-negative integer; the
  /// session discards messages with a different generation.
  final int generation;

  /// The replication revision the message belongs to.
  ///
  /// The host assigns increasing revisions to replicated changes within
  /// its session. Clients use them to establish the bootstrap baseline and
  /// discard obsolete membership, spawn, despawn, authority, and state
  /// messages, and acknowledge an authority transfer with its revision. RPCs
  /// do not advance this counter. The protocol layer validates a
  /// non-negative integer; the session enforces ordering.
  final int revision;
}

/// A message exchanged between peers.
sealed class ProtocolMessage {
  const ProtocolMessage();

  /// The kind of this message.
  MessageKind get kind;
}

/// Starts the handshake: a client asks the host to accept its connection.
final class HelloMessage extends ProtocolMessage {
  /// Creates a message that presents the [fingerprint] of the client's
  /// schema and, optionally, its join [request].
  const HelloMessage({required this.fingerprint, this.request});

  /// The fingerprint of the client's schema, which must match the host's.
  final String fingerprint;

  /// The client's join request as a wire value, or `null` if it sends none.
  ///
  /// The protocol layer checks only the wire limits. Once the fingerprints
  /// match, the host decodes the request with the join request codec of its
  /// schema, which is then also the client's.
  final Object? request;

  @override
  MessageKind get kind => MessageKind.hello;
}

/// Accepts a client into the host's session.
///
/// The envelope's generation is the one that every later message on the
/// connection carries, and its revision is the replication revision of the
/// baseline that follows.
final class WelcomeMessage extends ProtocolMessage {
  /// Creates a message that admits a client as [peer] into the session
  /// identified by [epoch].
  const WelcomeMessage({required this.peer, required this.epoch});

  /// The ID that the host assigned to the client.
  final PeerId peer;

  /// Identifies the host's session. A host that starts a new session
  /// chooses a new epoch.
  final int epoch;

  @override
  MessageKind get kind => MessageKind.welcome;
}

/// Ends the baseline: the host has sent every entity and value up to the
/// envelope's revision.
final class SyncedMessage extends ProtocolMessage {
  /// Creates a message that ends the baseline.
  const SyncedMessage();

  @override
  MessageKind get kind => MessageKind.synced;
}

/// Reports that a client has applied everything up to the envelope's
/// revision and is ready for gameplay.
final class ReadyMessage extends ProtocolMessage {
  /// Creates a message that reports a client ready.
  const ReadyMessage();

  @override
  MessageKind get kind => MessageKind.ready;
}

/// Tells the other side why the sender is about to close the connection.
final class GoodbyeMessage extends ProtocolMessage {
  /// Creates a message that gives the [reason] for closing a connection,
  /// with an optional [detail] for the other side to show.
  const GoodbyeMessage(this.reason, {this.detail});

  /// The maximum length of a [detail], in UTF-16 code units.
  static const maxDetailLength = 256;

  /// Why the sender closes the connection.
  final GoodbyeReason reason;

  /// An explanation in the sender's words, such as the reason a host gave
  /// for rejecting a client, or `null` if there is none.
  final String? detail;

  @override
  MessageKind get kind => MessageKind.goodbye;
}

/// Why a peer closes a connection, as stated in a [GoodbyeMessage].
enum GoodbyeReason {
  /// The host removed the client.
  kicked('kicked'),

  /// The peers use different protocol versions.
  versionMismatch('version'),

  /// The peers registered different schemas.
  schemaMismatch('schema'),

  /// The other side did not complete a stage of the handshake in time.
  timeout('timeout'),

  /// The client could not install the host's baseline.
  bootstrapFailed('bootstrap'),

  /// The other side sent a message that violates the protocol.
  protocolViolation('violation'),

  /// The host decided not to admit the client.
  rejected('rejected'),

  /// The host is not admitting new clients.
  notAdmitting('not_admitting');

  const GoodbyeReason(this.code);

  /// The stable code that identifies this reason on the wire.
  final String code;
}

/// Asks the other side of an accepted connection to answer with a
/// [PongMessage], so the sender can measure the round trip.
///
/// The receiver answers while it handles the ping, so the round trip
/// includes the time until the receiver's next update.
final class PingMessage extends ProtocolMessage {
  /// Creates a ping that the answering pong identifies by [sequence].
  const PingMessage(this.sequence);

  /// Identifies this ping among the pings sent on its connection.
  final int sequence;

  @override
  MessageKind get kind => MessageKind.ping;
}

/// Answers a [PingMessage].
final class PongMessage extends ProtocolMessage {
  /// Creates the answer to the ping with [sequence].
  const PongMessage(this.sequence);

  /// The sequence of the ping that this pong answers.
  final int sequence;

  @override
  MessageKind get kind => MessageKind.pong;
}

/// Tells a client that another client joined the session.
///
/// Only the host sends membership messages, as replicated changes ordered by
/// their revision. A client's baseline announces each client that joined
/// before it, followed by a [PeerReadyMessage] for those that are ready.
/// A client is never told about itself.
final class PeerJoinedMessage extends ProtocolMessage {
  /// Creates a message announcing that [peer] joined.
  const PeerJoinedMessage({required this.peer});

  /// The client that joined.
  final PeerId peer;

  @override
  MessageKind get kind => MessageKind.peerJoined;
}

/// Tells a client that another client finished joining and takes part in
/// gameplay.
final class PeerReadyMessage extends ProtocolMessage {
  /// Creates a message announcing that [peer] is ready.
  const PeerReadyMessage({required this.peer});

  /// The client that became ready.
  final PeerId peer;

  @override
  MessageKind get kind => MessageKind.peerReady;
}

/// Tells a client that another client left the session.
final class PeerLeftMessage extends ProtocolMessage {
  /// Creates a message announcing that [peer] left for [reason].
  const PeerLeftMessage({required this.peer, required this.reason});

  /// The client that left.
  final PeerId peer;

  /// Why the client left.
  final DepartureReason reason;

  @override
  MessageKind get kind => MessageKind.peerLeft;
}

/// Why a client left the session, as a [PeerLeftMessage] states it to the
/// other clients.
enum DepartureReason {
  /// The client closed its connection.
  left('left'),

  /// The host removed the client.
  kicked('kicked'),

  /// The client did not install the baseline in time, or went quiet.
  timeout('timeout'),

  /// The client could not install the host's baseline.
  bootstrapFailed('bootstrap'),

  /// The client sent a message that violates the protocol.
  protocolViolation('violation'),

  /// The client's connection failed.
  transportError('transport');

  const DepartureReason(this.code);

  /// The stable code that identifies this reason on the wire.
  final String code;
}

/// Creates a replicated entity of a registered spawn type.
///
/// Only the host sends spawn records. It allocates the entity ID and chooses
/// the metadata, which receivers validate before creating the entity.
final class SpawnMessage extends ProtocolMessage {
  /// Creates a message that spawns [entity] as a [type] built from [data],
  /// owned by [owner] and simulated by [authority], under [parent] if given.
  const SpawnMessage({
    required this.entity,
    required this.type,
    required this.data,
    required this.owner,
    required this.authority,
    this.parent,
  });

  /// The entity to create.
  final EntityId entity;

  /// The spawn type of the entity.
  final SpawnTypeId type;

  /// The construction data, encoded with the codec registered for [type].
  final Object? data;

  /// The peer that controls the entity's input.
  final PeerId owner;

  /// The peer whose copy of the entity is the source of truth.
  ///
  /// When the entity is spawned, this is the host or [owner]. In a joining
  /// client's baseline, it is the entity's current authority, which an
  /// [AuthorityMessage] may have transferred to another peer.
  final PeerId authority;

  /// The replicated entity that this entity belongs to, if any.
  ///
  /// Despawning the parent also despawns this entity.
  final EntityId? parent;

  @override
  MessageKind get kind => MessageKind.spawn;
}

/// Removes a replicated entity and its descendants.
final class DespawnMessage extends ProtocolMessage {
  /// Creates a message that removes [entity] and its descendants.
  const DespawnMessage({required this.entity});

  /// The entity to remove.
  final EntityId entity;

  @override
  MessageKind get kind => MessageKind.despawn;
}

/// Transfers the authority of a replicated or static entity to another peer.
///
/// Only the host sends transfers, as replicated changes ordered by their
/// revision. The entity's previous and new authority each acknowledge one
/// with an [AuthorityAckMessage].
final class AuthorityMessage extends ProtocolMessage {
  /// Creates a message that makes [authority] the authority of [entity].
  const AuthorityMessage({required this.entity, required this.authority});

  /// The entity whose authority changes.
  final EntityId entity;

  /// The entity's new authority.
  final PeerId authority;

  @override
  MessageKind get kind => MessageKind.authority;
}

/// Acknowledges the authority transfer of [entity] with the envelope's
/// revision.
///
/// A client sends it once it has applied a transfer that makes it, or stops
/// it being, the entity's authority. Authority-written state that the
/// client sends about the entity follows the acknowledgement, so the host
/// can tell it from state sent before the client applied the transfer.
final class AuthorityAckMessage extends ProtocolMessage {
  /// Creates a message that acknowledges the transfer of [entity].
  const AuthorityAckMessage({required this.entity});

  /// The entity whose transfer is acknowledged.
  final EntityId entity;

  @override
  MessageKind get kind => MessageKind.authorityAck;
}

/// Asks the host to route a registered RPC on an entity.
///
/// Requests never carry a sender identity. The host derives it from the
/// authenticated connection before validating and routing the call.
final class RpcMessage extends ProtocolMessage {
  /// Creates a message that invokes [rpc] on [entity] with [payload].
  const RpcMessage({
    required this.entity,
    required this.rpc,
    required this.payload,
    this.target,
  });

  /// The entity the call is addressed to.
  final EntityId entity;

  /// The RPC to invoke.
  final RpcId rpc;

  /// The call payload, encoded with the codec registered for [rpc].
  final Object? payload;

  /// The requested recipient for an RPC that targets a specific peer.
  ///
  /// Other RPC routes omit this value and let the host choose recipients.
  final PeerId? target;

  @override
  MessageKind get kind => MessageKind.rpc;
}

/// Delivers an RPC that the host has validated and routed.
///
/// Only the host may send this message. The session authenticates its
/// origin before trusting [sender] and verifies [target] is the recipient.
final class RpcDeliveryMessage extends ProtocolMessage {
  /// Creates a delivery of [rpc] on [entity] from [sender] to [target].
  const RpcDeliveryMessage({
    required this.entity,
    required this.rpc,
    required this.payload,
    required this.sender,
    required this.target,
  });

  /// The entity the call is addressed to.
  final EntityId entity;

  /// The RPC to invoke.
  final RpcId rpc;

  /// The call payload, encoded with the codec registered for [rpc].
  final Object? payload;

  /// The caller authenticated by the host.
  final PeerId sender;

  /// The recipient selected by the host.
  final PeerId target;

  @override
  MessageKind get kind => MessageKind.rpcDelivery;
}

/// Carries new values of an entity's synchronized fields.
///
/// Sessions send the values of authority-written and owner-written fields
/// in separate messages, as different peers may write them.
final class StateMessage extends ProtocolMessage {
  /// Creates a message that sets the [values] of fields of [entity], as
  /// their writer sampled them at [sampledAt], if given, after applying the
  /// inputs up to [inputSequence], if given.
  StateMessage({
    required this.entity,
    required Map<FieldId, Object?> values,
    this.sampledAt,
    this.sequence,
    this.inputSequence,
  }) : values = Map<FieldId, Object?>.unmodifiable(values);

  /// The entity whose fields changed.
  final EntityId entity;

  /// The new field values, each encoded with the codec registered for its
  /// field.
  final Map<FieldId, Object?> values;

  /// When the writer of [values], the entity's authority or its owner,
  /// sampled them on its session clock, or `null` for values that their
  /// current writer did not sample.
  ///
  /// The host relays state with its writer's time. Peers' clocks are not
  /// synchronized, so a time is only comparable with other times from the
  /// same writer, for example to interpolate values at the pace they were
  /// sampled. After an authority transfer, the host sends values that
  /// a previous authority sampled without a time: in a joining client's
  /// baseline, and to the previous authority, to replace the values it sent
  /// after the transfer. Clients always send a time. The protocol layer
  /// validates a non-negative whole number of microseconds.
  final Duration? sampledAt;

  /// The independent live-state sequence, or `null` for ordered state on
  /// the reliable control channel, including baseline and authority resync.
  ///
  /// With a sequence, the envelope revision is a lifecycle dependency, not a
  /// new replication revision. Receivers compare sequences per entity/field.
  final int? sequence;

  /// The sequence number of the latest input from the entity's owner that
  /// its authority had applied when it sampled [values], zero if it had
  /// applied none, or `null` if the message does not report inputs.
  ///
  /// Only the host reports inputs, in the state of an entity whose inputs it
  /// applies, so its owner can tell which of the inputs it predicted the
  /// values include. The protocol layer validates a non-negative integer.
  final int? inputSequence;

  @override
  MessageKind get kind => MessageKind.state;
}

/// Carries consecutive inputs of an entity's input stream from its owner to
/// the host.
///
/// The owner numbers the inputs of each entity from 1, one for each tick of
/// the stream. [values] holds the input numbered [sequence] and the inputs
/// that follow it, in order. A message may repeat inputs that an earlier
/// one carried, so that unreliable delivery can repair a lost message; the
/// receiver applies each input at most once.
final class InputMessage extends ProtocolMessage {
  /// Creates a message that carries the inputs [values] of [input] for
  /// [entity], numbered from [sequence].
  InputMessage({
    required this.entity,
    required this.input,
    required this.sequence,
    required List<Object?> values,
  }) : values = List<Object?>.unmodifiable(values);

  /// The entity whose inputs these are.
  final EntityId entity;

  /// The input stream of the inputs.
  final InputId input;

  /// The sequence number of the first of [values], from 1. The protocol
  /// layer validates that every input's number is a safe integer.
  final int sequence;

  /// The inputs, at least one, each encoded with the codec registered for
  /// [input].
  final List<Object?> values;

  @override
  MessageKind get kind => MessageKind.input;
}
