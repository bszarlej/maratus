import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'ice_server.dart';
import 'webrtc_driver.dart';

/// Whether this browser provides `RTCPeerConnection`.
bool get supportsWebRtc => globalContext.has('RTCPeerConnection');

/// Creates a driver backed by the browser's WebRTC implementation.
///
/// Browsers deliver received data as it arrives, so [maxQueuedBytes] does
/// not apply.
WebRtcDriver createWebRtcDriver({required int maxQueuedBytes}) =>
    _BrowserDriver();

final class _BrowserDriver implements WebRtcDriver {
  final _events = Queue<WebRtcDriverEvent>();
  final _connections = <int, _BrowserConnection>{};
  var _nextId = 1;

  @override
  int open(int laneCount, List<IceServer> iceServers) {
    final id = _nextId++;
    _connections[id] = _BrowserConnection(this, id, laneCount, iceServers);
    return id;
  }

  _BrowserConnection _connection(int id) =>
      _connections[id] ?? (throw StateError('Unknown connection $id.'));

  @override
  void createOffer(int connection) => _connection(connection).createOffer();

  @override
  void acceptOffer(int connection, String sdp) =>
      _connection(connection).acceptOffer(sdp);

  @override
  void acceptAnswer(int connection, String sdp) =>
      _connection(connection).acceptAnswer(sdp);

  @override
  void addCandidate(int connection, String candidate, String? mid) =>
      _connection(connection).addCandidate(candidate, mid);

  @override
  void send(int connection, int lane, Uint8List bytes) =>
      _connection(connection).send(lane, bytes);

  @override
  int bufferedAmount(int connection, int lane) =>
      _connection(connection).bufferedAmount(lane);

  @override
  void close(int connection) => _connections.remove(connection)?.close();

  @override
  WebRtcDriverEvent? poll() => _events.isEmpty ? null : _events.removeFirst();

  @override
  void dispose() {
    for (final connection in _connections.values.toList()) {
      connection.close();
    }
    _connections.clear();
    _events.clear();
  }
}

final class _BrowserConnection {
  _BrowserConnection(
    this._driver,
    this._id,
    int laneCount,
    List<IceServer> iceServers,
  ) : _peer = web.RTCPeerConnection(
        web.RTCConfiguration(
          iceServers: [for (final server in iceServers) _server(server)].toJS,
        ),
      ) {
    _peer
      ..onicecandidate = ((web.RTCPeerConnectionIceEvent event) {
        final candidate = event.candidate;
        if (candidate == null || candidate.candidate.isEmpty) return;
        final found = WebRtcDriverCandidate(
          _id,
          candidate.candidate,
          candidate.sdpMid,
        );
        // Signaling must carry the description before its candidates.
        if (_described) {
          _report(found);
        } else {
          _candidates.add(found);
        }
      }).toJS
      ..onconnectionstatechange = ((web.Event _) {
        if (_peer.connectionState == 'failed') _fail();
      }).toJS;
    for (var lane = 0; lane < laneCount; lane++) {
      final channel = _peer.createDataChannel(
        'maratus-$lane',
        lane.isEven
            ? web.RTCDataChannelInit(negotiated: true, id: lane)
            : web.RTCDataChannelInit(
                negotiated: true,
                id: lane,
                ordered: false,
                maxRetransmits: 0,
              ),
      )..binaryType = 'arraybuffer';
      channel
        ..onopen = ((web.Event _) {
          _report(WebRtcDriverLaneOpened(_id, lane));
        }).toJS
        ..onmessage = ((web.MessageEvent event) {
          final data = event.data;
          if (data.isA<JSArrayBuffer>()) {
            final bytes = (data as JSArrayBuffer).toDart.asUint8List();
            _report(WebRtcDriverMessage(_id, lane, bytes));
          } else {
            // Text is not part of the protocol.
            _fail();
          }
        }).toJS
        ..onerror = ((web.Event _) => _fail()).toJS
        ..onclose = ((web.Event _) => _fail()).toJS;
      _lanes.add(channel);
    }
  }

  final _BrowserDriver _driver;
  final int _id;
  final web.RTCPeerConnection _peer;
  final _lanes = <web.RTCDataChannel>[];
  final _candidates = <WebRtcDriverCandidate>[];
  var _described = false;
  var _failed = false;
  var _closed = false;

  void createOffer() => _describe(_peer.setLocalDescription().toDart);

  void acceptOffer(String sdp) => _describe(
    _peer
        .setRemoteDescription(_description('offer', sdp))
        .toDart
        .then((_) => _peer.setLocalDescription().toDart),
  );

  void acceptAnswer(String sdp) {
    unawaited(
      _peer
          .setRemoteDescription(_description('answer', sdp))
          .toDart
          .then<void>((_) {}, onError: (Object _) => _fail()),
    );
  }

  void addCandidate(String candidate, String? mid) {
    unawaited(
      _peer
          .addIceCandidate(
            web.RTCIceCandidateInit(
              candidate: candidate,
              sdpMid: mid,
              sdpMLineIndex: mid == null ? 0 : null,
            ),
          )
          .toDart
          // An unusable candidate leaves the other network paths to be tried.
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  void send(int lane, Uint8List bytes) => _lanes[lane].send(bytes.toJS);

  int bufferedAmount(int lane) => _lanes[lane].bufferedAmount;

  void _describe(Future<Object?> operation) {
    unawaited(
      operation.then<void>((_) {
        final description = _peer.localDescription;
        if (description == null) {
          _fail();
          return;
        }
        _report(WebRtcDriverDescription(_id, description.sdp));
        _described = true;
        _candidates.forEach(_report);
        _candidates.clear();
      }, onError: (Object _) => _fail()),
    );
  }

  void _report(WebRtcDriverEvent event) {
    if (!_closed && !_failed) _driver._events.add(event);
  }

  void _fail() {
    if (_closed || _failed) return;
    _driver._events.add(WebRtcDriverClosed(_id));
    _failed = true;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _peer
      ..onicecandidate = null
      ..onconnectionstatechange = null;
    for (final channel in _lanes) {
      channel
        ..onopen = null
        ..onmessage = null
        ..onerror = null
        ..onclose = null;
    }
    try {
      _peer.close();
    } on Object {
      // Releasing a failed connection is best effort.
    }
  }
}

web.RTCIceServer _server(IceServer server) {
  final urls = [for (final url in server.urls) url.toJS].toJS;
  final username = server.username;
  final credential = server.credential;
  return username == null || credential == null
      ? web.RTCIceServer(urls: urls)
      : web.RTCIceServer(
          urls: urls,
          username: username,
          credential: credential,
        );
}

web.RTCSessionDescriptionInit _description(String type, String sdp) =>
    web.RTCSessionDescriptionInit(type: type, sdp: sdp);
