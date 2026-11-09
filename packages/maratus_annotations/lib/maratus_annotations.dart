/// Annotations for `maratus_generator`, which generates protocol handles,
/// their registration, handler bindings, typed RPC senders, and value codecs
/// for `maratus` from annotated classes.
///
/// Annotate a class with `@Networked` and its members with `@RpcMethod` and
/// `@SyncedField`, or a data class with `@NetworkCodec` and its fields with
/// `@WireKey`. `@Range`, `@MaxLength`, and `@UseCodec` select the codec of
/// each value that crosses the network.
library;

export 'src/codecs.dart';
export 'src/networked.dart';
