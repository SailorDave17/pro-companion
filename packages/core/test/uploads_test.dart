import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

import 'support.dart';

/// #6: what sync keeps beside the log about each of this phone's events on its way to shore, and
/// how the UI reads it. The events table refuses UPDATE, so these are tables of their own, and
/// append-only the same way: an event's outcome is a fact that never changes.
const admissionA = '3f6c1a52-8d0e-4b7a-9c21-5e4f0a9b7d13';
const admissionB = '8a1d2c3b-4e5f-4a6b-8c7d-9e0f1a2b3c4d';
const dayOne = 'b3c7e9a1-2d4f-4b6a-8c0e-1f2a3b4c5d6e';
const dayTwo = 'c4d8f0b2-3e5a-4c7b-9d1f-2a3b4c5d6e7f';
const note = NewEvent(kind: 'note', source: 'tap', payload: {'text': 'Mark 2 hold'});

void main() {
  group('the upload tables are append-only for every code path', () {
    late EventStore store;
    late String ulid;

    setUp(() {
      store = openStore(tempDbPath());
      store.setAdmissionId(admissionA);
      ulid = store.append(note).ulid;
      store.recordAdmissionEvent(admissionA, dayOne);
      final attempt = store.beginAttempt(ulid);
      store.voidAttempt(ulid, attempt.n);
      store.recordAccepted(ulid, chainHash(store.readCanonical().single));
    });

    // Each table, a row it holds, and a statement that would replace that row.
    final tables = {
      'upload_admission': ("SET event_id = '$dayTwo'", "INSERT OR REPLACE INTO upload_admission VALUES ('$admissionA', '$dayTwo')"),
      'upload_attempt': ('SET at = 0', 'INSERT OR REPLACE INTO upload_attempt SELECT ulid, n, 0 FROM upload_attempt'),
      'upload_attempt_void': ('SET n = 9', 'INSERT OR REPLACE INTO upload_attempt_void SELECT ulid, n FROM upload_attempt_void'),
      // A value every CHECK allows, so only the trigger can refuse it.
      'upload_outcome': ('SET at = 0',
          "INSERT OR REPLACE INTO upload_outcome SELECT ulid, 'refused', 'x', NULL, 0, 0 FROM upload_outcome"),
    };

    // Matched on the trigger's own words: a statement some other constraint refuses would pass a
    // bare "throws", and prove nothing about the trigger (the #6 review found one that did).
    Matcher refusedBy(String table, String what) =>
        throwsA(isA<sql.SqliteException>().having((e) => e.message, 'message', contains('$table is append-only: $what')));

    for (final MapEntry(key: table, value: (set, replace)) in tables.entries) {
      test('$table refuses UPDATE, DELETE and a replacing INSERT', () {
        final db = store.debugDatabase;
        final before = db.select('SELECT * FROM $table').toString();
        expect(before, isNot('[]'), reason: 'the fixture wrote a row to $table');
        expect(() => db.execute('UPDATE $table $set'), refusedBy(table, 'UPDATE refused'));
        expect(() => db.execute('DELETE FROM $table'), refusedBy(table, 'DELETE refused'));
        expect(() => db.execute(replace), refusedBy(table, 'an existing row cannot be replaced'));
        expect(db.select('SELECT * FROM $table').toString(), before);
      });
    }
  });

  group('pendingUploads', () {
    test("lists this device's events with no outcome, by sequence number, each body exactly as stored", () {
      final store = openStore(tempDbPath());
      final before = store.append(note); // written before any admission
      store.setAdmissionId(admissionA);
      final a = store.append(const NewEvent(kind: 'finish', source: 'tap', payload: {'z': 12.0, 'a': 0.1}));
      final b = store.append(note);
      // Another phone's event, pulled down (#64): never this phone's to upload.
      final otherPhone = '01J8${'Z'.padLeft(22, '0')}';
      store.insert(EventEnvelope(
        ulid: '01J8${'1'.padLeft(22, '0')}',
        deviceTs: 1,
        deviceId: otherPhone,
        seq: 1,
        source: 'tap',
        kind: 'note',
        payloadVersion: 1,
        payload: const {},
      ));

      final pending = store.pendingUploads();
      expect([for (final p in pending) p.ulid], [before.ulid, a.ulid, b.ulid]);
      expect([for (final p in pending) p.seq], [1, 2, 3]);
      expect([for (final p in pending) p.admissionId], [null, admissionA, admissionA]);
      final own = store.readCanonical().where((t) => !t.contains('"device_id":"$otherPhone"')).toList();
      expect(own, hasLength(3), reason: 'the other phone\'s event is the one left out');
      expect([for (final p in pending) p.canonical], own, reason: 'the stored text, not a re-serialisation');
      expect(pending[1].canonical, contains('"payload":{"a":0.1,"z":12}'));

      store.recordAccepted(a.ulid, chainHash(pending[1].canonical));
      store.recordRefused(b.ulid, 'revoked', mayBeOnShore: false);
      expect([for (final p in store.pendingUploads()) p.ulid], [before.ulid]);
    });
  });

  group('the admission to race day map', () {
    test('an admission names one race day for good', () {
      final store = openStore(tempDbPath());
      expect(store.admissionEvent(admissionA), isNull);
      store.recordAdmissionEvent(admissionA, dayOne);
      store.recordAdmissionEvent(admissionA, dayOne); // again: a no-op, not an error
      store.recordAdmissionEvent(admissionB, dayTwo);
      expect(store.admissionEvent(admissionA), dayOne);
      expect(store.admissionEvent(admissionB), dayTwo);
      expect(() => store.recordAdmissionEvent(admissionA, dayTwo), throwsStateError);
      expect(store.admissionEvent(admissionA), dayOne);
      expect(() => store.recordAdmissionEvent('A1', dayOne), throwsArgumentError);
      expect(() => store.recordAdmissionEvent(admissionA, 'day one'), throwsArgumentError);
    });
  });

  group('attempts', () {
    test('an earlier send is unknown until it is answered or proved to have stored nothing, across a restart',
        () {
      final path = tempDbPath();
      var store = EventStore.open(path);
      store.setAdmissionId(admissionA);
      final u = store.append(note).ulid;

      expect(store.beginAttempt(u), (n: 1, earlierUnknown: false));
      // The process dies with send 1 in flight, and comes back.
      store.close();
      store = openStore(path);
      expect(store.beginAttempt(u), (n: 2, earlierUnknown: true), reason: 'send 1 may have landed');
      store.voidAttempt(u, 2);
      store.voidAttempt(u, 2); // again: a no-op
      expect(store.beginAttempt(u), (n: 3, earlierUnknown: true), reason: 'send 1 is still unknown');

      final v = store.append(note).ulid;
      expect(store.beginAttempt(v), (n: 1, earlierUnknown: false));
      store.voidAttempt(v, 1);
      expect(store.beginAttempt(v), (n: 2, earlierUnknown: false), reason: 'send 1 proved to store nothing');
      expect(() => store.voidAttempt(v, 7), throwsStateError);
    });
  });

  group('outcomes', () {
    late EventStore store;
    late String u;

    setUp(() {
      store = openStore(tempDbPath());
      store.setAdmissionId(admissionA);
      u = store.append(note).ulid;
    });

    test('one final outcome per event: the same one again is a no-op, another is refused', () {
      store.recordRefused(u, 'revoked', mayBeOnShore: true);
      store.recordRefused(u, 'revoked', mayBeOnShore: true);
      expect(() => store.recordAccepted(u, 'a' * 64), throwsStateError);
      expect(() => store.recordRefused(u, 'ulid_conflict', mayBeOnShore: true), throwsStateError);
      expect(store.uploadStatus().refused, [RefusedUpload(ulid: u, reason: 'revoked', mayBeOnShore: true)]);
    });

    test("an outcome is kept only for this device's own events", () {
      expect(() => store.recordAccepted('01J8${'9'.padLeft(22, '0')}', 'a' * 64), throwsArgumentError);
      expect(() => store.beginAttempt('01J8${'9'.padLeft(22, '0')}'), throwsArgumentError);
      expect(() => store.recordRefused(u, '', mayBeOnShore: false), throwsArgumentError);
    });

    test("another phone's event, stored here, takes no attempt and no outcome", () {
      // Pulled down (#64): in this store, and still not this phone's to upload.
      final theirs = '01J8${'1'.padLeft(22, '0')}';
      store.insert(EventEnvelope(
        ulid: theirs,
        deviceTs: 1,
        deviceId: '01J8${'Z'.padLeft(22, '0')}',
        seq: 1,
        source: 'tap',
        kind: 'note',
        payloadVersion: 1,
        payload: const {},
      ));
      expect(store.readCanonical(), hasLength(2), reason: "control: the other phone's event is stored");
      expect(() => store.beginAttempt(theirs), throwsArgumentError);
      expect(() => store.recordAccepted(theirs, 'a' * 64), throwsArgumentError);
      expect(() => store.recordRefused(theirs, 'revoked', mayBeOnShore: false), throwsArgumentError);
      expect(store.debugDatabase.select('SELECT * FROM upload_attempt WHERE ulid = ?', [theirs]), isEmpty);
    });
  });

  group('uploadStatus', () {
    test('counts what waits, what landed and what was never admitted, and lists refusals and the last run', () {
      final store = openStore(tempDbPath(), clock: steppingClock([1000, 2000, 3000, 4000, 5000, 6000, 7000]));
      store.append(note); // never admitted
      store.setAdmissionId(admissionA);
      final a = store.append(note);
      final b = store.append(note);
      store.append(note);
      store.recordAccepted(a.ulid, 'a' * 64);
      store.recordRefused(b.ulid, 'inconsistent_canonical', mayBeOnShore: false);
      expect(store.uploadStatus().lastRun, isNull);

      store.recordUploadRun(const UploadRun(state: UploadRunState.unreachable, at: 5, error: 'offline'));
      store.recordUploadRun(const UploadRun(state: UploadRunState.notAdmitted, at: 9, paused: 1));
      final status = store.uploadStatus();
      expect(status.pending, 1);
      expect(status.accepted, 1);
      expect(status.neverAdmitted, 1);
      expect(status.refused, [RefusedUpload(ulid: b.ulid, reason: 'inconsistent_canonical', mayBeOnShore: false)]);
      expect(status.lastRun, const UploadRun(state: UploadRunState.notAdmitted, at: 9, paused: 1),
          reason: 'the latest run replaces the one before');
      expect(() => store.recordUploadRun(const UploadRun(state: 'asleep', at: 1)), throwsArgumentError);
    });

    test('crosses the core boundary as plain data, from the store a real core serves', () async {
      final path = tempDbPath();
      final store = EventStore.open(path);
      store.setAdmissionId(admissionA);
      final u = store.append(note).ulid;
      store.append(note);
      store.recordRefused(u, 'revoked', mayBeOnShore: true);
      store.recordUploadRun(const UploadRun(state: UploadRunState.noSession, at: 42, paused: 0));
      store.close();

      final core = await spawnCore(path);
      addTearDown(core.close);
      final status = await core.uploadStatus();
      expect(status.pending, 1);
      expect(status.refused, [RefusedUpload(ulid: u, reason: 'revoked', mayBeOnShore: true)]);
      expect(status.lastRun, const UploadRun(state: UploadRunState.noSession, at: 42));
    });

    test('the fake core answers what the test set, through the same wire form', () async {
      final fake = FakeCore()
        ..uploadStatusValue = const UploadStatus(
          pending: 3,
          accepted: 2,
          neverAdmitted: 1,
          refused: [RefusedUpload(ulid: 'U', reason: 'revoked', mayBeOnShore: false)],
          lastRun: UploadRun(state: UploadRunState.unreachable, at: 7),
        );
      final status = await fake.uploadStatus();
      expect(status.toWire(), fake.uploadStatusValue.toWire());
      expect(fake.calls['uploadStatus'], 1);
    });
  });
}
