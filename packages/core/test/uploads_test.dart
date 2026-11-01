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
      store.recordRevoked(admissionA);
      store.recordRaceDayName(dayOne, 'Fall Series Day 2');
    });

    // Each table, a row it holds, and a statement that would replace that row.
    final tables = {
      'upload_admission': ("SET event_id = '$dayTwo'", "INSERT OR REPLACE INTO upload_admission VALUES ('$admissionA', '$dayTwo')"),
      'upload_attempt': ('SET at = 0', 'INSERT OR REPLACE INTO upload_attempt SELECT ulid, n, 0 FROM upload_attempt'),
      'upload_attempt_void': ('SET n = 9', 'INSERT OR REPLACE INTO upload_attempt_void SELECT ulid, n FROM upload_attempt_void'),
      // A value every CHECK allows, so only the trigger can refuse it.
      'upload_outcome': ('SET at = 0',
          "INSERT OR REPLACE INTO upload_outcome SELECT ulid, 'refused', 'x', NULL, 0, 0 FROM upload_outcome"),
      'upload_revocation': ('SET at = 0',
          "INSERT OR REPLACE INTO upload_revocation VALUES ('$admissionA', '$dayTwo', 0)"),
      'race_day_name': ("SET name = 'x'", "INSERT OR REPLACE INTO race_day_name VALUES ('$dayOne', 'x')"),
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
      // A kind that joins no race, so no clock offset (#55) is appended before it.
      final a = store.append(const NewEvent(kind: 'note', source: 'tap', payload: {'z': 12.0, 'a': 0.1}));
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
      expect(store.uploadStatus().refused, [RefusedUpload(ulid: u, reason: 'revoked', mayBeOnShore: true, kind: 'note')]);
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
      expect(status.refused, [RefusedUpload(ulid: b.ulid, reason: 'inconsistent_canonical', mayBeOnShore: false, kind: 'note')]);
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
      expect(status.refused, [RefusedUpload(ulid: u, reason: 'revoked', mayBeOnShore: true, kind: 'note')]);
      expect(status.lastRun, const UploadRun(state: UploadRunState.noSession, at: 42));
      expect(status.waitingByKind, {'note': 1}, reason: '#66: the map crosses too');
    });

    test('#66: counts what waits by kind, only what will still be sent, adding up to pending', () {
      final store = openStore(tempDbPath());
      store.append(const NewEvent(kind: 'role.assigned', source: 'tap', payload: {'role': 'pro'})); // never admitted
      store.setAdmissionId(admissionA);
      final held = store.append(note).ulid;
      store.append(note);
      store.setAdmissionId(admissionB);
      final accepted = store.append(note).ulid;
      store.append(const NewEvent(kind: 'station.selected', source: 'tap', payload: {'mark': 'mark_1'}));
      store.append(note);
      final refused = store.append(note).ulid;
      store.recordAccepted(accepted, 'a' * 64);
      store.recordRefused(refused, 'ulid_conflict', mayBeOnShore: false);
      store.recordAdmissionEvent(admissionA, dayOne);
      store.recordRefused(held, 'revoked', mayBeOnShore: false);
      store.recordRevoked(admissionA);

      final status = store.uploadStatus();
      // Held: the note under A, and the role-change marker the change to B appended under A (#71).
      expect([status.pending, status.neverAdmitted, status.held], [2, 1, 2], reason: 'control: the counts as #6, #53 and #71 left them');
      expect(status.waitingByKind, {'note': 1, 'station.selected': 1});
      expect(status.waitingByKind.values.fold(0, (a, b) => a + b), status.pending);
    });

    test('#66 criterion 1: 10 events, 6 of them acknowledged, leave 4 waiting, at the last acceptance', () {
      var now = 1000;
      final store = openStore(tempDbPath(), clock: () => now);
      store.setAdmissionId(admissionA);
      final ulids = [for (var i = 0; i < 10; i++) store.append(note).ulid];
      for (final u in ulids.take(6)) {
        now += 1000;
        store.recordAccepted(u, 'a' * 64);
      }
      final status = store.uploadStatus();
      expect([status.pending, status.accepted, status.refused.length], [4, 6, 0]);
      expect(status.waitingByKind, {'note': 4});
      expect(status.lastAcceptedAt, 7000);
    });

    test('#66: an event whose stored body names no kind waits, and is refused, under no kind', () {
      final store = openStore(tempDbPath());
      store.setAdmissionId(admissionA);
      store.append(note);
      // A corrupt write, as sync_test plants one: an admission, but no kind.
      String plant(int seq) {
        final ulid = '01J8${'$seq'.padLeft(22, '0')}';
        store.debugDatabase.execute('INSERT INTO events (ulid, device_id, seq, device_ts, body) VALUES (?, ?, ?, ?, ?)',
            [ulid, store.deviceId, seq, 1, '{"admission_id":"$admissionA","ulid":"$ulid"}']);
        return ulid;
      }

      plant(100);
      final refused = plant(101);
      store.recordRefused(refused, 'inconsistent_canonical', mayBeOnShore: false);
      final status = store.uploadStatus();
      expect(status.waitingByKind, {'note': 1, UploadStatus.noKind: 1});
      expect(status.refused, [RefusedUpload(ulid: refused, reason: 'inconsistent_canonical', mayBeOnShore: false)]);
    });

    test('#66: the last successful upload is the latest accepted answer, never a refusal', () {
      var now = 1000;
      final store = openStore(tempDbPath(), clock: () => now);
      store.setAdmissionId(admissionA);
      final a = store.append(note).ulid;
      final b = store.append(note).ulid;
      final c = store.append(note).ulid;
      expect(store.uploadStatus().lastAcceptedAt, isNull, reason: 'nothing accepted yet');

      // Accepted out of sequence order, so the latest answer is not the highest seq.
      now = 5000;
      store.recordAccepted(b, 'b' * 64);
      now = 7000;
      store.recordAccepted(a, 'a' * 64);
      now = 9000;
      store.recordRefused(c, 'ulid_conflict', mayBeOnShore: false);
      expect(store.uploadStatus().lastAcceptedAt, 7000, reason: 'a later refusal is not an upload');
    });

    test('the fake core answers what the test set, through the same wire form', () async {
      final fake = FakeCore()
        ..uploadStatusValue = const UploadStatus(
          pending: 3,
          accepted: 2,
          neverAdmitted: 1,
          refused: [RefusedUpload(ulid: 'U', reason: 'revoked', mayBeOnShore: false, kind: 'finish')],
          lastRun: UploadRun(state: UploadRunState.unreachable, at: 7),
          lastAcceptedAt: 6,
          waitingByKind: {'finish': 2, 'start': 1},
        );
      final status = await fake.uploadStatus();
      expect(status.toWire(), fake.uploadStatusValue.toWire());
      expect(fake.calls['uploadStatus'], 1);
    });
  });

  group('#53: a revoked admission', () {
    test('its events are held, not pending; the rest are counted as before', () {
      final store = openStore(tempDbPath());
      store.setAdmissionId(admissionA);
      final refused = store.append(note).ulid;
      store.append(note);
      store.append(note);
      store.setAdmissionId(admissionB);
      store.append(note);
      store.recordAdmissionEvent(admissionA, dayOne);
      store.recordRefused(refused, 'revoked', mayBeOnShore: false);
      // Two notes under A, the role-change marker the change to B appended under A (#71), and B's note.
      expect([store.uploadStatus().pending, store.uploadStatus().held], [4, 0], reason: 'control: not yet revoked');

      store.recordRevoked(admissionA);
      final status = store.uploadStatus();
      expect([status.pending, status.held, status.refused.length], [1, 3, 1]);
      expect(store.pendingUploads().length, 4, reason: 'held events still have no outcome: nothing is invented');
    });

    test('an event whose earlier send may have landed waits rather than being held, since it goes once '
        'more for its flagged refusal', () {
      final store = openStore(tempDbPath());
      store.setAdmissionId(admissionA);
      final unknown = store.append(note).ulid;
      final voided = store.append(note).ulid;
      final never = store.append(note).ulid;
      store.recordAdmissionEvent(admissionA, dayOne);
      store.beginAttempt(unknown); // sent, never answered
      store.voidAttempt(voided, store.beginAttempt(voided).n); // sent, proved to have stored nothing
      expect(store.unansweredSends(), {unknown});
      expect(never, isNotEmpty);

      store.recordRevoked(admissionA);
      expect([store.uploadStatus().pending, store.uploadStatus().held], [1, 2]);
      store.recordRefused(unknown, 'revoked', mayBeOnShore: true);
      expect(store.unansweredSends(), isEmpty, reason: 'answered now');
      expect([store.uploadStatus().pending, store.uploadStatus().held], [0, 2]);
    });

    test('is recorded once, against the race day sync learned for it, and never for an unknown one', () {
      var now = 1000;
      final store = openStore(tempDbPath(), clock: () => now);
      expect(() => store.recordRevoked(admissionA), throwsStateError);
      store.recordAdmissionEvent(admissionA, dayOne);
      store.recordRevoked(admissionA);
      now = 2000;
      store.recordRevoked(admissionA);
      expect(store.revokedAdmissions(), {admissionA});
      expect(store.debugDatabase.select('SELECT event_id, at FROM upload_revocation').map((r) => [r['event_id'], r['at']]),
          [
            [dayOne, 1000]
          ],
          reason: 'the second is a no-op: the first time sync learned it stays');
    });

    test('revocation() answers for the admission the taps go under, with the race day\'s name when '
        'sync read it', () {
      final store = openStore(tempDbPath(), clock: () => 7000);
      expect(store.revocation(), isNull, reason: 'never admitted');
      store.setAdmissionId(admissionA);
      store.recordAdmissionEvent(admissionA, dayOne);
      expect(store.revocation(), isNull, reason: 'admitted, standing');

      store.recordRevoked(admissionA);
      expect(store.revocation(), const Revocation(eventId: dayOne, at: 7000), reason: 'no name was read');
      expect(store.recordRaceDayName(dayOne, 'Fall Series Day 2'), isTrue);
      expect(store.recordRaceDayName(dayOne, 'Renamed'), isFalse, reason: 'the first name read stays');
      expect(store.revocation(), const Revocation(eventId: dayOne, eventName: 'Fall Series Day 2', at: 7000));

      store.setAdmissionId(admissionB);
      expect(store.revocation(), isNull, reason: 'the phone moved on: its taps go under an admission that stands');
      expect(() => store.recordRaceDayName('not-a-uuid', 'x'), throwsArgumentError);
    });

    test('crosses the core boundary as plain data, from the store a real core serves', () async {
      final path = tempDbPath();
      final store = EventStore.open(path);
      store.setAdmissionId(admissionA);
      store.recordAdmissionEvent(admissionA, dayOne);
      store.recordRaceDayName(dayOne, 'Fall Series Day 2');
      store.append(note);
      store.recordRevoked(admissionA);
      final at = store.revocation()!.at;
      store.close();

      final core = await spawnCore(path);
      addTearDown(core.close);
      expect(await core.revocation(), Revocation(eventId: dayOne, eventName: 'Fall Series Day 2', at: at));
      expect((await core.uploadStatus()).held, 1);
    });

    test('the fake core answers what the test set, through the same wire form, and null by default',
        () async {
      final fake = FakeCore();
      expect(await fake.revocation(), isNull);
      fake.revocationValue = const Revocation(eventId: dayOne, eventName: 'Fall Series Day 2', at: 5);
      expect(await fake.revocation(), fake.revocationValue);
      expect(fake.calls['revocation'], 2);
    });
  });
}
