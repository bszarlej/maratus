/// The generators that the builder of `maratus_generator` runs, for
/// composing them into another builder.
///
/// Most packages only add `maratus_generator` as a dev dependency and run
/// `dart run build_runner build`, which applies the builder in
/// `package:maratus_generator/builder.dart` automatically.
library;

export 'src/network_codec_generator.dart' show NetworkCodecGenerator;
export 'src/networked_generator.dart' show NetworkedGenerator;
