import 'dart:convert';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart' as sql;

import 'chain.dart';
import 'chain_status.dart';
import 'clock_offsets.dart';
import 'envelope.dart';
import 'location.dart';
import 'pulls.dart';
import 'roles.dart';
import 'starts.dart';
import 'stations.dart';
import 'uploads.dart';
import 'wire.dart';

/// The append-only event log on the phone (ADR 002): SQLite through
/// package:sqlite3, WAL with synchronous=FULL, so an append that has returned
/// is committed. The engine itself refuses edits, so the rule holds for every
/// code path, not only for the ones that remember it.
///
/// Each row's body is the event's canonical text (docs/event-chain.md), the
/// exact text its hash is taken over, so a chain is always verified against
/// what was stored and never against a re-serialisation of it.
///
/// Synchronous by design. It runs inside the core's isolate and is reached by
/// the UI only through the async interface (ADR 003).
class EventStore {
  EventStore._(this._db, this.deviceId, this._clock, this._random, this._nextSeq, this._prevHash,
      this._admissionId, this.location) {
    _insert = _db.prepare(
      'INSERT INTO events (ulid, device_id, seq, device_ts, body) VALUES (?, ?, ?, ?, ?)',
    );
    _count = _db.prepare('SELECT count(*) AS n FROM events');
    _all = _db.prepare('SELECT body FROM events ORDER BY device_ts, device_id, ulid');
    _own = _db.prepare('SELECT body FROM events WHERE device_id = ? ORDER BY device_ts, device_id, ulid');
    _canonical = _db.prepare('SELECT body FROM events ORDER BY device_id, seq');
    // The canonical text has no spaces (RFC 8785), so every role and station
    // event's body holds one of these, and LIKE narrows the read to them
    // before the kind is checked.
    for (final r in _db.select('SELECT body FROM events WHERE device_id = ? AND (body LIKE ? OR body LIKE ?)',
        [deviceId, '%"kind":"role.%', '%"kind":"station.%'])) {
      _noteStateEvent(EventEnvelope.fromWire(jsonDecode(r['body'] as String) as Map));
    }
    // Every phone's guns, and this phone's clock offsets and changes, the same
    // way.
    for (final r in _db.select('SELECT body FROM events WHERE body LIKE ? OR body LIKE ?',
        ['%"kind":"start%', '%"kind":"clock.%'])) {
      _noteRaceEvent(EventEnvelope.fromWire(jsonDecode(r['body'] as String) as Map));
    }
  }

  /// Opens (creating if needed) the log at [path]. The device id is minted on
  /// first open and kept in the file, so it is stable for the install.
  /// [location] is where every appended event's position comes from (#31): a
  /// [LatestFix] the phone's location feed reports to, unless a test gives
  /// its own.
  factory EventStore.open(String path, {int Function()? clock, Random? random, LocationProvider? location}) {
    final db = sql.sqlite3.open(path);
    try {
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('PRAGMA synchronous=FULL');
      _createSchema(db);
      final now = clock ?? () => DateTime.now().millisecondsSinceEpoch;
      final rng = random ?? Random.secure();
      final deviceId = _deviceId(db, now, rng);
      final admission = db.select("SELECT value FROM meta WHERE key = 'admission_id'");
      final admissionId = admission.isEmpty ? null : admission.first['value'] as String;
      // The chain continues from this device's last event as stored.
      final last = db.select(
        'SELECT seq, body FROM events WHERE device_id = ? ORDER BY seq DESC LIMIT 1',
        [deviceId],
      );
      final where = location ?? LatestFix();
      return last.isEmpty
          ? EventStore._(db, deviceId, now, rng, 1, genesisHash, admissionId, where)
          : EventStore._(db, deviceId, now, rng, (last.first['seq'] as int) + 1,
              chainHash(last.first['body'] as String), admissionId, where);
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  final sql.Database _db;
  final int Function() _clock;
  final Random _random;
  int _nextSeq;

  /// The hash of this device's last stored event: the next append's
  /// `prev_hash`. The genesis value before the first.
  String _prevHash;
  late final sql.PreparedStatement _insert;
  late final sql.PreparedStatement _count;
  late final sql.PreparedStatement _all;
  late final sql.PreparedStatement _own;
  late final sql.PreparedStatement _canonical;

  /// This install's device id. Every event it appends carries it.
  final String deviceId;

  /// Where the phone is (#31). Every event appended carries its position, or
  /// the reason there is none, read from here at the moment of the append.
  final LocationProvider location;

  String? _admissionId;

  /// The admission this phone holds (#49), kept in the file beside the device
  /// id, so a restart keeps it. Every event appended carries it. Null until
  /// the phone is admitted.
  String? get admissionId => _admissionId;

  /// This device's own role picks (#20) and station picks (#26), and their
  /// undos, read from the log when it opens and kept as they are appended.
  final _stateEvents = <EventEnvelope>[];

  /// The role this phone runs as (#20), from its latest role pick not undone.
  /// Every event appended without a role of its own carries it. Null until a
  /// role is picked.
  String? get role => currentRole(_stateEvents, deviceId);

  /// The mark this phone is stationed at (#26), from its latest station pick
  /// not undone under its role pick in force. Every event appended without a
  /// mark of its own carries it. Null until a station is picked.
  String? get station => currentStation(_stateEvents, deviceId);

  void _noteStateEvent(EventEnvelope e) {
    if (e.deviceId == deviceId && (RoleKinds.all.contains(e.kind) || StationKinds.all.contains(e.kind))) {
      _stateEvents.add(e);
    }
  }

  /// What [raceToJoin] reads (#55): every phone's starts, recalls and their
  /// undos, pulled ones included, since a finish joins the race of a gun
  /// another phone fired; and this phone's own clock offsets and clock
  /// changes. Read from the log when it opens and kept as events arrive.
  final _raceEvents = <EventEnvelope>[];

  void _noteRaceEvent(EventEnvelope e) {
    if (StartKinds.sequence.contains(e.kind) ||
        e.kind == StartKinds.undo ||
        (ClockKinds.all.contains(e.kind) && e.deviceId == deviceId)) {
      _raceEvents.add(e);
    }
  }

  static void _createSchema(sql.Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS events (
        ulid TEXT PRIMARY KEY NOT NULL,
        device_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        device_ts INTEGER NOT NULL,
        body TEXT NOT NULL,
        UNIQUE (device_id, seq)
      ) STRICT''');
    db.execute('CREATE INDEX IF NOT EXISTS events_order ON events (device_ts, device_id, ulid)');
    // UPDATE and DELETE raise, whatever issued them.
    db.execute('''
      CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events
      BEGIN SELECT RAISE(ABORT, 'events is append-only: UPDATE refused'); END''');
    db.execute('''
      CREATE TRIGGER IF NOT EXISTS events_no_delete BEFORE DELETE ON events
      BEGIN SELECT RAISE(ABORT, 'events is append-only: DELETE refused'); END''');
    // INSERT OR REPLACE removes the old row WITHOUT firing the delete trigger
    // (SQLite fires it only with recursive_triggers on, a per-connection
    // setting). So an insert that would displace an existing row is refused
    // here, for every connection.
    db.execute('''
      CREATE TRIGGER IF NOT EXISTS events_no_replace BEFORE INSERT ON events
      WHEN EXISTS (SELECT 1 FROM events
                   WHERE ulid = NEW.ulid OR (device_id = NEW.device_id AND seq = NEW.seq))
      BEGIN SELECT RAISE(ABORT, 'events is append-only: an existing event cannot be replaced'); END''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      ) STRICT''');
    _createUploadSchema(db);
    _createPullSchema(db);
  }

  /// What sync (#64) keeps about other phones' events it pulled down: the race
  /// day each came from, so each race day has a cursor of its own, and the
  /// refusal stubs (#60) beside them. Append-only like everything else here.
  static void _createPullSchema(sql.Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS pulled_event (
        ulid TEXT PRIMARY KEY NOT NULL,
        event_id TEXT NOT NULL
      ) STRICT''');
    // One per refused event on a race day, as the server keeps them
    // (event_refusal_once): a device may be refused twice at one sequence
    // number, with two different texts.
    db.execute('''
      CREATE TABLE IF NOT EXISTS pulled_refusal (
        event_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        event_hash TEXT NOT NULL,
        reason TEXT NOT NULL,
        PRIMARY KEY (event_id, event_hash)
      ) STRICT''');
    // Each race day's name, read while the phone may read it, so a phone
    // later revoked there can still say which race day it was (#53).
    db.execute('''
      CREATE TABLE IF NOT EXISTS race_day_name (
        event_id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL
      ) STRICT''');
    for (final (table, key) in const [
      ('pulled_event', 'ulid = NEW.ulid'),
      ('pulled_refusal', 'event_id = NEW.event_id AND event_hash = NEW.event_hash'),
      ('race_day_name', 'event_id = NEW.event_id'),
    ]) {
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${table}_no_update BEFORE UPDATE ON $table
        BEGIN SELECT RAISE(ABORT, '$table is append-only: UPDATE refused'); END''');
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${table}_no_delete BEFORE DELETE ON $table
        BEGIN SELECT RAISE(ABORT, '$table is append-only: DELETE refused'); END''');
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${table}_no_replace BEFORE INSERT ON $table
        WHEN EXISTS (SELECT 1 FROM $table WHERE $key)
        BEGIN SELECT RAISE(ABORT, '$table is append-only: an existing row cannot be replaced'); END''');
    }
  }

  /// What sync (#6) keeps about each event on its way to shore. The events
  /// table refuses UPDATE, so an event's upload state is kept beside it, in
  /// tables that are append-only the same way: each row records a fact that
  /// never changes.
  static void _createUploadSchema(sql.Database db) {
    // The race day each admission belongs to. An admission's race day never
    // changes, so an event is sent to the same race day on every retry: a
    // re-send under another would come back as a ulid_conflict.
    db.execute('''
      CREATE TABLE IF NOT EXISTS upload_admission (
        admission_id TEXT PRIMARY KEY NOT NULL,
        event_id TEXT NOT NULL
      ) STRICT''');
    // Each send of an event, written before it goes out, so it survives a
    // kill with the request in flight.
    db.execute('''
      CREATE TABLE IF NOT EXISTS upload_attempt (
        ulid TEXT NOT NULL,
        n INTEGER NOT NULL,
        at INTEGER NOT NULL,
        PRIMARY KEY (ulid, n)
      ) STRICT''');
    // A send whose failure proves the server stored nothing. A send with no
    // row here and no outcome may have landed.
    db.execute('''
      CREATE TABLE IF NOT EXISTS upload_attempt_void (
        ulid TEXT NOT NULL,
        n INTEGER NOT NULL,
        PRIMARY KEY (ulid, n)
      ) STRICT''');
    // One final answer per event: accepted, or refused with its reason.
    db.execute('''
      CREATE TABLE IF NOT EXISTS upload_outcome (
        ulid TEXT PRIMARY KEY NOT NULL,
        outcome TEXT NOT NULL CHECK (outcome IN ('accepted', 'refused')),
        reason TEXT,
        server_hash TEXT,
        may_be_on_shore INTEGER NOT NULL CHECK (may_be_on_shore IN (0, 1)),
        at INTEGER NOT NULL,
        CHECK ((outcome = 'refused') = (reason IS NOT NULL))
      ) STRICT''');
    // An admission the server refused an event for, as revoked (#53). A
    // revocation is never lifted (a phone revoked on a race day is refused
    // there whatever code it presents, #70), so nothing more is sent under it.
    db.execute('''
      CREATE TABLE IF NOT EXISTS upload_revocation (
        admission_id TEXT PRIMARY KEY NOT NULL,
        event_id TEXT NOT NULL,
        at INTEGER NOT NULL
      ) STRICT''');
    for (final (table, key) in const [
      ('upload_admission', 'admission_id = NEW.admission_id'),
      ('upload_attempt', 'ulid = NEW.ulid AND n = NEW.n'),
      ('upload_attempt_void', 'ulid = NEW.ulid AND n = NEW.n'),
      ('upload_outcome', 'ulid = NEW.ulid'),
      ('upload_revocation', 'admission_id = NEW.admission_id'),
    ]) {
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${table}_no_update BEFORE UPDATE ON $table
        BEGIN SELECT RAISE(ABORT, '$table is append-only: UPDATE refused'); END''');
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${table}_no_delete BEFORE DELETE ON $table
        BEGIN SELECT RAISE(ABORT, '$table is append-only: DELETE refused'); END''');
      // As on events: INSERT OR REPLACE would delete without the delete
      // trigger, and INSERT OR IGNORE and ON CONFLICT reach this too, so every
      // idempotent write below checks before it inserts.
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS ${table}_no_replace BEFORE INSERT ON $table
        WHEN EXISTS (SELECT 1 FROM $table WHERE $key)
        BEGIN SELECT RAISE(ABORT, '$table is append-only: an existing row cannot be replaced'); END''');
    }
  }

  static String _deviceId(sql.Database db, int Function() clock, Random random) {
    final rows = db.select("SELECT value FROM meta WHERE key = 'device_id'");
    if (rows.isNotEmpty) return rows.first['value'] as String;
    final id = newUlid(clock(), random);
    db.execute("INSERT INTO meta (key, value) VALUES ('device_id', ?)", [id]);
    return id;
  }

  /// Caches [admissionId], `admit_device`'s answer, as the admission every
  /// later event is stamped with (#49). A re-admission calls this again and
  /// replaces it; events already stored keep the admission they were written
  /// under. When this returns, it is committed.
  void setAdmissionId(String admissionId) {
    validateAdmissionId(admissionId);
    _db.execute(
      "INSERT INTO meta (key, value) VALUES ('admission_id', ?) "
      'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
      [admissionId],
    );
    _admissionId = admissionId;
  }

  /// Appends [event] as this device's next event, chained to its last one
  /// (#28), stamped with the admission the phone holds (#49) and with where
  /// the phone is (#31), unless it names a role of its own with the role the
  /// phone runs as (#20), and unless it names a mark of its own with the
  /// station the phone is at (#26), and returns it as stored. When this
  /// returns, it is committed. It never waits on GPS: the position is
  /// whatever [location] holds now, or the reason it holds none.
  ///
  /// When [event] joins a race this phone has no clock offset for yet
  /// ([raceToJoin], #55), a clock-offset event read from [location] goes in
  /// just before it, at the same time and in the same commit: both are
  /// stored, or neither is.
  EventEnvelope append(NewEvent event) {
    validateNewEvent(event);
    final now = _clock();
    final where = location.current();
    final stamp = location.clockOffset(now);
    final join = raceToJoin(_raceEvents, event, deviceId: deviceId, now: now, measuredNow: stamp.offsetMs != null);
    if (join == null) return _appendOne(event, newUlid(now, _random), now, where);

    // Two ULIDs from one millisecond sort by their random tails, so the
    // smaller goes to the offset: it then comes first in every read, as it
    // does by sequence number.
    var offsetUlid = newUlid(now, _random);
    var eventUlid = newUlid(now, _random);
    if (offsetUlid.compareTo(eventUlid) > 0) (offsetUlid, eventUlid) = (eventUlid, offsetUlid);
    final offset = ClockEvents.offset(fleet: join.fleet, race: join.atOwnGun ? eventUlid : join.race, stamp: stamp);
    final seq = _nextSeq;
    final prevHash = _prevHash;
    _db.execute('BEGIN IMMEDIATE');
    try {
      _appendOne(offset, offsetUlid, now, where);
      final envelope = _appendOne(event, eventUlid, now, where);
      _db.execute('COMMIT');
      return envelope;
    } catch (_) {
      // Put memory back first: SQLite rolls some failures back itself (a full
      // disk at COMMIT), and then a ROLLBACK of ours would throw before it.
      _nextSeq = seq;
      _prevHash = prevHash;
      _raceEvents.removeWhere((e) => e.ulid == offsetUlid || e.ulid == eventUlid);
      if (!_db.autocommit) _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// The phone's clock was set (#55, after its review): the offset [location]
  /// holds is dropped, and a `clock.changed` event is appended, so that every
  /// race this phone joined before it is joined again with a fresh offset, and
  /// the log says the clock moved. When this returns, it is committed.
  EventEnvelope recordClockChanged() {
    final location = this.location;
    if (location is LatestFix) location.reportClockChanged();
    return append(ClockEvents.changed());
  }

  EventEnvelope _appendOne(NewEvent event, String ulid, int now, GpsStamp where) {
    final envelope = EventEnvelope(
      ulid: ulid,
      deviceTs: now,
      deviceId: deviceId,
      seq: _nextSeq,
      person: event.person,
      role: event.role ?? role,
      admissionId: _admissionId,
      gps: where.fix,
      gpsReason: where.reason,
      source: event.source,
      kind: event.kind,
      payloadVersion: event.payloadVersion,
      correctsUlid: event.correctsUlid,
      prevHash: _prevHash,
      payload: withStation(event.payload, station),
    );
    final text = _store(envelope);
    _nextSeq++;
    _prevHash = chainHash(text);
    _noteStateEvent(envelope);
    _noteRaceEvent(envelope);
    return envelope;
  }

  /// Stores an event from its fields, as given, for the core's own tests and
  /// tools. Never replaces one. Another phone's event pulled down by sync
  /// goes through [insertPulled] instead, which keeps the server's text byte
  /// for byte (#64).
  void insert(EventEnvelope e) {
    _store(e);
    _noteStateEvent(e);
    _noteRaceEvent(e);
  }

  // Sync's records (#6) -------------------------------------------------------

  /// This device's own events that have no outcome yet, by sequence number,
  /// each with its body exactly as stored. Events another phone wrote are
  /// never here: each phone uploads its own.
  List<PendingUpload> pendingUploads() => [
        for (final r in _db.select(
            'SELECT e.ulid, e.seq, e.body FROM events e '
            'WHERE e.device_id = ? AND NOT EXISTS (SELECT 1 FROM upload_outcome o WHERE o.ulid = e.ulid) '
            'ORDER BY e.seq',
            [deviceId]))
          PendingUpload(
            ulid: r['ulid'] as String,
            seq: r['seq'] as int,
            admissionId: _admissionOf(r['body'] as String),
            canonical: r['body'] as String,
          ),
      ];

  static String? _admissionOf(String body) {
    try {
      final id = (jsonDecode(body) as Map)['admission_id'];
      return id is String ? id : null;
    } on FormatException {
      return null;
    }
  }

  /// Records that [admissionId] admits this phone to race day [eventId]. An
  /// admission's race day never changes: recording it again is a no-op, and
  /// recording another race day for it is refused.
  void recordAdmissionEvent(String admissionId, String eventId) {
    validateAdmissionId(admissionId);
    if (!isAdmissionId(eventId)) {
      throw ArgumentError.value(eventId, 'eventId', 'is not a UUID in the form Postgres prints');
    }
    final known = admissionEvent(admissionId);
    if (known == eventId) return;
    if (known != null) {
      throw StateError('admission $admissionId is for race day $known, not $eventId');
    }
    _db.execute('INSERT INTO upload_admission (admission_id, event_id) VALUES (?, ?)', [admissionId, eventId]);
  }

  /// The race day [admissionId] admits this phone to, or null when sync has
  /// not learned it.
  String? admissionEvent(String admissionId) {
    final rows = _db.select('SELECT event_id FROM upload_admission WHERE admission_id = ?', [admissionId]);
    return rows.isEmpty ? null : rows.first['event_id'] as String;
  }

  /// Records that send [n] of [ulid] is about to go out, before it does, and
  /// says whether an earlier send's outcome is unknown: one that may have
  /// reached the server, since it was neither answered nor proved to have
  /// stored nothing ([voidAttempt]).
  ({int n, bool earlierUnknown}) beginAttempt(String ulid) {
    _requireOwnEvent(ulid);
    final rows = _db.select(
      'SELECT coalesce(max(a.n), 0) AS last, '
      'count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM upload_attempt_void v '
      'WHERE v.ulid = a.ulid AND v.n = a.n)) AS unknown '
      'FROM upload_attempt a WHERE a.ulid = ?',
      [ulid],
    );
    final n = (rows.first['last'] as int) + 1;
    _db.execute('INSERT INTO upload_attempt (ulid, n, at) VALUES (?, ?, ?)', [ulid, n, _clock()]);
    return (n: n, earlierUnknown: (rows.first['unknown'] as int) > 0);
  }

  /// Records that send [n] of [ulid] failed in a way that proves the server
  /// stored nothing. Recording it again is a no-op.
  void voidAttempt(String ulid, int n) {
    if (_db.select('SELECT 1 FROM upload_attempt WHERE ulid = ? AND n = ?', [ulid, n]).isEmpty) {
      throw StateError('$ulid has no send $n to void');
    }
    if (_db.select('SELECT 1 FROM upload_attempt_void WHERE ulid = ? AND n = ?', [ulid, n]).isNotEmpty) return;
    _db.execute('INSERT INTO upload_attempt_void (ulid, n) VALUES (?, ?)', [ulid, n]);
  }

  /// Records that the server holds [ulid], answering with [serverHash].
  void recordAccepted(String ulid, String serverHash) =>
      _recordOutcome(ulid, 'accepted', null, serverHash, mayBeOnShore: false);

  /// Records that the server refused [ulid] for [reason]. It is final: the
  /// event stays on the phone, flagged, and is never sent again (#6).
  void recordRefused(String ulid, String reason, {required bool mayBeOnShore}) {
    if (reason.isEmpty) throw ArgumentError.value(reason, 'reason', 'must not be empty');
    _recordOutcome(ulid, 'refused', reason, null, mayBeOnShore: mayBeOnShore);
  }

  void _recordOutcome(String ulid, String outcome, String? reason, String? serverHash,
      {required bool mayBeOnShore}) {
    _requireOwnEvent(ulid);
    final existing = _db.select(
        'SELECT outcome, reason, server_hash, may_be_on_shore FROM upload_outcome WHERE ulid = ?', [ulid]);
    if (existing.isNotEmpty) {
      final r = existing.first;
      if (r['outcome'] == outcome &&
          r['reason'] == reason &&
          r['server_hash'] == serverHash &&
          r['may_be_on_shore'] == (mayBeOnShore ? 1 : 0)) {
        return;
      }
      throw StateError('$ulid already has an outcome: ${r['outcome']}');
    }
    _db.execute(
      'INSERT INTO upload_outcome (ulid, outcome, reason, server_hash, may_be_on_shore, at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [ulid, outcome, reason, serverHash, mayBeOnShore ? 1 : 0, _clock()],
    );
  }

  void _requireOwnEvent(String ulid) {
    if (_db.select('SELECT 1 FROM events WHERE ulid = ? AND device_id = ?', [ulid, deviceId]).isEmpty) {
      throw ArgumentError.value(ulid, 'ulid', "is not one of this device's events");
    }
  }

  /// Keeps [run] as sync's latest, replacing the one before: the one piece of
  /// sync's state that is a current value rather than a fact.
  void recordUploadRun(UploadRun run) {
    if (!UploadRunState.all.contains(run.state)) {
      throw ArgumentError.value(run.state, 'state', 'is not an upload run state');
    }
    _db.execute(
      "INSERT INTO meta (key, value) VALUES ('upload_run', ?) "
      'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
      [jsonEncode(run.toWire())],
    );
  }

  /// Records that the server refused an event under [admissionId] because the
  /// admission was revoked (#53). Nothing more is sent under it, and the UI
  /// says so while it is the admission the phone's taps go under
  /// ([revocation]). Sync must have learned the admission's race day first:
  /// it sent the event there. Recording it again is a no-op.
  void recordRevoked(String admissionId) {
    final eventId = admissionEvent(admissionId);
    if (eventId == null) {
      throw StateError('admission $admissionId names no race day sync has learned');
    }
    if (_db.select('SELECT 1 FROM upload_revocation WHERE admission_id = ?', [admissionId]).isNotEmpty) return;
    _db.execute(
        'INSERT INTO upload_revocation (admission_id, event_id, at) VALUES (?, ?, ?)', [admissionId, eventId, _clock()]);
  }

  /// Every admission sync has learned was revoked.
  Set<String> revokedAdmissions() =>
      {for (final r in _db.select('SELECT admission_id FROM upload_revocation')) r['admission_id'] as String};

  /// This device's events with no outcome and a send whose outcome is
  /// unknown: neither answered nor proved to have stored nothing
  /// ([voidAttempt]). The server may hold any of them.
  Set<String> unansweredSends() => {
        for (final r in _db.select('SELECT DISTINCT a.ulid FROM upload_attempt a '
            'WHERE NOT EXISTS (SELECT 1 FROM upload_attempt_void v WHERE v.ulid = a.ulid AND v.n = a.n) '
            'AND NOT EXISTS (SELECT 1 FROM upload_outcome o WHERE o.ulid = a.ulid)'))
          r['ulid'] as String,
      };

  /// Keeps [name] as race day [eventId]'s name, read while the phone could
  /// read it (#53), and returns true; or false when a name is already kept,
  /// which stays.
  bool recordRaceDayName(String eventId, String name) {
    if (!isAdmissionId(eventId)) {
      throw ArgumentError.value(eventId, 'eventId', 'is not a UUID in the form Postgres prints');
    }
    if (raceDayName(eventId) != null) return false;
    _db.execute('INSERT INTO race_day_name (event_id, name) VALUES (?, ?)', [eventId, name]);
    return true;
  }

  /// Race day [eventId]'s name, or null when sync never read it.
  String? raceDayName(String eventId) {
    final rows = _db.select('SELECT name FROM race_day_name WHERE event_id = ?', [eventId]);
    return rows.isEmpty ? null : rows.first['name'] as String;
  }

  /// The revocation of the admission this phone's taps go under (#53), or
  /// null while that admission stands, or when the phone holds none. An
  /// earlier admission revoked after the phone moved on is not this.
  Revocation? revocation() {
    final current = _admissionId;
    if (current == null) return null;
    final rows = _db.select(
        'SELECT r.event_id, r.at, n.name FROM upload_revocation r '
        'LEFT JOIN race_day_name n ON n.event_id = r.event_id WHERE r.admission_id = ?',
        [current]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Revocation(eventId: r['event_id'] as String, eventName: r['name'] as String?, at: r['at'] as int);
  }

  /// Where this device's own events stand on their way to shore.
  UploadStatus uploadStatus() {
    var pending = 0;
    var neverAdmitted = 0;
    var held = 0;
    final revoked = revokedAdmissions();
    // One whose earlier send may have landed still goes once, for its flagged
    // refusal, so it waits rather than being held (#53).
    final unanswered = unansweredSends();
    for (final p in pendingUploads()) {
      if (p.admissionId == null) {
        neverAdmitted++;
      } else if (revoked.contains(p.admissionId) && !unanswered.contains(p.ulid)) {
        held++;
      } else {
        pending++;
      }
    }
    final accepted = _db.select("SELECT count(*) AS n FROM upload_outcome WHERE outcome = 'accepted'").first['n'] as int;
    final refused = [
      for (final r in _db.select("SELECT ulid, reason, may_be_on_shore FROM upload_outcome "
          "WHERE outcome = 'refused' ORDER BY at, ulid"))
        RefusedUpload(ulid: r['ulid'] as String, reason: r['reason'] as String, mayBeOnShore: r['may_be_on_shore'] == 1),
    ];
    final run = _db.select("SELECT value FROM meta WHERE key = 'upload_run'");
    return UploadStatus(
      pending: pending,
      accepted: accepted,
      neverAdmitted: neverAdmitted,
      refused: refused,
      held: held,
      lastRun: run.isEmpty ? null : UploadRun.fromWire(jsonDecode(run.first['value'] as String) as Map),
    );
  }

  // Sync's pull (#64) -----------------------------------------------------------

  /// Stores [canonical], another committee phone's event pulled down from race
  /// day [eventId], byte for byte as the server holds it, so its hash and its
  /// device's chain verify on this phone as they do on its own. Returns true
  /// when it was stored, and false when this phone already holds exactly
  /// that text: an echo of one of its own events, or one pulled before.
  ///
  /// It never enters this device's own chain (criterion 6). Refused with
  /// [PullRefused], storing nothing: text that is not an event's canonical
  /// text; an event naming this device that this device never wrote, which
  /// would take the sequence number its next tap needs; and one that clashes
  /// with an event already held under its ULID, or under its device and
  /// sequence number.
  bool insertPulled(String eventId, String canonical) {
    if (!isAdmissionId(eventId)) {
      throw ArgumentError.value(eventId, 'eventId', 'is not a UUID in the form Postgres prints');
    }
    final EventEnvelope e;
    try {
      final wire = jsonDecode(canonical);
      e = EventEnvelope.fromWire(wire as Map);
      if (canonicalJson(wire) != canonical) throw const PullRefused('it is not canonical text (RFC 8785)');
    } on PullRefused {
      rethrow;
    } on Object catch (error) {
      throw PullRefused('it is not an event: $error');
    }
    if (!isUlid(e.ulid) || !isUlid(e.deviceId) || e.seq < 1) {
      throw PullRefused('${e.ulid} does not name an event: ulid, device id or seq is malformed');
    }
    final held = _db.select('SELECT body FROM events WHERE ulid = ?', [e.ulid]);
    if (held.isNotEmpty) {
      if (held.first['body'] == canonical) return false;
      throw PullRefused('this phone holds another text under ${e.ulid}');
    }
    if (e.deviceId == deviceId) {
      throw PullRefused('${e.ulid} names this phone, which never wrote it');
    }
    if (_db.select('SELECT 1 FROM events WHERE device_id = ? AND seq = ?', [e.deviceId, e.seq]).isNotEmpty) {
      throw PullRefused('this phone holds another event at ${e.deviceId} seq ${e.seq}');
    }
    _db.execute('BEGIN IMMEDIATE');
    try {
      _insert.execute([e.ulid, e.deviceId, e.seq, e.deviceTs, canonical]);
      _db.execute('INSERT INTO pulled_event (ulid, event_id) VALUES (?, ?)', [e.ulid, eventId]);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    // Another phone's gun begins a race this phone's finishes may join (#55).
    _noteRaceEvent(e);
    return true;
  }

  /// Stores [stub], a refusal on its race day (criterion 7), and returns true;
  /// or false when it is already held. One the server keeps once
  /// (`event_refusal_once`) is refused when a held one disagrees with it.
  bool insertRefusalStub(RefusalStub stub) {
    if (!isAdmissionId(stub.eventId)) {
      throw ArgumentError.value(stub.eventId, 'eventId', 'is not a UUID in the form Postgres prints');
    }
    if (!isUlid(stub.deviceId) || stub.seq < 1 || stub.eventHash.isEmpty || stub.reason.isEmpty) {
      throw PullRefused('$stub does not name a refused event');
    }
    final held = _db.select(
        'SELECT device_id, seq, reason FROM pulled_refusal WHERE event_id = ? AND event_hash = ?',
        [stub.eventId, stub.eventHash]);
    if (held.isNotEmpty) {
      final r = held.first;
      if (r['device_id'] == stub.deviceId && r['seq'] == stub.seq && r['reason'] == stub.reason) return false;
      throw PullRefused('this phone holds another refusal of ${stub.eventHash} on ${stub.eventId}');
    }
    _db.execute(
      'INSERT INTO pulled_refusal (event_id, device_id, seq, event_hash, reason) VALUES (?, ?, ?, ?, ?)',
      [stub.eventId, stub.deviceId, stub.seq, stub.eventHash, stub.reason],
    );
    return true;
  }

  /// The refusal stubs held for race day [eventId], by device and sequence.
  List<RefusalStub> refusalStubs(String eventId) => [
        for (final r in _db.select(
            'SELECT device_id, seq, event_hash, reason FROM pulled_refusal WHERE event_id = ? '
            'ORDER BY device_id, seq, event_hash',
            [eventId]))
          RefusalStub(
            eventId: eventId,
            deviceId: r['device_id'] as String,
            seq: r['seq'] as int,
            eventHash: r['event_hash'] as String,
            reason: r['reason'] as String,
          ),
      ];

  /// The pull's cursor for race day [eventId] (criterion 2), one per device
  /// seen there, from the numbers held from it: by an event pulled from that
  /// race day, or by a refusal stub. Its floor, its highest held contiguously
  /// from the floor, its highest held, and the ranges in between not held
  /// ([PullCursor]). This device's own cursor runs from 1 to its last event,
  /// all of which it holds, so its own events are never asked for again.
  ///
  /// Worked out from what is stored rather than kept beside it, so a pull
  /// that died mid-page resumes from exactly what it stored (criterion 5).
  Map<String, PullCursor> pullCursors(String eventId) {
    final seen = <String, Set<int>>{};
    for (final r in _db.select(
        'SELECT e.device_id, e.seq FROM events e JOIN pulled_event p ON p.ulid = e.ulid WHERE p.event_id = ? '
        'UNION SELECT device_id, seq FROM pulled_refusal WHERE event_id = ?',
        [eventId, eventId])) {
      (seen[r['device_id'] as String] ??= <int>{}).add(r['seq'] as int);
    }
    seen.remove(deviceId);
    final cursors = <String, PullCursor>{};
    for (final MapEntry(key: device, value: seqs) in seen.entries) {
      final sorted = seqs.toList()..sort();
      final missing = <(int, int)>[
        for (var i = 1; i < sorted.length; i++)
          if (sorted[i] > sorted[i - 1] + 1) (sorted[i - 1] + 1, sorted[i] - 1),
      ];
      cursors[device] = PullCursor(
        floor: sorted.first,
        contiguous: missing.isEmpty ? sorted.last : missing.first.$1 - 1,
        highest: sorted.last,
        missing: missing,
      );
    }
    cursors[deviceId] = PullCursor(floor: 1, contiguous: _nextSeq - 1);
    return cursors;
  }

  /// Keeps [run] as sync's latest pull, and, when it read every race day the
  /// phone may read, its time as the last successful pull (criterion 8).
  void recordPullRun(PullRun run) {
    if (!PullRunState.all.contains(run.state)) {
      throw ArgumentError.value(run.state, 'state', 'is not a pull run state');
    }
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute(
        "INSERT INTO meta (key, value) VALUES ('pull_run', ?) "
        'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
        [jsonEncode(run.toWire())],
      );
      if (run.state == PullRunState.done) {
        _db.execute(
          "INSERT INTO meta (key, value) VALUES ('last_pulled_at', ?) "
          'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
          ['${run.at}'],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// How up to date this phone is with the other committee phones.
  PullStatus pullStatus() {
    final run = _db.select("SELECT value FROM meta WHERE key = 'pull_run'");
    final at = _db.select("SELECT value FROM meta WHERE key = 'last_pulled_at'");
    return PullStatus(
      lastPulledAt: at.isEmpty ? null : int.parse(at.first['value'] as String),
      lastRun: run.isEmpty ? null : PullRun.fromWire(jsonDecode(run.first['value'] as String) as Map),
    );
  }

  // The committee log view (#67) ------------------------------------------------

  /// What the log view shows: this device's own chain, verified with every
  /// stub naming it, and each other device's log on each race day it was
  /// pulled from, verified from that race day's events and stubs alone. A
  /// race day this phone holds nothing from for a device has its own row
  /// rather than a hole in another's: a device's stint on a race day this
  /// phone was not admitted to never reaches it (#64).
  ChainStatus chainStatus() {
    ChainRefusal refusalOf(sql.Row r) => ChainRefusal(
          deviceId: r['device_id'] as String,
          seq: r['seq'] as int,
          hash: r['event_hash'] as String,
          reason: r['reason'] as String,
        );

    final own = <String, Map>{};
    for (final r in _db.select('SELECT body FROM events WHERE device_id = ?', [deviceId])) {
      own[r['body'] as String] = jsonDecode(r['body'] as String) as Map;
    }
    final ownVerdict = verifyChain(own.keys, refusals: [
      for (final r in _db.select('SELECT device_id, seq, event_hash, reason FROM pulled_refusal WHERE device_id = ?',
          [deviceId]))
        refusalOf(r),
    ]);

    // Race day -> device -> what is held from it there.
    final events = <String, Map<String, List<(String, Map)>>>{};
    final refusals = <String, Map<String, List<ChainRefusal>>>{};
    final newest = <String, int>{};
    for (final r in _db.select(
        'SELECT p.event_id, e.body, e.device_ts FROM events e JOIN pulled_event p ON p.ulid = e.ulid '
        'WHERE e.device_id <> ?',
        [deviceId])) {
      final day = r['event_id'] as String;
      final text = r['body'] as String;
      final wire = jsonDecode(text) as Map;
      ((events[day] ??= {})[wire['device_id'] as String] ??= []).add((text, wire));
      final ts = r['device_ts'] as int;
      if (ts > (newest[day] ?? ts - 1)) newest[day] = ts;
    }
    for (final r in _db.select(
        'SELECT event_id, device_id, seq, event_hash, reason FROM pulled_refusal WHERE device_id <> ?', [deviceId])) {
      final day = r['event_id'] as String;
      ((refusals[day] ??= {})[r['device_id'] as String] ??= []).add(refusalOf(r));
    }
    final days = {...events.keys, ...refusals.keys}.toList()
      ..sort((a, b) {
        // A race day held only as refusals has no time of its own, so it goes last.
        final byNewest = (newest[b] ?? -1).compareTo(newest[a] ?? -1);
        return byNewest != 0 ? byNewest : a.compareTo(b);
      });
    return ChainStatus(
      ownBreak: ownVerdict.state == ChainState.broken
          ? breakOf(ownVerdict, {for (final w in own.values) w['ulid'] as String: w})
          : null,
      devices: [
        for (final day in days)
          for (final device in ({...?events[day]?.keys, ...?refusals[day]?.keys}.toList()..sort()))
            classifyDeviceChain(
              eventId: day,
              raceDayName: raceDayName(day),
              deviceId: device,
              events: events[day]?[device] ?? const [],
              refusals: refusals[day]?[device] ?? const [],
            ),
      ],
    );
  }

  String _store(EventEnvelope e) {
    final wire = e.toWire();
    requireWireSafe(wire, 'event');
    final text = canonicalJson(wire);
    _insert.execute([e.ulid, e.deviceId, e.seq, e.deviceTs, text]);
    return text;
  }

  /// Every event, ordered by device time, then device id, then ULID (ADR
  /// 001), so every read and every phone agrees on the order.
  List<EventEnvelope> readAll() => _all
      .select()
      .map((r) => EventEnvelope.fromWire(jsonDecode(r['body'] as String) as Map))
      .toList();

  /// This device's own events, in the same order as [readAll]: what every
  /// screen reads, so another phone's pulled events (#64) change none of them.
  List<EventEnvelope> readOwn() => _own
      .select([deviceId])
      .map((r) => EventEnvelope.fromWire(jsonDecode(r['body'] as String) as Map))
      .toList();

  int count() => _count.select().first['n'] as int;

  /// Every event's canonical text as stored, by device and then sequence
  /// number: what [verifyChains] takes.
  List<String> readCanonical() => [for (final r in _canonical.select()) r['body'] as String];

  /// The raw connection, for tests that attempt what the core never does.
  sql.Database get debugDatabase => _db;

  void close() {
    _insert.close();
    _count.close();
    _all.close();
    _own.close();
    _canonical.close();
    _db.close();
  }
}
