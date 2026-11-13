import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:maratus/maratus.dart';
import 'package:maratus/src/protocol/messages.dart';
import 'package:maratus/src/protocol/protocol_codec.dart';
import 'package:maratus/src/protocol/wire_codec.dart';
import 'package:test/test.dart';

import 'protocol_test_utils.dart';

/// A schema fingerprint, as a client presents it in a hello message.
const _fingerprint =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

/// Encoded messages of each kind, written against the test schema.
const _fixtures = {
  'hello': '{"v":1,"k":"hello","g":0,"r":0,"b":{"f":"$_fingerprint"}}',
  'hello with request':
      '{"v":1,"k":"hello","g":0,"r":0,'
      '"b":{"f":"$_fingerprint","j":{"name":"Ada","roles":["player"]}}}',
  'welcome': '{"v":1,"k":"welcome","g":5,"r":12,"b":{"p":2,"e":3735928559}}',
  'synced': '{"v":1,"k":"synced","g":5,"r":12,"b":{}}',
  'ready': '{"v":1,"k":"ready","g":5,"r":12,"b":{}}',
  'goodbye': '{"v":1,"k":"goodbye","g":5,"r":0,"b":{"c":"kicked"}}',
  'rejected goodbye':
      '{"v":1,"k":"goodbye","g":0,"r":0,'
      '"b":{"c":"rejected","m":"Match full"}}',
  'not admitting goodbye':
      '{"v":1,"k":"goodbye","g":0,"r":0,"b":{"c":"not_admitting"}}',
  'ping': '{"v":1,"k":"ping","g":5,"r":0,"b":{"n":3}}',
  'pong': '{"v":1,"k":"pong","g":5,"r":0,"b":{"n":3}}',
  'peer joined': '{"v":1,"k":"peer_joined","g":5,"r":11,"b":{"p":3}}',
  'peer ready': '{"v":1,"k":"peer_ready","g":5,"r":12,"b":{"p":3}}',
  'peer left': '{"v":1,"k":"peer_left","g":5,"r":13,"b":{"p":3,"c":"kicked"}}',
  'spawn':
      '{"v":1,"k":"spawn","g":0,"r":0,'
      '"b":{"e":7,"t":"player","d":"Ada","o":2,"a":1}}',
  'parented spawn':
      '{"v":1,"k":"spawn","g":5,"r":9,'
      '"b":{"e":8,"t":"player","d":"Bob","o":3,"a":3,"p":7}}',
  'despawn': '{"v":1,"k":"despawn","g":0,"r":0,"b":{"e":7}}',
  'authority': '{"v":1,"k":"authority","g":5,"r":10,"b":{"e":7,"a":3}}',
  'authority ack': '{"v":1,"k":"authority_ack","g":5,"r":10,"b":{"e":7}}',
  'rpc':
      '{"v":1,"k":"rpc","g":0,"r":0,'
      '"b":{"e":7,"m":"player.move","p":{"x":0.5,"y":-0.25}}}',
  'targeted rpc':
      '{"v":1,"k":"rpc","g":5,"r":0,'
      '"b":{"e":7,"m":"player.move","p":{"x":0.5,"y":-0.25},"t":3}}',
  'rpc delivery':
      '{"v":1,"k":"rpc_delivery","g":5,"r":0,'
      '"b":{"e":7,"m":"player.move","p":{"x":0.5,"y":-0.25},"s":2,"t":3}}',
  'state':
      '{"v":1,"k":"state","g":3,"r":42,'
      '"b":{"e":7,"t":1500000,"f":{"player.health":75,"player.name":"Ada"}}}',
  'untimed state':
      '{"v":1,"k":"state","g":3,"r":43,"b":{"e":7,"f":{"player.health":75}}}',
  'sequenced state':
      '{"v":1,"k":"state","g":3,"r":42,'
      '"b":{"e":7,"n":9,"t":1500000,"f":{"player.health":75}}}',
  'state with an applied input':
      '{"v":1,"k":"state","g":3,"r":42,'
      '"b":{"e":7,"n":9,"t":1500000,"i":40,"f":{"player.health":75}}}',
  'untimed state without applied inputs':
      '{"v":1,"k":"state","g":3,"r":44,'
      '"b":{"e":7,"i":0,"f":{"player.health":75}}}',
  'input':
      '{"v":1,"k":"input","g":5,"r":3,'
      '"b":{"e":7,"m":"player.steer","n":41,'
      '"d":[{"x":0.5,"y":-0.25},{"x":0.25,"y":0.5}]}}',
};

/// The envelopes that [_fixtures] encode.
final _envelopes = {
  'sequenced state': MessageEnvelope(
    StateMessage(
      entity: const EntityId(7),
      values: const {FieldId('player.health'): 75},
      sampledAt: const Duration(milliseconds: 1500),
      sequence: 9,
    ),
    generation: 3,
    revision: 42,
  ),
  'hello': const MessageEnvelope(HelloMessage(fingerprint: _fingerprint)),
  'hello with request': const MessageEnvelope(
    HelloMessage(
      fingerprint: _fingerprint,
      request: {
        'name': 'Ada',
        'roles': ['player'],
      },
    ),
  ),
  'welcome': const MessageEnvelope(
    WelcomeMessage(peer: PeerId(2), epoch: 3735928559),
    generation: 5,
    revision: 12,
  ),
  'synced': const MessageEnvelope(SyncedMessage(), generation: 5, revision: 12),
  'ready': const MessageEnvelope(ReadyMessage(), generation: 5, revision: 12),
  'goodbye': const MessageEnvelope(
    GoodbyeMessage(GoodbyeReason.kicked),
    generation: 5,
  ),
  'rejected goodbye': const MessageEnvelope(
    GoodbyeMessage(GoodbyeReason.rejected, detail: 'Match full'),
  ),
  'not admitting goodbye': const MessageEnvelope(
    GoodbyeMessage(GoodbyeReason.notAdmitting),
  ),
  'ping': const MessageEnvelope(PingMessage(3), generation: 5),
  'pong': const MessageEnvelope(PongMessage(3), generation: 5),
  'peer joined': const MessageEnvelope(
    PeerJoinedMessage(peer: PeerId(3)),
    generation: 5,
    revision: 11,
  ),
  'peer ready': const MessageEnvelope(
    PeerReadyMessage(peer: PeerId(3)),
    generation: 5,
    revision: 12,
  ),
  'peer left': const MessageEnvelope(
    PeerLeftMessage(peer: PeerId(3), reason: DepartureReason.kicked),
    generation: 5,
    revision: 13,
  ),
  'spawn': const MessageEnvelope(
    SpawnMessage(
      entity: EntityId(7),
      type: SpawnTypeId('player'),
      data: 'Ada',
      owner: PeerId(2),
      authority: PeerId.host,
    ),
  ),
  'parented spawn': const MessageEnvelope(
    SpawnMessage(
      entity: EntityId(8),
      type: SpawnTypeId('player'),
      data: 'Bob',
      owner: PeerId(3),
      authority: PeerId(3),
      parent: EntityId(7),
    ),
    generation: 5,
    revision: 9,
  ),
  'despawn': const MessageEnvelope(DespawnMessage(entity: EntityId(7))),
  'authority': const MessageEnvelope(
    AuthorityMessage(entity: EntityId(7), authority: PeerId(3)),
    generation: 5,
    revision: 10,
  ),
  'authority ack': const MessageEnvelope(
    AuthorityAckMessage(entity: EntityId(7)),
    generation: 5,
    revision: 10,
  ),
  'rpc': const MessageEnvelope(
    RpcMessage(
      entity: EntityId(7),
      rpc: RpcId('player.move'),
      payload: MoveInput(0.5, -0.25),
    ),
  ),
  'targeted rpc': const MessageEnvelope(
    RpcMessage(
      entity: EntityId(7),
      rpc: RpcId('player.move'),
      payload: MoveInput(0.5, -0.25),
      target: PeerId(3),
    ),
    generation: 5,
  ),
  'rpc delivery': const MessageEnvelope(
    RpcDeliveryMessage(
      entity: EntityId(7),
      rpc: RpcId('player.move'),
      payload: MoveInput(0.5, -0.25),
      sender: PeerId(2),
      target: PeerId(3),
    ),
    generation: 5,
  ),
  'state': MessageEnvelope(
    StateMessage(
      entity: const EntityId(7),
      values: const {
        FieldId('player.health'): 75,
        FieldId('player.name'): 'Ada',
      },
      sampledAt: const Duration(milliseconds: 1500),
    ),
    generation: 3,
    revision: 42,
  ),
  'untimed state': MessageEnvelope(
    StateMessage(
      entity: const EntityId(7),
      values: const {FieldId('player.health'): 75},
    ),
    generation: 3,
    revision: 43,
  ),
  'state with an applied input': MessageEnvelope(
    StateMessage(
      entity: const EntityId(7),
      values: const {FieldId('player.health'): 75},
      sampledAt: const Duration(milliseconds: 1500),
      sequence: 9,
      inputSequence: 40,
    ),
    generation: 3,
    revision: 42,
  ),
  'untimed state without applied inputs': MessageEnvelope(
    StateMessage(
      entity: const EntityId(7),
      values: const {FieldId('player.health'): 75},
      inputSequence: 0,
    ),
    generation: 3,
    revision: 44,
  ),
  'input': MessageEnvelope(
    InputMessage(
      entity: const EntityId(7),
      input: const InputId('player.steer'),
      sequence: 41,
      values: const [MoveInput(0.5, -0.25), MoveInput(0.25, 0.5)],
    ),
    generation: 5,
    revision: 3,
  ),
};

typedef _InvalidInput = ({
  String reason,
  List<int> bytes,
  ProtocolErrorCode code,
  List<String> path,
});

_InvalidInput _invalid(
  String reason,
  String json,
  ProtocolErrorCode code, {
  List<String> path = const [],
}) => (reason: reason, bytes: utf8.encode(json), code: code, path: path);

/// Received inputs that must be rejected, with the expected error code and
/// location.
final _invalidInputs = <_InvalidInput>[
  for (final sequence in ['0', '-1', '9007199254740992', '1.5', 'null', '"1"'])
    _invalid(
      'invalid state sequence $sequence',
      '{"v":1,"k":"state","g":3,"r":42,'
          '"b":{"e":7,"t":0,"n":$sequence,"f":{"player.health":75}}}',
      ProtocolErrorCode.invalidValue,
      path: ['b', 'n'],
    ),
  for (final sequence in ['-1', '9007199254740992', '1.5', 'null', '"1"'])
    _invalid(
      'invalid applied input sequence $sequence',
      '{"v":1,"k":"state","g":3,"r":42,'
          '"b":{"e":7,"t":0,"i":$sequence,"f":{"player.health":75}}}',
      ProtocolErrorCode.invalidValue,
      path: ['b', 'i'],
    ),
  _invalid(
    'an unknown input stream',
    '{"v":1,"k":"input","g":5,"r":0,'
        '"b":{"e":7,"m":"player.fly","n":1,"d":[{"x":0,"y":0}]}}',
    ProtocolErrorCode.unknownIdentifier,
    path: ['b', 'm'],
  ),
  for (final (description, sequence) in [
    ('zero', '0'),
    ('negative', '-1'),
    ('fractional', '1.5'),
    ('string', '"1"'),
    ('null', 'null'),
    ('web-unsafe', '9007199254740992'),
  ])
    _invalid(
      'a $description input sequence',
      '{"v":1,"k":"input","g":5,"r":0,'
          '"b":{"e":7,"m":"player.steer","n":$sequence,"d":[{"x":0,"y":0}]}}',
      ProtocolErrorCode.invalidValue,
      path: ['b', 'n'],
    ),
  _invalid(
    'inputs numbered beyond the largest safe integer',
    '{"v":1,"k":"input","g":5,"r":0,'
        '"b":{"e":7,"m":"player.steer","n":9007199254740991,'
        '"d":[{"x":0,"y":0},{"x":0,"y":0}]}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'n'],
  ),
  _invalid(
    'an empty list of inputs',
    '{"v":1,"k":"input","g":5,"r":0,'
        '"b":{"e":7,"m":"player.steer","n":1,"d":[]}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'd'],
  ),
  _invalid(
    'inputs that are not a list',
    '{"v":1,"k":"input","g":5,"r":0,'
        '"b":{"e":7,"m":"player.steer","n":1,"d":{"x":0,"y":0}}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'd'],
  ),
  _invalid(
    'an input out of range',
    '{"v":1,"k":"input","g":5,"r":0,'
        '"b":{"e":7,"m":"player.steer","n":1,'
        '"d":[{"x":0,"y":0},{"x":2,"y":0}]}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'd', '1', 'x'],
  ),
  _invalid(
    'an input message without inputs',
    '{"v":1,"k":"input","g":5,"r":0,"b":{"e":7,"m":"player.steer","n":1}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  _invalid(
    'an input message that claims a sender',
    '{"v":1,"k":"input","g":5,"r":0,'
        '"b":{"e":7,"m":"player.steer","n":1,"d":[{"x":0,"y":0}],"s":2}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  _invalid('empty input', '', ProtocolErrorCode.malformed),
  (
    reason: 'invalid UTF-8',
    bytes: [0x7b, 0xff, 0x7d],
    code: ProtocolErrorCode.malformed,
    path: const [],
  ),
  _invalid('text that is not JSON', 'rpc', ProtocolErrorCode.malformed),
  _invalid(
    'a number that overflows to infinity',
    '{"v":1,"k":"rpc","g":0,"r":0,'
        '"b":{"e":7,"m":"player.move","p":{"x":1e400,"y":0}}}',
    ProtocolErrorCode.malformed,
  ),
  _invalid(
    'a value that is not an envelope',
    '[1]',
    ProtocolErrorCode.invalidValue,
  ),
  _invalid(
    'a missing version',
    '{"k":"despawn","g":0,"r":0,"b":{"e":7}}',
    ProtocolErrorCode.invalidValue,
  ),
  _invalid(
    'a fractional version',
    '{"v":1.5,"k":"despawn","g":0,"r":0,"b":{"e":7}}',
    ProtocolErrorCode.invalidValue,
    path: ['v'],
  ),
  _invalid(
    'a string version',
    '{"v":"1","k":"despawn","g":0,"r":0,"b":{"e":7}}',
    ProtocolErrorCode.invalidValue,
    path: ['v'],
  ),
  _invalid(
    'a newer version with another envelope shape',
    '{"v":2,"hello":{}}',
    ProtocolErrorCode.unsupportedVersion,
  ),
  _invalid(
    'an older version',
    '{"v":0,"k":"despawn","g":0,"r":0,"b":{"e":7}}',
    ProtocolErrorCode.unsupportedVersion,
  ),
  _invalid(
    'an unknown message kind',
    '{"v":1,"k":"teleport","g":0,"r":0,"b":{"e":7}}',
    ProtocolErrorCode.unknownKind,
    path: ['k'],
  ),
  _invalid(
    'a missing envelope key',
    '{"v":1,"k":"despawn","g":0,"b":{"e":7}}',
    ProtocolErrorCode.invalidValue,
  ),
  _invalid(
    'an unexpected envelope key',
    '{"v":1,"k":"despawn","g":0,"r":0,"b":{"e":7},"x":0}',
    ProtocolErrorCode.invalidValue,
  ),
  _invalid(
    'a negative generation',
    '{"v":1,"k":"despawn","g":-1,"r":0,"b":{"e":7}}',
    ProtocolErrorCode.invalidValue,
    path: ['g'],
  ),
  _invalid(
    'a fractional revision',
    '{"v":1,"k":"despawn","g":0,"r":0.5,"b":{"e":7}}',
    ProtocolErrorCode.invalidValue,
    path: ['r'],
  ),
  for (final (description, entity) in [
    ('zero', '0'),
    ('fractional', '7.5'),
    ('string', '"7"'),
    ('web-unsafe', '9007199254740992'),
  ])
    _invalid(
      'a $description entity ID',
      '{"v":1,"k":"despawn","g":0,"r":0,"b":{"e":$entity}}',
      ProtocolErrorCode.invalidValue,
      path: ['b', 'e'],
    ),
  _invalid(
    'a missing body key',
    '{"v":1,"k":"rpc","g":0,"r":0,"b":{"e":7,"m":"player.move"}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  _invalid(
    'an unknown spawn type',
    '{"v":1,"k":"spawn","g":0,"r":0,'
        '"b":{"e":7,"t":"monster","d":"Ada","o":2,"a":1}}',
    ProtocolErrorCode.unknownIdentifier,
    path: ['b', 't'],
  ),
  for (final (reason, body) in [
    ('owner', '"e":7,"t":"player","d":"Ada","a":1'),
    ('authority', '"e":7,"t":"player","d":"Ada","o":2'),
  ])
    _invalid(
      'a spawn without an $reason',
      '{"v":1,"k":"spawn","g":0,"r":0,"b":{$body}}',
      ProtocolErrorCode.invalidValue,
      path: ['b'],
    ),
  _invalid(
    'a spawn with an unexpected key',
    '{"v":1,"k":"spawn","g":0,"r":0,'
        '"b":{"e":7,"t":"player","d":"Ada","o":2,"a":1,"x":0}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  for (final (field, other) in [
    ('o', ',"a":1'),
    ('a', ',"o":2'),
    ('p', ',"o":2,"a":1'),
  ])
    for (final (description, value) in [
      ('null', 'null'),
      ('zero', '0'),
      ('negative', '-1'),
      ('fractional', '2.5'),
      ('string', '"2"'),
      ('web-unsafe', '9007199254740992'),
    ])
      _invalid(
        'a $description spawn $field identifier',
        '{"v":1,"k":"spawn","g":0,"r":0,'
            '"b":{"e":7,"t":"player","d":"Ada","$field":$value$other}}',
        ProtocolErrorCode.invalidValue,
        path: ['b', field],
      ),
  _invalid(
    'an unknown RPC',
    '{"v":1,"k":"rpc","g":0,"r":0,"b":{"e":7,"m":"player.fly","p":null}}',
    ProtocolErrorCode.unknownIdentifier,
    path: ['b', 'm'],
  ),
  _invalid(
    'an unknown RPC in a delivery',
    '{"v":1,"k":"rpc_delivery","g":5,"r":0,'
        '"b":{"e":7,"m":"player.fly","p":null,"s":2,"t":3}}',
    ProtocolErrorCode.unknownIdentifier,
    path: ['b', 'm'],
  ),
  for (final origin in ['s', 'sender', 'origin', 'unexpected'])
    for (final target in ['', ',"t":3'])
      _invalid(
        'an RPC request with a claimed $origin and target "$target"',
        '{"v":1,"k":"rpc","g":5,"r":0,'
            '"b":{"e":7,"m":"player.move","p":{"x":0,"y":0},'
            '"$origin":2$target}}',
        ProtocolErrorCode.invalidValue,
        path: ['b'],
      ),
  for (final (kind, field, other) in [
    ('rpc', 't', ''),
    ('rpc_delivery', 's', ',"t":3'),
    ('rpc_delivery', 't', ',"s":2'),
  ])
    for (final (description, peer) in [
      ('null', 'null'),
      ('zero', '0'),
      ('negative', '-1'),
      ('fractional', '2.5'),
      ('string', '"2"'),
      ('boolean', 'true'),
      ('web-unsafe', '9007199254740992'),
    ])
      _invalid(
        'a $description $kind $field peer ID',
        '{"v":1,"k":"$kind","g":5,"r":0,'
            '"b":{"e":7,"m":"player.move","p":{"x":0,"y":0},'
            '"$field":$peer$other}}',
        ProtocolErrorCode.invalidValue,
        path: ['b', field],
      ),
  for (final (reason, extra) in [
    ('sender', ',"t":3'),
    ('target', ',"s":2'),
    ('sender and target', ''),
  ])
    _invalid(
      'an RPC delivery without $reason',
      '{"v":1,"k":"rpc_delivery","g":5,"r":0,'
          '"b":{"e":7,"m":"player.move","p":{"x":0,"y":0}$extra}}',
      ProtocolErrorCode.invalidValue,
      path: ['b'],
    ),
  _invalid(
    'an RPC delivery with an unexpected key',
    '{"v":1,"k":"rpc_delivery","g":5,"r":0,'
        '"b":{"e":7,"m":"player.move","p":{"x":0,"y":0},'
        '"s":2,"t":3,"extra":0}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  _invalid(
    'an unknown field',
    '{"v":1,"k":"state","g":0,"r":0,"b":{"e":7,"t":0,"f":{"player.mana":1}}}',
    ProtocolErrorCode.unknownIdentifier,
    path: ['b', 'f', 'player.mana'],
  ),
  _invalid(
    'a state with an unexpected key',
    '{"v":1,"k":"state","g":0,"r":0,'
        '"b":{"e":7,"t":0,"f":{"player.health":1},"a":2}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  _invalid(
    'an authority transfer without a new authority',
    '{"v":1,"k":"authority","g":5,"r":10,"b":{"e":7}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  _invalid(
    'an authority transfer with an unexpected key',
    '{"v":1,"k":"authority","g":5,"r":10,"b":{"e":7,"a":3,"o":2}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  for (final (description, peer) in [
    ('null', 'null'),
    ('zero', '0'),
    ('fractional', '2.5'),
    ('string', '"2"'),
    ('web-unsafe', '9007199254740992'),
  ])
    _invalid(
      'a $description new authority',
      '{"v":1,"k":"authority","g":5,"r":10,"b":{"e":7,"a":$peer}}',
      ProtocolErrorCode.invalidValue,
      path: ['b', 'a'],
    ),
  _invalid(
    'an authority acknowledgement that names an authority',
    '{"v":1,"k":"authority_ack","g":5,"r":10,"b":{"e":7,"a":3}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  _invalid(
    'an authority acknowledgement without an entity',
    '{"v":1,"k":"authority_ack","g":5,"r":10,"b":{}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  for (final (description, time) in [
    ('null', 'null'),
    ('negative', '-1'),
    ('fractional', '0.5'),
    ('string', '"0"'),
    ('web-unsafe', '9007199254740992'),
  ])
    _invalid(
      'a $description sample time',
      '{"v":1,"k":"state","g":0,"r":0,'
          '"b":{"e":7,"t":$time,"f":{"player.health":1}}}',
      ProtocolErrorCode.invalidValue,
      path: ['b', 't'],
    ),
  for (final kind in ['ping', 'pong']) ...[
    _invalid(
      'a $kind without a sequence',
      '{"v":1,"k":"$kind","g":5,"r":0,"b":{}}',
      ProtocolErrorCode.invalidValue,
      path: ['b'],
    ),
    _invalid(
      'a $kind with an unexpected key',
      '{"v":1,"k":"$kind","g":5,"r":0,"b":{"n":3,"t":1}}',
      ProtocolErrorCode.invalidValue,
      path: ['b'],
    ),
    for (final (description, sequence) in [
      ('negative', '-1'),
      ('fractional', '1.5'),
      ('string', '"3"'),
    ])
      _invalid(
        'a $description $kind sequence',
        '{"v":1,"k":"$kind","g":5,"r":0,"b":{"n":$sequence}}',
        ProtocolErrorCode.invalidValue,
        path: ['b', 'n'],
      ),
  ],
  for (final kind in ['peer_joined', 'peer_ready']) ...[
    _invalid(
      'a $kind message without a peer',
      '{"v":1,"k":"$kind","g":5,"r":11,"b":{}}',
      ProtocolErrorCode.invalidValue,
      path: ['b'],
    ),
    _invalid(
      'a $kind message with an unexpected key',
      '{"v":1,"k":"$kind","g":5,"r":11,"b":{"p":3,"c":"kicked"}}',
      ProtocolErrorCode.invalidValue,
      path: ['b'],
    ),
  ],
  for (final kind in ['peer_joined', 'peer_ready', 'peer_left'])
    for (final (description, peer) in [
      ('null', 'null'),
      ("the host's", '1'),
      ('zero', '0'),
      ('fractional', '2.5'),
      ('string', '"2"'),
      ('web-unsafe', '9007199254740992'),
    ])
      _invalid(
        'a $kind message with a $description peer ID',
        '{"v":1,"k":"$kind","g":5,"r":11,'
            '"b":{"p":$peer${kind == 'peer_left' ? ',"c":"left"' : ''}}}',
        ProtocolErrorCode.invalidValue,
        path: ['b', 'p'],
      ),
  _invalid(
    'a departure without a reason',
    '{"v":1,"k":"peer_left","g":5,"r":13,"b":{"p":3}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  _invalid(
    'an unknown departure reason',
    '{"v":1,"k":"peer_left","g":5,"r":13,"b":{"p":3,"c":"bored"}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'c'],
  ),
  _invalid(
    'a departure reason that is not a string',
    '{"v":1,"k":"peer_left","g":5,"r":13,"b":{"p":3,"c":7}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'c'],
  ),
  _invalid(
    'an overlong RPC identifier',
    '{"v":1,"k":"rpc","g":0,"r":0,"b":{"e":7,"m":"${'a' * 65}","p":null}}',
    ProtocolErrorCode.limitExceeded,
    path: ['b', 'm'],
  ),
  _invalid(
    'an overlong field identifier',
    '{"v":1,"k":"state","g":0,"r":0,"b":{"e":7,"t":0,"f":{"${'a' * 65}":1}}}',
    ProtocolErrorCode.limitExceeded,
    path: ['b', 'f'],
  ),
  _invalid(
    'construction data of the wrong type',
    '{"v":1,"k":"spawn","g":0,"r":0,'
        '"b":{"e":7,"t":"player","d":7,"o":2,"a":1}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'd'],
  ),
  _invalid(
    'construction data over its length limit',
    '{"v":1,"k":"spawn","g":0,"r":0,'
        '"b":{"e":7,"t":"player","d":"${'a' * 17}","o":2,"a":1}}',
    ProtocolErrorCode.limitExceeded,
    path: ['b', 'd'],
  ),
  _invalid(
    'a payload value out of range',
    '{"v":1,"k":"rpc","g":0,"r":0,'
        '"b":{"e":7,"m":"player.move","p":{"x":2,"y":0}}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'p', 'x'],
  ),
  _invalid(
    'a payload with a missing key',
    '{"v":1,"k":"rpc","g":0,"r":0,'
        '"b":{"e":7,"m":"player.move","p":{"x":0}}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'p'],
  ),
  _invalid(
    'an RPC delivery payload value out of range',
    '{"v":1,"k":"rpc_delivery","g":5,"r":0,'
        '"b":{"e":7,"m":"player.move","p":{"x":2,"y":0},"s":2,"t":3}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'p', 'x'],
  ),
  _invalid(
    'a field value out of range',
    '{"v":1,"k":"state","g":0,"r":0,'
        '"b":{"e":7,"t":0,"f":{"player.health":101}}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'f', 'player.health'],
  ),
  _invalid(
    'empty field values',
    '{"v":1,"k":"state","g":0,"r":0,"b":{"e":7,"t":0,"f":{}}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'f'],
  ),
  _invalid(
    'field values that are not an object',
    '{"v":1,"k":"state","g":0,"r":0,"b":{"e":7,"t":0,"f":[]}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'f'],
  ),
  _invalid(
    'a hello without a fingerprint',
    '{"v":1,"k":"hello","g":0,"r":0,"b":{}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  _invalid(
    'a hello that claims a peer ID',
    '{"v":1,"k":"hello","g":0,"r":0,"b":{"f":"$_fingerprint","p":3}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  _invalid(
    'a fingerprint that is not a string',
    '{"v":1,"k":"hello","g":0,"r":0,"b":{"f":7}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'f'],
  ),
  _invalid(
    'an overlong fingerprint',
    '{"v":1,"k":"hello","g":0,"r":0,"b":{"f":"${'a' * 65}"}}',
    ProtocolErrorCode.limitExceeded,
    path: ['b', 'f'],
  ),
  _invalid(
    "a welcome that assigns the host's peer ID",
    '{"v":1,"k":"welcome","g":5,"r":0,"b":{"p":1,"e":7}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'p'],
  ),
  _invalid(
    'a zero epoch',
    '{"v":1,"k":"welcome","g":5,"r":0,"b":{"p":2,"e":0}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'e'],
  ),
  _invalid(
    'a synced message with a body',
    '{"v":1,"k":"synced","g":5,"r":0,"b":{"e":7}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  _invalid(
    'a ready message that is not an object',
    '{"v":1,"k":"ready","g":5,"r":0,"b":null}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  _invalid(
    'an unknown goodbye reason',
    '{"v":1,"k":"goodbye","g":5,"r":0,"b":{"c":"bored"}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'c'],
  ),
  _invalid(
    'a goodbye detail that is not a string',
    '{"v":1,"k":"goodbye","g":0,"r":0,"b":{"c":"rejected","m":7}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'm'],
  ),
  _invalid(
    'an explicit null goodbye detail',
    '{"v":1,"k":"goodbye","g":0,"r":0,"b":{"c":"rejected","m":null}}',
    ProtocolErrorCode.invalidValue,
    path: ['b', 'm'],
  ),
  _invalid(
    'an overlong goodbye detail',
    '{"v":1,"k":"goodbye","g":0,"r":0,'
        '"b":{"c":"rejected","m":"${'a' * (GoodbyeMessage.maxDetailLength + 1)}"}}',
    ProtocolErrorCode.limitExceeded,
    path: ['b', 'm'],
  ),
  _invalid(
    'a goodbye with an unexpected field beside its detail',
    '{"v":1,"k":"goodbye","g":0,"r":0,'
        '"b":{"c":"rejected","m":"Match full","p":2}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
  _invalid(
    'a hello with an unexpected field beside its request',
    '{"v":1,"k":"hello","g":0,"r":0,'
        '"b":{"f":"$_fingerprint","j":"Ada","p":2}}',
    ProtocolErrorCode.invalidValue,
    path: ['b'],
  ),
];

Uint8List _bytes(String text) => utf8.encode(text);

void main() {
  final codec = _jsonCodec(buildTestSchema());

  group('binary fixtures', () {
    final binary = ProtocolCodec(buildTestSchema());
    for (final entry in _fixtures.entries) {
      test('round-trips ${entry.key} through independent codecs', () {
        final bytes = binary.encode(_envelopes[entry.key]!);
        final decoded = ProtocolCodec(buildTestSchema()).decode(bytes);
        expect(
          jsonDecode(utf8.decode(codec.encode(decoded))),
          jsonDecode(entry.value),
        );
        for (var end = 0; end < bytes.length; end++) {
          expect(
            () => binary.decode(Uint8List.sublistView(bytes, 0, end)),
            throwsA(isA<ProtocolException>()),
          );
        }
        expect(
          () => binary.decode(Uint8List.fromList([...bytes, 0])),
          throwsA(isA<ProtocolException>()),
        );
      });
    }
  });

  group('encode', () {
    for (final MapEntry(key: name, value: fixture) in _fixtures.entries) {
      test('writes the $name fixture', () {
        expect(utf8.decode(codec.encode(_envelopes[name]!)), fixture);
      });
    }
  });

  group('decode', () {
    for (final MapEntry(key: name, value: fixture) in _fixtures.entries) {
      test('round-trips the $name fixture', () {
        expect(codec.encode(codec.decode(_bytes(fixture))), _bytes(fixture));
      });
    }

    test('decodes payloads with their registered codecs', () {
      final envelope = codec.decode(_bytes(_fixtures['rpc']!));

      expect(
        envelope.message,
        isA<RpcMessage>()
            .having((m) => m.entity, 'entity', const EntityId(7))
            .having((m) => m.rpc, 'rpc', const RpcId('player.move'))
            .having((m) => m.target, 'target', isNull)
            .having(
              (m) => m.payload,
              'payload',
              isA<MoveInput>()
                  .having((p) => p.x, 'x', 0.5)
                  .having((p) => p.y, 'y', -0.25),
            ),
      );
    });

    test('decodes requested recipients and host-authenticated deliveries', () {
      final request = codec.decode(_bytes(_fixtures['targeted rpc']!));
      final delivery = codec.decode(_bytes(_fixtures['rpc delivery']!));

      expect(
        request.message,
        isA<RpcMessage>().having((m) => m.target, 'target', const PeerId(3)),
      );
      expect(
        delivery.message,
        isA<RpcDeliveryMessage>()
            .having((m) => m.entity, 'entity', const EntityId(7))
            .having((m) => m.rpc, 'rpc', const RpcId('player.move'))
            .having((m) => m.sender, 'sender', const PeerId(2))
            .having((m) => m.target, 'target', const PeerId(3))
            .having(
              (m) => m.payload,
              'payload',
              isA<MoveInput>()
                  .having((p) => p.x, 'x', 0.5)
                  .having((p) => p.y, 'y', -0.25),
            ),
      );
    });

    test('round-trips host and maximum safe RPC peer IDs', () {
      for (final peer in [PeerId.host, const PeerId(IntCodec.maxSafe)]) {
        final request = codec.decode(
          codec.encode(
            MessageEnvelope(
              RpcMessage(
                entity: const EntityId(7),
                rpc: const RpcId('player.move'),
                payload: const MoveInput(0, 0),
                target: peer,
              ),
            ),
          ),
        );
        final delivery = codec.decode(
          codec.encode(
            MessageEnvelope(
              RpcDeliveryMessage(
                entity: const EntityId(7),
                rpc: const RpcId('player.move'),
                payload: const MoveInput(0, 0),
                sender: peer,
                target: peer,
              ),
            ),
          ),
        );

        expect((request.message as RpcMessage).target, peer);
        expect((delivery.message as RpcDeliveryMessage).sender, peer);
        expect((delivery.message as RpcDeliveryMessage).target, peer);
      }
    });

    test('decodes handshake messages', () {
      final welcome = codec.decode(_bytes(_fixtures['welcome']!));
      final goodbye = codec.decode(_bytes(_fixtures['goodbye']!));
      final hello = codec.decode(_bytes(_fixtures['hello']!));

      expect(welcome.generation, 5);
      expect(welcome.revision, 12);
      expect(
        welcome.message,
        isA<WelcomeMessage>()
            .having((m) => m.peer, 'peer', const PeerId(2))
            .having((m) => m.epoch, 'epoch', 3735928559),
      );
      expect(
        goodbye.message,
        isA<GoodbyeMessage>().having(
          (m) => m.reason,
          'reason',
          GoodbyeReason.kicked,
        ),
      );
      expect(
        hello.message,
        isA<HelloMessage>().having(
          (m) => m.fingerprint,
          'fingerprint',
          _fingerprint,
        ),
      );
    });

    test(
      'preserves join wire values for validation after schema comparison',
      () {
        final schema =
            (ProtocolSchemaBuilder()..setJoinRequest(const StringCodec()))
                .build();
        final withJoinRequest = _jsonCodec(schema);
        for (final request in <Object?>[
          null,
          false,
          7,
          'Ada',
          <Object?>[],
          <String, Object?>{},
          {
            'players': ['Ada', null],
          },
        ]) {
          final message =
              withJoinRequest
                      .decode(
                        withJoinRequest.encode(
                          MessageEnvelope(
                            HelloMessage(
                              fingerprint: _fingerprint,
                              request: request,
                            ),
                          ),
                        ),
                      )
                      .message
                  as HelloMessage;

          expect(message.fingerprint, _fingerprint);
          expect(message.request, request);
        }
        final explicitNull =
            codec
                    .decode(
                      _bytes(
                        '{"v":1,"k":"hello","g":0,"r":0,'
                        '"b":{"f":"$_fingerprint","j":null}}',
                      ),
                    )
                    .message
                as HelloMessage;

        expect(explicitNull.request, isNull);
      },
    );

    test('decodes admission rejection codes and optional detail', () {
      for (final reason in [
        GoodbyeReason.rejected,
        GoodbyeReason.notAdmitting,
      ]) {
        for (final detail in [
          null,
          '',
          'Match full',
          'a' * GoodbyeMessage.maxDetailLength,
        ]) {
          final message =
              codec
                      .decode(
                        codec.encode(
                          MessageEnvelope(
                            GoodbyeMessage(reason, detail: detail),
                          ),
                        ),
                      )
                      .message
                  as GoodbyeMessage;

          expect(message.reason, reason);
          expect(message.detail, detail);
        }
      }
    });

    test('enforces wire limits inside a join request in both directions', () {
      final cases = <({WireLimits limits, Object request})>[
        (
          limits: const WireLimits(maxCollectionLength: 5),
          request: [0, 1, 2, 3, 4, 5],
        ),
        (
          limits: const WireLimits(maxDepth: 2),
          request: {
            'nested': [1],
          },
        ),
        (limits: const WireLimits(maxMessageBytes: 128), request: 'a' * 129),
      ];
      for (final testCase in cases) {
        final limited = _jsonCodec(buildTestSchema(), limits: testCase.limits);
        final envelope = MessageEnvelope(
          HelloMessage(fingerprint: _fingerprint, request: testCase.request),
        );

        expect(() => limited.encode(envelope), throwsArgumentError);
        expect(
          () => limited.decode(codec.encode(envelope)),
          throwsProtocolException(ProtocolErrorCode.limitExceeded),
        );
      }
    });

    test('decodes spawn metadata with and without a parent', () {
      final root = codec.decode(_bytes(_fixtures['spawn']!));
      final child = codec.decode(_bytes(_fixtures['parented spawn']!));

      expect(
        root.message,
        isA<SpawnMessage>()
            .having((m) => m.entity, 'entity', const EntityId(7))
            .having((m) => m.type, 'type', const SpawnTypeId('player'))
            .having((m) => m.data, 'data', 'Ada')
            .having((m) => m.owner, 'owner', const PeerId(2))
            .having((m) => m.authority, 'authority', PeerId.host)
            .having((m) => m.parent, 'parent', isNull),
      );
      expect(child.generation, 5);
      expect(child.revision, 9);
      expect(
        child.message,
        isA<SpawnMessage>()
            .having((m) => m.owner, 'owner', const PeerId(3))
            .having((m) => m.authority, 'authority', const PeerId(3))
            .having((m) => m.parent, 'parent', const EntityId(7)),
      );
    });

    test('decodes field values and envelope metadata', () {
      final envelope = codec.decode(_bytes(_fixtures['state']!));

      expect(envelope.generation, 3);
      expect(envelope.revision, 42);
      expect(
        envelope.message,
        isA<StateMessage>()
            .having((m) => m.values, 'values', {
              const FieldId('player.health'): 75,
              const FieldId('player.name'): 'Ada',
            })
            .having(
              (m) => m.sampledAt,
              'sampledAt',
              const Duration(milliseconds: 1500),
            ),
      );
    });

    test('decodes state without a sample time', () {
      final envelope = codec.decode(_bytes(_fixtures['untimed state']!));

      expect(
        envelope.message,
        isA<StateMessage>()
            .having((m) => m.values, 'values', {
              const FieldId('player.health'): 75,
            })
            .having((m) => m.sampledAt, 'sampledAt', isNull),
      );
    });

    test('decodes the input that state reports as applied', () {
      final applied = codec
          .decode(_bytes(_fixtures['state with an applied input']!))
          .message;
      final none = codec
          .decode(_bytes(_fixtures['untimed state without applied inputs']!))
          .message;
      final unreported = codec.decode(_bytes(_fixtures['state']!)).message;

      expect(
        applied,
        isA<StateMessage>()
            .having((m) => m.inputSequence, 'inputSequence', 40)
            .having((m) => m.sequence, 'sequence', 9),
      );
      expect(
        none,
        isA<StateMessage>()
            .having((m) => m.inputSequence, 'inputSequence', 0)
            .having((m) => m.sampledAt, 'sampledAt', isNull),
      );
      expect(
        unreported,
        isA<StateMessage>().having(
          (m) => m.inputSequence,
          'inputSequence',
          isNull,
        ),
      );
    });

    test('decodes numbered inputs with their registered codec', () {
      final envelope = codec.decode(_bytes(_fixtures['input']!));

      expect(envelope.generation, 5);
      expect(envelope.revision, 3);
      expect(
        envelope.message,
        isA<InputMessage>()
            .having((m) => m.entity, 'entity', const EntityId(7))
            .having((m) => m.input, 'input', const InputId('player.steer'))
            .having((m) => m.sequence, 'sequence', 41)
            .having((m) => m.values, 'values', [
              isA<MoveInput>()
                  .having((p) => p.x, 'x', 0.5)
                  .having((p) => p.y, 'y', -0.25),
              isA<MoveInput>()
                  .having((p) => p.x, 'x', 0.25)
                  .having((p) => p.y, 'y', 0.5),
            ]),
      );
    });

    test('decodes the largest safe input sequences', () {
      final last =
          codec
                  .decode(
                    codec.encode(
                      MessageEnvelope(
                        InputMessage(
                          entity: const EntityId(7),
                          input: const InputId('player.steer'),
                          sequence: IntCodec.maxSafe - 1,
                          values: const [MoveInput(0, 0), MoveInput(1, 1)],
                        ),
                      ),
                    ),
                  )
                  .message
              as InputMessage;
      final state =
          codec
                  .decode(
                    codec.encode(
                      MessageEnvelope(
                        StateMessage(
                          entity: const EntityId(7),
                          values: const {FieldId('player.health'): 1},
                          inputSequence: IntCodec.maxSafe,
                        ),
                      ),
                    ),
                  )
                  .message
              as StateMessage;

      expect(last.sequence, IntCodec.maxSafe - 1);
      expect(last.values, hasLength(2));
      expect(state.inputSequence, IntCodec.maxSafe);
    });

    test('decodes authority transfers and their acknowledgements', () {
      final transfer = codec.decode(_bytes(_fixtures['authority']!));
      final ack = codec.decode(_bytes(_fixtures['authority ack']!));

      expect(transfer.revision, 10);
      expect(
        transfer.message,
        isA<AuthorityMessage>()
            .having((m) => m.entity, 'entity', const EntityId(7))
            .having((m) => m.authority, 'authority', const PeerId(3)),
      );
      expect(ack.revision, 10);
      expect(
        ack.message,
        isA<AuthorityAckMessage>().having(
          (m) => m.entity,
          'entity',
          const EntityId(7),
        ),
      );
    });

    test('decodes membership changes', () {
      final joined = codec.decode(_bytes(_fixtures['peer joined']!));
      final ready = codec.decode(_bytes(_fixtures['peer ready']!));
      final left = codec.decode(_bytes(_fixtures['peer left']!));

      expect(joined.revision, 11);
      expect(
        joined.message,
        isA<PeerJoinedMessage>().having((m) => m.peer, 'peer', const PeerId(3)),
      );
      expect(ready.revision, 12);
      expect(
        ready.message,
        isA<PeerReadyMessage>().having((m) => m.peer, 'peer', const PeerId(3)),
      );
      expect(left.revision, 13);
      expect(
        left.message,
        isA<PeerLeftMessage>()
            .having((m) => m.peer, 'peer', const PeerId(3))
            .having((m) => m.reason, 'reason', DepartureReason.kicked),
      );
    });

    test('decodes every departure reason and the largest safe peer ID', () {
      for (final reason in DepartureReason.values) {
        final message =
            codec
                    .decode(
                      codec.encode(
                        MessageEnvelope(
                          PeerLeftMessage(
                            peer: const PeerId(IntCodec.maxSafe),
                            reason: reason,
                          ),
                        ),
                      ),
                    )
                    .message
                as PeerLeftMessage;

        expect(message.peer, const PeerId(IntCodec.maxSafe));
        expect(message.reason, reason);
      }
    });

    test('decodes ping sequences, including the largest safe one', () {
      for (final sequence in [0, 3, IntCodec.maxSafe]) {
        final ping = codec.decode(
          codec.encode(MessageEnvelope(PingMessage(sequence))),
        );
        final pong = codec.decode(
          codec.encode(MessageEnvelope(PongMessage(sequence))),
        );

        expect((ping.message as PingMessage).sequence, sequence);
        expect((pong.message as PongMessage).sequence, sequence);
      }
    });

    for (final input in _invalidInputs) {
      test('rejects ${input.reason}', () {
        expect(
          () => codec.decode(Uint8List.fromList(input.bytes)),
          throwsProtocolException(input.code, path: input.path),
        );
      });
    }

    test('rejects every truncation of valid messages', () {
      for (final fixture in _fixtures.values) {
        final bytes = _bytes(fixture);
        for (var length = 0; length < bytes.length; length++) {
          expect(
            () => codec.decode(Uint8List.sublistView(bytes, 0, length)),
            throwsProtocolException(ProtocolErrorCode.malformed),
            reason: 'first $length bytes of $fixture',
          );
        }
      }
    });

    test('rejects oversized messages before parsing them', () {
      final small = _jsonCodec(
        buildTestSchema(),
        limits: const WireLimits(maxMessageBytes: 32),
      );

      expect(
        () => small.decode(_bytes('x' * 33)),
        throwsProtocolException(ProtocolErrorCode.limitExceeded),
      );
    });

    test('rejects values nested deeper than the limit', () {
      final shallow = _jsonCodec(
        buildTestSchema(),
        limits: const WireLimits(maxDepth: 2),
      );

      expect(
        () => shallow.decode(_bytes(_fixtures['rpc']!)),
        throwsProtocolException(ProtocolErrorCode.limitExceeded),
      );
    });

    test('rejects collections longer than the limit', () {
      final narrow = _jsonCodec(
        buildTestSchema(),
        limits: const WireLimits(maxCollectionLength: 4),
      );

      expect(
        () => narrow.decode(_bytes(_fixtures['despawn']!)),
        throwsProtocolException(ProtocolErrorCode.limitExceeded),
      );
    });

    test('lets mutated input through only as valid messages', () {
      // Anything decoded must also satisfy every check made when encoding,
      // and every rejection must be a ProtocolException.
      final random = Random(7);
      const alphabet = '{}[]":,.-+eE0123456789 tfnul\\';
      final fixtures = _fixtures.values.map(_bytes).toList();
      var accepted = 0;
      var rejected = 0;
      for (var i = 0; i < 5000; i++) {
        final bytes = Uint8List.fromList(
          fixtures[random.nextInt(fixtures.length)],
        );
        for (
          var mutations = 1 + random.nextInt(3);
          mutations > 0;
          mutations--
        ) {
          bytes[random.nextInt(bytes.length)] = random.nextBool()
              ? alphabet.codeUnitAt(random.nextInt(alphabet.length))
              : random.nextInt(256);
        }
        try {
          codec.encode(codec.decode(bytes));
          accepted++;
        } on ProtocolException {
          rejected++;
        }
      }

      expect(accepted, greaterThan(0));
      expect(rejected, greaterThan(0));
    });

    test('never passes invalid input to handlers', () {
      final receiver = _Receiver(codec);

      for (final input in _invalidInputs) {
        receiver.receive(Uint8List.fromList(input.bytes));
      }
      expect(receiver.handled, isEmpty);
      expect(receiver.rejected, hasLength(_invalidInputs.length));

      for (final fixture in _fixtures.values) {
        receiver.receive(_bytes(fixture));
      }
      expect(receiver.handled, hasLength(_fixtures.length));
    });
  });

  group('encode rejects', () {
    void expectRejected(ProtocolMessage message) {
      expect(
        () => codec.encode(MessageEnvelope(message)),
        throwsArgumentError,
        reason: message.kind.code,
      );
    }

    test('unregistered identifiers', () {
      expectRejected(
        const SpawnMessage(
          entity: EntityId(7),
          type: SpawnTypeId('monster'),
          data: 'Ada',
          owner: PeerId(2),
          authority: PeerId.host,
        ),
      );
      expectRejected(
        const RpcMessage(
          entity: EntityId(7),
          rpc: RpcId('player.fly'),
          payload: null,
        ),
      );
      expectRejected(
        const RpcDeliveryMessage(
          entity: EntityId(7),
          rpc: RpcId('player.fly'),
          payload: null,
          sender: PeerId(2),
          target: PeerId(3),
        ),
      );
      expectRejected(
        StateMessage(
          entity: const EntityId(7),
          values: const {FieldId('player.mana'): 1},
          sampledAt: Duration.zero,
        ),
      );
      expectRejected(
        InputMessage(
          entity: const EntityId(7),
          input: const InputId('player.fly'),
          sequence: 1,
          values: const [MoveInput(0, 0)],
        ),
      );
    });

    test('values that their codecs reject', () {
      expectRejected(
        const RpcMessage(
          entity: EntityId(7),
          rpc: RpcId('player.move'),
          payload: 'up',
        ),
      );
      expectRejected(
        const RpcMessage(
          entity: EntityId(7),
          rpc: RpcId('player.move'),
          payload: MoveInput(2, 0),
        ),
      );
      expectRejected(
        const RpcDeliveryMessage(
          entity: EntityId(7),
          rpc: RpcId('player.move'),
          payload: MoveInput(2, 0),
          sender: PeerId(2),
          target: PeerId(3),
        ),
      );
      expectRejected(
        StateMessage(
          entity: const EntityId(7),
          values: const {FieldId('player.health'): 101},
          sampledAt: Duration.zero,
        ),
      );
      for (final input in <Object?>['up', const MoveInput(2, 0)]) {
        expectRejected(
          InputMessage(
            entity: const EntityId(7),
            input: const InputId('player.steer'),
            sequence: 1,
            values: [const MoveInput(0, 0), input],
          ),
        );
      }
    });

    test('input messages without inputs', () {
      expectRejected(
        InputMessage(
          entity: const EntityId(7),
          input: const InputId('player.steer'),
          sequence: 1,
          values: const [],
        ),
      );
    });

    test('inputs numbered outside the safe integers', () {
      for (final (sequence, count) in [
        (0, 1),
        (-1, 1),
        (IntCodec.maxSafe + 1, 1),
        (IntCodec.maxSafe, 2),
      ]) {
        expectRejected(
          InputMessage(
            entity: const EntityId(7),
            input: const InputId('player.steer'),
            sequence: sequence,
            values: List.filled(count, const MoveInput(0, 0)),
          ),
        );
      }
      for (final inputSequence in [-1, IntCodec.maxSafe + 1]) {
        expectRejected(
          StateMessage(
            entity: const EntityId(7),
            values: const {FieldId('player.health'): 1},
            inputSequence: inputSequence,
          ),
        );
      }
    });

    test('state messages without field values', () {
      expectRejected(
        StateMessage(
          entity: const EntityId(7),
          values: const {},
          sampledAt: Duration.zero,
        ),
      );
    });

    test('invalid sample times and ping sequences', () {
      for (final sequence in [0, -1, IntCodec.maxSafe + 1]) {
        expectRejected(
          StateMessage(
            entity: const EntityId(7),
            values: const {FieldId('player.health'): 1},
            sampledAt: Duration.zero,
            sequence: sequence,
          ),
        );
      }
      for (final sampledAt in [
        const Duration(microseconds: -1),
        const Duration(microseconds: IntCodec.maxSafe + 1),
      ]) {
        expectRejected(
          StateMessage(
            entity: const EntityId(7),
            values: const {FieldId('player.health'): 1},
            sampledAt: sampledAt,
          ),
        );
      }
      for (final sequence in [-1, IntCodec.maxSafe + 1]) {
        expectRejected(PingMessage(sequence));
        expectRejected(PongMessage(sequence));
      }
    });

    test('invalid handshake values', () {
      expectRejected(HelloMessage(fingerprint: 'a' * 65));
      expectRejected(const WelcomeMessage(peer: PeerId.host, epoch: 7));
      expectRejected(const WelcomeMessage(peer: PeerId(2), epoch: 0));
      expectRejected(
        GoodbyeMessage(
          GoodbyeReason.rejected,
          detail: 'a' * (GoodbyeMessage.maxDetailLength + 1),
        ),
      );
      for (final request in <Object>[
        double.nan,
        double.infinity,
        {1: 'Ada'},
        Object(),
      ]) {
        expectRejected(
          HelloMessage(fingerprint: _fingerprint, request: request),
        );
      }
    });

    test('invalid entity IDs and envelope counters', () {
      const despawn = DespawnMessage(entity: EntityId(7));

      expectRejected(const DespawnMessage(entity: EntityId(0)));
      expect(
        () => codec.encode(const MessageEnvelope(despawn, generation: -1)),
        throwsArgumentError,
      );
      expect(
        () => codec.encode(const MessageEnvelope(despawn, revision: -1)),
        throwsArgumentError,
      );
    });

    test('invalid spawn owners, authorities, and parents', () {
      for (final value in [-1, 0, IntCodec.maxSafe + 1]) {
        expectRejected(
          SpawnMessage(
            entity: const EntityId(7),
            type: const SpawnTypeId('player'),
            data: 'Ada',
            owner: PeerId(value),
            authority: PeerId.host,
          ),
        );
        expectRejected(
          SpawnMessage(
            entity: const EntityId(7),
            type: const SpawnTypeId('player'),
            data: 'Ada',
            owner: PeerId.host,
            authority: PeerId(value),
          ),
        );
        expectRejected(
          SpawnMessage(
            entity: const EntityId(7),
            type: const SpawnTypeId('player'),
            data: 'Ada',
            owner: PeerId.host,
            authority: PeerId.host,
            parent: EntityId(value),
          ),
        );
      }
    });

    test('membership changes about the host or invalid peer IDs', () {
      for (final value in [-1, 0, 1, IntCodec.maxSafe + 1]) {
        final peer = PeerId(value);
        expectRejected(PeerJoinedMessage(peer: peer));
        expectRejected(PeerReadyMessage(peer: peer));
        expectRejected(
          PeerLeftMessage(peer: peer, reason: DepartureReason.left),
        );
      }
    });

    test('invalid RPC request targets and delivery peer IDs', () {
      for (final value in [-1, 0, IntCodec.maxSafe + 1]) {
        expectRejected(
          RpcMessage(
            entity: const EntityId(7),
            rpc: const RpcId('player.move'),
            payload: const MoveInput(0, 0),
            target: PeerId(value),
          ),
        );
        expectRejected(
          RpcDeliveryMessage(
            entity: const EntityId(7),
            rpc: const RpcId('player.move'),
            payload: const MoveInput(0, 0),
            sender: PeerId(value),
            target: const PeerId(3),
          ),
        );
        expectRejected(
          RpcDeliveryMessage(
            entity: const EntityId(7),
            rpc: const RpcId('player.move'),
            payload: const MoveInput(0, 0),
            sender: const PeerId(2),
            target: PeerId(value),
          ),
        );
      }
    });

    test('messages larger than the limit', () {
      final small = _jsonCodec(
        buildTestSchema(),
        limits: const WireLimits(maxMessageBytes: 32),
      );

      expect(() => small.encode(_envelopes['rpc']!), throwsArgumentError);
    });
  });

  group('with a replacement wire codec', () {
    test('round-trips messages in its byte representation', () {
      final reversed = _jsonCodec(
        buildTestSchema(),
        wire: const _ReversedJsonWireCodec(),
      );
      final bytes = reversed.encode(_envelopes['rpc']!);

      expect(bytes, isNot(_bytes(_fixtures['rpc']!)));
      expect(reversed.encode(reversed.decode(bytes)), bytes);
    });

    test('validates the wire values it produces', () {
      for (final value in [
        {
          'v': 1,
          'k': 'despawn',
          'g': 0,
          'r': 0,
          'b': {'e': double.nan},
        },
        <Object?>{1},
      ]) {
        final codec = _jsonCodec(
          buildTestSchema(),
          wire: _FixedWireCodec(value),
        );

        expect(
          () => codec.decode(Uint8List(0)),
          throwsProtocolException(ProtocolErrorCode.malformed),
          reason: '$value',
        );
      }
    });

    test('reports its format errors as malformed input', () {
      final codec = _jsonCodec(
        buildTestSchema(),
        wire: const _FailingWireCodec(),
      );

      expect(
        () => codec.decode(Uint8List(0)),
        throwsProtocolException(ProtocolErrorCode.malformed),
      );
    });
  });
}

/// Hands decoded envelopes to a handler, the way a session consumes
/// received bytes.
final class _Receiver {
  _Receiver(this.codec);

  final ProtocolCodec codec;
  final handled = <MessageEnvelope>[];
  final rejected = <ProtocolException>[];

  void receive(Uint8List bytes) {
    final MessageEnvelope envelope;
    try {
      envelope = codec.decode(bytes);
    } on ProtocolException catch (error) {
      rejected.add(error);
      return;
    }
    handled.add(envelope);
  }
}

/// Stores wire values as reversed UTF-8 JSON.
final class _ReversedJsonWireCodec implements WireCodec {
  const _ReversedJsonWireCodec();

  static const _json = JsonWireCodec();

  @override
  Uint8List encode(Object? value) =>
      Uint8List.fromList(_json.encode(value).reversed.toList());

  @override
  Object? decode(Uint8List bytes) =>
      _json.decode(Uint8List.fromList(bytes.reversed.toList()));
}

/// Decodes every input to the same wire [value].
final class _FixedWireCodec implements WireCodec {
  const _FixedWireCodec(this.value);

  final Object? value;

  @override
  Uint8List encode(Object? value) => Uint8List(0);

  @override
  Object? decode(Uint8List bytes) => value;
}

/// Fails to decode every input with a [FormatException].
final class _FailingWireCodec implements WireCodec {
  const _FailingWireCodec();

  @override
  Uint8List encode(Object? value) => Uint8List(0);

  @override
  Object? decode(Uint8List bytes) =>
      throw const FormatException('unreadable bytes');
}

ProtocolCodec _jsonCodec(
  ProtocolSchema schema, {
  WireCodec wire = const JsonWireCodec(),
  WireLimits limits = const WireLimits(),
}) => ProtocolCodec(schema, wire: wire, limits: limits);
