import 'dart:convert';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #54 in the core, through the real store: a mark-boat phone's rounding
/// names the station's mark, the boat's lap there, the fleet and the sail
/// number. A boat tapped unidentified is named later by a correction event,
/// and the original is never edited. The app's half is
/// test/rounding_screen_test.dart.
void main() {
  /// 2024-09-24 15:00 UTC: mid-morning on the owner's machines and midday on
  /// CI's, so a day's events never straddle a local midnight in either.
  const start = 1727190000000;
  const day = 24 * 60 * 60 * 1000;
  late int t;
  late EventStore store;

  /// A mark boat's phone at [mark]: the role pick, then the station pick.
  EventStore stationed(String mark, {int seed = 1}) {
    final s = openStore(tempDbPath(), clock: () => t += 1000, seed: seed);
    s.append(RoleEvents.assign(Roles.markBoat));
    s.append(StationEvents.select(mark));
    return s;
  }

  Map<String, Object?> canonical(EventEnvelope e) =>
      jsonDecode(store.readCanonical().singleWhere((c) => (jsonDecode(c) as Map)['ulid'] == e.ulid))
          as Map<String, Object?>;

  /// The PRO's gun for [fleet], fired on another phone at [at] and pulled down
  /// by sync: what a mark-boat phone learns a race from (#64).
  var pulled = 0;
  EventEnvelope gun(String? fleet, int at, {String kind = StartKinds.start, String? corrects}) => EventEnvelope(
        ulid: '01J9${(++pulled).toString().padLeft(22, '0')}',
        deviceTs: at,
        deviceId: '01J9PR0PH0NE00000000000000',
        seq: pulled,
        source: 'manual',
        kind: kind,
        payloadVersion: 1,
        correctsUlid: corrects,
        payload: {'fleet': fleet},
      );

  EventEnvelope round(String? sail, {String? fleet = 'f1'}) =>
      store.append(RoundingEvents.rounding(fleet: fleet, sail: sail));

  List<EventEnvelope> roundingsOf(EventStore s) => [for (final e in s.readAll()) if (e.kind == RoundingKinds.rounding) e];

  setUp(() {
    t = start;
    pulled = 0;
    store = stationed(StandardMarks.windward);
  });

  group("criterion 1: a rounding names the station's mark, the lap, the fleet and the sail number", () {
    test('as stored, in the payload and in the canonical text, with the role and the device', () {
      final e = round('887');
      expect([e.kind, e.source, e.role, e.deviceId], [RoundingKinds.rounding, 'tap', Roles.markBoat, store.deviceId]);
      const payload = {'fleet': 'f1', 'sail': '887', 'mark': 'windward', 'race': null, 'lap': 1};
      expect(e.payload, payload);
      expect(canonical(e)['payload'], payload, reason: 'what the chain hashes and shore receives');
    });

    test('a single-fleet day names no fleet', () {
      expect(round('887', fleet: null).payload, {'fleet': null, 'sail': '887', 'mark': 'windward', 'race': null, 'lap': 1});
    });

    test('an unidentified boat is a rounding with no sail number and no lap', () {
      final e = round(null);
      expect([e.payload['sail'], e.payload['lap'], markOf(e)], [null, null, StandardMarks.windward]);
    });

    test('the lap counts the boat at this mark, for this fleet: lap 2 on her second, lap 1 for another boat', () {
      expect(round('887').payload['lap'], 1);
      expect(round('412').payload['lap'], 1);
      expect(round('887').payload['lap'], 2);
      expect(round('887', fleet: 'f2').payload['lap'], 1, reason: "another fleet's 887 is another boat");
      expect(round('412').payload['lap'], 2);
      expect(round('887').payload['lap'], 3);
    });

    test('a new station starts its own count, and returning to the old one picks it up again', () {
      round('887');
      round('887');
      store.append(StationEvents.select(StandardMarks.leeward));
      expect(round('887').payload, containsPair('lap', 1));
      expect(markOf(roundingsOf(store).last), StandardMarks.leeward);
      store.append(StationEvents.select(StandardMarks.windward));
      expect(round('887').payload['lap'], 3);
    });

    test('an undone rounding is not counted', () {
      round('887');
      final second = round('887');
      store.append(RoundingEvents.undo(second.ulid));
      expect(round('887').payload['lap'], 2);
    });

    test('a boat named later counts: her next rounding is her second', () {
      final unknown = round(null);
      store.append(RoundingEvents.assignSail(unknown.ulid, '887'));
      expect(round('887').payload['lap'], 2);
    });

    test('a corrected sail number moves the rounding to the boat it now names', () {
      final wrong = round('878');
      store.append(RoundingEvents.assignSail(wrong.ulid, '887'));
      expect(round('887').payload['lap'], 2);
      expect(round('878').payload['lap'], 1);
    });

    test('the gun the phone knows names the race, and the lap counts from it (owner decision at pickup)', () {
      round('887');
      round('887');
      final g = gun('f1', t + 500);
      store.insert(g);
      final after = round('887');
      expect([after.payload['race'], after.payload['lap']], [g.ulid, 1],
          reason: 'her two roundings before the gun were another race');
      expect(round('887').payload['lap'], 2);
    });

    test("a rounding logged before the phone learned of the race's gun still counts once it is known", () {
      final g = gun('f1', t + 500);
      t += 2000; // the gun goes; the phone has not pulled it yet
      round('887');
      store.insert(g);
      final second = round('887');
      expect([second.payload['race'], second.payload['lap']], [g.ulid, 2]);
    });

    test("another fleet's gun, a recalled gun and yesterday's gun name no race for this fleet", () {
      store.insert(gun('f2', t + 1));
      expect(round('887').payload['race'], isNull, reason: "another fleet's gun");
      final recalled = gun('f1', t + 1);
      store.insert(recalled);
      store.insert(gun('f1', t + 2, kind: StartKinds.generalRecall));
      expect(round('412').payload['race'], isNull, reason: 'a recalled gun starts no race');

      final next = stationed(StandardMarks.windward, seed: 2);
      next.insert(gun('f1', t - day));
      expect(next.append(RoundingEvents.rounding(fleet: 'f1', sail: '887')).payload['race'], isNull,
          reason: "yesterday's gun");
    });

    test('with no gun known, a second race on the same day counts on from the first (the decided limit)', () {
      round('887');
      t += 60 * 60 * 1000; // an hour later, the next race, no gun on this phone
      expect(round('887').payload['lap'], 2);
      t += day; // the next day starts again
      expect(round('887').payload['lap'], 1);
    });

    test('a restart keeps the count, read back from the log', () {
      final path = tempDbPath();
      final first = openStore(path, clock: () => t += 1000);
      first.append(RoleEvents.assign(Roles.markBoat));
      first.append(StationEvents.select(StandardMarks.offset));
      first.append(RoundingEvents.rounding(fleet: null, sail: '887'));
      first.insert(gun(null, t - 10 * 60 * 1000)); // a gun before it, pulled after
      first.close();
      final again = openStore(path, clock: () => t += 1000);
      final e = again.append(RoundingEvents.rounding(fleet: null, sail: '887'));
      expect([markOf(e), e.payload['lap'], e.payload['race']], [StandardMarks.offset, 2, isNotNull],
          reason: 'the station, the earlier rounding and the pulled gun were all read back');
    });

    test('a rounding that names its own race or lap keeps it, with a gun the phone would have named', () {
      final g = gun('f1', t - 60 * 1000);
      store.insert(g);
      expect(round('412').payload['race'], g.ulid, reason: 'the control: unnamed, the gun names the race');
      final e = store.append(const NewEvent(
        kind: RoundingKinds.rounding,
        source: 'race-timer',
        payload: {'fleet': 'f1', 'sail': '887', 'race': null, 'lap': 4},
      ));
      expect([e.payload['race'], e.payload['lap']], [null, 4]);
    });

    test("a gun's corrected time, pulled after a rounding the phone logged before knowing the gun, "
        'decides whether that rounding is in the race (#54 review)', () {
      // The phone taps 887 at a time between the gun as tapped and the gun as
      // corrected, knowing no gun. Then it pulls the gun and its correction.
      final g = gun('f1', t + 1000);
      t += 3000;
      round('887'); // after the gun as tapped, before the gun as corrected
      store.insert(g);
      store.insert(EventEnvelope(
        ulid: '01J9${(++pulled).toString().padLeft(22, '0')}',
        deviceTs: t + 4000,
        deviceId: g.deviceId,
        seq: pulled,
        source: 'manual',
        kind: StartKinds.timeCorrected,
        payloadVersion: 1,
        correctsUlid: g.ulid,
        payload: {'time': t + 5000},
      ));
      expect(round('887').payload['lap'], 1, reason: 'the earlier rounding came before the corrected gun');
    });

    test('the first rounding in a race brings the clock offset its phone joins it with (#55)', () {
      final g = gun('f1', t - 60 * 1000);
      store.insert(g);
      round('887');
      round('412');
      final kinds = [for (final e in store.readAll()) if (e.deviceId == store.deviceId) e.kind];
      expect(kinds, [RoleKinds.assigned, StationKinds.selected, ClockKinds.offset, RoundingKinds.rounding, RoundingKinds.rounding],
          reason: 'one offset, just before the first rounding, and none before the second');
      final offset = store.readAll().singleWhere((e) => e.kind == ClockKinds.offset);
      expect([offset.payload['fleet'], offset.payload['race']], ['f1', g.ulid]);
    });

    test('over the core interface, as the UI reaches it', () async {
      final core = await spawnCore(tempDbPath());
      addTearDown(core.close);
      await core.append(RoleEvents.assign(Roles.markBoat));
      await core.append(StationEvents.select(StandardMarks.gateLeft));
      await core.append(RoundingEvents.rounding(fleet: null, sail: '887'));
      final e = await core.append(RoundingEvents.rounding(fleet: null, sail: '887'));
      expect(e.payload, {'fleet': null, 'sail': '887', 'mark': 'gate_left', 'race': null, 'lap': 2});
      expect((await core.readAll()).last.toWire()['payload'], e.payload);
    });

    test('and the fake core stamps the same way, so widget tests see what the real core writes', () async {
      final fake = FakeCore(clock: () => t += 1000);
      await fake.append(RoleEvents.assign(Roles.markBoat));
      await fake.append(StationEvents.select(StandardMarks.gateLeft));
      final first = await fake.append(RoundingEvents.rounding(fleet: 'f1', sail: '887'));
      await fake.append(RoundingEvents.undo(first.ulid));
      await fake.append(RoundingEvents.rounding(fleet: 'f1', sail: '887'));
      final third = await fake.append(RoundingEvents.rounding(fleet: 'f1', sail: '887'));
      expect(third.payload, {'fleet': 'f1', 'sail': '887', 'mark': 'gate_left', 'race': null, 'lap': 2});
    });
  });

  group('criterion 2: a sail number attached later is a correction event, and the original is never edited', () {
    test('the correction names the rounding; the rounding is stored exactly as tapped', () {
      final unknown = round(null);
      final before = canonical(unknown);
      final named = store.append(RoundingEvents.assignSail(unknown.ulid, '887'));
      expect([named.kind, named.correctsUlid, named.payload['sail']], [RoundingKinds.sail, unknown.ulid, '887']);
      expect(canonical(unknown), before, reason: 'append-only: the original text is unchanged');
      expect(roundingsAt(store.readAll(), fleet: 'f1', mark: 'windward', day: t).single.sail, '887');
    });

    test('the latest sail number wins, and an empty one names nobody', () {
      final r = round(null);
      store.append(RoundingEvents.assignSail(r.ulid, '878'));
      store.append(RoundingEvents.assignSail(r.ulid, '887'));
      expect(roundingsAt(store.readAll(), fleet: 'f1', mark: 'windward', day: t).single.sail, '887');
      final other = round(null);
      store.append(RoundingEvents.assignSail(other.ulid, ''));
      expect(roundingsAt(store.readAll(), fleet: 'f1', mark: 'windward', day: t).last.sail, isNull);
    });
  });

  group('criterion 3: ten roundings tapped in 10 s are stored in tap order', () {
    test('ten taps a second apart: ten roundings, each committed as it returns, read back in tap order', () {
      final sails = ['887', '412', '1033', '5', '77', '2207', '3150', '919', '64', '12'];
      final tapped = [for (final s in sails) round(s)];
      expect([for (final e in roundingsOf(store)) e.ulid], [for (final e in tapped) e.ulid]);
      expect(roundingsAt(store.readAll(), fleet: 'f1', mark: 'windward', day: t).map((r) => r.sail), sails);
      expect(tapped.last.deviceTs - tapped.first.deviceTs, lessThanOrEqualTo(10000));
    });

    test('ten in one millisecond keep the order they were tapped in (#145)', () {
      final frozen = openStore(tempDbPath(), clock: () => start, seed: 7);
      frozen.append(RoleEvents.assign(Roles.markBoat));
      frozen.append(StationEvents.select(StandardMarks.windward));
      final sails = [for (var i = 1; i <= 10; i++) '$i'];
      for (final s in sails) {
        frozen.append(RoundingEvents.rounding(fleet: null, sail: s));
      }
      expect(roundingsAt(frozen.readAll(), fleet: null, mark: 'windward', day: start).map((r) => r.sail), sails);
    });
  });

  group('criterion 5: UNDO LAST takes back the latest rounding here with a correction event', () {
    test('the latest not undone, at this mark and fleet, on this day', () {
      final first = round('887');
      final second = round('412');
      expect(lastUndoableRounding(store.readAll(), fleet: 'f1', mark: 'windward', day: t)?.ulid, second.ulid);
      final undo = store.append(RoundingEvents.undo(second.ulid));
      expect([undo.kind, undo.correctsUlid], [RoundingKinds.undo, second.ulid]);
      expect(lastUndoableRounding(store.readAll(), fleet: 'f1', mark: 'windward', day: t)?.ulid, first.ulid);
      expect(roundingsAt(store.readAll(), fleet: 'f1', mark: 'windward', day: t).map((r) => r.sail), ['887']);
      expect(lastUndoableRounding(store.readAll(), fleet: 'f2', mark: 'windward', day: t), isNull);
      expect(lastUndoableRounding(store.readAll(), fleet: 'f1', mark: 'leeward', day: t), isNull);
      expect(lastUndoableRounding(store.readAll(), fleet: 'f1', mark: 'windward', day: t + day), isNull);
    });
  });

  test("after the phone's clock is set back, UNDO LAST takes the rounding tapped last, and the list keeps tap "
      "order (#54's review)", () {
    final first = round('412');
    t -= 5 * 60 * 1000; // the clock is set back five minutes
    store.recordClockChanged();
    final second = round('887');
    expect(second.deviceTs, lessThan(first.deviceTs), reason: 'the precondition: by the clock, 887 came first');
    expect(lastUndoableRounding(store.readAll(), fleet: 'f1', mark: 'windward', day: t)?.ulid, second.ulid);
    expect(roundingsAt(store.readAll(), fleet: 'f1', mark: 'windward', day: t).map((r) => r.sail), ['412', '887']);
  });

  test("after a clock set back, the sail number named last wins, and the boats offered keep tap order "
      "(#54's second review)", () {
    final r = round(null);
    store.append(RoundingEvents.assignSail(r.ulid, '878'));
    round('412');
    t -= 5 * 60 * 1000;
    store.recordClockChanged();
    store.append(RoundingEvents.assignSail(r.ulid, '887')); // named last, stamped earliest
    round('5');
    expect(roundingsAt(store.readAll(), fleet: 'f1', mark: 'windward', day: t).first.sail, '887');
    expect(knownRoundingSails(store.readAll(), fleet: 'f1', day: t), ['887', '412', '5'],
        reason: 'in the order each was last logged: by the clock, 5 would come first');
  });

  group('the boats the rounding screen offers (owner decision at pickup)', () {
    test("this fleet's boats today, from roundings and finishes at a mark, in the order each was last logged", () {
      round('887');
      round('412');
      round('1033');
      round('887'); // her second lap puts her last
      round('5', fleet: 'f2');
      final finish = store.append(FinishEvents.atMark(fleet: 'f1'));
      store.append(FinishEvents.assignSail(finish.ulid, '2207'));
      expect(knownRoundingSails(store.readAll(), fleet: 'f1', day: t), ['412', '1033', '887', '2207']);
      expect(knownRoundingSails(store.readAll(), fleet: 'f2', day: t), ['5']);
      expect(knownRoundingSails(store.readAll(), fleet: 'f1', day: t + day), isEmpty, reason: "yesterday's boats");
    });

    test('an undone rounding, an unnamed one and a corrected number are not offered', () {
      final undone = round('887');
      store.append(RoundingEvents.undo(undone.ulid));
      round(null);
      final wrong = round('878');
      store.append(RoundingEvents.assignSail(wrong.ulid, '412'));
      final finish = store.append(FinishEvents.atMark(fleet: 'f1'));
      store.append(FinishEvents.assignSail(finish.ulid, '9'));
      store.append(FinishEvents.undo(finish.ulid));
      expect(knownRoundingSails(store.readAll(), fleet: 'f1', day: t), ['412']);
    });
  });

  test('every rounding kind is in the set the log can hold', () {
    expect(EventKinds.all, containsAll(RoundingKinds.all));
  });
}
