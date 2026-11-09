import 'package:analyzer/dart/element/type.dart';
import 'package:maratus_annotations/maratus_annotations.dart';
import 'package:source_gen/source_gen.dart';

import 'library_context.dart';

/// Matches [Networked] annotations.
const networkedChecker = TypeChecker.typeNamed(
  Networked,
  inPackage: 'maratus_annotations',
);

/// Matches [RpcMethod] annotations.
const rpcMethodChecker = TypeChecker.typeNamed(
  RpcMethod,
  inPackage: 'maratus_annotations',
);

/// Matches [SyncedField] annotations.
const syncedFieldChecker = TypeChecker.typeNamed(
  SyncedField,
  inPackage: 'maratus_annotations',
);

/// Matches [NetworkCodec] annotations.
const networkCodecChecker = TypeChecker.typeNamed(
  NetworkCodec,
  inPackage: 'maratus_annotations',
);

/// Matches [WireKey] annotations.
const wireKeyChecker = TypeChecker.typeNamed(
  WireKey,
  inPackage: 'maratus_annotations',
);

/// Matches [Range] annotations.
const rangeChecker = TypeChecker.typeNamed(
  Range,
  inPackage: 'maratus_annotations',
);

/// Matches [MaxLength] annotations.
const maxLengthChecker = TypeChecker.typeNamed(
  MaxLength,
  inPackage: 'maratus_annotations',
);

/// Matches [UseCodec] annotations.
const useCodecChecker = TypeChecker.typeNamed(
  UseCodec,
  inPackage: 'maratus_annotations',
);

/// The type of the values that a `ValueCodec` of [type] encodes, or `null`
/// if [type] is not a codec type.
DartType? encodedType(DartType? type) =>
    _typeArgumentOf(type, 'ValueCodec', 'maratus');

/// The type of the values that an `Interpolator` of [type] blends, or
/// `null` if [type] is not an interpolator type.
DartType? interpolatedType(DartType? type) =>
    _typeArgumentOf(type, 'Interpolator', 'maratus');

DartType? _typeArgumentOf(DartType? type, String name, String package) {
  if (type is! InterfaceType) return null;
  for (final candidate in [type, ...type.allSupertypes]) {
    if (isDeclaredIn(candidate.element, name, package)) {
      return candidate.typeArguments.single;
    }
  }
  return null;
}
