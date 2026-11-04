/// Godot-inspired multiplayer for Dart: host-authoritative sessions, typed
/// RPCs, replicated spawning, property synchronization, and late joining.
///
/// This package has no Flutter dependency, so it runs in dedicated hosts,
/// command-line tools, and browser tests as well as in games. Flame games use
/// `package:maratus_flame`, which re-exports these APIs.
library;

export 'src/core/clock.dart';
export 'src/core/entity_registry.dart';
export 'src/core/multiplayer_session.dart';
export 'src/core/session_events.dart';
export 'src/protocol/identifiers.dart'
    show SpawnTypeId, RpcId, FieldId, EntityId, PeerId;
export 'src/protocol/messages.dart'
    show
        MessageKind,
        MessageEnvelope,
        ProtocolMessage,
        SpawnMessage,
        DespawnMessage,
        RpcMessage,
        StateMessage;
export 'src/protocol/protocol_exception.dart';
export 'src/protocol/rpc.dart';
export 'src/protocol/schema.dart';
export 'src/protocol/spawn_type.dart';
export 'src/protocol/sync_field.dart';
export 'src/protocol/value_codec.dart';
export 'src/transport/in_memory_network.dart';
export 'src/transport/multiplayer_peer.dart';
export 'src/transport/web_socket_peer.dart';
