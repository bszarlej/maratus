import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../core/clock.dart';
import 'multiplayer_peer.dart';

/// Connects [MultiplayerPeer]s within a single process, for tests and
/// simulations.
///
/// A network has at most one open host, created with [host], and clients
/// join it with [connect]. Each client is joined to the host by an
/// [InMemoryLink], which delays everything sent over it by its latency.
/// Deliveries are timers on [clock]: with a [ManualClock], nothing arrives
/// until the clock is advanced, so the same steps always produce the same
/// events.
///
/// Delivery is reliable and ordered. Loss and reordering are not simulated.
/// As over WebSockets, a sent message counts in its connection's
/// [PeerConnection.outgoing] queue until the receiver polls it and an
/// acknowledgement crosses the link back, so a receiver that stops polling
/// fills its sender's queue.
final class InMemoryNetwork {
  /// Creates a network timed by [clock], whose links have [latency] unless
  /// [connect] is given another.
  InMemoryNetwork({required this.clock, this.latency = Duration.zero}) {
    _checkLatency(latency);
  }

  /// The capabilities of in-memory peers.
  static const capabilities = TransportCapabilities(canHost: true);

  /// The clock that times deliveries.
  final MonotonicClock clock;

  /// The default latency of new links.
  final Duration latency;

  final _links = <InMemoryLink>{};
  InMemoryHost? _host;
  var _nextLinkId = 1;

  /// The links that can still deliver something, in the order they were
  /// created.
  ///
  /// A link is removed once neither end can observe anything more on it:
  /// when both ends have closed, or when a connection attempt has failed or
  /// been abandoned.
  List<InMemoryLink> get links => List.unmodifiable(_links);

  /// Creates the host of this network.
  ///
  /// The host accepts connections until it is closed, after which another
  /// host can be created. Throws a [StateError] if the network already has
  /// an open host.
  InMemoryHost host({
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
  }) {
    if (_host != null) {
      throw StateError('The network already has an open host.');
    }
    return _host = InMemoryHost._(this, incomingLimits, outgoingLimits);
  }

  /// Creates a client and starts connecting it to the host.
  ///
  /// The connection request reaches the host after the link's latency, and
  /// the answer takes as long again: the host reports the connection open
  /// when the request arrives, and the client after a round trip. If no host
  /// is accepting connections when the request arrives, the client's
  /// connection fails with [CloseReason.connectFailed]. The link has
  /// [latency] if given, and this network's [latency] otherwise.
  InMemoryClient connect({
    Duration? latency,
    QueueLimits incomingLimits = const QueueLimits(),
    QueueLimits outgoingLimits = const QueueLimits(),
  }) {
    final linkLatency = latency ?? this.latency;
    _checkLatency(linkLatency);
    final client = InMemoryClient._(incomingLimits, outgoingLimits);
    _links.add(InMemoryLink._(this, _nextLinkId++, linkLatency, client));
    return client;
  }
}

void _checkLatency(Duration latency) {
  if (latency.isNegative) {
    throw ArgumentError.value(latency, 'latency', 'must not be negative');
  }
}

/// A peer on an [InMemoryNetwork].
sealed class InMemoryPeer implements MultiplayerPeer {
  InMemoryPeer._(this.incomingLimits, this.outgoingLimits);

  /// The limits on each connection's received messages that have not been
  /// polled.
  final QueueLimits incomingLimits;

  /// The limits on each connection's sent messages that the receiver has not
  /// polled and acknowledged.
  final QueueLimits outgoingLimits;

  final _events = Queue<PeerEvent>();
  var _closed = false;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  @override
  TransportCapabilities get capabilities => InMemoryNetwork.capabilities;

  @override
  PeerEvent? poll() {
    if (_events.isEmpty) return null;
    final event = _events.removeFirst();
    if (event is MessageReceived) _release(event);
    return event;
  }

  void _report(PeerEvent event) {
    if (!_closed) _events.add(event);
  }

  /// Removes the pending events that [test] matches.
  void _discard(bool Function(PeerEvent event) test) {
    _events.removeWhere((event) {
      final discarded = test(event);
      if (discarded && event is MessageReceived) _release(event);
      return discarded;
    });
  }

  void _release(MessageReceived event) =>
      (event.connection as InMemoryConnection)._taken(event.message.length);

  /// Called when [connection] closes.
  void _removed(InMemoryConnection connection) {}
}

/// The host of an [InMemoryNetwork].
final class InMemoryHost extends InMemoryPeer {
  InMemoryHost._(this._network, super.incomingLimits, super.outgoingLimits)
    : super._();

  final InMemoryNetwork _network;
  final _connections = <InMemoryConnection>{};

  @override
  bool get isHost => true;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _network._host = null;
    for (final connection in _connections.toList()) {
      connection.close();
    }
    _discard((_) => true);
  }

  void _accept(InMemoryConnection connection) {
    _connections.add(connection);
    _report(ConnectionOpened(connection));
  }

  @override
  void _removed(InMemoryConnection connection) =>
      _connections.remove(connection);
}

/// A client on an [InMemoryNetwork].
final class InMemoryClient extends InMemoryPeer {
  InMemoryClient._(super.incomingLimits, super.outgoingLimits) : super._();

  late final InMemoryConnection _connection;

  /// The link between this client and the host.
  InMemoryLink get link => _connection.link;

  @override
  bool get isHost => false;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _connection.close();
    _discard((_) => true);
  }
}

/// One end of an [InMemoryLink]: the host's connection to a client, or a
/// client's connection to the host.
final class InMemoryConnection implements PeerConnection {
  InMemoryConnection._(
    this._peer,
    this.link,
    this._outbox, {
    required bool open,
  }) : _state = open ? _State.open : _State.connecting;

  final InMemoryPeer _peer;

  /// The link that this connection is an end of.
  final InMemoryLink link;

  final _Pipe _outbox;
  _State _state;
  CloseReason? _closeReason;
  var _incomingMessages = 0;
  var _incomingBytes = 0;

  /// The sizes of the sent messages that the receiver has not acknowledged,
  /// oldest first.
  final _unacknowledged = Queue<int>();
  var _outgoingBytes = 0;

  @override
  bool get isOpen => _state == _State.open;

  @override
  CloseReason? get closeReason => _closeReason;

  @override
  QueueDepth get incoming =>
      (messages: _incomingMessages, bytes: _incomingBytes);

  @override
  QueueDepth get outgoing =>
      (messages: _unacknowledged.length, bytes: _outgoingBytes);

  @override
  bool send(
    Uint8List message, {
    DeliveryMode mode = DeliveryMode.reliable,
    int channel = 0,
  }) {
    if (!InMemoryNetwork.capabilities.supports(mode, channel: channel)) {
      throw UnsupportedError(
        'In-memory connections do not support ${mode.name} delivery on '
        'channel $channel.',
      );
    }
    if (!isOpen) return false;
    if (!_peer.outgoingLimits.accepts(outgoing, message.length)) {
      _closeLocally(CloseReason.overflow);
      return false;
    }
    _unacknowledged.add(message.length);
    _outgoingBytes += message.length;
    _outbox.send(_Message(Uint8List.fromList(message)));
    return true;
  }

  @override
  void close() => _closeLocally(CloseReason.local);

  void _open() {
    if (_state != _State.connecting) return;
    _state = _State.open;
    _peer._report(ConnectionOpened(this));
  }

  void _receive(Uint8List message) {
    if (!isOpen) return;
    if (!_peer.incomingLimits.accepts(incoming, message.length)) {
      _closeLocally(CloseReason.overflow);
      return;
    }
    _incomingMessages++;
    _incomingBytes += message.length;
    _peer._report(MessageReceived(this, message));
  }

  /// Called when a received message of [size] bytes is polled, or
  /// discarded.
  void _taken(int size) {
    _incomingMessages--;
    _incomingBytes -= size;
    // Tell the sender it no longer needs to count a polled message. A
    // closed end has nobody to tell.
    if (isOpen) _outbox.send(_Signal.acknowledge);
  }

  /// Called when the receiver acknowledges the oldest sent message.
  void _acknowledged() {
    if (_unacknowledged.isEmpty) return;
    _outgoingBytes -= _unacknowledged.removeFirst();
  }

  /// Stops counting sent messages, which a closed end is never told about.
  void _forgetOutgoing() {
    _unacknowledged.clear();
    _outgoingBytes = 0;
  }

  /// Closes this end for a reason on this side: [close], or an overflow.
  ///
  /// Unpolled messages are discarded, and the other end is told after
  /// everything this end already sent.
  void _closeLocally(CloseReason reason) {
    if (_state == _State.closed) return;
    _state = _State.closed;
    _closeReason = reason;
    _forgetOutgoing();
    _peer._discard(
      (event) => event is MessageReceived && event.connection == this,
    );
    if (reason != CloseReason.local) {
      _peer._report(ConnectionClosed(this, reason));
    }
    _peer._removed(this);
    link._closedLocally(this);
  }

  /// Closes this end because of something that arrived over the link or
  /// happened to it.
  ///
  /// Unpolled messages stay pending, ahead of the [ConnectionClosed] event.
  void _closeRemotely(CloseReason reason) {
    if (_state == _State.closed) return;
    _state = _State.closed;
    _closeReason = reason;
    _forgetOutgoing();
    _peer._report(ConnectionClosed(this, reason));
    _peer._removed(this);
    link._release();
  }

  @override
  String toString() =>
      'InMemoryConnection(${_peer.isHost ? 'host' : 'client'} end of $link)';
}

enum _State { connecting, open, closed }

/// The link between a client and the host of an [InMemoryNetwork].
///
/// Tests use a link to change its latency or to simulate a network failure.
final class InMemoryLink {
  InMemoryLink._(
    this._network,
    this._id,
    this._latency,
    InMemoryClient client,
  ) {
    client._connection = _client = InMemoryConnection._(
      client,
      this,
      _toHost,
      open: false,
    );
    _requested = true;
    _toHost.send(_Signal.connect);
  }

  final InMemoryNetwork _network;
  final int _id;
  Duration _latency;
  late final _toHost = _Pipe(this, (packet) => _arrive(packet, atHost: true));
  late final _toClient = _Pipe(
    this,
    (packet) => _arrive(packet, atHost: false),
  );
  late final InMemoryConnection _client;
  InMemoryConnection? _host;

  /// Whether the connection request is still on its way to the host.
  var _requested = false;
  var _released = false;

  /// How long anything sent over this link takes to arrive, in either
  /// direction.
  ///
  /// A change applies to what is sent afterwards, which still arrives after
  /// everything sent before it, as on a real connection whose latency
  /// changes.
  Duration get latency => _latency;

  set latency(Duration value) {
    _checkLatency(value);
    _latency = value;
  }

  /// Simulates a network failure.
  ///
  /// Everything in transit is lost. Each end that has not closed reports
  /// [CloseReason.lost], or [CloseReason.connectFailed] if it was still
  /// connecting. Has no effect once the link has been removed from
  /// [InMemoryNetwork.links].
  void disconnect() {
    if (_released) return;
    // Closing both ends releases the link, which drops what is in transit.
    _requested = false;
    _host?._closeRemotely(CloseReason.lost);
    _client._closeRemotely(
      _client._state == _State.connecting
          ? CloseReason.connectFailed
          : CloseReason.lost,
    );
  }

  void _arrive(_Packet packet, {required bool atHost}) {
    final end = atHost ? _host : _client;
    switch (packet) {
      case _Message(:final bytes):
        end?._receive(bytes);
      case _Signal.close:
        end?._closeRemotely(CloseReason.remote);
      case _Signal.connect:
        _requested = false;
        _accept();
      case _Signal.accept:
        _client._open();
      case _Signal.refuse:
        _client._closeRemotely(CloseReason.connectFailed);
      case _Signal.acknowledge:
        end?._acknowledged();
    }
  }

  void _accept() {
    final host = _network._host;
    if (host == null) {
      _toClient.send(_Signal.refuse);
      return;
    }
    final end = _host = InMemoryConnection._(host, this, _toClient, open: true);
    host._accept(end);
    _toClient.send(_Signal.accept);
  }

  void _closedLocally(InMemoryConnection end) {
    if (end == _client && _requested) {
      // The host has not seen the request yet, so withdraw it.
      _requested = false;
      _toHost.clear();
    } else {
      end._outbox.send(_Signal.close);
    }
    _release();
  }

  /// Removes this link from the network once neither end can observe
  /// anything more on it.
  void _release() {
    final host = _host;
    final hostDone = host == null ? !_requested : host._state == _State.closed;
    if (_released || _client._state != _State.closed || !hostDone) return;
    _released = true;
    _toHost.clear();
    _toClient.clear();
    _network._links.remove(this);
  }

  @override
  String toString() => 'InMemoryLink($_id)';
}

/// Something in transit over a link.
sealed class _Packet {}

final class _Message implements _Packet {
  _Message(this.bytes);

  final Uint8List bytes;
}

enum _Signal implements _Packet {
  /// Asks the host to accept the connection.
  connect,

  /// Tells the client that the host accepted the connection.
  accept,

  /// Tells the client that no host was accepting connections.
  refuse,

  /// Tells the other end that this end closed.
  close,

  /// Tells the other end that this end polled the oldest message it sent.
  acknowledge,
}

/// One direction of a link, which delivers packets in the order they were
/// sent, once the link's latency has elapsed.
final class _Pipe {
  _Pipe(this._link, this._arrive);

  final InMemoryLink _link;
  final void Function(_Packet packet) _arrive;
  final _queue = Queue<({Duration due, _Packet packet})>();
  Timer? _timer;

  MonotonicClock get _clock => _link._network.clock;

  void send(_Packet packet) {
    final now = _clock.now;
    var due = now + _link._latency;
    // A packet never overtakes one sent before it.
    if (_queue.isNotEmpty && _queue.last.due > due) due = _queue.last.due;
    _queue.add((due: due, packet: packet));
    _timer ??= _clock.schedule(_queue.first.due - now, _deliver);
  }

  void _deliver() {
    _timer = null;
    while (_queue.isNotEmpty && _queue.first.due <= _clock.now) {
      _arrive(_queue.removeFirst().packet);
    }
    if (_queue.isNotEmpty) {
      _timer ??= _clock.schedule(_queue.first.due - _clock.now, _deliver);
    }
  }

  /// Drops everything in transit.
  void clear() {
    _queue.clear();
    _timer?.cancel();
    _timer = null;
  }
}
