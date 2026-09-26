import 'dart:convert';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart' as sql;

import 'chain.dart';
import 'envelope.dart';
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
  /// (#28) and stamped with the admission the phone holds (#49), and returns
  /// it as stored. When this returns, it is committed.
  EventEnvelope append(NewEvent event) {
    validateNewEvent(event);
    final now = _clock();
    final envelope = EventEnvelope(
      ulid: newUlid(now, _random),
      deviceTs: now,
      deviceId: deviceId,
      seq: _nextSeq,
      person: event.person,
      role: event.role,
      admissionId: _admissionId,
      gps: event.gps,
      source: event.source,
      kind: event.kind,
      payloadVersion: event.payloadVersion,
      correctsUlid: event.correctsUlid,
      prevHash: _prevHash,
      payload: event.payload,
    );
    final text = _store(envelope);
    _nextSeq++;
    _prevHash = chainHash(text);
    return envelope;
  }

  /// Stores an event exactly as given - one of this device's, or one written
  /// by another phone and arriving through sync (#6). Never replaces one.
  void insert(EventEnvelope e) => _store(e);

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
