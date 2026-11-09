/// The `build_runner` builder of `maratus_generator`.
///
/// Packages that depend on `maratus_generator` apply it automatically: it
/// writes the code for `maratus_annotations` into each library's `.g.dart`
/// part. Run it with `dart run build_runner build`.
library;

import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'maratus_generator.dart';

/// Creates the builder that generates codecs for `NetworkCodec` classes and
/// handles, bindings, and senders for `Networked` classes.
Builder maratus(BuilderOptions options) => SharedPartBuilder(const [
  NetworkCodecGenerator(),
  NetworkedGenerator(),
], 'maratus');
