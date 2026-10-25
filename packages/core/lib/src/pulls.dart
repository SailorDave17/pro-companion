/// What sync (#64) keeps about other committee phones' events pulled down to
/// this one, and how the UI reads it (ADR 006). Sync runs beside the store in
/// the core engine and writes these through [EventStore]; the UI reads
/// [PullStatus] through [CoreClient.pullStatus], and the pulled events
/// themselves through [CoreClient.readAll], never learning how sync works.
library;

/// A row the server sent that the store would not take, and why. Nothing is
/// stored, and nothing already stored changes.
class PullRefused implements Exception {
  const PullRefused(this.message);
  final String message;

  @override
  String toString() => 'PullRefused: $message';
}

/// A content-free stub of an event the server refused (#60, groom decision
/// G41): which device's chain was refused at which sequence number, the
/// refused event's hash and the reason, and none of its text.
class RefusalStub {
  const RefusalStub({
    required this.eventId,
    required this.deviceId,
    required this.seq,
    required this.eventHash,
    required this.reason,
  });

  /// The race day it was refused on.
  final String eventId;
  final String deviceId;
  final int seq;
  final String eventHash;

  /// append_event's reason category, as the server keeps it.
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is RefusalStub &&
      other.eventId == eventId &&
      other.deviceId == deviceId &&
      other.seq == seq &&
      other.eventHash == eventHash &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(eventId, deviceId, seq, eventHash, reason);

  @override
  String toString() => 'RefusalStub($deviceId seq $seq on $eventId: $reason)';
}

/// Where the pull of one race day stands for one device (#64 criterion 2):
/// the lowest sequence number held from it there ([floor]), the highest held
/// contiguously from that one ([contiguous]), the highest held at all
/// ([highest]), and the numbers between [floor] and [highest] not held
/// ([missing], inclusive ranges, ascending). A refused sequence number counts
/// as held, from its stub (criterion 7).
///
/// A pull asks for exactly what is not held: every number below [floor],
/// every number above [highest], and each range in [missing]. So a lower
/// number that reaches shore late (7 seen, then 6) is still delivered, and
/// nothing held is sent again.
///
/// It counts from the lowest held, not from 1: a phone's first events (its
/// role pick, logged before it is admitted) never reach shore. And a range a
/// device logged on another race day leaves a hole here that never fills,
/// which costs one range in the pull rather than every number above it.
class PullCursor {
  const PullCursor({required this.floor, required this.contiguous, int? highest, this.missing = const []})
      : highest = highest ?? contiguous;

  final int floor;
  final int contiguous;
  final int highest;
  final List<(int, int)> missing;

  @override
  bool operator ==(Object other) =>
      other is PullCursor &&
      other.floor == floor &&
      other.contiguous == contiguous &&
      other.highest == highest &&
      other.missing.length == missing.length &&
      [for (var i = 0; i < missing.length; i++) other.missing[i] == missing[i]].every((same) => same);

  @override
  int get hashCode => Object.hash(floor, contiguous, highest, Object.hashAll(missing));

  @override
  String toString() =>
      'PullCursor($floor..$contiguous${highest == contiguous ? '' : ', highest $highest, missing $missing'})';
}

/// How sync's latest pull ended, kept so the UI can say why other phones'
/// events may be missing: no signal, no session, not admitted, or revoked.
abstract final class PullRunState {
  /// Every race day this phone may read was read to its end.
  static const done = 'done';

  /// The server could not be reached: no signal, or no answer in time.
  static const unreachable = 'unreachable';

  /// The phone holds no session.
  static const noSession = 'no_session';

  /// The kept session could not be read.
  static const sessionUnreadable = 'session_unreadable';

  /// The phone holds no admission to any race day, so there is nothing to
  /// read.
  static const notAdmitted = 'not_admitted';

  /// Every race day the phone was admitted to has revoked it (#64 criterion
  /// 10). Nothing is read, and nothing already stored is touched.
  static const revoked = 'revoked';

  /// The server answered with an error of its own; the pull is retried.
  static const retrying = 'retrying';

  static const all = {done, unreachable, noSession, sessionUnreadable, notAdmitted, revoked, retrying};
}

/// A summary of sync's latest pull.
class PullRun {
  const PullRun({required this.state, required this.at, this.stored = 0, this.revoked = 0, this.rejected = 0, this.error});

  /// One of [PullRunState.all].
  final String state;

  /// When it ended, on the phone's clock (milliseconds since the epoch).
  final int at;

  /// Events and refusal stubs stored by this run.
  final int stored;

  /// Race days refused to this phone because it was revoked there.
  final int revoked;

  /// Rows the server sent that the store would not take: another phone's
  /// event naming this phone, or one clashing with an event already held.
  final int rejected;

  /// The last error the run met, described without any token, or null.
  final String? error;

  Map<String, Object?> toWire() =>
      {'state': state, 'at': at, 'stored': stored, 'revoked': revoked, 'rejected': rejected, 'error': error};

  static PullRun fromWire(Map w) => PullRun(
        state: w['state'] as String,
        at: w['at'] as int,
        stored: w['stored'] as int,
        revoked: w['revoked'] as int,
        rejected: w['rejected'] as int,
        error: w['error'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is PullRun &&
      other.state == state &&
      other.at == at &&
      other.stored == stored &&
      other.revoked == revoked &&
      other.rejected == rejected &&
      other.error == error;

  @override
  int get hashCode => Object.hash(state, at, stored, revoked, rejected, error);

  @override
  String toString() => 'PullRun($state at $at, stored $stored, revoked $revoked, rejected $rejected'
      '${error == null ? '' : ', $error'})';
}

/// How up to date this phone is with the other committee phones (#64
/// criterion 8), for the UI (#66) through [CoreClient.pullStatus].
class PullStatus {
  const PullStatus({this.lastPulledAt, this.lastRun});

  static const empty = PullStatus();

  /// When a pull last read every race day this phone may read, on the
  /// phone's clock, or null before the first.
  final int? lastPulledAt;

  /// Sync's latest pull, or null before its first.
  final PullRun? lastRun;

  Map<String, Object?> toWire() => {'last_pulled_at': lastPulledAt, 'last_run': lastRun?.toWire()};

  static PullStatus fromWire(Map w) => PullStatus(
        lastPulledAt: w['last_pulled_at'] as int?,
        lastRun: w['last_run'] == null ? null : PullRun.fromWire(w['last_run'] as Map),
      );

  @override
  bool operator ==(Object other) => other is PullStatus && other.lastPulledAt == lastPulledAt && other.lastRun == lastRun;

  @override
  int get hashCode => Object.hash(lastPulledAt, lastRun);

  @override
  String toString() => 'PullStatus(last pulled at $lastPulledAt, last run $lastRun)';
}
