part of 'multiplayer_session.dart';

/// Coalesces consecutive state envelopes within one update/capture boundary.
final class _StateBatches {
  _StateBatches(this.session)
    : codec = StateBatchCodec(limits: session._codec.limits);

  final MultiplayerSession session;
  final StateBatchCodec codec;
  final _pending = <_Remote, _StateBatch>{};
  var _active = false;

  void begin() => _active = true;

  void end() {
    _active = false;
    for (final remote in _pending.keys.toList()) {
      if (!flush(remote)) session._refused(remote);
    }
  }

  void forget(_Remote remote) => _pending.remove(remote);
  void clear() => _pending.clear();

  QueueDepth outgoing(_Remote remote) {
    final transport = remote.connection.outgoing;
    final batch = _pending[remote];
    return (
      messages: transport.messages + (batch == null ? 0 : 1),
      bytes: transport.bytes + (batch?.upperBound ?? 0),
    );
  }

  bool send(
    _Remote remote,
    ProtocolMessage message,
    Uint8List bytes,
    _Delivery delivery,
  ) {
    if (!_active || message is! StateMessage) {
      if (!flush(remote)) return false;
      if (!remote.connection.send(
        bytes,
        mode: delivery.mode,
        channel: delivery.channel,
      )) {
        return false;
      }
      MultiplayerSession._count(
        remote.sent,
        session._sent,
        message.kind,
        bytes.length,
      );
      return true;
    }
    // Avoid oversized datagrams, while permitting existing large reliable
    // singleton messages to use their transport's fragmentation support.
    var maximum = min(1200, session._codec.limits.maxMessageBytes);
    final unreliable = session._peer?.capabilities.maxUnreliableMessageBytes;
    if (delivery.mode != DeliveryMode.reliable && unreliable != null) {
      maximum = min(maximum, unreliable);
    }
    var batch = _pending[remote];
    if (batch != null &&
        (batch.delivery != delivery ||
            batch.messages.length >=
                session._codec.limits.maxCollectionLength ||
            batch.totalBytes + bytes.length + 16 > maximum)) {
      if (!flush(remote)) return false;
      batch = null;
    }
    batch ??= _pending[remote] = _StateBatch(delivery);
    batch.messages.add(bytes);
    batch.totalBytes += bytes.length;
    return true;
  }

  bool flush(_Remote remote) {
    final batch = _pending.remove(remote);
    if (batch == null) return true;
    if (session._remotes[remote.connection] != remote) return true;
    final bytes = codec.encode(batch.messages);
    if (!remote.connection.send(
      bytes,
      mode: batch.delivery.mode,
      channel: batch.delivery.channel,
    )) {
      return false;
    }
    for (var i = 0; i < batch.messages.length; i++) {
      final share =
          bytes.length ~/ batch.messages.length +
          (i < bytes.length % batch.messages.length ? 1 : 0);
      MultiplayerSession._count(
        remote.sent,
        session._sent,
        MessageKind.state,
        share,
      );
    }
    return true;
  }
}

final class _StateBatch {
  _StateBatch(this.delivery);
  final _Delivery delivery;
  final messages = <Uint8List>[];
  var totalBytes = 0;
  int get upperBound => totalBytes + (messages.length > 1 ? 16 : 0);
}
