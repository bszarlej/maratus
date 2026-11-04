import 'package:maratus/maratus.dart';

/// The wire contract shared by the native fixture and browser tests.
final class WebSocketTestSchema {
  /// Builds typed broadcast and host-shutdown RPCs with stable identifiers.
  factory WebSocketTestSchema() {
    final builder = ProtocolSchemaBuilder();
    final echo = builder.addRpc(
      const RpcId('browser.echo'),
      const StringCodec(maxLength: 128),
      caller: RpcCaller.anyPeer,
      target: RpcTarget.all,
      local: RpcLocal.include,
    );
    final stop = builder.addRpc(
      const RpcId('browser.stop'),
      const BoolCodec(),
      caller: RpcCaller.anyPeer,
      target: RpcTarget.host,
    );
    return WebSocketTestSchema._(builder.build(), echo, stop);
  }

  WebSocketTestSchema._(this.schema, this.echo, this.stop);

  /// The schema checked during the native/browser handshake.
  final ProtocolSchema schema;

  /// Broadcasts text to the host and all ready browser clients.
  final Rpc<String> echo;

  /// Requests a clean shutdown of this test fixture's native host.
  final Rpc<bool> stop;

  /// Registers and binds the same static entity immediately after starting.
  NetworkEntity bind(
    MultiplayerSession session, {
    required void Function(RpcContext context, String payload) onEcho,
    void Function(RpcContext context, bool payload)? onStop,
  }) {
    final entity = session.registry.register(
      const EntityId(1),
      owner: PeerId.host,
      authority: PeerId.host,
    );
    session.bindRpc(entity, echo, onEcho);
    if (onStop != null) session.bindRpc(entity, stop, onStop);
    session.registry.markReady(entity.id);
    return entity;
  }
}
