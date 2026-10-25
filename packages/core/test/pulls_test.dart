import 'dart:convert';

import 'package:pro_companion_core/core.dart' show RoleEvents, Roles;
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

import 'support.dart';

/// #64, the store's half: other committee phones' events pulled down to this one, kept byte for
/// byte, never in this device's own chain, each race day with a cursor of its own worked out from
/// what is stored, and refusal stubs counted as seen. The sync engine's half, the pull itself, is
/// packages/sync/test/pull_test.dart.
const dayOne = 'b3c7e9a1-2d4f-4b6a-8c0e-1f2a3b4c5d6e';
const dayTwo = 'c4d8f0b2-3e5a-4c7b-9d1f-2a3b4c5d6e7f';
const note = NewEvent(kind: 'note', source: 'tap', payload: {'text': 'Mark 2 hold'});

/// A real Crockford ULID ending in [n] (the overlay: '01J8' + n.padLeft(22, '0') is one that
/// works), so ids can be ordered by hand.
String id(String prefix, int n) => '$prefix${'$n'.padLeft(26 - prefix.length, '0')}';

/// An event's canonical text built by hand, for tests where only the keys matter.
String textOf({required String ulid, required String device, required int seq, required int ts}) => canonicalJson(
      EventEnvelope(
        ulid: ulid,
        deviceTs: ts,
        deviceId: device,
        seq: seq,
        source: 'tap',
        kind: 'note',
        payloadVersion: 1,
        payload: const {'text': 'from another phone'},
        prevHash: genesisHash,
      ).toWire(),
    );

/// Another committee phone: a log of its own with [n] notes, and their texts as it stored them,
/// by sequence number from 1.
(EventStore, List<String>) otherPhone(int n, {int seed = 2}) {
  final phone = openStore(tempDbPath(), seed: seed);
  for (var i = 0; i < n; i++) {
    phone.append(NewEvent(kind: 'note', source: 'tap', payload: {'text': 'Mark 2 hold $i'}));
  }
  return (phone, phone.readCanonical());
}

Map decodeText(String text) => jsonDecode(text) as Map;
String ulidOf(String text) => EventEnvelope.fromWire(decodeText(text)).ulid;

void main() {
  group('a pulled event is kept as the server holds it', () {
    test("another phone's event is stored byte for byte, and its chain verifies here as there", () {
      final (other, texts) = otherPhone(3);
      final store = openStore(tempDbPath());
      for (final t in texts) {
        expect(store.insertPulled(dayOne, t), isTrue);
      }
      expect(store.readCanonical(), texts);
      expect(verifyChains(store.readCanonical())[other.deviceId]?.state, ChainState.intact);
      final read = store.readAll();
      expect([for (final e in read) e.deviceId], everyElement(other.deviceId), reason: 'attributed to its device');
    });

    test('text from a core older than #49, with no admission_id, keeps its own bytes and its hash', () {
      // An envelope written before the admission stamp: re-serialised from its fields it would
      // gain "admission_id":null and a new hash (the overlay's note for #6 and #64).
      final old = Map<String, Object?>.from(decodeText(textOf(ulid: id('01J8', 1), device: id('01J9', 1), seq: 1, ts: 1000)))
        ..remove('admission_id');
      final text = canonicalJson(old);
      final store = openStore(tempDbPath());
      expect(store.insertPulled(dayOne, text), isTrue);
      expect(store.readCanonical().single, text);
      expect(chainHash(store.readCanonical().single), chainHash(text));
    });

    test('text that is not an event, or not canonical, is refused and nothing is stored', () {
      final store = openStore(tempDbPath());
      final good = textOf(ulid: id('01J8', 1), device: id('01J9', 1), seq: 1, ts: 1000);
      for (final bad in [
        good.replaceFirst(',', ', '), // the same event, not RFC 8785
        '{"ulid":"${id('01J8', 2)}"}', // not an envelope
        'not json',
        '[1,2]',
        textOf(ulid: 'not-a-ulid', device: id('01J9', 1), seq: 1, ts: 1000),
        textOf(ulid: id('01J8', 3), device: id('01J9', 1), seq: 0, ts: 1000),
      ]) {
        expect(() => store.insertPulled(dayOne, bad), throwsA(isA<PullRefused>()), reason: bad);
      }
      expect(store.count(), 0);
      expect(() => store.insertPulled('day one', good), throwsArgumentError, reason: 'a race day is a UUID');
      expect(store.count(), 0);
    });
  });

  group('criterion 4: no duplicate is stored', () {
    test("this phone's own events echoed back are taken as held, and stored once", () {
      final store = openStore(tempDbPath());
      store.append(note);
      store.append(note);
      final own = store.readCanonical();
      for (final t in own) {
        expect(store.insertPulled(dayOne, t), isFalse, reason: 'already held');
      }
      expect(store.count(), 2);
      expect(store.readCanonical(), own);
    });

    test('an event pulled twice, from one race day or another, is stored once', () {
      final (_, texts) = otherPhone(2);
      final store = openStore(tempDbPath());
      expect(store.insertPulled(dayOne, texts[0]), isTrue);
      expect(store.insertPulled(dayOne, texts[0]), isFalse);
      expect(store.insertPulled(dayTwo, texts[0]), isFalse);
      expect(store.count(), 1);
      expect(store.pullCursors(dayTwo).keys, [store.deviceId], reason: 'it counts on the race day it came from only');
    });

    test('another text under a held ULID, or another event at a held device and seq, is refused', () {
      final (other, texts) = otherPhone(2);
      final store = openStore(tempDbPath());
      store.insertPulled(dayOne, texts[0]);
      Matcher refusedFor(String why) => throwsA(isA<PullRefused>().having((e) => e.message, 'message', contains(why)));
      // At a number nothing holds, so only the ULID check can refuse it (the review of #64: at the
      // held number, the device-and-seq check refused it first, and the ULID check went untested).
      final held = Map<String, Object?>.from(jsonDecode(texts[0]) as Map);
      final sameUlid = canonicalJson({...held, 'seq': 9, 'payload': {'text': 'Mark 3 hold 0'}});
      expect(() => store.insertPulled(dayOne, sameUlid), refusedFor('holds another text under'));
      final sameSeq = textOf(ulid: id('01J8', 9), device: other.deviceId, seq: 1, ts: 1000);
      expect(() => store.insertPulled(dayOne, sameSeq), refusedFor('holds another event at'));
      expect(store.readCanonical(), [texts[0]]);
    });
  });

  group("criterion 6: a pulled event never enters this device's own chain", () {
    test("another phone's events, at the very numbers this phone uses next, leave its chain whole", () {
      final store = openStore(tempDbPath());
      final mine = [store.append(note), store.append(note)];
      final (other, texts) = otherPhone(4);
      for (final t in texts) {
        store.insertPulled(dayOne, t);
      }

      final next = store.append(note);
      expect(next.seq, 3, reason: "this device's own next number, whatever the other phone holds");
      expect(next.prevHash, chainHash(store.readCanonical().where((t) => t.contains(mine[1].ulid)).single));
      final verdicts = verifyChains(store.readCanonical());
      expect(verdicts[store.deviceId]?.state, ChainState.intact);
      expect(verdicts[other.deviceId]?.state, ChainState.intact);
    });

    test('an event naming this phone that it never wrote is refused, and the next tap still lands', () {
      final store = openStore(tempDbPath());
      store.append(note);
      // seq 2 is the number this phone's next tap takes: stored, it would refuse that tap.
      final forged = textOf(ulid: id('01J8', 7), device: store.deviceId, seq: 2, ts: 1000);
      expect(() => store.insertPulled(dayOne, forged), throwsA(isA<PullRefused>()));
      expect(store.count(), 1);
      expect(store.append(note).seq, 2);
      expect(verifyChains(store.readCanonical())[store.deviceId]?.state, ChainState.intact);
    });

    test("a pulled role pick is another phone's, never this phone's role", () {
      final (_, theirs) = (() {
        final phone = openStore(tempDbPath(), seed: 3);
        phone.append(RoleEvents.assign(Roles.recorder));
        return (phone, phone.readCanonical());
      })();
      final store = openStore(tempDbPath());
      store.insertPulled(dayOne, theirs.single);
      expect(store.role, isNull);
      expect(store.append(note).role, isNull);
    });
  });

  group('criterion 3: the union by ULID, ordered by device time, device id, then ULID', () {
    test('ties on device time break on device id, then ULID, whatever order they were pulled in', () {
      // At ts 5000, device order and ULID order disagree: the lower device holds the higher ULIDs.
      // Pulled in an order that agrees with neither, so only the stated keys can produce the result.
      final lowDevice = id('01J91', 1);
      final highDevice = id('01J92', 1);
      final rows = [
        textOf(ulid: id('01J8', 9), device: lowDevice, seq: 2, ts: 5000),
        textOf(ulid: id('01J8', 1), device: highDevice, seq: 1, ts: 5000),
        textOf(ulid: id('01J8', 5), device: lowDevice, seq: 3, ts: 4999),
        textOf(ulid: id('01J8', 8), device: lowDevice, seq: 1, ts: 5000),
        textOf(ulid: id('01J8', 2), device: highDevice, seq: 2, ts: 5000),
      ];
      final store = openStore(tempDbPath(), clock: () => 5000);
      final own = store.append(note); // ts 5000 too, on a device id minted at 5000
      for (final t in rows) {
        store.insertPulled(dayOne, t);
      }
      store.insertPulled(dayOne, rows[1]); // and one pulled twice
      final devices = [lowDevice, highDevice, store.deviceId]..sort();
      final expected = [
        id('01J8', 5), // ts 4999
        for (final d in devices)
          ...switch (d) {
            _ when d == lowDevice => [id('01J8', 8), id('01J8', 9)],
            _ when d == highDevice => [id('01J8', 1), id('01J8', 2)],
            _ => [own.ulid],
          },
      ];
      expect([for (final e in store.readAll()) e.ulid], expected);
      expect(store.count(), 6, reason: 'the union: one row per ULID');
    });
  });

  group("criterion 2: the cursor tracks the highest contiguous sequence seen, per device and race day", () {
    test("a device's sequence 7 stored before its 6: both kept, and the cursor waits for 6", () {
      final (other, texts) = otherPhone(7);
      final store = openStore(tempDbPath());
      for (final t in texts.take(5)) {
        store.insertPulled(dayOne, t);
      }
      expect(store.pullCursors(dayOne)[other.deviceId], const PullCursor(floor: 1, contiguous: 5));
      expect(store.insertPulled(dayOne, texts[6]), isTrue, reason: '7 is kept, not held back for 6');
      expect(store.pullCursors(dayOne)[other.deviceId],
          const PullCursor(floor: 1, contiguous: 5, highest: 7, missing: [(6, 6)]),
          reason: 'contiguous: 6 is still missing, and named as missing');
      expect(store.insertPulled(dayOne, texts[5]), isTrue);
      expect(store.pullCursors(dayOne)[other.deviceId], const PullCursor(floor: 1, contiguous: 7));
      expect(store.count(), 7);
    });

    test("it counts from the device's lowest sequence on the race day, not from 1", () {
      // A phone's first events never reach shore (its role pick, before it is admitted), and its
      // other race days' events are not in this one.
      final (other, texts) = otherPhone(6);
      final store = openStore(tempDbPath());
      for (final t in texts.skip(3)) {
        store.insertPulled(dayOne, t);
      }
      expect(store.pullCursors(dayOne)[other.deviceId], const PullCursor(floor: 4, contiguous: 6));
      store.insertPulled(dayOne, texts[2]);
      expect(store.pullCursors(dayOne)[other.deviceId], const PullCursor(floor: 3, contiguous: 6),
          reason: 'a lower number that arrives late moves the floor down');
    });

    test("each race day has its own cursor, and this device's own runs from 1 to its last event", () {
      final (other, texts) = otherPhone(4);
      final store = openStore(tempDbPath());
      store.append(note);
      store.append(note);
      store.insertPulled(dayOne, texts[0]);
      store.insertPulled(dayOne, texts[1]);
      store.insertPulled(dayTwo, texts[3]);
      expect(store.pullCursors(dayOne), {
        other.deviceId: const PullCursor(floor: 1, contiguous: 2),
        store.deviceId: const PullCursor(floor: 1, contiguous: 2),
      });
      expect(store.pullCursors(dayTwo), {
        other.deviceId: const PullCursor(floor: 4, contiguous: 4),
        store.deviceId: const PullCursor(floor: 1, contiguous: 2),
      });
    });

    test("numbers a device logged on another race day are a hole here, named, never a stall", () {
      // The review of #64: it logs 1-3 here, 4-5 on another race day, then 6-8 here again. The hole
      // never fills on this race day, so the cursor names it rather than asking from 4 up for good.
      final (other, texts) = otherPhone(8);
      final store = openStore(tempDbPath());
      for (final i in [0, 1, 2, 5, 6, 7]) {
        store.insertPulled(dayOne, texts[i]);
      }
      store.insertPulled(dayTwo, texts[3]);
      store.insertPulled(dayTwo, texts[4]);
      expect(store.pullCursors(dayOne)[other.deviceId],
          const PullCursor(floor: 1, contiguous: 3, highest: 8, missing: [(4, 5)]));
      expect(store.pullCursors(dayTwo)[other.deviceId], const PullCursor(floor: 4, contiguous: 5));
    });

    test('several holes are each named, in order', () {
      final (other, texts) = otherPhone(10);
      final store = openStore(tempDbPath());
      for (final i in [1, 3, 4, 8, 9]) {
        store.insertPulled(dayOne, texts[i]);
      }
      expect(store.pullCursors(dayOne)[other.deviceId],
          const PullCursor(floor: 2, contiguous: 2, highest: 10, missing: [(3, 3), (6, 8)]));
    });

    test('a fresh phone knows only itself, at nothing yet', () {
      final store = openStore(tempDbPath());
      expect(store.pullCursors(dayOne), {store.deviceId: const PullCursor(floor: 1, contiguous: 0)});
    });
  });

  group('criterion 7: refusal stubs', () {
    RefusalStub stub(String device, int seq, {String hash = 'a1', String reason = 'inconsistent_canonical', String day = dayOne}) =>
        RefusalStub(eventId: day, deviceId: device, seq: seq, eventHash: hash, reason: reason);

    test('each is stored against the device and sequence it names, once', () {
      final store = openStore(tempDbPath());
      final device = id('01J9', 1);
      expect(store.insertRefusalStub(stub(device, 3)), isTrue);
      expect(store.insertRefusalStub(stub(device, 3)), isFalse, reason: 'pulled again: held');
      expect(store.insertRefusalStub(stub(device, 3, hash: 'b2', reason: 'ulid_conflict')), isTrue,
          reason: 'a second refused text at one number is its own record, as on the server');
      expect(store.refusalStubs(dayOne), [stub(device, 3), stub(device, 3, hash: 'b2', reason: 'ulid_conflict')]);
      expect(store.refusalStubs(dayTwo), isEmpty);
      expect(store.count(), 0, reason: 'a stub is not an event');
    });

    test('one disagreeing with the stub held for its hash is refused', () {
      final store = openStore(tempDbPath());
      store.insertRefusalStub(stub(id('01J9', 1), 3));
      expect(() => store.insertRefusalStub(stub(id('01J9', 1), 4)), throwsA(isA<PullRefused>()));
      expect(() => store.insertRefusalStub(stub(id('01J9', 1), 3, reason: 'revoked')), throwsA(isA<PullRefused>()));
      expect(store.refusalStubs(dayOne), [stub(id('01J9', 1), 3)]);
    });

    test('a stubbed sequence counts as seen, so the cursor passes it', () {
      final (other, texts) = otherPhone(5);
      final store = openStore(tempDbPath());
      for (final i in [0, 1, 3, 4]) {
        store.insertPulled(dayOne, texts[i]);
      }
      expect(store.pullCursors(dayOne)[other.deviceId],
          const PullCursor(floor: 1, contiguous: 2, highest: 5, missing: [(3, 3)]));
      store.insertRefusalStub(stub(other.deviceId, 3));
      expect(store.pullCursors(dayOne)[other.deviceId], const PullCursor(floor: 1, contiguous: 5));
      store.insertRefusalStub(stub(other.deviceId, 6, hash: 'c3', day: dayTwo));
      expect(store.pullCursors(dayOne)[other.deviceId], const PullCursor(floor: 1, contiguous: 5),
          reason: "another race day's stub is not this one's");
    });
  });

  group('the pull tables are append-only for every code path (criterion 10: nothing is deleted)', () {
    Matcher refusedBy(String table, String what) =>
        throwsA(isA<sql.SqliteException>().having((e) => e.message, 'message', contains('$table is append-only: $what')));

    test('pulled_event and pulled_refusal refuse UPDATE, DELETE and a replacing INSERT', () {
      final (_, texts) = otherPhone(1);
      final store = openStore(tempDbPath());
      store.insertPulled(dayOne, texts.single);
      store.insertRefusalStub(RefusalStub(eventId: dayOne, deviceId: id('01J9', 1), seq: 2, eventHash: 'a1', reason: 'revoked'));
      final db = store.debugDatabase;
      for (final (table, set, replace) in [
        ('pulled_event', "SET event_id = '$dayTwo'", "INSERT OR REPLACE INTO pulled_event SELECT ulid, '$dayTwo' FROM pulled_event"),
        ('pulled_refusal', "SET reason = 'x'",
            "INSERT OR REPLACE INTO pulled_refusal SELECT event_id, device_id, seq, event_hash, 'x' FROM pulled_refusal"),
      ]) {
        final before = db.select('SELECT * FROM $table').toString();
        expect(before, isNot('[]'), reason: 'the fixture wrote a row to $table');
        expect(() => db.execute('UPDATE $table $set'), refusedBy(table, 'UPDATE refused'));
        expect(() => db.execute('DELETE FROM $table'), refusedBy(table, 'DELETE refused'));
        expect(() => db.execute(replace), refusedBy(table, 'an existing row cannot be replaced'));
        expect(db.select('SELECT * FROM $table').toString(), before);
      }
      expect(() => db.execute("DELETE FROM events WHERE ulid = '${ulidOf(texts.single)}'"),
          refusedBy('events', 'DELETE refused'));
    });
  });

  group('criterion 8: the last successful pull, through the core interface', () {
    test('only a pull that read everything moves it, and it survives a reopen', () {
      final path = tempDbPath();
      final store = EventStore.open(path);
      expect(store.pullStatus(), PullStatus.empty);
      store.recordPullRun(const PullRun(state: PullRunState.done, at: 1000, stored: 3));
      store.recordPullRun(const PullRun(state: PullRunState.unreachable, at: 2000, error: 'offline'));
      expect(store.pullStatus(),
          const PullStatus(lastPulledAt: 1000, lastRun: PullRun(state: PullRunState.unreachable, at: 2000, error: 'offline')));
      expect(() => store.recordPullRun(const PullRun(state: 'nonsense', at: 3000)), throwsArgumentError);
      store.close();
      expect(openStore(path).pullStatus().lastPulledAt, 1000);
    });

    test('pullStatus and readOwn cross the isolate boundary as plain data', () async {
      final path = tempDbPath();
      final seeded = EventStore.open(path);
      final (_, texts) = otherPhone(2);
      seeded.append(note);
      for (final t in texts) {
        seeded.insertPulled(dayOne, t);
      }
      seeded.recordPullRun(const PullRun(state: PullRunState.done, at: 1234, stored: 2));
      final mine = seeded.deviceId;
      seeded.close();

      final core = await spawnCore(path);
      addTearDown(core.close);
      expect(await core.pullStatus(), const PullStatus(lastPulledAt: 1234, lastRun: PullRun(state: PullRunState.done, at: 1234, stored: 2)));
      expect((await core.readAll()).length, 3);
      expect([for (final e in await core.readOwn()) e.deviceId], [mine]);
    });

    test('the fake core answers what a test sets, through the wire form', () async {
      final fake = FakeCore()..pullStatusValue = const PullStatus(lastPulledAt: 5);
      expect(await fake.pullStatus(), const PullStatus(lastPulledAt: 5));
      expect(fake.calls['pullStatus'], 1);
    });
  });

  group("readOwn: this phone's own events only", () {
    test('ordered by device time, not by sequence number or by when they were stored', () {
      // A phone clock that steps backwards (the review of #64: in a fixture where every key agrees,
      // ORDER BY seq, or none at all, passed). Device time disagrees with seq and with insertion.
      final store = openStore(tempDbPath(), clock: steppingClock([100, 3000, 1000, 2000]));
      final appended = [store.append(note), store.append(note), store.append(note)];
      expect([for (final e in appended) e.seq], [1, 2, 3]);
      expect([for (final e in store.readOwn()) e.seq], [2, 3, 1], reason: 'device time 1000, 2000, 3000');
    });

    test('in the same order as readAll, with every pulled event left out', () {
      final store = openStore(tempDbPath());
      store.append(note);
      final (_, texts) = otherPhone(3);
      for (final t in texts) {
        store.insertPulled(dayOne, t);
      }
      store.append(note);
      final own = [for (final e in store.readAll()) if (e.deviceId == store.deviceId) e.ulid];
      expect(own, hasLength(2));
      expect([for (final e in store.readOwn()) e.ulid], own);
    });

    test("the fake core's readOwn leaves another phone's seeded events out", () async {
      final fake = FakeCore();
      final mine = await fake.append(note);
      fake.seed([EventEnvelope.fromWire(decodeText(textOf(ulid: id('01J8', 1), device: id('01J9', 1), seq: 1, ts: 1)))]);
      expect([for (final e in await fake.readAll()) e.ulid], hasLength(2));
      expect([for (final e in await fake.readOwn()) e.ulid], [mine.ulid]);
    });
  });
}
