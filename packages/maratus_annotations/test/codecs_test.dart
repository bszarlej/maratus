import 'package:maratus/maratus.dart';
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:test/test.dart';

void main() {
  test('NetworkCodec and WireKey keep their explicit names', () {
    expect(
      const NetworkCodec('arena.move_input@1').descriptor,
      'arena.move_input@1',
    );
    expect(const WireKey('x').key, 'x');
  });

  test('Range bounds are optional on either side', () {
    const both = Range(min: -1, max: 1.5);
    const lower = Range(min: 0);

    expect(both.min, -1);
    expect(both.max, 1.5);
    expect(lower.min, 0);
    expect(lower.max, isNull);
  });

  test('MaxLength keeps its length', () {
    expect(const MaxLength(120).length, 120);
  });

  test('UseCodec accepts a const codec of any type', () {
    const annotation = UseCodec(
      ListCodec(IntCodec(min: 0, max: 9), maxLength: 4),
    );

    expect(annotation.codec.descriptor, 'list<int(min=0,max=9)>(maxLength=4)');
  });
}
