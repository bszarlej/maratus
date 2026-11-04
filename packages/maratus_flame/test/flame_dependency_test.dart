import 'package:flame/components.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Exercises the resolved Flame version against the component lifecycle
  // that the Flame bindings rely on.
  testWithFlameGame('mounts and removes components', (game) async {
    final component = Component();

    await game.ensureAdd(component);
    expect(component.isMounted, isTrue);

    game.remove(component);
    await game.ready();
    expect(component.isRemoved, isTrue);
  });
}
