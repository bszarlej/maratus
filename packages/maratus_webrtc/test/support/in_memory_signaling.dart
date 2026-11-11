import 'dart:async';

import 'package:maratus_webrtc/maratus_webrtc.dart';

/// Signaling between a host and clients in the same isolate.
final class InMemorySignaling implements HostSignaling {
  final _clients = StreamController<SignalingChannel>();

  /// Whether [close] has been called.
  var isClosed = false;

  @override
  Stream<SignalingChannel> get clients => _clients.stream;

  /// Delivers [channel] to the host as a client's end of signaling.
  void accept(SignalingChannel channel) => _clients.add(channel);

  /// Connects a new client to the host and returns the client's end.
  ///
  /// The returned channel is already closed when the host stopped accepting.
  InMemorySignalingChannel join() {
    final (client, host) = InMemorySignalingChannel.pair();
    if (isClosed) {
      client.close();
    } else {
      _clients.add(host);
    }
    return client;
  }

  @override
  void close() {
    if (isClosed) return;
    isClosed = true;
    unawaited(_clients.close());
  }
}

/// One end of an in-memory signaling path.
final class InMemorySignalingChannel implements SignalingChannel {
  InMemorySignalingChannel._();

  /// Creates two connected ends.
  static (InMemorySignalingChannel, InMemorySignalingChannel) pair() {
    final first = InMemorySignalingChannel._();
    final second = InMemorySignalingChannel._();
    first._remote = second;
    second._remote = first;
    return (first, second);
  }

  final _messages = StreamController<String>();
  late final InMemorySignalingChannel _remote;

  /// Messages sent from this end, in order.
  final sent = <String>[];

  /// Whether this end has been closed.
  var isClosed = false;

  /// Whether [send] throws instead of sending.
  var throwOnSend = false;

  /// Whether [close] throws after closing.
  var throwOnClose = false;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  void send(String message) {
    if (throwOnSend) throw StateError('Signaling send failed.');
    if (isClosed) return;
    sent.add(message);
    if (!_remote.isClosed) _remote._messages.add(message);
  }

  /// Reports a failure to this end's listener.
  void fail() => _messages.addError(StateError('Signaling failed.'));

  @override
  void close() {
    if (isClosed) return;
    isClosed = true;
    unawaited(_messages.close());
    unawaited(_remote._messages.close());
    if (throwOnClose) throw StateError('Signaling close failed.');
  }
}
