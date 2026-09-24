import 'dart:io';

import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;
import 'package:sembast/sembast_io.dart' as sb;
import 'package:sqlite3/sqlite3.dart' as sql;

import 'envelope.dart';

/// What happened when a stored event was UPDATEd or DELETEd (#13 criterion 3).
class MutationOutcome {
  const MutationOutcome({required this.refusedNatively, required this.detail});

  /// True when the engine itself refused. False means the core must guard.
  final bool refusedNatively;
  final String detail;

  Map<String, Object?> toJson() => {'refused_natively': refusedNatively, 'detail': detail};
}

/// The narrow surface the benchmark drives. Not the local core's interface.
abstract class EventStore {
  String get name;
  Future<void> open(String dir);
  Future<void> append(Envelope e);
  Future<Envelope?> readBack(String ulid);
  Future<int> count();
  Future<List<Envelope>> all();
  Future<MutationOutcome> tryUpdate(String ulid);
  Future<MutationOutcome> tryDelete(String ulid);
  Future<void> close();
}

/// SQLite through FFI (package:sqlite3). WAL with synchronous=FULL, so a
/// committed append survives a crash of the process and of the OS. Triggers
/// make the table append-only at the engine.
class SqliteStore implements EventStore {
  late sql.Database _db;
  late sql.PreparedStatement _insert;
  late sql.PreparedStatement _byUlid;

  @override
  String get name => 'sqlite3';

  @override
  Future<void> open(String dir) async {
    _db = sql.sqlite3.open(p.join(dir, 'events.db'));
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA synchronous=FULL');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS events (
        ulid TEXT PRIMARY KEY NOT NULL,
        device_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        body TEXT NOT NULL,
        UNIQUE (device_id, seq)
      ) STRICT''');
    _db.execute('''
      CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events
      BEGIN SELECT RAISE(ABORT, 'events is append-only'); END''');
    _db.execute('''
      CREATE TRIGGER IF NOT EXISTS events_no_delete BEFORE DELETE ON events
      BEGIN SELECT RAISE(ABORT, 'events is append-only'); END''');
    _insert = _db.prepare('INSERT INTO events (ulid, device_id, seq, body) VALUES (?, ?, ?, ?)');
    _byUlid = _db.prepare('SELECT body FROM events WHERE ulid = ?');
  }

  @override
  Future<void> append(Envelope e) async =>
      _insert.execute([e.ulid, e.deviceId, e.seq, e.encode()]);

  @override
  Future<Envelope?> readBack(String ulid) async {
    final rows = _byUlid.select([ulid]);
    return rows.isEmpty ? null : Envelope.decode(rows.first['body'] as String);
  }

  @override
  Future<int> count() async => _db.select('SELECT count(*) AS n FROM events').first['n'] as int;

  @override
  Future<List<Envelope>> all() async => _db
      .select('SELECT body FROM events ORDER BY device_id, seq')
      .map((r) => Envelope.decode(r['body'] as String))
      .toList();

  @override
  Future<MutationOutcome> tryUpdate(String ulid) async =>
      _refused(() => _db.execute("UPDATE events SET body = '{}' WHERE ulid = ?", [ulid]));

  @override
  Future<MutationOutcome> tryDelete(String ulid) async =>
      _refused(() => _db.execute('DELETE FROM events WHERE ulid = ?', [ulid]));

  MutationOutcome _refused(void Function() op) {
    try {
      op();
      return const MutationOutcome(refusedNatively: false, detail: 'statement succeeded');
    } on sql.SqliteException catch (e) {
      return MutationOutcome(refusedNatively: true, detail: 'SqliteException: ${e.message}');
    }
  }

  @override
  Future<void> close() async {
    _insert.close();
    _byUlid.close();
    _db.close();
  }
}

/// sembast: a pure-Dart document store over an append-log file.
class SembastStore implements EventStore {
  late sb.Database _db;
  final _events = sb.stringMapStoreFactory.store('events');

  @override
  String get name => 'sembast';

  @override
  Future<void> open(String dir) async {
    _db = await sb.databaseFactoryIo.openDatabase(p.join(dir, 'events.sembast'));
  }

  @override
  Future<void> append(Envelope e) async {
    final key = await _events.record(e.ulid).add(_db, e.toJson());
    if (key == null) throw StateError('duplicate ulid ${e.ulid}');
  }

  @override
  Future<Envelope?> readBack(String ulid) async {
    final v = await _events.record(ulid).get(_db);
    return v == null ? null : Envelope.fromJson(Map<String, Object?>.from(v));
  }

  @override
  Future<int> count() => _events.count(_db);

  @override
  Future<List<Envelope>> all() async => (await _events.find(_db))
      .map((r) => Envelope.fromJson(Map<String, Object?>.from(r.value)))
      .toList();

  @override
  Future<MutationOutcome> tryUpdate(String ulid) async {
    final updated = await _events.record(ulid).update(_db, {'payload': <String, Object?>{}});
    return MutationOutcome(
        refusedNatively: false,
        detail: updated == null ? 'record absent' : 'update succeeded; no engine-level refusal exists');
  }

  @override
  Future<MutationOutcome> tryDelete(String ulid) async {
    final deleted = await _events.record(ulid).delete(_db);
    return MutationOutcome(
        refusedNatively: false,
        detail: deleted == null ? 'record absent' : 'delete succeeded; no engine-level refusal exists');
  }

  @override
  Future<void> close() => _db.close();
}

/// hive_ce: a pure-Dart key-value box over an append-log file.
class HiveStore implements EventStore {
  late Box<String> _box;

  @override
  String get name => 'hive_ce';

  @override
  Future<void> open(String dir) async {
    Hive.init(dir);
    _box = await Hive.openBox<String>('events');
  }

  @override
  Future<void> append(Envelope e) async {
    if (_box.containsKey(e.ulid)) throw StateError('duplicate ulid ${e.ulid}');
    await _box.put(e.ulid, e.encode());
  }

  @override
  Future<Envelope?> readBack(String ulid) async {
    final v = _box.get(ulid);
    return v == null ? null : Envelope.decode(v);
  }

  @override
  Future<int> count() async => _box.length;

  @override
  Future<List<Envelope>> all() async => _box.values.map(Envelope.decode).toList();

  @override
  Future<MutationOutcome> tryUpdate(String ulid) async {
    await _box.put(ulid, '{}');
    return const MutationOutcome(
        refusedNatively: false, detail: 'put over an existing key succeeded; no engine-level refusal exists');
  }

  @override
  Future<MutationOutcome> tryDelete(String ulid) async {
    await _box.delete(ulid);
    return const MutationOutcome(
        refusedNatively: false, detail: 'delete succeeded; no engine-level refusal exists');
  }

  @override
  Future<void> close() async {
    await _box.close();
    await Hive.close();
  }
}

List<EventStore> candidates() => [SqliteStore(), SembastStore(), HiveStore()];

EventStore storeNamed(String name) => candidates().firstWhere((s) => s.name == name);

/// A fresh, empty directory for one store.
Future<String> freshDir(String root, String name) async {
  final d = Directory(p.join(root, name));
  if (await d.exists()) await d.delete(recursive: true);
  await d.create(recursive: true);
  return d.path;
}
