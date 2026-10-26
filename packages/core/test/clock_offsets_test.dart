import 'dart:convert';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #55: each phone records its clock's offset from satellite time as it joins a race (groom
/// decision G10), so a finish taken on one phone can be timed against a gun fired on another.
void main() {
  const fleet = '01J8Z0E0000000000000000001';
  const otherFleet = '01J8Z0E0000000000000000002';

  /// Noon on a race day by the phones' local clocks, so no case crosses midnight by accident.
  late _Water water;
  setUp(() => water = _Water(DateTime(2026, 10, 24, 12).millisecondsSinceEpoch));

  /// The phone's own offsets in the order it wrote them, which a clock set back would scramble by time.
  List<EventEnvelope> offsetsIn(EventStore store) =>
      [for (final e in store.readAll()) if (e.kind == ClockKinds.offset && e.deviceId == store.deviceId) e]
        ..sort((a, b) => a.seq.compareTo(b.seq));

  Future<CoreClient> spawnedCore() async {
    final core = await spawnCore(tempDbPath());
    addTearDown(() async {
      try {
        await core.close();
      } on Object {
        // Closed by the test.
      }
    });
    return core;
  }

  group('criterion 1: with satellite time, a phone joining a race appends its offset, uncertainty and fix age',
      () {
    test('just before its gun, naming the gun as the race, at the same time and the sequence number before', () {
      final pro = _Phone(water, skewMs: -4000);
      pro.location.reportFix(const GpsFix(lat: 33.4012, lon: -86.8123, accuracyM: 4, ageMs: 0));
      pro.fix(ageMs: 1500, uncertaintyMs: 7);
      water.pass(2000);
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'race-timer'));

      final all = pro.store.readAll();
      expect([for (final e in all) e.kind], [ClockKinds.offset, StartKinds.start]);
      final offset = all.first;
      expect(offset.payload, {
        'fleet': fleet,
        'race': gun.ulid,
        'offset_ms': 4000,
        'uncertainty_ms': 7,
        'age_ms': 3500,
        'reason': null,
      }, reason: 'satellite time minus a clock 4 s slow is +4 s; the fix was 1.5 s old, then 2 s passed');
      expect([offset.seq, offset.deviceTs, offset.source], [gun.seq - 1, gun.deviceTs, 'core'],
          reason: 'written by the core on its own account');
      expect([offset.gps, gun.gps], everyElement(const GpsFix(lat: 33.4012, lon: -86.8123, accuracyM: 4, ageMs: 0)),
          reason: 'stamped with the position like any event the phone appends');
      expect(verifyChains(pro.store.readCanonical()).values.single, const ChainVerdict.intact());
    });

    test('just before a mark boat\'s first finish, naming the gun pulled from the PRO phone', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: -4000)..pull(pro);
      water.pass(60000);
      mark.fix(ageMs: 200, uncertaintyMs: 3);
      final finish = mark.store.append(FinishEvents.atMark(fleet: fleet));

      final offsets = offsetsIn(mark.store);
      expect(offsets, hasLength(1));
      expect(offsets.single.payload, {
        'fleet': fleet,
        'race': gun.ulid,
        'offset_ms': 4000,
        'uncertainty_ms': 3,
        'age_ms': 200,
        'reason': null,
      });
      expect(offsets.single.seq, finish.seq - 1);
    });

    test('from satellite time the UI reports, through the core interface and on the fake core', () async {
      for (final core in [await spawnedCore(), FakeCore()]) {
        final now = DateTime.now().millisecondsSinceEpoch;
        await core.reportGpsTime(GpsTimeSample(gpsTimeMs: now - 1000 + 4000, deviceTimeMs: now - 1000, uncertaintyMs: 9));
        final gun = await core.append(StartEvents.start(fleet: null, source: 'manual'));
        final offset = (await core.readAll()).singleWhere((e) => e.kind == ClockKinds.offset);
        expect([offset.payload['offset_ms'], offset.payload['uncertainty_ms'], offset.payload['race']],
            [4000, 9, gun.ulid], reason: '$core');
        expect(offset.payload['age_ms'], inInclusiveRange(1000, 30000), reason: '$core');
      }
    });

    test('nothing else joins a race: no offset before a note, a recall, a sail number or an undo', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      pro.store.append(const NewEvent(kind: 'note', source: 'tap'));
      pro.store.append(StartEvents.generalRecall(fleet: fleet, source: 'manual'));
      pro.store.append(StartEvents.postponement(fleet: fleet, source: 'manual'));
      pro.store.append(FinishEvents.missed(fleet: fleet, afterUlid: null, beforeUlid: '01J8${'1'.padLeft(22, '0')}'));
      pro.store.append(FinishEvents.assignSail('01J8${'1'.padLeft(22, '0')}', '12345'));
      pro.store.append(CourseEvents.shortened(fleet: fleet));
      pro.store.append(StartEvents.undo('01J8${'2'.padLeft(22, '0')}'));
      pro.store.append(FinishEvents.undo('01J8${'3'.padLeft(22, '0')}'));
      expect(offsetsIn(pro.store), isEmpty);
    });

    test('a second finish in a race the phone has joined appends none', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      for (var i = 0; i < 3; i++) {
        water.pass(1000);
        pro.store.append(FinishEvents.finish(fleet: fleet));
      }
      expect(offsetsIn(pro.store), hasLength(1), reason: 'the gun joined the race; its finishes are in it');
    });

    test('the offset comes before its gun in every read, as it does by sequence number', () async {
      // The two share a millisecond, and ULIDs of one millisecond sort by their random tails, so
      // without care about half would read the other way round. Each gun is read at its own time.
      final pro = _Phone(water, skewMs: 0)..fix();
      final fake = FakeCore(clock: () => water.now);
      for (var i = 0; i < 30; i++) {
        water.pass(1);
        pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
        await fake.append(StartEvents.start(fleet: fleet, source: 'manual'));
      }
      for (final all in [pro.store.readAll(), await fake.readOwn()]) {
        expect(all, hasLength(60));
        for (var i = 0; i < 60; i += 2) {
          expect([all[i].kind, all[i + 1].kind], [ClockKinds.offset, StartKinds.start]);
          expect([all[i].payload['race'], all[i].seq], [all[i + 1].ulid, all[i + 1].seq - 1]);
        }
      }
    });

    test('the two are stored together or not at all', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      // Something already holds sequence number 2, so the gun cannot be stored after its offset.
      pro.store.debugDatabase.execute('INSERT INTO events (ulid, device_id, seq, device_ts, body) VALUES (?, ?, ?, ?, ?)',
          ['01J8${'9'.padLeft(22, '0')}', pro.store.deviceId, 2, 1, '{}']);
      expect(() => pro.store.append(StartEvents.start(fleet: fleet, source: 'manual')), throwsA(anything));
      expect(pro.store.count(), 1, reason: 'the offset went back out with the gun');

      final next = pro.store.append(const NewEvent(kind: 'note', source: 'tap'));
      expect([next.seq, next.prevHash], [1, genesisHash], reason: 'and the chain carries on from where it was');
    });

    test('a finish whose join failed joins again when it is retried', () {
      // A gun always joins, so only a finish shows whether the failed offset was forgotten.
      final pro = _Phone(water, skewMs: 0)..fix();
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: -4000)
        ..fix()
        ..pull(pro);
      final db = mark.store.debugDatabase;
      db.execute('INSERT INTO events (ulid, device_id, seq, device_ts, body) VALUES (?, ?, ?, ?, ?)',
          ['01J8${'9'.padLeft(22, '0')}', mark.store.deviceId, 2, 1, '{}']);
      expect(() => mark.store.append(FinishEvents.atMark(fleet: fleet)), throwsA(anything));
      // What blocked it goes, which only a test reaching past the core can do.
      db.execute('DROP TRIGGER events_no_delete');
      db.execute('DELETE FROM events WHERE device_id = ? AND seq = 2', [mark.store.deviceId]);

      final finish = mark.store.append(FinishEvents.atMark(fleet: fleet));
      final offsets = offsetsIn(mark.store);
      expect([for (final o in offsets) (o.seq, o.payload['race'])], [(finish.seq - 1, gun.ulid)]);
    });
  });

  group('criterion 2: each race the phone joins gets its own offset', () {
    test('a new gun on the same day: a new offset for the new race, measured afresh', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gun1 = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      water.pass(45 * 60000);
      pro.store.append(FinishEvents.finish(fleet: fleet));
      pro.skewMs += 120; // the phone's clock gained 120 ms over the race
      pro.fix();
      final gun2 = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      pro.store.append(FinishEvents.finish(fleet: fleet));

      expect([for (final o in offsetsIn(pro.store)) (o.payload['race'], o.payload['offset_ms'])],
          [(gun1.ulid, 0), (gun2.ulid, -120)]);
    });

    test('a mark boat: each gun pulled from the PRO phone is a new race for its next finish', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final mark = _Phone(water, skewMs: -4000)..fix();
      final gun1 = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      mark.pull(pro);
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      water.pass(30 * 60000);
      final gun2 = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      mark.pull(pro);
      mark.store.append(FinishEvents.atMark(fleet: fleet));

      expect([for (final o in offsetsIn(mark.store)) o.payload['race']], [gun1.ulid, gun2.ulid]);
    });

    test('with no gun known, a fleet\'s first finish of the day joins its race of the day, once; another fleet '
        'and the next day join again', () {
      final mark = _Phone(water, skewMs: 0)..fix();
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      mark.store.append(FinishEvents.atMark(fleet: otherFleet));
      water.pass(24 * 3600000);
      mark.fix();
      mark.store.append(FinishEvents.atMark(fleet: fleet));

      expect([for (final o in offsetsIn(mark.store)) (o.payload['fleet'], o.payload['race'])],
          [(fleet, null), (otherFleet, null), (fleet, null)]);
    });

    test('a reopened log remembers the races its phone joined and the guns it pulled', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: 0)..fix()..pull(pro);
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      mark.store.close();

      final reopened = EventStore.open(mark.path, clock: () => water.now, location: mark.location);
      addTearDown(reopened.close);
      reopened.append(FinishEvents.atMark(fleet: fleet));
      expect([for (final o in offsetsIn(reopened)) o.payload['race']], [gun.ulid],
          reason: 'the race of a pulled gun, already joined: no second offset');
    });

    test('a gun from an earlier day begins no race today: the next day\'s first finish joins the race of the day',
        () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gun1 = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: -4000)
        ..fix()
        ..pull(pro);
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      water.pass(24 * 3600000);
      mark.skewMs += 3000; // overnight the mark boat's clock moved
      mark.fix();
      pro.fix();
      final gunAt = water.now;
      final gun2 = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      water.pass(20 * 60000);
      final finishAt = water.now;
      final finish = mark.store.append(FinishEvents.atMark(fleet: fleet)); // offline: gun 2 not pulled yet

      expect([for (final o in offsetsIn(mark.store)) (o.payload['race'], o.payload['offset_ms'])],
          [(gun1.ulid, 4000), (null, 1000)]);
      mark.pull(pro);
      final events = mark.store.readAll();
      expect(crossPhoneElapsed(events, gun: events.singleWhere((e) => e.ulid == gun2.ulid), finish: finish).elapsedMs,
          finishAt - gunAt);
    });

    test('a recalled or undone gun begins no race: a finish after it joins the race of the day', () {
      for (final takeBack in [
        (_Phone pro, EventEnvelope gun) => pro.store.append(StartEvents.generalRecall(fleet: fleet, source: 'manual')),
        (_Phone pro, EventEnvelope gun) => pro.store.append(StartEvents.undo(gun.ulid)),
      ]) {
        final pro = _Phone(water, skewMs: 0)..fix();
        final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
        takeBack(pro, gun);
        final mark = _Phone(water, skewMs: 0)
          ..fix()
          ..pull(pro);
        mark.store.append(FinishEvents.atMark(fleet: fleet));
        pro.store.append(FinishEvents.finish(fleet: fleet));
        expect([for (final o in offsetsIn(mark.store)) o.payload['race']], [null], reason: 'the mark boat');
        expect([for (final o in offsetsIn(pro.store)) o.payload['race']], [gun.ulid, null],
            reason: 'the gun\'s own phone joins the race after it afresh');
      }
    });

    test('a reopened log remembers a recall it pulled', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      pro.store.append(StartEvents.generalRecall(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: 0)
        ..fix()
        ..pull(pro);
      mark.store.close();
      final reopened = EventStore.open(mark.path, clock: () => water.now, location: mark.location);
      addTearDown(reopened.close);
      reopened.append(FinishEvents.atMark(fleet: fleet));
      expect([for (final o in offsetsIn(reopened)) o.payload['race']], [null]);
    });

    test('the day is the phone\'s local date, not UTC\'s', () {
      // Vacuous where local time is UTC, as on CI's runner: no instant then splits the two calendars.
      final utcMidnight = DateTime.utc(2026, 10, 25).millisecondsSinceEpoch;
      final localMidnight = DateTime(2026, 10, 25).millisecondsSinceEpoch;
      int offsetsAcross(int midnight) {
        water.now = midnight - 30 * 60000;
        final mark = _Phone(water, skewMs: 0)..fix();
        mark.store.append(FinishEvents.atMark(fleet: fleet));
        water.pass(60 * 60000);
        mark.fix();
        mark.store.append(FinishEvents.atMark(fleet: fleet));
        return offsetsIn(mark.store).length;
      }

      expect(offsetsAcross(utcMidnight), 1, reason: 'one local day either side of UTC midnight');
      expect(offsetsAcross(localMidnight), 2, reason: 'two local days, one UTC day');
    }, skip: DateTime(2026, 10, 25).timeZoneOffset == Duration.zero ? 'local time is UTC here' : false);
  });

  group('criterion 3: two phones 4 s apart, each fed satellite time', () {
    test('a finish on the mark boat timed against the PRO phone\'s gun is within 1 s of the true elapsed time', () {
      final pro = _Phone(water, skewMs: 1500);
      final mark = _Phone(water, skewMs: -2500);
      pro.fix(ageMs: 800);
      water.pass(2000);
      final gunAt = water.now;
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'race-timer'));
      mark.fix(ageMs: 3000);
      water.pass(9 * 60000 + 37250);
      mark.pull(pro);
      final finishAt = water.now;
      final finish = mark.store.append(FinishEvents.atMark(fleet: fleet));

      final trueElapsed = finishAt - gunAt;
      expect(finish.deviceTs - gun.deviceTs, trueElapsed - 4000, reason: 'control: the raw clocks are 4 s apart');
      final events = mark.store.readAll();
      final result = crossPhoneElapsed(events, gun: events.singleWhere((e) => e.ulid == gun.ulid), finish: finish);
      expect(result.flagged, isFalse);
      expect(result.elapsedMs, closeTo(trueElapsed, 1000), reason: 'the criterion');
      expect(result.elapsedMs, trueElapsed, reason: 'and exact here, where the satellite time is');

      pro.pull(mark);
      expect(crossPhoneElapsed(pro.store.readAll(), gun: gun, finish: finish).elapsedMs, trueElapsed,
          reason: 'the PRO phone, pulling the finish, computes the same');
    });

    test('an offset either phone recorded after its event never applies to it', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final mark = _Phone(water, skewMs: -4000)..fix();
      final gunAt = water.now;
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      mark.pull(pro);
      water.pass(300000);
      final finishAt = water.now;
      final finish = mark.store.append(FinishEvents.atMark(fleet: fleet));
      // Later both clocks are set, by different amounts so the two errors cannot cancel, and each
      // phone joins another fleet's race at its new offset.
      pro.skewMs += 5000;
      mark.skewMs += 2000;
      pro.fix();
      mark.fix();
      pro.store.append(StartEvents.start(fleet: otherFleet, source: 'manual'));
      mark.pull(pro);
      mark.store.append(FinishEvents.atMark(fleet: otherFleet));

      final events = mark.store.readAll();
      expect([for (final e in events) if (e.kind == ClockKinds.offset) e.payload['offset_ms']]..sort(),
          [-5000, 0, 2000, 4000], reason: 'control: the later offsets are there to be misapplied');
      expect(crossPhoneElapsed(events, gun: events.singleWhere((e) => e.ulid == gun.ulid), finish: finish).elapsedMs,
          finishAt - gunAt);
    });

    test('a second race is timed through that race\'s offset, the latest, not the first race\'s', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final mark = _Phone(water, skewMs: -4000)..fix();
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      mark.pull(pro);
      water.pass(600000);
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      mark.skewMs += 120; // the mark boat's clock gained 120 ms over the race
      mark.fix();
      pro.fix();
      final gunAt = water.now;
      final gun2 = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      mark.pull(pro);
      water.pass(600000);
      final finish = mark.store.append(FinishEvents.atMark(fleet: fleet));

      expect([for (final o in offsetsIn(mark.store)) o.payload['offset_ms']], [4000, 3880],
          reason: 'control: two measured offsets before the finish, which differ');
      final events = mark.store.readAll();
      expect(crossPhoneElapsed(events, gun: events.singleWhere((e) => e.ulid == gun2.ulid), finish: finish).elapsedMs,
          water.now - gunAt);
    });

    test('from a gun time the PRO corrected by hand, which is read on the PRO phone\'s clock', () {
      final pro = _Phone(water, skewMs: 1500)..fix();
      final mark = _Phone(water, skewMs: -2500)..fix();
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final realGunAt = water.now - 2000; // the gun went 2 s before it was tapped
      pro.store.append(StartEvents.correctTime(gun.ulid, time: gun.deviceTs - 2000));
      water.pass(600000);
      mark.pull(pro);
      final finishAt = water.now;
      final finish = mark.store.append(FinishEvents.finish(fleet: fleet));

      final events = mark.store.readAll();
      expect(crossPhoneElapsed(events, gun: events.singleWhere((e) => e.ulid == gun.ulid), finish: finish).elapsedMs,
          finishAt - realGunAt);
    });
  });

  group('criterion 4: no GPS fix for 10 min, then a finish', () {
    test('the last known offset is applied, and its age is recorded', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final mark = _Phone(water, skewMs: -4000);
      final gunAt = water.now;
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      mark.location.reportFix(const GpsFix(lat: 33.4, lon: -86.8, accuracyM: 5, ageMs: 0));
      mark.fix();
      mark.location.reportNone(GpsReasons.noFix); // the fix is lost
      water.pass(10 * 60000);
      mark.pull(pro);
      final finishAt = water.now;
      final finish = mark.store.append(FinishEvents.atMark(fleet: fleet));

      final offset = offsetsIn(mark.store).single;
      expect([offset.payload['offset_ms'], offset.payload['age_ms'], offset.payload['reason']], [4000, 600000, null]);
      expect(finish.gpsReason, GpsReasons.noFix, reason: 'the position is gone; the offset is kept');
      final events = mark.store.readAll();
      final result = crossPhoneElapsed(events, gun: events.singleWhere((e) => e.ulid == gun.ulid), finish: finish);
      expect([result.elapsedMs, result.finishOffsetAgeMs, result.gunOffsetAgeMs], [finishAt - gunAt, 600000, 0]);
    });

    test('a later finish in a race already joined uses the race\'s offset, aged by the time since', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: -4000)..pull(pro);
      mark.fix(ageMs: 1000);
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      water.pass(10 * 60000);
      final finish = mark.store.append(FinishEvents.atMark(fleet: fleet));

      final events = mark.store.readAll();
      final result = crossPhoneElapsed(events, gun: events.singleWhere((e) => e.ulid == gun.ulid), finish: finish);
      expect(result.finishOffsetAgeMs, 601000);
      expect(result.elapsedMs, 600000);
    });
  });

  group('criterion 5: with no satellite time at all', () {
    test('the offset event says so, and why', () {
      final cases = <String, void Function(LatestFix)>{
        GpsReasons.noSource: (_) {},
        GpsReasons.noPermission: (l) => l.reportNone(GpsReasons.noPermission),
        GpsReasons.locationOff: (l) => l.reportNone(GpsReasons.locationOff),
        GpsReasons.noFix: (l) => l.reportNone(GpsReasons.noFix),
        ClockOffsetReasons.noGpsTime: (l) => l.reportFix(const GpsFix(lat: 33.4, lon: -86.8, ageMs: 0)),
      };
      for (final MapEntry(key: reason, value: arrange) in cases.entries) {
        final pro = _Phone(water, skewMs: 0);
        arrange(pro.location);
        pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
        expect(offsetsIn(pro.store).single.payload,
            allOf(containsPair('offset_ms', null), containsPair('uncertainty_ms', null), containsPair('age_ms', null),
                containsPair('reason', reason)),
            reason: reason);
      }
    });

    test('a clock set since the last satellite time: clock_changed until the next, whether the phone said so or '
        'the clock reads earlier than the fix', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      pro.store.recordClockChanged();
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      pro.fix();
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      pro.skewMs -= 60000; // set back a minute, with no word from the phone
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      water.pass(120000); // the clock passes the fix's time again, still with no new fix
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));

      expect([for (final o in offsetsIn(pro.store)) (o.payload['offset_ms'], o.payload['reason'])], [
        (null, ClockOffsetReasons.clockChanged),
        (0, null),
        (null, ClockOffsetReasons.clockChanged),
        (null, ClockOffsetReasons.clockChanged),
      ]);
      expect([for (final e in pro.store.readAll()) if (e.kind == ClockKinds.changed) e.source], ['core'],
          reason: 'the phone\'s word is logged; the set it never reported is not');
    });

    test('a clock set with no offset held changes no reason, and is still logged', () {
      final pro = _Phone(water, skewMs: 0);
      pro.location.reportNone(GpsReasons.noPermission);
      pro.store.recordClockChanged();
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      expect(offsetsIn(pro.store).single.payload['reason'], GpsReasons.noPermission);
      expect(pro.store.readAll().where((e) => e.kind == ClockKinds.changed), hasLength(1));
    });

    test('an elapsed time across two phones is flagged, never computed from the raw clocks', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final blind = _Phone(water, skewMs: -4000)..pull(pro); // no satellite time
      water.pass(60000);
      final finish = blind.store.append(FinishEvents.atMark(fleet: fleet));
      var events = blind.store.readAll();
      final result = crossPhoneElapsed(events, gun: events.singleWhere((e) => e.ulid == gun.ulid), finish: finish);
      expect([result.flagged, result.elapsedMs, result.flags], [true, null, [CrossPhoneFlags.finishPhoneUnmeasured]]);

      // A gun from a phone that recorded no offset at all, as one logged before #55.
      final older = _Phone(water, skewMs: 0);
      final oldGun = EventEnvelope(
        ulid: '01J8${'2'.padLeft(22, '0')}',
        deviceTs: water.now,
        deviceId: older.store.deviceId,
        seq: 1,
        source: 'manual',
        kind: StartKinds.start,
        payloadVersion: 1,
        payload: const {'fleet': otherFleet},
      );
      blind.store.insert(oldGun);
      water.pass(60000);
      final finish2 = blind.store.append(FinishEvents.atMark(fleet: otherFleet));
      events = blind.store.readAll();
      expect(crossPhoneElapsed(events, gun: oldGun, finish: finish2).flags,
          [CrossPhoneFlags.gunPhoneNoOffset, CrossPhoneFlags.finishPhoneUnmeasured]);
    });

    test('one phone\'s own gun and finish need no offset, so are not flagged', () {
      final pro = _Phone(water, skewMs: -4000); // no satellite time
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      water.pass(61500);
      final finish = pro.store.append(FinishEvents.finish(fleet: fleet));
      final result = crossPhoneElapsed(pro.store.readAll(), gun: gun, finish: finish);
      expect([result.flagged, result.elapsedMs], [false, 61500]);
    });
  });

  group('criterion 5, the other two flags', () {
    test('a gun\'s phone without satellite time, and a finish\'s phone that recorded no offset', () {
      final blindPro = _Phone(water, skewMs: 0); // no satellite time
      final gun = blindPro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: -4000)
        ..fix()
        ..pull(blindPro);
      water.pass(60000);
      final finish = mark.store.append(FinishEvents.atMark(fleet: fleet));
      var events = mark.store.readAll();
      expect(crossPhoneElapsed(events, gun: events.singleWhere((e) => e.ulid == gun.ulid), finish: finish).flags,
          [CrossPhoneFlags.gunPhoneUnmeasured]);

      final pro = _Phone(water, skewMs: 0)..fix();
      final measuredGun = pro.store.append(StartEvents.start(fleet: otherFleet, source: 'manual'));
      final older = _Phone(water, skewMs: 0);
      // A finish from a phone that recorded no offset at all, as one logged before #55.
      final oldFinish = EventEnvelope(
        ulid: '01J8${'4'.padLeft(22, '0')}',
        deviceTs: water.now + 60000,
        deviceId: older.store.deviceId,
        seq: 1,
        source: 'tap',
        kind: FinishKinds.atMark,
        payloadVersion: 1,
        payload: const {'fleet': otherFleet},
      );
      pro.store.insert(oldFinish);
      events = pro.store.readAll();
      expect(crossPhoneElapsed(events, gun: measuredGun, finish: oldFinish).flags, [CrossPhoneFlags.finishPhoneNoOffset]);
    });
  });

  group('after the review: a clock set mid-race, and a race joined before satellite time', () {
    test('a clock set after a phone joined a race: its next finish joins again with a fresh offset, and the '
        'elapsed time stays true', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gunAt = water.now;
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: -4000)
        ..fix()
        ..pull(pro);
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      mark.skewMs += 4000; // network time sets the mark boat's clock right
      mark.store.recordClockChanged();
      mark.fix();
      water.pass(120000);
      final finish = mark.store.append(FinishEvents.atMark(fleet: fleet));

      expect([for (final o in offsetsIn(mark.store)) (o.payload['race'], o.payload['offset_ms'])],
          [(gun.ulid, 4000), (gun.ulid, 0)]);
      final events = mark.store.readAll();
      expect(crossPhoneElapsed(events, gun: events.singleWhere((e) => e.ulid == gun.ulid), finish: finish).elapsedMs,
          water.now - gunAt);
    });

    test('with no satellite time since the set, that finish is flagged, never timed across the step', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: -4000)
        ..fix()
        ..pull(pro);
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      mark.skewMs += 4000;
      mark.store.recordClockChanged();
      water.pass(60000);
      final finish = mark.store.append(FinishEvents.atMark(fleet: fleet));
      final events = mark.store.readAll();
      expect(crossPhoneElapsed(events, gun: events.singleWhere((e) => e.ulid == gun.ulid), finish: finish).flags,
          [CrossPhoneFlags.finishPhoneUnmeasured]);
    });

    test('one phone\'s gun and finish either side of a set are timed through its offsets, or flagged', () {
      for (final refix in [true, false]) {
        final pro = _Phone(water, skewMs: 0)..fix();
        final gunAt = water.now;
        final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
        pro.skewMs -= 4000;
        pro.store.recordClockChanged();
        if (refix) pro.fix();
        water.pass(120000);
        final finish = pro.store.append(FinishEvents.finish(fleet: fleet));
        final result = crossPhoneElapsed(pro.store.readAll(), gun: gun, finish: finish);
        expect(finish.deviceTs - gun.deviceTs, 116000, reason: 'control: the raw readings cross the step');
        expect([result.elapsedMs, result.flags],
            refix ? [water.now - gunAt, isEmpty] : [null, [CrossPhoneFlags.finishPhoneUnmeasured]],
            reason: 'refix: $refix');
      }
    });

    test('a reopened log remembers the set', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: -4000)
        ..fix()
        ..pull(pro);
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      mark.skewMs += 4000;
      mark.store.recordClockChanged();
      mark.store.close();
      mark.fix();
      final reopened = EventStore.open(mark.path, clock: () => mark.clock, location: mark.location);
      addTearDown(reopened.close);
      reopened.append(FinishEvents.atMark(fleet: fleet));
      expect([for (final o in offsetsIn(reopened)) (o.payload['race'], o.payload['offset_ms'])],
          [(gun.ulid, 4000), (gun.ulid, 0)]);
    });

    test('a race joined before satellite time is joined again once it arrives, and only then', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gunAt = water.now;
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: -4000)..pull(pro); // no satellite time yet
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      mark.fix();
      water.pass(90000);
      final finish = mark.store.append(FinishEvents.atMark(fleet: fleet));
      mark.store.append(FinishEvents.atMark(fleet: fleet));

      expect([for (final o in offsetsIn(mark.store)) (o.payload['offset_ms'], o.payload['reason'])],
          [(null, GpsReasons.noSource), (4000, null)],
          reason: 'one offset that could not be measured, then one that was: none per finish meanwhile');
      final events = mark.store.readAll();
      expect(crossPhoneElapsed(events, gun: events.singleWhere((e) => e.ulid == gun.ulid), finish: finish).elapsedMs,
          water.now - gunAt);
    });
  });

  group('the uncertainty', () {
    test('a phone that states no figure of its own: the offset is recorded, its uncertainty null (owner '
        'decision on #55)', () {
      final pro = _Phone(water, skewMs: -4000)..fix(uncertaintyMs: null);
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final payload = offsetsIn(pro.store).single.payload;
      expect([payload['offset_ms'], payload['uncertainty_ms'], payload['reason']], [4000, null, null]);
    });
  });

  group('satellite time the core cannot have been given is refused before it is kept', () {
    const bad = [
      GpsTimeSample(gpsTimeMs: 0, deviceTimeMs: 1, uncertaintyMs: 1),
      GpsTimeSample(gpsTimeMs: 1, deviceTimeMs: 0, uncertaintyMs: 1),
      GpsTimeSample(gpsTimeMs: 1, deviceTimeMs: 1, uncertaintyMs: -1),
    ];

    test('in the core, over the wire, and on the fake core', () async {
      final core = await spawnedCore();
      final fake = FakeCore();
      for (final sample in bad) {
        expect(() => LatestFix().reportGpsTime(sample), throwsArgumentError, reason: '$sample');
        await expectLater(core.reportGpsTime(sample),
            throwsA(isA<CoreException>().having((e) => e.code, 'code', 'invalid')), reason: '$sample');
        await expectLater(fake.reportGpsTime(sample), throwsArgumentError, reason: '$sample');
      }
      await core.append(StartEvents.start(fleet: null, source: 'manual'));
      final offset = (await core.readAll()).first;
      expect(offset.payload['reason'], GpsReasons.noSource, reason: 'none of them was kept');
    });

    test('a clock change crosses the wire too', () async {
      final core = await spawnedCore();
      final now = DateTime.now().millisecondsSinceEpoch;
      await core.reportGpsTime(GpsTimeSample(gpsTimeMs: now, deviceTimeMs: now));
      await core.reportClockChanged();
      await core.append(StartEvents.start(fleet: null, source: 'manual'));
      final all = await core.readAll();
      expect([for (final e in all) if (ClockKinds.all.contains(e.kind)) e.kind],
          containsAll([ClockKinds.changed, ClockKinds.offset]));
      expect(all.singleWhere((e) => e.kind == ClockKinds.offset).payload['reason'], ClockOffsetReasons.clockChanged);
    });
  });

  test('the clock-offset kind is a kind the log can hold, and every reason a position can lack is one an offset '
      'can', () {
    expect(EventKinds.all, containsAll([ClockKinds.offset, ClockKinds.changed]));
    expect(ClockOffsetReasons.all, containsAll([...GpsReasons.all, 'no_gps_time', 'clock_changed']));
  });
}

/// True time on the water, which every phone's clock reads with its own error.
class _Water {
  _Water(this.now);

  int now;

  void pass(int ms) => now += ms;
}

/// One committee phone: its log, its own clock [skewMs] off true time, and the satellite time its
/// location feed reports, as the platform half measures it.
class _Phone {
  _Phone(this.water, {required this.skewMs}) {
    store = EventStore.open(path, clock: () => clock, location: location);
    addTearDown(() {
      try {
        store.close();
      } catch (_) {
        // Closed by the test.
      }
    });
  }

  final _Water water;
  int skewMs;
  final path = tempDbPath();
  final location = LatestFix(elapsedMs: () => 0);
  late final EventStore store;

  /// The phone's own clock.
  int get clock => water.now + skewMs;

  /// A fix [ageMs] old, carrying satellite time, and this phone's clock at that fix.
  void fix({int ageMs = 0, int? uncertaintyMs = 5}) => location.reportGpsTime(
      GpsTimeSample(gpsTimeMs: water.now - ageMs, deviceTimeMs: clock - ageMs, uncertaintyMs: uncertaintyMs));

  /// What sync's pull (#64) leaves here: [other]'s own events, each kept as its own text.
  void pull(_Phone other) {
    for (final text in other.store.readCanonical()) {
      if ((jsonDecode(text) as Map)['device_id'] == other.store.deviceId) {
        store.insertPulled('3f6c1a52-8d0e-4b7a-9c21-5e4f0a9b7d13', text);
      }
    }
  }
}
