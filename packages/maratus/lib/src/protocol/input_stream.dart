import '../transport/multiplayer_peer.dart';
import 'identifiers.dart';
import 'value_codec.dart';

/// An immutable description and typed handle for a stream of inputs.
///
/// The owner of an entity samples one input for each [tick] of its time,
/// numbers it, and sends it to the entity's authority, which applies every
/// input in order, one tick at a time. Because the owner applies the same
/// inputs with the same step, it can predict the result before the
/// authority's state arrives.
///
/// Create and register a handle with `ProtocolSchemaBuilder.addInput`, or
/// register an existing one, such as a `const` handle, with
/// `ProtocolSchemaBuilder.addInputDefinition`. Sessions accept only the
/// handles retained by their schema, so constructing another handle with the
/// same identifier does not register a stream.
final class InputStream<T> {
  /// Describes input stream [id], the [codec] for its inputs, and the [tick]
  /// that each input covers.
  const InputStream({
    required this.id,
    required this.codec,
    required this.tick,
    this.deliveryMode = DeliveryMode.reliable,
    this.channel = 0,
  });

  /// The stable stream identifier, independent of Dart names or object
  /// hashes.
  final InputId id;

  /// The codec used to serialize and validate the inputs.
  final ValueCodec<T> codec;

  /// The fixed time step that each input covers.
  ///
  /// The owner and the authority both apply one input per tick, so the
  /// step that applies an input never depends on a frame time that the
  /// owner reports. Registration rejects a tick that is not positive.
  final Duration tick;

  /// How inputs are delivered to the authority.
  ///
  /// Every peer's transport must support this mode on [channel].
  final DeliveryMode deliveryMode;

  /// The transport channel for inputs, numbered from zero.
  ///
  /// Registration rejects negative channels, and the session validates
  /// transport support.
  final int channel;
}
