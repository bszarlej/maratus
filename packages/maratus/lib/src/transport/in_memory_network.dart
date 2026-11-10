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
/// By default, delivery is reliable on one channel. Additional delivery modes
/// and channels can be enabled for simulations. [dropNextUnreliable] and
/// [delayNextUnreliable] deterministically simulate loss and reordering.
/// Reliable messages stay in [PeerConnection.outgoing] until the receiver
/// polls them and their acknowledgement crosses the link back. Unreliable
/// messages release their outgoing credit when they arrive or are dropped.
/// Received messages of every mode count against the incoming queue limit:
/// an unreliable message that does not fit is discarded, and a reliable one
/// closes the connection with [CloseReason.overflow].
final class InMemoryNetwork {
  /// Creates a network timed by [clock], whose links have [latency] unless
  /// [connect] is given another.
  ///
  /// [maxUnreliableMessageBytes] optionally limits the size accepted by
  /// unreliable sends, as a datagram transport does. Oversized sends throw
  /// [ArgumentError] without closing the connection or consuming queue space.
  InMemoryNetwork({
    required this.clock,
    this.latency = Duration.zero,
    Set<DeliveryMode> deliveryModes = const {DeliveryMode.reliable},
    int channelCount = 1,
    int? maxUnreliableMessageBytes,
  }) {
    _checkLatency(latency);
    if (!deliveryModes.contains(DeliveryMode.reliable)) {
      throw ArgumentError.value(
        deliveryModes,
        'deliveryModes',
        'must include reliable delivery',
      );
    }
    if (channelCount < 1) {
      throw ArgumentError.value(
        channelCount,
        'channelCount',
        'must be positive',
      );
    }
    if (maxUnreliableMessageBytes != null && maxUnreliableMessageBytes < 1) {
      throw ArgumentError.value(
        maxUnreliableMessageBytes,
        'maxUnreliableMessageBytes',
        'must be positive',
      );
    }
    _capabilities =
        deliveryModes.length == 1 &&
            channelCount == 1 &&
            maxUnreliableMessageBytes == null
        ? capabilities
        : TransportCapabilities(
            canHost: true,
            deliveryModes: Set.unmodifiable(deliveryModes),
            channelCount: channelCount,
            maxUnreliableMessageBytes: maxUnreliableMessageBytes,
          );
  }

  /// The default capabilities of in-memory peers.
  static const capabilities = TransportCapabilities(canHost: true);

  late final TransportCapabilities _capabilities;
  final _unreliableFaults = <_UnreliableFault>[];

  /// Drops the next [count] matching unreliable messages accepted for sending.
  ///
  /// Both unreliable modes are eligible. [channel] restricts matching to one
  /// channel, and [fromHost] restricts it to sends from the host or its clients.
  /// Reliable messages and connection events are never affected. Faults are
  /// matched in the order they were added, with one fault applied per message.
  /// Dropped messages release outgoing credit after the link's latency.
  void dropNextUnreliable({int count = 1, int? channel, bool? fromHost}) {
    _addFault(
      _UnreliableFault(
        count: count,
        channel: channel,
        fromHost: fromHost,
        drop: true,
      ),
    );
  }

  /// Adds [delay] to the next [count] matching unreliable messages' latency.
  ///
  /// Send a delayed message followed by another to simulate reordering.
  /// Filtering and matching follow [dropNextUnreliable]. Reliable messages
  /// and other channels proceed independently of the delayed messages.
  void delayNextUnreliable(
    Duration delay, {
    int count = 1,
    int? channel,
    bool? fromHost,
  }) {
    _checkLatency(delay);
    _addFault(
      _UnreliableFault(
        count: count,
        channel: channel,
        fromHost: fromHost,
        delay: delay,
      ),
    );
  }

  /// Clears faults that have not yet been assigned to an accepted message.
  /// Messages already in transit keep their assigned delay or loss.
  void clearUnreliableFaults() => _unreliableFaults.clear();

  void _addFault(_UnreliableFault fault) {
    if (fault.count < 1) {
      throw ArgumentError.value(fault.count, 'count', 'must be positive');
    }
    final channel = fault.channel;
    if (channel != null &&
        (channel < 0 || channel >= _capabilities.channelCount)) {
      throw ArgumentError.value(
        channel,
        'channel',
        'must be a supported channel',
      );
    }
    _unreliableFaults.add(fault);
  }

  _UnreliableFault? _takeFault(_Message message) {
    if (message.mode == DeliveryMode.reliable) return null;
    for (var index = 0; index < _unreliableFaults.length; index++) {
      final fault = _unreliableFaults[index];
      if ((fault.channel == null || fault.channel == message.channel) &&
          (fault.fromHost == null ||
              fault.fromHost == message.sender._peer.isHost)) {
        if (--fault.count == 0) _unreliableFaults.removeAt(index);
        return fault;
      }
    }
    return null;
  }

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
    final client = InMemoryClient._(this, incomingLimits, outgoingLimits);
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
  InMemoryPeer._(this._network, this.incomingLimits, this.outgoingLimits);

  final InMemoryNetwork _network;

  /// The limits on each connection's received messages that have not been
  /// polled.
  final QueueLimits incomingLimits;

  /// The limits on each connection's outstanding sent messages.
  final QueueLimits outgoingLimits;

  final _events = Queue<PeerEvent>();
  var _closed = false;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  @override
  TransportCapabilities get capabilities => _network._capabilities;

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
      (event.connection as InMemoryConnection)._taken(event);

  /// Called when [connection] closes.
  void _removed(InMemoryConnection connection) {}
}

/// The host of an [InMemoryNetwork].
final class InMemoryHost extends InMemoryPeer {
  InMemoryHost._(super._network, super.incomingLimits, super.outgoingLimits)
    : super._();

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
  InMemoryClient._(super._network, super.incomingLimits, super.outgoingLimits)
    : super._();

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

  /// Outstanding message IDs and their sizes; channels can finish independently.
  final _unacknowledged = <int, int>{};
  final _receivedIds = Map<MessageReceived, int>.identity();
  final _lastOrderedSequence = <int, int>{};
  var _nextMessageId = 0;
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
    if (!_peer.capabilities.supports(mode, channel: channel)) {
      throw UnsupportedError(
        'In-memory connections do not support ${mode.name} delivery on '
        'channel $channel.',
      );
    }
    final maximum = _peer.capabilities.maxUnreliableMessageBytes;
    if (mode != DeliveryMode.reliable &&
        maximum != null &&
        message.length > maximum) {
      throw ArgumentError.value(
        message.length,
        'message.length',
        'unreliable payloads must not exceed $maximum bytes',
      );
    }
    if (!isOpen) return false;
    if (!_peer.outgoingLimits.accepts(outgoing, message.length)) {
      _closeLocally(CloseReason.overflow);
      return false;
    }
    final id = _nextMessageId++;
    _unacknowledged[id] = message.length;
    _outgoingBytes += message.length;
    _outbox.send(
      _Message(Uint8List.fromList(message), this, id, mode, channel),
    );
    return true;
  }

  @override
  void close() => _closeLocally(CloseReason.local);

  void _open() {
    if (_state != _State.connecting) return;
    _state = _State.open;
    _peer._report(ConnectionOpened(this));
  }

  void _receive(_Message packet) {
    if (!isOpen) return;
    if (packet.mode == DeliveryMode.unreliableOrdered) {
      final previous = _lastOrderedSequence[packet.channel];
      if (previous != null && packet.id <= previous) return;
      _lastOrderedSequence[packet.channel] = packet.id;
    }
    final message = packet.bytes;
    if (!_peer.incomingLimits.accepts(incoming, message.length)) {
      // Only a reliable message has to arrive, so only it closes.
      if (packet.mode == DeliveryMode.reliable) {
        _closeLocally(CloseReason.overflow);
      }
      return;
    }
    _incomingMessages++;
    _incomingBytes += message.length;
    final event = MessageReceived(
      this,
      message,
      mode: packet.mode,
      channel: packet.channel,
    );
    if (packet.mode == DeliveryMode.reliable) _receivedIds[event] = packet.id;
    _peer._report(event);
  }

  /// Called when a received message is polled or discarded.
  void _taken(MessageReceived event) {
    _incomingMessages--;
    _incomingBytes -= event.message.length;
    final id = _receivedIds.remove(event);
    // Tell the sender it no longer needs to count a polled message. A
    // closed end has nobody to tell.
    if (isOpen && id != null) {
      _outbox.send(_Acknowledgement(id, event.channel));
    }
  }

  /// Releases one message's credit, including when channels arrive out of order.
  void _acknowledged(int id) {
    _outgoingBytes -= _unacknowledged.remove(id) ?? 0;
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
  /// earlier reliable messages on the same channel. Independent channels
  /// and unreliable messages can overtake earlier messages.
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
      case _Message():
        if (packet.mode != DeliveryMode.reliable) {
          packet.sender._acknowledged(packet.id);
        }
        end?._receive(packet);
      case _Acknowledgement(:final id):
        end?._acknowledged(id);
      case _Signal.close:
        end?._closeRemotely(CloseReason.remote);
      case _Signal.connect:
        _requested = false;
        _accept();
      case _Signal.accept:
        _client._open();
      case _Signal.refuse:
        _client._closeRemotely(CloseReason.connectFailed);
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
  _Message(this.bytes, this.sender, this.id, this.mode, this.channel);

  final Uint8List bytes;
  final InMemoryConnection sender;
  final int id;
  final DeliveryMode mode;
  final int channel;
}

final class _Acknowledgement implements _Packet {
  _Acknowledgement(this.id, this.channel);

  final int id;
  final int channel;
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
}

final class _UnreliableFault {
  _UnreliableFault({
    required this.count,
    this.channel,
    this.fromHost,
    this.drop = false,
    this.delay = Duration.zero,
  });

  int count;
  final int? channel;
  final bool? fromHost;
  final bool drop;
  final Duration delay;
}

final class _Delivery {
  _Delivery(this.due, this.sequence, this.packet, this.drop);

  final Duration due;
  final int sequence;
  final _Packet packet;
  final bool drop;

  static int compare(_Delivery first, _Delivery second) {
    final byDue = first.due.compareTo(second.due);
    return byDue != 0 ? byDue : first.sequence.compareTo(second.sequence);
  }
}

/// One direction of a link, preserving reliable order within each channel.
final class _Pipe {
  _Pipe(this._link, this._arrive);

  final InMemoryLink _link;
  final void Function(_Packet packet) _arrive;
  final _queue = SplayTreeSet<_Delivery>(_Delivery.compare);
  final _reliableDue = <int, Duration>{};
  var _controlDue = Duration.zero;
  var _nextSequence = 0;
  Timer? _timer;
  Duration? _timerDue;

  MonotonicClock get _clock => _link._network.clock;

  void send(_Packet packet) {
    final now = _clock.now;
    final fault = packet is _Message ? _link._network._takeFault(packet) : null;
    var due = now + _link._latency + (fault?.delay ?? Duration.zero);
    // Opening and closing a connection are barriers across all channels.
    if (due < _controlDue) due = _controlDue;
    switch (packet) {
      case _Message(mode: DeliveryMode.reliable, :final channel):
      case _Acknowledgement(:final channel):
        final previous = _reliableDue[channel];
        if (previous != null && previous > due) due = previous;
        _reliableDue[channel] = due;
      case _Message():
        break;
      case _Signal():
        if (_queue.isNotEmpty && _queue.last.due > due) due = _queue.last.due;
        _controlDue = due;
    }
    _queue.add(_Delivery(due, _nextSequence++, packet, fault?.drop ?? false));
    _schedule();
  }

  void _schedule() {
    if (_queue.isEmpty) return;
    final due = _queue.first.due;
    if (_timer != null && _timerDue == due) return;
    _timer?.cancel();
    _timerDue = due;
    _timer = _clock.schedule(due - _clock.now, _deliver);
  }

  void _deliver() {
    _timer = null;
    _timerDue = null;
    while (_queue.isNotEmpty && _queue.first.due <= _clock.now) {
      final delivery = _queue.first;
      _queue.remove(delivery);
      if (delivery.drop) {
        final message = delivery.packet as _Message;
        message.sender._acknowledged(message.id);
      } else {
        _arrive(delivery.packet);
      }
    }
    _schedule();
  }

  /// Drops everything in transit.
  void clear() {
    _queue.clear();
    _reliableDue.clear();
    _timer?.cancel();
    _timer = null;
    _timerDue = null;
  }
}
