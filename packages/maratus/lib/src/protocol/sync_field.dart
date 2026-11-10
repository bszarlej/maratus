import '../transport/multiplayer_peer.dart';
import 'identifiers.dart';
import 'value_codec.dart';

/// An immutable description and typed handle for a synchronized field.
///
/// Create and register a handle with `ProtocolSchemaBuilder.addField`, or
/// register an existing one, such as a `const` handle, with
/// `ProtocolSchemaBuilder.addFieldDefinition`. Sessions accept only the
/// handles retained by their schema, so constructing another handle with the
/// same identifier does not register a field.
final class SyncField<T> {
  /// Describes field [id] and the [codec] for its values.
  const SyncField({
    required this.id,
    required this.codec,
    this.deliveryMode = DeliveryMode.reliable,
    this.channel = 0,
  });

  /// The stable field identifier, independent of Dart names or object hashes.
  final FieldId id;

  /// The codec used to serialize and validate the field's values.
  ///
  /// Sessions also compare values by their encoding, so two values are equal
  /// when this codec encodes them identically.
  final ValueCodec<T> codec;

  /// How incremental updates of this field are delivered.
  ///
  /// Every peer's transport must support this mode on [channel]. Unreliable
  /// fields must use `SyncMode.always` so later samples can repair packet
  /// loss. Initial state and late-join snapshots are always reliable.
  final DeliveryMode deliveryMode;

  /// The transport channel for incremental updates, numbered from zero.
  ///
  /// Registration rejects negative channels, and the session validates
  /// transport support. Initial state travels on the reliable control channel.
  final int channel;
}
