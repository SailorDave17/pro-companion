import 'envelope.dart';

/// The order race-time events happened in: device time, then device, then -
/// for two events one phone logged in the same millisecond - that phone's
/// sequence number, which is the order they were tapped. ADR 001's log order
/// breaks that tie by ULID, whose random tail can invert two taps; a finish
/// order, a fleet switch or a start must not.
int happened(EventEnvelope a, EventEnvelope b) {
  final byTs = a.deviceTs.compareTo(b.deviceTs);
  if (byTs != 0) return byTs;
  final byDevice = a.deviceId.compareTo(b.deviceId);
  if (byDevice != 0) return byDevice;
  final bySeq = a.seq.compareTo(b.seq);
  return bySeq != 0 ? bySeq : a.ulid.compareTo(b.ulid);
}

/// The ULIDs that an undo of [undoKind] takes back.
Set<String> undoneBy(Iterable<EventEnvelope> events, String undoKind) => {
      for (final e in events)
        if (e.kind == undoKind && e.correctsUlid != null) e.correctsUlid!,
    };
