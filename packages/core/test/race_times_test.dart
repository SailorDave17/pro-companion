import 'dart:convert';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #69: finishes taken on a phone other than the gun phone, timed from the gun through both phones' clock
/// offsets (#55), and each fleet race flagged where a time could not be worked out or two phones took finishes.
void main() {
  const fleet = '01J8Z0E0000000000000000001';

  /// Noon on a race day by the phones' local clocks, so no case crosses midnight by accident.
  late _Water water;
  setUp(() => water = _Water(DateTime(2026, 10, 24, 12).millisecondsSinceEpoch));

  List<int?> elapsedOf(FleetRaceTimes race) => [for (final f in race.finishes) f.elapsedMs];

  group('criterion 1: a mark phone\'s finishes timed from the gun pulled from the PRO phone', () {
    test('through both phones\' offsets, with each device timestamp as its phone logged it', () {
      final pro = _Phone(water, skewMs: 1500)..fix(ageMs: 800);
      water.pass(2000);
      final gunAt = water.now;
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'race-timer'));
      final mark = _Phone(water, skewMs: -2500)..fix(ageMs: 3000);
      mark.store.append(RoleEvents.assign(Roles.markBoat));
      mark.store.append(StationEvents.select(StandardMarks.leeward));
      water.pass(9 * 60000 + 37250);
      mark.pull(pro);
      final firstAt = water.now;
      final first = mark.store.append(FinishEvents.atMark(fleet: fleet));
      water.pass(4250);
      final second = mark.store.append(FinishEvents.atMark(fleet: fleet));

      final logged = mark.store.readCanonical();
      final race = raceTimesOf(mark.store.readAll()).single;
      expect(first.deviceTs - gun.deviceTs, firstAt - gunAt - 4000, reason: 'control: the raw clocks are 4 s apart');
      expect(race.gun, gun.ulid);
      expect(elapsedOf(race), [firstAt - gunAt, firstAt + 4250 - gunAt], reason: 'the criterion');
      expect([for (final f in race.finishes) (f.ulid, f.deviceTs)], [(first.ulid, first.deviceTs), (second.ulid, second.deviceTs)],
          reason: 'each finish at the time its own phone logged it');
      expect([race.finishes.first.gunOffsetAgeMs, race.finishes.first.finishOffsetAgeMs], [2800, 3000 + 577250],
          reason: 'both phones\' offsets were applied, each with its age');
      expect([race.flags, race.finishes.first.kind, race.finishes.first.mark],
          [isEmpty, FinishKinds.atMark, StandardMarks.leeward], reason: 'the mark its phone was stationed at');
      expect(mark.store.readCanonical(), logged, reason: 'reading the times writes nothing: the log is as it was');

      pro.pull(mark);
      expect(raceTimesOf(pro.store.readAll()), [race], reason: 'the PRO phone, pulling the finishes, reads the same');
    });

    test('the gun phone\'s own line finishes are timed on its own clock, with no offset applied', () {
      final pro = _Phone(water, skewMs: -4000); // no satellite time, which one phone does not need
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      water.pass(61500);
      pro.store.append(FinishEvents.finish(fleet: fleet));

      final finish = raceTimesOf(pro.store.readAll()).single.finishes.single;
      expect([finish.elapsedMs, finish.flags, finish.gunOffsetAgeMs, finish.finishOffsetAgeMs, finish.mark],
          [61500, isEmpty, null, null, null], reason: 'and no mark from a phone with no station');
    });

    test('from a gun time the PRO corrected by hand', () {
      final pro = _Phone(water, skewMs: 1500)..fix();
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final realGunAt = water.now - 2000; // the gun went 2 s before it was tapped
      pro.store.append(StartEvents.correctTime(gun.ulid, time: gun.deviceTs - 2000));
      final mark = _Phone(water, skewMs: -2500)..fix();
      water.pass(600000);
      mark.pull(pro);
      final finishAt = water.now;
      mark.store.append(FinishEvents.atMark(fleet: fleet));

      expect(elapsedOf(raceTimesOf(mark.store.readAll()).single), [finishAt - realGunAt]);
    });
  });

  group('criterion 2: no offset recorded for the finishing or the gun phone', () {
    test('a finishing phone with no satellite time: flagged unreconciled, never computed from the raw clocks', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final blind = _Phone(water, skewMs: -4000)..pull(pro);
      water.pass(60000);
      blind.store.append(FinishEvents.atMark(fleet: fleet));

      final race = raceTimesOf(blind.store.readAll()).single;
      expect([race.flags, race.unreconciled], [[FleetRaceFlags.unreconciled], isTrue]);
      expect([race.finishes.single.elapsedMs, race.finishes.single.flags], [null, [CrossPhoneFlags.finishPhoneUnmeasured]]);
    });

    test('a gun phone that recorded no offset at all, as one logged before #55: flagged, naming the gun\'s phone', () {
      final mark = _Phone(water, skewMs: -4000)..fix();
      final older = _Phone(water, skewMs: 0);
      final oldGun = EventEnvelope(
        ulid: '01J8${'2'.padLeft(22, '0')}',
        deviceTs: water.now,
        deviceId: older.store.deviceId,
        seq: 1,
        source: 'manual',
        kind: StartKinds.start,
        payloadVersion: 1,
        payload: const {'fleet': fleet},
      );
      mark.store.insert(oldGun);
      water.pass(60000);
      mark.store.append(FinishEvents.atMark(fleet: fleet));

      final race = raceTimesOf(mark.store.readAll()).single;
      expect([race.gun, race.flags], [oldGun.ulid, [FleetRaceFlags.unreconciled]]);
      expect(race.finishes.single.flags, [CrossPhoneFlags.gunPhoneNoOffset]);
    });

    test('no gun held, as on every mark phone until #113: each finish flagged no_gun, and the race unreconciled '
        '(owner decision at #69\'s pickup), until the gun is pulled', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gunAt = water.now;
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: -4000)..fix();
      water.pass(60000);
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      mark.store.append(FinishEvents.atMark(fleet: fleet));

      final alone = raceTimesOf(mark.store.readAll()).single;
      expect([alone.gun, alone.flags], [null, [FleetRaceFlags.unreconciled]]);
      expect([for (final f in alone.finishes) [f.elapsedMs, f.flags]], [
        [null, [FinishTimeFlags.noGun]],
        [null, [FinishTimeFlags.noGun]],
      ]);

      mark.pull(pro);
      final pulled = raceTimesOf(mark.store.readAll()).single;
      expect([pulled.gun, pulled.flags, elapsedOf(pulled)], [gun.ulid, isEmpty, [water.now - gunAt, water.now - gunAt]],
          reason: 'the offset the phone recorded with no gun known times them once the gun arrives');
    });
  });

  group('criterion 3: two phones recording finishes for one fleet race', () {
    test('both sets are kept, phone by phone, and the race is flagged as having two finish sources', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gunAt = water.now;
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      // 1 s slow, less than the gap between boats, so by device time the two phones' taps interleave.
      const recorderSkew = -1000;
      final recorder = _Phone(water, skewMs: recorderSkew)
        ..fix()
        ..pull(pro);
      water.pass(600000);
      // The same two boats, taken on both phones a little apart, and named alike on both.
      final taken = <EventEnvelope>[];
      for (final (sail, gap) in [('101', 0), ('202', 3000)]) {
        water.pass(gap);
        for (final phone in [pro, recorder]) {
          final f = phone.store.append(FinishEvents.finish(fleet: fleet));
          phone.store.append(FinishEvents.assignSail(f.ulid, sail));
          taken.add(f);
        }
        water.pass(400);
      }
      pro.pull(recorder);
      recorder.pull(pro);

      final race = raceTimesOf(pro.store.readAll()).single;
      expect(race.flags, [FleetRaceFlags.twoFinishSources], reason: 'the criterion; every time was measured');
      final byPhone = [...taken]..sort((a, b) => a.deviceId != b.deviceId ? a.deviceId.compareTo(b.deviceId) : a.seq - b.seq);
      expect([for (final f in [...taken]..sort(happened)) f.deviceId], isNot([for (final f in byPhone) f.deviceId]),
          reason: 'control: by device time the phones interleave, so phone by phone is a different order');
      expect([for (final f in race.finishes) f.ulid], [for (final f in byPhone) f.ulid],
          reason: 'all four kept, each phone\'s in the order it logged them, never merged into one order');
      expect([for (final f in race.finishes) (f.sail, f.elapsedMs)], [
        for (final f in byPhone)
          (f == taken[0] || f == taken[1] ? '101' : '202', f.deviceId == pro.store.deviceId
              ? f.deviceTs - gunAt
              : f.deviceTs - recorderSkew - gunAt),
      ], reason: 'no reconciliation: each boat twice, each at the time its own phone took her');
      expect(raceTimesOf(recorder.store.readAll()), [race], reason: 'the merged logs read the same on either phone');
    });

    test('a line phone and a mark phone in one race are two sources too', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: -4000)
        ..fix()
        ..pull(pro);
      water.pass(600000);
      pro.store.append(FinishEvents.finish(fleet: fleet));
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      mark.pull(pro);

      final race = raceTimesOf(mark.store.readAll()).single;
      expect([race.flags, race.twoFinishSources], [[FleetRaceFlags.twoFinishSources], isTrue]);
      expect({for (final f in race.finishes) f.kind}, {FinishKinds.finish, FinishKinds.atMark});
    });

    test('one phone\'s tapped and volume-key finishes are one source: a phone is the source, not what logged it', () {
      final pro = _Phone(water, skewMs: 0);
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      water.pass(60000);
      pro.store.append(FinishEvents.finish(fleet: fleet));
      pro.store.append(FinishEvents.finish(fleet: fleet, source: FinishSources.volumeKey));

      final race = raceTimesOf(pro.store.readAll()).single;
      expect([race.finishes.length, race.flags], [2, isEmpty]);
    });

    test('two phones finishing different races of the fleet are not two sources in either', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gun1 = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final recorder = _Phone(water, skewMs: -4000)
        ..fix()
        ..pull(pro);
      water.pass(600000);
      recorder.store.append(FinishEvents.finish(fleet: fleet));
      water.pass(300000);
      final gun2 = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      water.pass(600000);
      pro.store.append(FinishEvents.finish(fleet: fleet));
      pro.pull(recorder);

      expect([for (final r in raceTimesOf(pro.store.readAll())) [r.gun, r.finishes.length, r.flags]], [
        [gun1.ulid, 1, isEmpty],
        [gun2.ulid, 1, isEmpty],
      ]);
    });
  });

  group('criterion 4: the flags per fleet race, through the core interface', () {
    test('CoreClient.raceTimes answers each fleet race with its own flags, worked out in the core', () async {
      final pro = _Phone(water, skewMs: 0)..fix();
      final alpha = pro.store.append(FleetEvents.define('Alpha')).ulid;
      final bravo = pro.store.append(FleetEvents.define('Bravo')).ulid;
      pro.store.append(StartEvents.start(fleet: alpha, source: 'manual'));
      pro.store.append(StartEvents.start(fleet: bravo, source: 'manual'));
      final blind = _Phone(water, skewMs: -4000)..pull(pro); // no satellite time
      // The slowest clock, so bravo's finish is the first logged: first-finish order is not the day's order.
      final mark = _Phone(water, skewMs: -6000)
        ..fix()
        ..pull(pro);
      water.pass(600000);
      blind.store.append(FinishEvents.atMark(fleet: alpha));
      mark.store.append(FinishEvents.atMark(fleet: bravo));
      pro.store.append(FinishEvents.finish(fleet: bravo));
      mark
        ..pull(pro)
        ..pull(blind);

      expect([for (final e in mark.store.readAll()) if (e.kind == FinishKinds.atMark) fleetOf(e)].first, bravo,
          reason: 'control: bravo finished first');
      final expected = raceTimesOf(mark.store.readAll());
      expect([for (final r in expected) [r.fleet, r.flags]], [
        [alpha, [FleetRaceFlags.unreconciled]],
        [bravo, [FleetRaceFlags.twoFinishSources]],
      ], reason: 'the criterion: one flag for each race, on that race alone');
      mark.store.close();
      final core = await spawnCore(mark.path);
      addTearDown(core.close);
      expect(await core.raceTimes(), expected, reason: 'the real core answers the same, as plain data');
    });

    test('every field survives the wire form', () {
      const race = FleetRaceTimes(
        fleet: fleet,
        gun: 'G',
        finishes: [
          FinishTime(
            ulid: 'U',
            kind: FinishKinds.atMark,
            deviceId: 'D',
            deviceTs: 9,
            mark: StandardMarks.leeward,
            sail: '101',
            elapsedMs: 7,
            gunOffsetAgeMs: 5,
            finishOffsetAgeMs: 6,
          ),
          FinishTime(ulid: 'V', kind: FinishKinds.finish, deviceId: 'E', deviceTs: 8, flags: [FinishTimeFlags.noGun]),
        ],
        flags: [FleetRaceFlags.unreconciled, FleetRaceFlags.twoFinishSources],
      );
      final wire = race.toWire();
      expect(isWireSafe(wire), isTrue);
      expect(FleetRaceTimes.fromWire(jsonDecode(jsonEncode(wire)) as Map), race);
    });

    test('the fake core works them out from its own events, through the wire form', () async {
      final pro = _Phone(water, skewMs: 0)..fix();
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: -4000)
        ..fix()
        ..pull(pro);
      water.pass(600000);
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      final events = mark.store.readAll();

      final fake = FakeCore()..seed(events);
      expect(await fake.raceTimes(), raceTimesOf(events));
      expect((await fake.raceTimes()).single.finishes.single.elapsedMs, 600000);
    });
  });

  group('which race a finish from another phone is in (owner decision at #69\'s pickup)', () {
    test('by satellite time where both phones have an offset measured, so a slow clock cannot move it a race back',
        () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gun1 = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      water.pass(600000);
      final gunAt = water.now;
      final gun2 = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: -120000)
        ..fix()
        ..pull(pro); // two minutes slow
      water.pass(60000);
      final finish = mark.store.append(FinishEvents.atMark(fleet: fleet));

      expect([finish.deviceTs > gun1.deviceTs, finish.deviceTs < gun2.deviceTs], [true, true],
          reason: 'control: on the raw clocks it came between the guns, so in race 1');
      expect([for (final r in raceTimesOf(mark.store.readAll())) [r.gun, elapsedOf(r)]], [
        [gun2.ulid, [water.now - gunAt]],
      ]);
    });

    test('on the raw clocks where either phone has none measured, and the finish is flagged', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gun1 = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      water.pass(600000);
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final blind = _Phone(water, skewMs: -120000)..pull(pro); // two minutes slow, no satellite time
      water.pass(60000);
      blind.store.append(FinishEvents.atMark(fleet: fleet));

      final race = raceTimesOf(blind.store.readAll()).single;
      expect([race.gun, race.finishes.single.flags], [gun1.ulid, [CrossPhoneFlags.finishPhoneUnmeasured]]);
    });

    test('a later gun the raw clocks put after the finish passes its flags on, so an earlier gun cannot time it '
        'clean (#69\'s review)', () {
      for (final backupMeasured in [true, false]) {
        final pro = _Phone(water, skewMs: 0)..fix();
        final gun1 = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
        water.pass(600000);
        final backup = _Phone(water, skewMs: 0); // a second gun phone
        if (backupMeasured) backup.fix();
        final gun2At = water.now;
        final gun2 = backup.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
        final mark = _Phone(water, skewMs: -120000)
          ..fix()
          ..pull(pro)
          ..pull(backup); // two minutes slow, with satellite time
        water.pass(60000);
        mark.store.append(FinishEvents.atMark(fleet: fleet));

        final race = raceTimesOf(mark.store.readAll()).single;
        final finish = race.finishes.single;
        expect([race.gun, finish.elapsedMs, finish.flags, race.flags], backupMeasured
            ? [gun2.ulid, water.now - gun2At, isEmpty, isEmpty]
            : [gun1.ulid, null, [CrossPhoneFlags.gunPhoneUnmeasured], [FleetRaceFlags.unreconciled]],
            reason: backupMeasured
                ? 'control: with both measured, it is gun 2\'s, 60 s'
                : 'gun 2\'s phone has no satellite time, so gun 1 must not time it 11 min clean');
      }
    });

    test('with one gun the raw clocks put after the finish, it keeps both reasons: the offset and no gun', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      final blind = _Phone(water, skewMs: -120000)..pull(pro); // two minutes slow, no satellite time
      water.pass(60000);
      blind.store.append(FinishEvents.atMark(fleet: fleet));

      final race = raceTimesOf(blind.store.readAll()).single;
      expect([race.gun, race.finishes.single.flags], [
        null,
        [CrossPhoneFlags.finishPhoneUnmeasured, FinishTimeFlags.noGun],
      ]);
    });

    test('a finish read before the day\'s gun puts the race of the day first, even from a fast clock', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final mark = _Phone(water, skewMs: 120000)..fix(); // two minutes fast, with satellite time
      mark.store.append(FinishEvents.atMark(fleet: fleet)); // a minute before the gun
      water.pass(60000);
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      mark.pull(pro);
      water.pass(600000);
      mark.store.append(FinishEvents.atMark(fleet: fleet));

      final early = mark.store.readAll().firstWhere((e) => e.kind == FinishKinds.atMark);
      expect(early.deviceTs, greaterThan(gun.deviceTs), reason: 'control: on the raw clocks it came after the gun');
      expect([for (final r in raceTimesOf(mark.store.readAll())) r.gun], [null, gun.ulid]);
    });

    test('the local date, not the UTC one: either side of UTC midnight is one race, with a gun or without', () {
      const otherFleet = '01J8Z0E0000000000000000002';
      water.now = DateTime.utc(2026, 10, 25).millisecondsSinceEpoch - 600000;
      final pro = _Phone(water, skewMs: 0);
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      pro.store.append(FinishEvents.finish(fleet: otherFleet));
      water.pass(1200000);
      pro.store.append(FinishEvents.finish(fleet: fleet));
      pro.store.append(FinishEvents.finish(fleet: otherFleet));

      final events = pro.store.readAll();
      expect([
        for (final f in [fleet, otherFleet])
          for (final r in fleetRaceTimes(events, fleet: f)) [r.gun, r.finishes.length, r.flags],
      ], [
        [gun.ulid, 1, isEmpty],
        [null, 2, [FleetRaceFlags.unreconciled]],
      ]);
    }, skip: DateTime.utc(2026, 10, 25).toLocal().timeZoneOffset == Duration.zero ? 'local time is UTC here' : false);

    test('a gun that went on another local date starts no race for it (#55\'s race rule), and the races are in '
        'date order', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      water.pass(60000);
      pro.store.append(FinishEvents.finish(fleet: fleet)); // that day's race
      water.pass(24 * 3600000);
      final mark = _Phone(water, skewMs: 0)
        ..fix()
        ..pull(pro);
      mark.store.append(FinishEvents.atMark(fleet: fleet));

      expect([for (final r in raceTimesOf(mark.store.readAll())) [r.gun, [for (final f in r.finishes) f.flags]]], [
        [gun.ulid, [isEmpty]],
        [null, [[FinishTimeFlags.noGun]]],
      ], reason: 'the day before\'s race first, then the next day\'s race of the day');
    });

    test('finishes with no gun held are the race of the day, one race per local date', () {
      final mark = _Phone(water, skewMs: 0)..fix();
      mark.store.append(FinishEvents.atMark(fleet: fleet));
      water.pass(24 * 3600000);
      mark.store.append(FinishEvents.atMark(fleet: fleet));

      expect([for (final r in raceTimesOf(mark.store.readAll())) [r.gun, r.finishes.length]], [[null, 1], [null, 1]]);
    });

    test('a recalled gun starts no race: a finish between the recall and the restart has no gun', () {
      final pro = _Phone(water, skewMs: 0)..fix();
      final recalled = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      pro.store.append(StartEvents.generalRecall(fleet: fleet, source: 'manual'));
      final mark = _Phone(water, skewMs: -4000)
        ..fix()
        ..pull(pro);
      water.pass(120000);
      mark.store.append(FinishEvents.atMark(fleet: fleet)); // after the recalled gun, before the restart
      water.pass(180000);
      final gunAt = water.now;
      final gun = pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      mark.pull(pro);
      water.pass(600000);
      mark.store.append(FinishEvents.atMark(fleet: fleet));

      expect([for (final r in raceTimesOf(mark.store.readAll())) [r.gun, elapsedOf(r)]], [
        [null, [null]],
        [gun.ulid, [water.now - gunAt]],
      ], reason: 'the recalled gun (${recalled.ulid}) times nothing');
    });
  });

  group('what a race lists', () {
    test('an undone finish is left out, and a missed one, which has no time', () {
      final pro = _Phone(water, skewMs: 0);
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      water.pass(60000);
      final first = pro.store.append(FinishEvents.finish(fleet: fleet));
      water.pass(1000);
      final second = pro.store.append(FinishEvents.finish(fleet: fleet));
      pro.store.append(FinishEvents.missed(fleet: fleet, afterUlid: first.ulid, beforeUlid: second.ulid));
      water.pass(1000);
      final third = pro.store.append(FinishEvents.finish(fleet: fleet));
      pro.store.append(FinishEvents.undo(third.ulid));

      expect([for (final f in raceTimesOf(pro.store.readAll()).single.finishes) f.ulid], [first.ulid, second.ulid]);
    });

    test('a sail number with a malformed payload, as no phone of this app writes, is passed over, not fatal', () {
      final pro = _Phone(water, skewMs: 0);
      pro.store.append(StartEvents.start(fleet: fleet, source: 'manual'));
      water.pass(60000);
      final finish = pro.store.append(FinishEvents.finish(fleet: fleet));
      pro.store.append(FinishEvents.assignSail(finish.ulid, '101'));
      final other = _Phone(water, skewMs: 0);
      pro.store.insert(EventEnvelope(
        ulid: '01J8${'7'.padLeft(22, '0')}',
        deviceTs: water.now + 1000,
        deviceId: other.store.deviceId,
        seq: 1,
        source: 'tap',
        kind: FinishKinds.sail,
        payloadVersion: 1,
        payload: {'finish': finish.ulid, 'sail': 110},
      ));

      expect(raceTimesOf(pro.store.readAll()).single.finishes.single.sail, '101');
    });

    test('each fleet\'s races: the fleets the day defined in that order, then any other a finish names, then the '
        'single fleet\'s', () {
      const undefined = '01J8Z0E0000000000000000009'; // a fleet no event here defines, as from another phone
      final pro = _Phone(water, skewMs: 0);
      final alpha = pro.store.append(FleetEvents.define('Alpha')).ulid;
      final bravo = pro.store.append(FleetEvents.define('Bravo')).ulid;
      for (final f in [null, undefined, bravo, alpha]) {
        pro.store.append(StartEvents.start(fleet: f, source: 'manual'));
      }
      water.pass(60000);
      // Finished in none of those orders, so neither first-finish order nor the guns' order passes.
      for (final f in [null, undefined, bravo, alpha]) {
        pro.store.append(FinishEvents.finish(fleet: f));
        water.pass(1000);
      }

      expect([for (final r in raceTimesOf(pro.store.readAll())) r.fleet], [alpha, bravo, undefined, null]);
    });
  });
}

/// True time on the water, which every phone's clock reads with its own error. As in clock_offsets_test.
class _Water {
  _Water(this.now);

  int now;

  void pass(int ms) => now += ms;
}

/// One committee phone: its log, its own clock [skewMs] off true time, and the satellite time its
/// location feed reports. As in clock_offsets_test.
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
  void fix({int ageMs = 0}) =>
      location.reportGpsTime(GpsTimeSample(gpsTimeMs: water.now - ageMs, deviceTimeMs: clock - ageMs, uncertaintyMs: 5));

  /// What sync's pull (#64) leaves here: [other]'s own events, each kept as its own text.
  void pull(_Phone other) {
    for (final text in other.store.readCanonical()) {
      if ((jsonDecode(text) as Map)['device_id'] == other.store.deviceId) {
        store.insertPulled('3f6c1a52-8d0e-4b7a-9c21-5e4f0a9b7d13', text);
      }
    }
  }
}
