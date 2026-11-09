import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:maratus_generator/builder.dart';
import 'package:test/test.dart';

/// The result of running the builder on one library.
final class Generation {
  Generation._(this.output, this.errors);

  /// The generated part, or `null` if the builder wrote none.
  final String? output;

  /// The errors that the builder reported.
  final List<String> errors;
}

TestReaderWriter? _sources;
var _inputs = 0;

/// Runs the builder on [source], a library of package `pkg`, next to the
/// libraries of every package this test can import and [assets].
///
/// The first call loads those libraries, which takes a few seconds.
Future<Generation> generate(
  String source, {
  Map<String, String> assets = const {},
}) async {
  final sources = _sources ??= await _loadSources();
  final input = 'lib/input_${_inputs++}.dart';
  final errors = <String>[];
  await testBuilder(
    maratus(BuilderOptions.empty),
    {'pkg|$input': source, ...assets},
    rootPackage: 'pkg',
    readerWriter: sources,
    flattenOutput: true,
    onLog: (record) {
      if (record.level.value >= 1000) errors.add(record.message);
    },
  );
  final output = AssetId('pkg', input.replaceFirst('.dart', '.maratus.g.part'));
  return Generation._(
    sources.testing.exists(output) ? sources.testing.readString(output) : null,
    errors,
  );
}

Future<TestReaderWriter> _loadSources() async {
  final sources = TestReaderWriter(rootPackage: 'pkg', flattenOutput: true);
  await sources.testing.loadIsolateSources();
  return sources;
}

/// Expects the builder to reject [source] with an error containing [message].
Future<void> expectError(
  String source,
  String message, {
  Map<String, String> assets = const {},
}) async {
  final generation = await generate(source, assets: assets);
  expect(generation.errors, contains(contains(message)), reason: source);
}
