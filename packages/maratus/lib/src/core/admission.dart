import 'dart:async';

import '../protocol/identifiers.dart';
import '../protocol/messages.dart';

/// Decides whether a host admits a client that asks to join.
///
/// A handler can decide at once, or return a future that completes later,
/// for example after checking an access token with a backend. Until it
/// decides, the client receives nothing from the session.
typedef AdmissionHandler = FutureOr<Admission> Function(JoinRequest request);

/// A client's request to join a host, which the host's [AdmissionHandler]
/// decides.
final class JoinRequest {
  /// Creates the request of the client that would join as [peer], with
  /// [data].
  const JoinRequest({required this.peer, required this.data});

  /// The ID that the client gets if the host admits it.
  ///
  /// Peer IDs are never reused within a session, so the ID of a client that
  /// is not admitted stays unused.
  final PeerId peer;

  /// The data that the client sent, decoded and validated with the join
  /// request codec of the schema, or `null` if the schema sets none.
  ///
  /// Each request has its own copy.
  final Object? data;
}

/// A host's decision about a [JoinRequest].
final class Admission {
  /// Admits the client, which then receives the host's baseline.
  const Admission.admit() : isAdmitted = true, reason = null;

  /// Rejects the client, telling it the [reason], if given, for example to
  /// show to its player.
  ///
  /// Throws an [ArgumentError] if [reason] is longer than [maxReasonLength]
  /// UTF-16 code units.
  Admission.reject([this.reason]) : isAdmitted = false {
    final reason = this.reason;
    if (reason != null && reason.length > maxReasonLength) {
      throw ArgumentError.value(
        reason,
        'reason',
        'is longer than $maxReasonLength characters',
      );
    }
  }

  /// The maximum length of a rejection [reason], in UTF-16 code units.
  static const maxReasonLength = GoodbyeMessage.maxDetailLength;

  /// Whether the client is admitted.
  final bool isAdmitted;

  /// Why the client was rejected, as the host tells it, or `null`.
  final String? reason;
}
