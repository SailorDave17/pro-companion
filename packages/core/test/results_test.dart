import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/store.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #7 at the domain level, through the real store: a fleet's finishes cut
/// into races by its starts, each boat by sail number or a placeholder, and
/// scored on the phone by the #2 engine. Every expected point here is worked
/// by hand from A4 and A5.2 (low point, DNC = boats entered + 1), never read
/// back from the engine. The screen's half is the app's
/// test/results_screen_test.dart.
void main() {
  late EventStore store;
  late int now;

  setUp(() {
    now = DateTime(2026, 9, 26, 14, 30).millisecondsSinceEpoch;
    store = openStore(tempDbPath(), clock: () => now);
  });

  List<EventEnvelope> log() => store.readAll();

  /// Appends [e] at [now], then moves the clock on a second.
  EventEnvelope at(NewEvent e) {
    final stored = store.append(e);
    now += 1000;
    return stored;
  }

  EventEnvelope gun({String? fleet}) => at(StartEvents.start(fleet: fleet, source: 'manual'));

  /// One finish for [fleet], named [sail] unless it is null.
  EventEnvelope finish(String? sail, {String? fleet}) {
    final f = at(FinishEvents.finish(fleet: fleet));
    if (sail != null) at(FinishEvents.assignSail(f.ulid, sail));
    return f;
  }

  ProvisionalResults results({String? fleet}) => provisionalResults(log(), fleet: fleet);

  /// Whole points from tenths; every case here scores whole points.
  int points(int tenths) {
    expect(tenths % 10, 0, reason: '$tenths tenths is not a whole number of points');
    return tenths ~/ 10;
  }

  /// Each boat's line as [rank, boat, [each race's points], net points].
  List<List<Object>> table(ProvisionalResults r) => [
        for (final s in r.standings)
          [s.rank, s.boat, [for (final race in s.races) points(race.tenths)], points(s.netTenths)],
      ];

  group('criterion 1: per-race points compute on the phone from the tapped finishes', () {
    test('a day with no start logged is one race, scored place for place', () {
      finish('11');
      finish('22');
      finish('33');
      final r = results();
      expect(r.races, 1);
      expect(table(r), [
        [1, '11', [1], 1],
        [2, '22', [2], 2],
        [3, '33', [3], 3],
      ]);
    });

    test('each gun starts a race, and a boat missing from one scores DNC, one more than the boats entered', () {
      gun();
      finish('11');
      finish('22');
      finish('33');
      gun();
      finish('33');
      finish('11');
      final r = results();
      expect(r.races, 2);
      // Race 2: 33 first, 11 second, 22 did not finish it, so DNC = 3 + 1.
      expect(table(r), [
        [1, '11', [1, 2], 3],
        [2, '33', [3, 1], 4],
        [3, '22', [2, 4], 6],
      ]);
      expect(r.standings.last.races.last.code, ScoreCode.dnc);
    });

    test('a recalled gun begins no race; the restart does', () {
      final first = gun();
      at(StartEvents.generalRecall(fleet: null, source: 'manual'));
      final restart = gun();
      finish('11');
      finish('22');
      expect(raceStarts(log(), fleet: null).map((e) => e.ulid), [restart.ulid]);
      expect(raceStarts(log(), fleet: null).map((e) => e.ulid), isNot(contains(first.ulid)));
      expect(results().races, 1);
    });

    test('an undone gun begins no race', () {
      gun();
      finish('11');
      final wrong = gun();
      at(StartEvents.undo(wrong.ulid));
      finish('22');
      final r = results();
      expect(r.races, 1, reason: 'the undone gun split nothing');
      expect(table(r), [
        [1, '11', [1], 1],
        [2, '22', [2], 2],
      ]);
    });

    test('finishes logged before the first gun make a race of their own', () {
      finish('11');
      gun();
      finish('22');
      final r = results();
      expect(r.races, 2);
      // 11 sailed race 1 only and 22 race 2 only: each scores DNC (2 + 1) in
      // the other. Tied on 4 and on A8.1; A8.2 gives it to 22, who won the
      // last race.
      expect(table(r), [
        [1, '22', [3, 1], 4],
        [2, '11', [1, 3], 4],
      ]);
    });

    test('a race started and not yet finished is left out, not refused', () {
      gun();
      finish('11');
      finish('22');
      gun();
      final r = results();
      expect(r.races, 1);
      expect(table(r), [
        [1, '11', [1], 1],
        [2, '22', [2], 2],
      ]);
    });

    test('with nothing finished there is nothing to score', () {
      gun();
      final r = results();
      expect(r.races, 0);
      expect(r.standings, isEmpty);
    });

    test('an undone finish is not scored, and the places behind it close up', () {
      finish('11');
      final wrong = finish('99');
      finish('22');
      at(FinishEvents.undo(wrong.ulid));
      expect(table(results()), [
        [1, '11', [1], 1],
        [2, '22', [2], 2],
      ]);
    });

    test('a missed finish scores in the race of the finish it was placed above, whenever it was logged', () {
      gun();
      finish('11');
      final r1Second = finish('22');
      gun();
      final r2First = finish('33');
      finish('44');
      gun();
      finish('55');
      // Both logged during race 3, long after the races they belong to.
      final m1 = at(FinishEvents.missed(fleet: null, afterUlid: null, beforeUlid: r2First.ulid));
      at(FinishEvents.assignSail(m1.ulid, '66'));
      final m2 = at(FinishEvents.missed(fleet: null, afterUlid: null, beforeUlid: r1Second.ulid));
      at(FinishEvents.assignSail(m2.ulid, '77'));

      final races = racesOf(log(), fleet: null);
      expect([for (final race in races) [for (final e in race) (e.place, e.sail)]], [
        [(1, '11'), (2, '77'), (3, '22')],
        [(1, '66'), (2, '33'), (3, '44')],
        [(1, '55')],
      ]);
    });

    // A gun forgotten and tapped late, then given its real time (#25): the
    // corrected time is where race 2 starts, not the moment of the tap.
    test('a late gun whose time was corrected splits the races where it really went', () {
      gun();
      finish('11');
      finish('22');
      finish('33');
      final realGun = now;
      now += 1000;
      finish('33');
      finish('11');
      final late = gun();
      expect(results().duplicates, isNotEmpty, reason: 'control: by its tapped time, race 2 folds into race 1');

      at(StartEvents.correctTime(late.ulid, time: realGun));
      final r = results();
      expect(r.races, 2);
      expect(table(r), [
        [1, '11', [1, 2], 3],
        [2, '33', [3, 1], 4],
        [3, '22', [2, 4], 6],
      ]);
    });

    test('a gun tapped early by mistake and corrected later keeps race 1\'s last finishers in race 1', () {
      gun();
      finish('11');
      finish('22');
      final early = gun();
      finish('33');
      final realGun = now;
      now += 1000;
      finish('22');
      finish('11');
      at(StartEvents.correctTime(early.ulid, time: realGun));
      // Race 1: 11, 22, 33. Race 2: 22, 11, and 33 did not finish it: DNC = 3 + 1.
      // 22 and 11 tie on 3 and on A8.1; A8.2 gives it to 22, who won race 2.
      expect(table(results()), [
        [1, '22', [2, 1], 3],
        [2, '11', [1, 2], 3],
        [3, '33', [3, 4], 7],
      ]);
    });

    test('a missed finish keeps the race of the finish it was placed above after that finish is undone', () {
      gun();
      final first = finish('11');
      final anchor = finish('22');
      gun();
      finish('33');
      // Placed, and the finish below her undone, while race 2 is sailing:
      // neither her own time nor the next finish in the list is race 1.
      final m = at(FinishEvents.missed(fleet: null, afterUlid: first.ulid, beforeUlid: anchor.ulid));
      at(FinishEvents.assignSail(m.ulid, '55'));
      at(FinishEvents.undo(anchor.ulid));
      expect([for (final race in racesOf(log(), fleet: null)) [for (final e in race) (e.place, e.sail)]], [
        [(1, '11'), (2, '55')],
        [(1, '33')],
      ]);
    });

    test('another fleet\'s guns and finishes never enter a fleet\'s races', () {
      final lasers = at(FleetEvents.define('Lasers')).ulid;
      final opti = at(FleetEvents.define('Optimists')).ulid;
      gun(fleet: lasers);
      finish('11', fleet: lasers);
      gun(fleet: opti);
      finish('501', fleet: opti);
      finish('22', fleet: lasers);
      gun(fleet: opti);
      finish('502', fleet: opti);

      final l = results(fleet: lasers);
      expect(l.races, 1, reason: "the Optimists' second gun does not split the Lasers' race");
      expect(table(l), [
        [1, '11', [1], 1],
        [2, '22', [2], 2],
      ]);
      final o = results(fleet: opti);
      expect(o.races, 2);
      expect(o.standings.map((s) => s.boat), unorderedEquals(['501', '502']));
      expect(results().races, 0, reason: 'nothing was logged without a fleet');
    });
  });

  group('a finish with no sail number (owner decision on #7)', () {
    test('keeps its place under a placeholder, so the boats behind it score right', () {
      finish('11');
      final unnamed = finish(null);
      finish('33');
      final r = results();
      final placeholder = placeholderId(1, 2);
      expect(r.unnamed, {placeholder: (race: 1, place: 2)});
      expect(table(r), [
        [1, '11', [1], 1],
        [2, placeholder, [2], 2],
        [3, '33', [3], 3],
      ]);
      expect(racesOf(log(), fleet: null).single[1].ulid, unnamed.ulid);
    });

    test('counts as a boat entered, so a DNC scores one more for each placeholder', () {
      gun();
      finish('11');
      finish(null);
      gun();
      finish('11');
      final r = results();
      // Entered: 11 and the placeholder, so DNC = 2 + 1.
      final line = r.standings.singleWhere((s) => s.boat == placeholderId(1, 2));
      expect([for (final race in line.races) race.tenths], [20, 30]);
      expect(line.races.last.code, ScoreCode.dnc);
    });

    test('two in one race are two boats, each in her own place', () {
      finish('11');
      finish(null);
      finish(null);
      final r = results();
      expect(r.unnamed.values, [(race: 1, place: 2), (race: 1, place: 3)]);
      expect(r.standings.map((s) => s.boat).toSet(), hasLength(3), reason: 'three boats, not two');
      expect([for (final s in r.standings) points(s.netTenths)], [1, 2, 3]);
    });

    test('one in each of two races are two boats, each scoring DNC in the other race', () {
      gun();
      finish('11');
      finish(null);
      gun();
      finish('11');
      finish(null);
      final r = results();
      expect(r.unnamed, hasLength(2));
      // Entered: 11 and two placeholders, so DNC = 3 + 1.
      List<int> racePoints(int race) => [
            for (final s in r.standings)
              if (r.unnamed[s.boat]?.race == race) ...[for (final x in s.races) points(x.tenths)],
          ];
      expect(racePoints(1), [2, 4]);
      expect(racePoints(2), [4, 2]);
    });

    test('is scored by its number once named, and the placeholder is gone', () {
      finish('11');
      final later = finish(null);
      at(FinishEvents.assignSail(later.ulid, '22'));
      final r = results();
      expect(r.unnamed, isEmpty);
      expect(r.standings.map((s) => s.boat), ['11', '22']);
    });
  });

  group('a missed finish placed between two races (owner decision on #7)', () {
    test('is scored in the later race, and named so the PRO can check her', () {
      gun();
      finish('11');
      final lastOfRace1 = finish('22');
      gun();
      final firstOfRace2 = finish('33');
      finish('44');
      final m = at(FinishEvents.missed(fleet: null, afterUlid: lastOfRace1.ulid, beforeUlid: firstOfRace2.ulid));
      at(FinishEvents.assignSail(m.ulid, '55'));
      final r = results();
      expect(r.betweenRaces, [(boat: '55', race: 2, place: 1)]);
      expect(racesOf(log(), fleet: null)[1].first.sail, '55');
    });

    test('is not flagged when both finishes around her are in one race', () {
      gun();
      final a = finish('11');
      final b = finish('22');
      gun();
      finish('33');
      final m = at(FinishEvents.missed(fleet: null, afterUlid: a.ulid, beforeUlid: b.ulid));
      at(FinishEvents.assignSail(m.ulid, '55'));
      expect(results().betweenRaces, isEmpty);
    });

    test('is not flagged when placed first, with nothing above her', () {
      gun();
      final a = finish('11');
      final m = at(FinishEvents.missed(fleet: null, afterUlid: null, beforeUlid: a.ulid));
      at(FinishEvents.assignSail(m.ulid, '55'));
      expect(results().betweenRaces, isEmpty);
    });
  });

  group('a sail number on two finishes in one race', () {
    test('stops the scoring and names the race and the number', () {
      finish('11');
      finish('22');
      finish('11');
      final r = results();
      expect(r.duplicates, [(race: 1, sail: '11')]);
      expect(r.standings, isEmpty);
    });

    test('three times in one race is named once', () {
      finish('11');
      finish('11');
      finish('11');
      expect(results().duplicates, [(race: 1, sail: '11')]);
    });

    test('names the race it is in', () {
      gun();
      finish('11');
      gun();
      finish('22');
      finish('22');
      expect(results().duplicates, [(race: 2, sail: '22')]);
    });

    test('in two different races is one boat sailing both', () {
      gun();
      finish('11');
      gun();
      finish('11');
      final r = results();
      expect(r.duplicates, isEmpty);
      expect(table(r), [
        [1, '11', [1, 1], 2],
      ]);
    });
  });

  group('the discard count the PRO sets (owner decision on #7)', () {
    void threeRaces({String? fleet}) {
      gun(fleet: fleet);
      finish('11', fleet: fleet);
      finish('22', fleet: fleet);
      gun(fleet: fleet);
      finish('22', fleet: fleet);
      finish('11', fleet: fleet);
      gun(fleet: fleet);
      finish('22', fleet: fleet);
      finish('11', fleet: fleet);
    }

    test('is none until one is set', () {
      threeRaces();
      final r = results();
      expect(r.discards, 0);
      // 11: 1 + 2 + 2 = 5; 22: 2 + 1 + 1 = 4.
      expect(table(r), [
        [1, '22', [2, 1, 1], 4],
        [2, '11', [1, 2, 2], 5],
      ]);
    });

    test('is a new event carrying the fleet and the count', () {
      final e = at(ResultsEvents.discards(fleet: null, count: 1));
      expect(e.kind, ResultsKinds.discards);
      expect(e.source, 'tap');
      expect(e.payload, {'fleet': null, 'count': 1});
    });

    test('excludes each boat\'s worst score, the earliest of equal worst (A2.1)', () {
      threeRaces();
      at(ResultsEvents.discards(fleet: null, count: 1));
      final r = results();
      expect(r.discards, 1);
      // 11 drops race 2's 2 (the earliest of two 2s): 1 + 2 = 3. 22 drops race 1's 2: 1 + 1 = 2.
      final eleven = r.standings.singleWhere((s) => s.boat == '11');
      expect([for (final race in eleven.races) race.excluded], [false, true, false]);
      expect(table(r), [
        [1, '22', [2, 1, 1], 2],
        [2, '11', [1, 2, 2], 3],
      ]);
    });

    test('the latest count wins', () {
      threeRaces();
      at(ResultsEvents.discards(fleet: null, count: 2));
      at(ResultsEvents.discards(fleet: null, count: 1));
      expect(discardsSet(log(), fleet: null), 1);
      expect(discardsSet(log().reversed, fleet: null), 1, reason: 'by when it was set, not by list order');
      expect(results().discards, 1);
    });

    test('is held to one fewer than the races scored, so a boat always keeps a score', () {
      threeRaces();
      at(ResultsEvents.discards(fleet: null, count: 5));
      expect(results().discards, 2);
    });

    test("is the fleet's own: another fleet's count never applies", () {
      final lasers = at(FleetEvents.define('Lasers')).ulid;
      final opti = at(FleetEvents.define('Optimists')).ulid;
      threeRaces(fleet: lasers);
      threeRaces(fleet: opti);
      at(ResultsEvents.discards(fleet: opti, count: 1));
      expect(results(fleet: lasers).discards, 0);
      expect(results(fleet: opti).discards, 1);
    });
  });
}
