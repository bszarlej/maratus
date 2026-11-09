import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

import 'inputs.dart';

/// The hand-written codec of the ValueCodec documentation, which the codec
/// generated for [MoveInput] must match.
final class _HandWrittenMoveInputCodec extends ValueCodec<MoveInput> {
  const _HandWrittenMoveInputCodec();

  static const _axis = DoubleCodec(min: -1, max: 1);

  @override
  String get descriptor => 'test.move_input@1';

  @override
  Object? encode(MoveInput value) => {
    'x': _axis.encode(value.x),
    'y': _axis.encode(value.y),
  };

  @override
  MoveInput decode(Object? wire) {
    final object = WireObject(wire, const {'x', 'y'});
    return MoveInput(object.read('x', _axis), object.read('y', _axis));
  }
}

/// A hand-written codec for [Profile], composed like the generated one.
final class _HandWrittenProfileCodec extends ValueCodec<Profile> {
  const _HandWrittenProfileCodec();

  static const _name = StringCodec(maxLength: 16);
  static const _level = IntCodec(min: 1, max: 99);
  static const _tags = ListCodec(StringCodec(), maxLength: 4);
  static const _nickname = NullableCodec(StringCodec());
  static const _input = _HandWrittenMoveInputCodec();

  @override
  String get descriptor => 'test.profile@1';

  @override
  Object? encode(Profile value) => {
    'name': _name.encode(value.name),
    'level': _level.encode(value.level),
    'tags': _tags.encode(value.tags),
    'nickname': _nickname.encode(value.nickname),
    'input': _input.encode(value.input),
  };

  @override
  Profile decode(Object? wire) {
    final object = WireObject(wire, const {
      'name',
      'level',
      'tags',
      'nickname',
      'input',
    });
    return Profile(
      name: object.read('name', _name),
      level: object.read('level', _level),
      tags: object.read('tags', _tags),
      nickname: object.read('nickname', _nickname),
      input: object.read('input', _input),
    );
  }
}

/// The outcome of decoding [wire] with [codec]: the encoding of the decoded
/// value, or the code and path of the rejection.
Object? _decoding<T>(ValueCodec<T> codec, Object? wire) {
  try {
    return codec.encode(codec.decode(wire));
  } on ProtocolException catch (error) {
    return 'rejected: ${error.code.name} at /${error.path.join('/')}';
  }
}

/// Expects [generated] to encode [values] and decode [wires] exactly as
/// [handWritten] does.
void _expectSameCodec<T>(
  ValueCodec<T> generated,
  ValueCodec<T> handWritten, {
  required List<T> values,
  required List<Object?> wires,
}) {
  expect(generated.descriptor, handWritten.descriptor);
  for (final value in values) {
    final wire = generated.encode(value);
    expect(wire, handWritten.encode(value));
    expect(generated.encode(generated.decode(wire)), wire);
  }
  for (final wire in wires) {
    expect(
      _decoding(generated, wire),
      _decoding(handWritten, wire),
      reason: '$wire',
    );
  }
}

void main() {
  test('a generated codec matches its hand-written equivalent', () {
    _expectSameCodec(
      const MoveInputCodec(),
      const _HandWrittenMoveInputCodec(),
      values: const [MoveInput(0, 0), MoveInput(-1, 1), MoveInput(0.25, -0.5)],
      wires: [
        {'x': 0.5, 'y': -1},
        {'x': 2, 'y': 0},
        {'x': 0, 'y': -1.5},
        {'x': 'left', 'y': 0},
        {'x': 0},
        {'x': 0, 'y': 0, 'z': 0},
        [0, 0],
        null,
      ],
    );
  });

  test('generated codecs compose optional, list, and nested values', () {
    const profile = Profile(
      name: 'Ada',
      level: 7,
      tags: ['fast', 'red'],
      nickname: 'A',
      input: MoveInput(1, -1),
    );
    const defaults = Profile(name: 'Bo', input: MoveInput(0, 0));
    _expectSameCodec(
      const ProfileCodec(),
      const _HandWrittenProfileCodec(),
      values: const [profile, defaults],
      wires: [
        {
          'name': 'Ada',
          'level': 7,
          'tags': ['fast'],
          'nickname': null,
          'input': {'x': 0, 'y': 0},
        },
        {
          'name': 'A name longer than sixteen',
          'level': 1,
          'tags': <Object?>[],
          'nickname': null,
          'input': {'x': 0, 'y': 0},
        },
        {
          'name': 'Ada',
          'level': 100,
          'tags': <Object?>[],
          'nickname': null,
          'input': {'x': 0, 'y': 0},
        },
        {
          'name': 'Ada',
          'level': 1,
          'tags': ['a', 'b', 'c', 'd', 'e'],
          'nickname': null,
          'input': {'x': 0, 'y': 0},
        },
        {
          'name': 'Ada',
          'level': 1,
          'tags': <Object?>[],
          'nickname': null,
          'input': {'x': 3, 'y': 0},
        },
      ],
    );

    final decoded = const ProfileCodec().decode(
      const ProfileCodec().encode(defaults),
    );
    expect(decoded.level, 1);
    expect(decoded.tags, isEmpty);
    expect(decoded.nickname, isNull);
  });

  test('a generated codec reports where nested values are invalid', () {
    expect(
      () => const ProfileCodec().decode({
        'name': 'Ada',
        'level': 1,
        'tags': ['ok', 7],
        'nickname': null,
        'input': {'x': 0, 'y': 0},
      }),
      throwsA(
        isA<ProtocolException>()
            .having(
              (error) => error.code,
              'code',
              ProtocolErrorCode.invalidValue,
            )
            .having((error) => error.path, 'path', ['tags', '1']),
      ),
    );
  });

  test('a generated codec gives a schema its hand-written fingerprint', () {
    String fingerprint(ValueCodec<MoveInput> codec) =>
        (ProtocolSchemaBuilder()
              ..addField(const FieldId('test.input'), codec)
              ..addRpc(const RpcId('test.move'), codec))
            .build()
            .fingerprint;

    expect(
      fingerprint(const MoveInputCodec()),
      fingerprint(const _HandWrittenMoveInputCodec()),
    );
  });

  test('a generated codec rejects values it cannot encode', () {
    expect(
      () => const MoveInputCodec().encode(const MoveInput(2, 0)),
      throwsArgumentError,
    );
    expect(
      () => const ProfileCodec().encode(
        const Profile(name: 'Ada', level: 0, input: MoveInput(0, 0)),
      ),
      throwsArgumentError,
    );
  });
}
