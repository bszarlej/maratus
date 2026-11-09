import 'package:maratus/maratus.dart';
import 'package:maratus_generator/src/names.dart';
import 'package:test/test.dart';

void main() {
  test('isValidIdentifier agrees with ProtocolSchemaBuilder', () {
    for (final id in [
      'player',
      'player.move',
      'arena_v2.score_board',
      'a' * maxIdentifierLength,
      '',
      'Player',
      '1player',
      'player.',
      '.player',
      'player..move',
      'player-move',
      'player move',
      'player.2d',
      'a' * (maxIdentifierLength + 1),
    ]) {
      bool registers;
      try {
        ProtocolSchemaBuilder().addRpc(RpcId(id), const BoolCodec());
        registers = true;
      } on ArgumentError {
        registers = false;
      }
      expect(isValidIdentifier(id), registers, reason: id);
    }
  });

  test('stringLiteral escapes quotes, interpolation, and control codes', () {
    expect(stringLiteral(r"it's $5 \ ok"), r"'it\'s \$5 \\ ok'");
    expect(stringLiteral('a\nb\tc\r\u0001'), r"'a\nb\tc\r\u{1}'");
    expect(stringLiteral('ünïcode ☃'), "'ünïcode ☃'");
  });

  test('numberLiteral writes integers and finite doubles', () {
    expect(numberLiteral(-3), '-3');
    expect(numberLiteral(0.5), '0.5');
    expect(numberLiteral(-100.0), '-100.0');
    expect(numberLiteral(1e21), '1e+21');
    expect(() => numberLiteral(double.nan), throwsArgumentError);
    expect(() => numberLiteral(double.infinity), throwsArgumentError);
  });

  test('name helpers adjust the first letter and leading underscores', () {
    expect(publicPart('__name'), 'name');
    expect(upperFirst('name'), 'Name');
    expect(lowerFirst('Name'), 'name');
    expect(upperFirst(''), '');
  });
}
