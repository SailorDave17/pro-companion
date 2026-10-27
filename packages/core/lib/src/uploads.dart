/// What sync (#6) keeps about each of this phone's events on its way to shore,
/// and how the UI reads it (ADR 006). Sync runs beside the store in the core
/// engine and writes these through [EventStore]; the UI reads [UploadStatus]
/// through [CoreClient.uploadStatus] and never learns how sync works.
library;

/// One of this phone's events not yet uploaded: its stored canonical text,
/// exactly as the store keeps it, which is exactly what is sent.
class PendingUpload {
  const PendingUpload({required this.ulid, required this.seq, required this.admissionId, required this.canonical});

  final String ulid;
  final int seq;

  /// The admission the event was written under (#49), or null on an event
  /// written before the phone was ever admitted, which never uploads (owner
  /// decision on #6: a tap is never put into a race day it may not belong to).
  final String? admissionId;

  /// The body as stored. Sync sends it verbatim; a re-serialisation that
  /// changed one byte would turn a retry into a ulid_conflict.
  final String canonical;
}

/// A refused event: kept on the phone, flagged with the server's reason, and
/// never sent again (#6 criterion 10). A refusal for revocation also stops
/// every later send under the same admission (#53): see [UploadStatus.held].
class RefusedUpload {
  const RefusedUpload({required this.ulid, required this.reason, required this.mayBeOnShore, this.kind});

  final String ulid;

  /// append_event's reason category, as it answered it (`revoked`,
  /// `inconsistent_canonical`, `ulid_conflict`, or one a later story adds).
  final String reason;

  /// True when an earlier attempt to send it had an unknown outcome, so the
  /// server may already hold it although this answer refused it (owner
  /// decision on #6): a lost response, then a revocation before the retry.
  final bool mayBeOnShore;

  /// The refused event's kind, read from its stored body, so the UI can list
  /// refusals by kind (#66). Null when the body names none: a corrupt write
  /// the server refuses as `inconsistent_canonical`.
  final String? kind;

  Map<String, Object?> toWire() => {'ulid': ulid, 'reason': reason, 'may_be_on_shore': mayBeOnShore, 'kind': kind};

  static RefusedUpload fromWire(Map w) => RefusedUpload(
        ulid: w['ulid'] as String,
        reason: w['reason'] as String,
        mayBeOnShore: w['may_be_on_shore'] as bool,
        kind: w['kind'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is RefusedUpload &&
      other.ulid == ulid &&
      other.reason == reason &&
      other.mayBeOnShore == mayBeOnShore &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(ulid, reason, mayBeOnShore, kind);

  @override
  String toString() => 'RefusedUpload($ulid ${kind ?? 'no kind'} $reason${mayBeOnShore ? ', may be on shore' : ''})';
}

/// How sync's latest run ended, kept so the UI can say why events are still
/// on the phone: no signal, no session, or not admitted to their race day.
abstract final class UploadRunState {
  /// Nothing this phone may upload is left.
  static const done = 'done';

  /// The server could not be reached: no signal, or no answer in time.
  static const unreachable = 'unreachable';

  /// The phone holds no session. It must sign in again (#71, #104).
  static const noSession = 'no_session';

  /// The kept session could not be read, and was set aside so the phone can
  /// sign in again.
  static const sessionUnreadable = 'session_unreadable';

  /// Events wait for a race day the signed-in phone is not admitted to: it
  /// must be admitted with that day's code. Nothing is refused while it waits.
  static const notAdmitted = 'not_admitted';

  /// The server answered some events with an error it did not judge them by;
  /// they are retried.
  static const retrying = 'retrying';

  static const all = {done, unreachable, noSession, sessionUnreadable, notAdmitted, retrying};
}

/// A summary of sync's latest run.
class UploadRun {
  const UploadRun({required this.state, required this.at, this.paused = 0, this.error});

  /// One of [UploadRunState.all].
  final String state;

  /// When it ended, on the phone's clock (milliseconds since the epoch).
  final int at;

  /// How many events waited for a race day this sign-in is not admitted to.
  final int paused;

  /// The last error the run met, described without any token, or null.
  final String? error;

  Map<String, Object?> toWire() => {'state': state, 'at': at, 'paused': paused, 'error': error};

  static UploadRun fromWire(Map w) => UploadRun(
        state: w['state'] as String,
        at: w['at'] as int,
        paused: w['paused'] as int,
        error: w['error'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is UploadRun && other.state == state && other.at == at && other.paused == paused && other.error == error;

  @override
  int get hashCode => Object.hash(state, at, paused, error);

  @override
  String toString() => 'UploadRun($state at $at, paused $paused${error == null ? '' : ', $error'})';
}

/// Where this phone's own events stand on their way to shore (#6), for the UI
/// (#66) through [CoreClient.uploadStatus].
class UploadStatus {
  const UploadStatus({
    required this.pending,
    required this.accepted,
    required this.neverAdmitted,
    required this.refused,
    this.held = 0,
    this.lastRun,
    this.lastAcceptedAt,
    this.waitingByKind = const {},
  });

  static const empty = UploadStatus(pending: 0, accepted: 0, neverAdmitted: 0, refused: []);

  /// The key [waitingByKind] counts an event under when its stored body names
  /// no kind.
  static const noKind = '';

  /// Events carrying an admission and not yet answered, including any that
  /// wait on a session or an admission. Never one that is [held].
  final int pending;

  /// The [pending] events counted by kind, so the UI can list what waits
  /// (#66). Its counts add up to [pending].
  final Map<String, int> waitingByKind;

  /// When the server last accepted one of this phone's events, on the
  /// phone's clock (milliseconds since the epoch), or null before the first:
  /// the last successful upload (owner decision on #66).
  final int? lastAcceptedAt;

  /// Events the server holds, as it answered.
  final int accepted;

  /// Events written before the phone was ever admitted. They stay on the
  /// phone and never upload.
  final int neverAdmitted;

  /// Events the server refused, oldest first.
  final List<RefusedUpload> refused;

  /// Events written under an admission the server has since revoked (#53).
  /// They stay on the phone and are never sent: sync stops at the first
  /// refusal for revocation, which is in [refused]. An event whose earlier
  /// send may have landed is not held: it goes once more, and its refusal is
  /// flagged [RefusedUpload.mayBeOnShore].
  final int held;

  /// Sync's latest run, or null before its first.
  final UploadRun? lastRun;

  Map<String, Object?> toWire() => {
        'pending': pending,
        'accepted': accepted,
        'never_admitted': neverAdmitted,
        'refused': [for (final r in refused) r.toWire()],
        'held': held,
        'last_run': lastRun?.toWire(),
        'last_accepted_at': lastAcceptedAt,
        'waiting_by_kind': waitingByKind,
      };

  static UploadStatus fromWire(Map w) => UploadStatus(
        pending: w['pending'] as int,
        accepted: w['accepted'] as int,
        neverAdmitted: w['never_admitted'] as int,
        refused: [for (final r in w['refused'] as List) RefusedUpload.fromWire(r as Map)],
        held: w['held'] as int,
        lastRun: w['last_run'] == null ? null : UploadRun.fromWire(w['last_run'] as Map),
        lastAcceptedAt: w['last_accepted_at'] as int?,
        waitingByKind: {
          for (final MapEntry(:key, :value) in (w['waiting_by_kind'] as Map).entries) key as String: value as int,
        },
      );

  @override
  String toString() => 'UploadStatus(pending $pending $waitingByKind, accepted $accepted, '
      'never admitted $neverAdmitted, refused ${refused.length}, held $held, '
      'last accepted at $lastAcceptedAt, last run $lastRun)';
}

/// The admission this phone's taps go under has been revoked (#53): the
/// server refused one of its events for it, and sync sends nothing more under
/// it. The UI reads it through [CoreClient.revocation] and tells the
/// volunteer.
class Revocation {
  const Revocation({required this.eventId, required this.at, this.eventName});

  /// The race day the admission was for.
  final String eventId;

  /// The race day's name, as sync read it while the phone could still read
  /// it, or null when it never learned it: once revoked, the server shows the
  /// phone no race day of the club unless it holds another admission there.
  final String? eventName;

  /// When sync learned it, on the phone's clock (milliseconds since the
  /// epoch).
  final int at;

  Map<String, Object?> toWire() => {'event_id': eventId, 'event_name': eventName, 'at': at};

  static Revocation fromWire(Map w) => Revocation(
        eventId: w['event_id'] as String,
        eventName: w['event_name'] as String?,
        at: w['at'] as int,
      );

  @override
  bool operator ==(Object other) =>
      other is Revocation && other.eventId == eventId && other.eventName == eventName && other.at == at;

  @override
  int get hashCode => Object.hash(eventId, eventName, at);

  @override
  String toString() => 'Revocation($eventId${eventName == null ? '' : ' "$eventName"'} at $at)';
}
