/// Flame bindings for maratus: scopes that drive a multiplayer session for a
/// component subtree, networked components, a spawner for replicated
/// entities, and synchronization of vectors.
///
/// This library re-exports `package:maratus/maratus.dart`, so games need only
/// this import. Code that must run without Flutter, such as a dedicated host,
/// imports `package:maratus` directly.
library;

export 'package:maratus/maratus.dart';

export 'src/multiplayer_scope.dart';
export 'src/vector2_sync.dart';
