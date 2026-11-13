import 'package:maratus/maratus.dart';
import 'package:test/test.dart';

/// Builds the schema that protocol fixtures are written against.
ProtocolSchema buildTestSchema() =>
    (ProtocolSchemaBuilder()
          ..addSpawnType(
            const SpawnTypeId('player'),
            const StringCodec(maxLength: 16),
          )
          ..addRpc(const RpcId('player.move'), const MoveInputCodec())
          ..addField(
            const FieldId('player.health'),
            const IntCodec(min: 0, max: 100),
          )
          ..addField(
            const FieldId('player.name'),
            const StringCodec(maxLength: 16),
          )
          ..addInput(
            const InputId('player.steer'),
            const MoveInputCodec(),
            tick: const Duration(milliseconds: 50),
          ))
        .build();

/// Matches a function that throws a [ProtocolException] with [code] and,
/// when given, [path].
Matcher throwsProtocolException(ProtocolErrorCode code, {List<String>? path}) {
  var matcher = isA<ProtocolException>().having((e) => e.code, 'code', code);
  if (path != null) {
    matcher = matcher.having((e) => e.path, 'path', path);
  }
  return throwsA(matcher);
}

/// A movement input, used as a custom RPC payload.
final class MoveInput {
  /// Creates an input that moves by [x] and [y].
  const MoveInput(this.x, this.y);

  /// The horizontal axis, from -1 to 1.
  final double x;

  /// The vertical axis, from -1 to 1.
  final double y;
}

/// A custom codec composed from built-in codecs, following the example in
/// the [ValueCodec] documentation.
final class MoveInputCodec extends ValueCodec<MoveInput> {
  /// Creates the codec.
  const MoveInputCodec();

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
