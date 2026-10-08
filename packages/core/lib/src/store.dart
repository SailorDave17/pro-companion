import 'dart:convert';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart' as sql;

import 'chain.dart';
import 'envelope.dart';
import 'roles.dart';
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
      this._admissionId) {
    _insert = _db.prepare(
      'INSERT INTO events (ulid, device_id, seq, device_ts, body) VALUES (?, ?, ?, ?, ?)',
    );
    _count = _db.prepare('SELECT count(*) AS n FROM events');
    _all = _db.prepare('SELECT body FROM events ORDER BY device_ts, device_id, ulid');
    _canonical = _db.prepare('SELECT body FROM events ORDER BY device_id, seq');
    // The canonical text has no spaces (RFC 8785), so every role and station
    // event's body holds one of these, and LIKE narrows the read to them
    // before the kind is checked.
    for (final r in _db.select('SELECT body FROM events WHERE device_id = ? AND (body LIKE ? OR body LIKE ?)',
        [deviceId, '%"kind":"role.%', '%"kind":"station.%'])) {
      _noteStateEvent(EventEnvelope.fromWire(jsonDecode(r['body'] as String) as Map));
    }
  }

  /// Opens (creating if needed) the log at [path]. The device id is minted on
  /// first open and kept in the file, so it is stable for the install.
  factory EventStore.open(String path, {int Function()? clock, Random? random}) {
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
      return last.isEmpty
          ? EventStore._(db, deviceId, now, rng, 1, genesisHash, admissionId)
          : EventStore._(db, deviceId, now, rng, (last.first['seq'] as int) + 1,
              chainHash(last.first['body'] as String), admissionId);
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
  late final sql.PreparedStatement _canonical;

  /// This install's device id. Every event it appends carries it.
  final String deviceId;

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
    for (final (table, key) in const [
      ('upload_admission', 'admission_id = NEW.admission_id'),
      ('upload_attempt', 'ulid = NEW.ulid AND n = NEW.n'),
      ('upload_attempt_void', 'ulid = NEW.ulid AND n = NEW.n'),
      ('upload_outcome', 'ulid = NEW.ulid'),
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
  /// (#28), stamped with the admission the phone holds (#49), unless it names
  /// a role of its own with the role the phone runs as (#20), and unless it
  /// names a mark of its own with the station the phone is at (#26), and
  /// returns it as stored. When this returns, it is committed.
  EventEnvelope append(NewEvent event) {
    validateNewEvent(event);
    final now = _clock();
    final envelope = EventEnvelope(
      ulid: newUlid(now, _random),
      deviceTs: now,
      deviceId: deviceId,
      seq: _nextSeq,
      person: event.person,
      role: event.role ?? role,
      admissionId: _admissionId,
      gps: event.gps,
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
    return envelope;
  }

  /// Stores an event exactly as given - one of this device's, or one written
  /// by another phone and pulled down to this one (#64). Never replaces one.
  void insert(EventEnvelope e) {
    _store(e);
    _noteStateEvent(e);
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

  /// Where this device's own events stand on their way to shore.
  UploadStatus uploadStatus() {
    var pending = 0;
    var neverAdmitted = 0;
    for (final p in pendingUploads()) {
      p.admissionId == null ? neverAdmitted++ : pending++;
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
      lastRun: run.isEmpty ? null : UploadRun.fromWire(jsonDecode(run.first['value'] as String) as Map),
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
    _canonical.close();
    _db.close();
  }
}
