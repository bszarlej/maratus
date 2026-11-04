import 'dart:io';

import 'package:test/test.dart';

/// Implementation areas allowed directly under `lib/src/`.
const _areas = {'core', 'protocol', 'transport', 'replication'};

final _directivePattern = RegExp(
  r'^\s*(?:import|export|part)\b[^;]*;',
  multiLine: true,
);
final _stringPattern = RegExp(r'''['"]([^'"]+)['"]''');
final _dependencyPattern = RegExp(r'^  ([a-z0-9_]+):', multiLine: true);

/// Returns layout violations for library sources keyed by package-relative
/// POSIX path, such as `lib/src/core/peer.dart`.
///
/// Sources must sit in a known area and must not depend on Flutter or Flame,
/// so that this package runs on the plain Dart SDK.
List<String> findLayoutViolations(Map<String, String> sources) {
  final violations = <String>[];
  for (final MapEntry(key: path, value: source) in sources.entries) {
    if (path.startsWith('lib/src/') && _areaOf(path) == null) {
      violations.add('$path is outside the ${_areas.join('/')} areas');
    }
    for (final directive in _directivePattern.allMatches(source)) {
      for (final match in _stringPattern.allMatches(directive[0]!)) {
        final uri = match[1]!;
        if (_isFrameworkUri(uri)) violations.add('$path depends on $uri');
      }
    }
  }
  return violations;
}

/// Returns the Flutter and Flame packages listed in a pubspec's dependency
/// sections.
List<String> findFrameworkDependencies(String pubspec) {
  final violations = <String>[];
  for (final section in pubspec.split(RegExp(r'^(?=\S)', multiLine: true))) {
    if (!section.startsWith('dependencies:') &&
        !section.startsWith('dev_dependencies:')) {
      continue;
    }
    for (final match in _dependencyPattern.allMatches(section)) {
      final name = match[1]!;
      if (_isFrameworkPackage(name)) violations.add(name);
    }
  }
  return violations;
}

String? _areaOf(String path) {
  final segments = path.split('/');
  if (segments.length < 4 || segments[0] != 'lib' || segments[1] != 'src') {
    return null;
  }
  return _areas.contains(segments[2]) ? segments[2] : null;
}

bool _isFrameworkUri(String uri) {
  if (uri == 'dart:ui' || uri.startsWith('dart:ui_web')) return true;
  if (!uri.startsWith('package:')) return false;
  return _isFrameworkPackage(uri.substring('package:'.length).split('/').first);
}

bool _isFrameworkPackage(String name) =>
    name == 'flutter' ||
    name.startsWith('flutter_') ||
    name == 'flame' ||
    name.startsWith('flame_');

void main() {
  group('findLayoutViolations', () {
    test('accepts known areas using Dart and sibling imports', () {
      expect(
        findLayoutViolations({
          'lib/src/protocol/codec.dart': '''
import 'dart:convert';
import 'package:meta/meta.dart';
import '../core/peer.dart';
import 'package:maratus/src/core/clock.dart';
''',
          'lib/maratus.dart': "export 'src/core/clock.dart';",
        }),
        isEmpty,
      );
    });

    test('rejects Flutter and Flame dependencies anywhere', () {
      expect(
        findLayoutViolations({
          'lib/src/core/a.dart': "import 'package:flutter/foundation.dart';",
          'lib/src/transport/b.dart': "export 'package:flame/game.dart';",
          'lib/src/replication/c.dart': "import 'dart:ui' as ui;",
          'lib/src/protocol/d.dart': '''
import 'stub.dart'
    if (dart.library.ui) 'package:flame_test/flame_test.dart';
''',
          'lib/maratus.dart':
              "export 'package:flutter_test/flutter_test.dart';",
        }),
        hasLength(5),
      );
    });

    test('rejects files outside the known areas', () {
      expect(
        findLayoutViolations({
          'lib/src/util.dart': '',
          'lib/src/flame/scope.dart': '',
        }),
        hasLength(2),
      );
    });
  });

  test('findFrameworkDependencies checks only dependency sections', () {
    expect(
      findFrameworkDependencies('''
name: maratus
description: Not flutter or flame.
dependencies:
  crypto: ^3.0.0
  flutter:
    sdk: flutter
dev_dependencies:
  flame_test: ^2.3.1
  test: ^1.26.3
'''),
      ['flutter', 'flame_test'],
    );
  });

  test('lib follows the package layout without Flutter or Flame', () {
    final sources = <String, String>{
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File && file.path.endsWith('.dart'))
          file.path.replaceAll(r'\', '/'): file.readAsStringSync(),
    };

    expect(sources, isNotEmpty);
    expect(findLayoutViolations(sources), isEmpty);
  });

  test('pubspec.yaml depends on neither Flutter nor Flame', () {
    expect(
      findFrameworkDependencies(File('pubspec.yaml').readAsStringSync()),
      isEmpty,
    );
  });
}
