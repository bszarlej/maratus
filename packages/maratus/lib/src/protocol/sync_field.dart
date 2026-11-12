import '../transport/multiplayer_peer.dart';
import 'identifiers.dart';
import 'value_codec.dart';

/// Which peer writes a synchronized field of an entity.
enum FieldWriter {
  /// The entity's authority, which the host can transfer to another peer.
  authority('authority'),

  /// The entity's owner, which controls its input and never changes, so
  /// input such as movement axes can travel as state.
  owner('owner');

  const FieldWriter(this.code);

  /// The stable code included in the application's schema fingerprint.
  final String code;
}

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
    this.writer = FieldWriter.authority,
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

  /// The peer that writes this field of each entity: its authority, the
  /// default, or its owner.
  ///
  /// The writer samples the field and every other peer applies the values
  /// it receives. The host accepts a client's values only for the fields
  /// that the client writes, and relays them to the other clients. An
  /// entity can combine both writers, for example an owner-written input
  /// field next to the position that its authority computes from it.
  final FieldWriter writer;
}
