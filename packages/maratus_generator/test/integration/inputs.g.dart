// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'inputs.dart';

// **************************************************************************
// NetworkCodecGenerator
// **************************************************************************

/// The codec of [MoveInput], generated from its annotations.
final class MoveInputCodec extends ValueCodec<MoveInput> {
  /// Creates the codec.
  const MoveInputCodec();

  static const _x = DoubleCodec(min: -1, max: 1);
  static const _y = MoveInput._axis;

  @override
  String get descriptor => 'test.move_input@1';

  @override
  Object? encode(MoveInput value) => {
    'x': _x.encode(value.x),
    'y': _y.encode(value.y),
  };

  @override
  MoveInput decode(Object? wire) {
    final object = WireObject(wire, const {'x', 'y'});
    return MoveInput(object.read('x', _x), object.read('y', _y));
  }
}

/// The codec of [Profile], generated from its annotations.
final class ProfileCodec extends ValueCodec<Profile> {
  /// Creates the codec.
  const ProfileCodec();

  static const _name = StringCodec(maxLength: 16);
  static const _level = IntCodec(min: 1, max: 99);
  static const _tags = ListCodec(StringCodec(), maxLength: 4);
  static const _nickname = NullableCodec(StringCodec());
  static const _input = MoveInputCodec();

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
      input: object.read('input', _input),
      level: object.read('level', _level),
      tags: object.read('tags', _tags),
      nickname: object.read('nickname', _nickname),
    );
  }
}
