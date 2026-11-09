import 'package:test/test.dart';

import 'support/generate.dart';

const _imports = '''
import 'package:maratus/maratus.dart';
import 'package:maratus_annotations/maratus_annotations.dart';
''';

void main() {
  test('writes a codec that reads each field under its wire key', () async {
    final generation = await generate('''
$_imports
@NetworkCodec('test.point@1')
final class Point {
  const Point(this.x, {this.label});

  @WireKey('x')
  @Range(min: 0, max: 9)
  final int x;

  @WireKey('label')
  @MaxLength(8)
  final String? label;

  final int unsent = 0;
}
''');

    expect(generation.errors, isEmpty);
    expect(generation.output, contains('final class PointCodec'));
    expect(
      generation.output,
      contains('static const _x = IntCodec(min: 0, max: 9);'),
    );
    expect(
      generation.output,
      contains(
        'static const _label = NullableCodec(StringCodec(maxLength: 8));',
      ),
    );
    expect(
      generation.output,
      contains("String get descriptor => 'test.point@1';"),
    );
    expect(generation.output, contains("label: object.read('label', _label)"));
    expect(generation.output, isNot(contains('unsent')));
  });

  test('uses the import prefix of maratus', () async {
    final generation = await generate('''
import 'package:maratus/maratus.dart' as m;
import 'package:maratus_annotations/maratus_annotations.dart';

@NetworkCodec('test.point@1')
final class Point {
  const Point(this.x);

  @WireKey('x')
  final double x;
}
''');

    expect(generation.errors, isEmpty);
    expect(generation.output, contains('extends m.ValueCodec<Point>'));
    expect(generation.output, contains('static const _x = m.DoubleCodec();'));
    expect(generation.output, contains('m.WireObject(wire'));
  });

  test('qualifies the static members that a field annotation uses', () async {
    final generation = await generate('''
$_imports
@NetworkCodec('test.point@1')
final class Point {
  const Point(this.x);

  static const _axis = DoubleCodec(min: -1, max: 1);

  @WireKey('x')
  @UseCodec(_axis)
  final double x;
}
''');

    expect(generation.errors, isEmpty);
    expect(generation.output, contains('static const _x = Point._axis;'));
  });

  test('moves a codec that a member would shadow to a constant', () async {
    final generation = await generate('''
$_imports
const encode = IntCodec(min: 0);

@NetworkCodec('test.point@1')
final class Point {
  const Point(this.x);

  @WireKey('x')
  @UseCodec(encode)
  final int x;
}
''');

    expect(generation.errors, isEmpty);
    expect(generation.output, contains(r'const _$pointXCodec = encode;'));
    expect(generation.output, contains(r'static const _x = _$pointXCodec;'));
  });

  test('decodes classes without fields', () async {
    final generation = await generate('''
$_imports
@NetworkCodec('test.ping@1')
final class Ping {
  const Ping();
}
''');

    expect(generation.errors, isEmpty);
    expect(generation.output, contains('const <String, Object?>{}'));
    expect(generation.output, contains('WireObject(wire, const <String>{});'));
  });

  group('rejects', () {
    for (final (description, declaration, message) in [
      (
        'enums',
        "@NetworkCodec('test.side@1') enum Side { left, right }",
        'applies only to classes',
      ),
      (
        'generic classes',
        "@NetworkCodec('test.box@1') final class Box<T> { const Box(); }",
        'does not support generic classes',
      ),
      (
        'empty descriptors',
        "@NetworkCodec('') final class Point { const Point(); }",
        'must not be empty',
      ),
      (
        'duplicate wire keys',
        '''
@NetworkCodec('test.point@1')
final class Point {
  const Point(this.x, this.y);
  @WireKey('v') final int x;
  @WireKey('v') final int y;
}''',
        'use the wire key "v"',
      ),
      (
        'limits on fields that are not sent',
        '''
@NetworkCodec('test.point@1')
final class Point {
  const Point(this.x);
  @WireKey('x') final int x;
  @Range(min: 0) final int y = 0;
}''',
        'has a codec annotation but no @WireKey',
      ),
      (
        'required parameters without a field',
        '''
@NetworkCodec('test.point@1')
final class Point {
  const Point(this.x, int y);
  @WireKey('x') final int x;
}''',
        'Parameter y of the unnamed constructor of Point is required',
      ),
      (
        'fields that the constructor does not take',
        '''
@NetworkCodec('test.point@1')
final class Point {
  const Point(this.x) : y = 0;
  @WireKey('x') final int x;
  @WireKey('y') final int y;
}''',
        'Field y of Point is not a parameter of its unnamed constructor',
      ),
      (
        'classes without an unnamed constructor',
        '''
@NetworkCodec('test.point@1')
final class Point {
  const Point.at(this.x);
  @WireKey('x') final int x;
}''',
        'needs an unnamed constructor',
      ),
      (
        'types without a known codec',
        '''
@NetworkCodec('test.event@1')
final class Event {
  const Event(this.at);
  @WireKey('at') final DateTime at;
}''',
        'No codec is known for DateTime',
      ),
      (
        'codecs of another type',
        '''
@NetworkCodec('test.point@1')
final class Point {
  const Point(this.x);
  @WireKey('x') @UseCodec(StringCodec()) final int x;
}''',
        'encodes String, but field x is int',
      ),
      (
        'codecs combined with limits',
        '''
@NetworkCodec('test.point@1')
final class Point {
  const Point(this.x);
  @WireKey('x') @UseCodec(IntCodec()) @Range(min: 0) final int x;
}''',
        'combines @UseCodec with @Range or @MaxLength',
      ),
      (
        'ranges of strings',
        '''
@NetworkCodec('test.name@1')
final class Name {
  const Name(this.value);
  @WireKey('v') @Range(max: 3) final String value;
}''',
        '@Range does not apply',
      ),
      (
        'lengths of numbers',
        '''
@NetworkCodec('test.point@1')
final class Point {
  const Point(this.x);
  @WireKey('x') @MaxLength(3) final int x;
}''',
        '@MaxLength does not apply',
      ),
      (
        'fractional bounds of integers',
        '''
@NetworkCodec('test.point@1')
final class Point {
  const Point(this.x);
  @WireKey('x') @Range(max: 2.5) final int x;
}''',
        'must be an integer',
      ),
      (
        'reversed ranges',
        '''
@NetworkCodec('test.point@1')
final class Point {
  const Point(this.x);
  @WireKey('x') @Range(min: 2, max: 1) final double x;
}''',
        'has a min greater than its max',
      ),
    ]) {
      test(description, () => expectError('$_imports\n$declaration', message));
    }

    test('libraries that do not import maratus', () async {
      await expectError('''
import 'package:maratus_annotations/maratus_annotations.dart';

@NetworkCodec('test.point@1')
final class Point {
  const Point(this.x);
  @WireKey('x') final int x;
}
''', 'needs the maratus API');
    });
  });
}
