import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/ui/race_time.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';
import 'support/revoked.dart';
import 'support/roles.dart';

/// #54 on the app, driven against the fake core: the mark-boat home's
/// ROUNDINGS opens the rounding screen, where a known boat is one tap, an
/// unidentified one is UNKNOWN and is named later from the list, and a boat
/// not yet seen is typed in. The core's half is
/// packages/core/test/roundings_test.dart.
void main() {
  late _Day day;
  late FakeConfirmationDevice device;
  late _Popups popups;

  final roundings = find.byKey(const ValueKey('roundings'));
  final unknown = find.byKey(const ValueKey('rounding-unknown'));
  final newBoat = find.byKey(const ValueKey('rounding-type'));
  final undoLast = find.byKey(const ValueKey('rounding-undo-last'));
  Finder boat(String sail) => find.byKey(ValueKey('rounding-boat-$sail'));
  Finder fleetBoat(String fleet, String sail) => find.byKey(ValueKey('rounding-boat-$fleet-$sail'));
  Finder sailButton(String ulid) => find.byKey(ValueKey('rounding-sail-$ulid'));
  Finder row(String ulid) => find.byKey(ValueKey('rounding-$ulid'));

  setUp(() {
    day = _Day();
    device = FakeConfirmationDevice();
    popups = _Popups();
  });

  Widget app({double textScale = 1, _Day? on, NavigatorObserver? observer}) {
    final d = on ?? day;
    return MediaQuery.withClampedTextScaling(
      minScaleFactor: textScale,
      maxScaleFactor: textScale,
      child: ProCompanionApp(
        core: d.core,
        confirmation: ConfirmationService(device),
        navigatorObservers: [observer ?? popups],
        clock: () => d.now,
      ),
    );
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  Future<void> openRoundings(WidgetTester tester, {double textScale = 1}) async {
    setPhoneSize(tester);
    await tester.pumpWidget(app(textScale: textScale));
    await tester.pumpAndSettle();
    await tap(tester, roundings);
  }

  Future<void> type(WidgetTester tester, String digits) async {
    for (final d in digits.split('')) {
      await tap(tester, find.byKey(ValueKey('key-$d')));
    }
  }

  /// What the app appended: everything after the seeded day, less the clock
  /// offset the core appends itself before a race's first rounding (#55).
  Future<List<EventEnvelope>> appended(WidgetTester tester) async => [
        for (final e in (await tester.runAsync(day.core.readAll))!)
          if (!day.seeded.contains(e.ulid) && e.kind != ClockKinds.offset) e,
      ];

  bool enabled(WidgetTester tester, Finder f) => tester.widget<ButtonStyleButton>(f).onPressed != null;
  String label(WidgetTester tester, Finder f) =>
      tester.widget<Text>(find.descendant(of: f, matching: find.byType(Text))).data!;

  group("criterion 1: a tap logs a rounding with the station's mark, the lap, the fleet and the sail", () {
    testWidgets('ROUNDINGS is off until the phone has a station', (tester) async {
      setPhoneSize(tester);
      await tester.pumpWidget(app(on: _Day(station: false)));
      await tester.pumpAndSettle();
      expect(enabled(tester, roundings), isFalse);
    });

    testWidgets('a known boat: ROUNDINGS, then her number - two taps, one rounding', (tester) async {
      day.rounding('887');
      day.rounding('412');
      await openRoundings(tester);
      expect(await appended(tester), isEmpty, reason: 'opening the screen logs nothing');
      await tap(tester, boat('887'));
      final logged = await appended(tester);
      expect(logged, hasLength(1));
      expect([logged.single.kind, logged.single.payload],
          [RoundingKinds.rounding, {'fleet': null, 'sail': '887', 'mark': 'windward', 'race': null, 'lap': 2}]);
      expect(row(logged.single.ulid), findsOneWidget);
    });

    testWidgets('UNKNOWN logs a boat with no number and no lap', (tester) async {
      await openRoundings(tester);
      await tap(tester, unknown);
      final logged = (await appended(tester)).single;
      expect([logged.payload['sail'], logged.payload['lap'], logged.payload['mark']], [null, null, 'windward']);
      expect(label(tester, sailButton(logged.ulid)), 'Sail #');
    });

    testWidgets('NEW BOAT: the number typed is a rounding, and she joins the end of the grid', (tester) async {
      day.rounding('887');
      await openRoundings(tester);
      await tap(tester, newBoat);
      expect(find.text('New boat'), findsOneWidget);
      await type(tester, '1033');
      await tap(tester, find.byKey(const ValueKey('keypad-save')));
      final logged = (await appended(tester)).single;
      expect([logged.payload['sail'], logged.payload['lap']], ['1033', 1]);
      // The known boats' section, three to a row: 887, then 1033 beside her.
      expect(tester.getTopLeft(boat('1033')).dy, tester.getTopLeft(boat('887')).dy);
      expect(tester.getTopLeft(boat('1033')).dx, greaterThan(tester.getTopLeft(boat('887')).dx));
    });

    testWidgets("the PRO's fleets, pulled down by sync, name the fleet a rounding carries (review escalation)",
        (tester) async {
      // The mark-boat phone names no fleets of its own: the PRO's phone does.
      final lasers = day.pulledFleet('Lasers');
      final four20s = day.pulledFleet('420s');
      day.rounding('887', fleet: lasers);
      day.rounding('5', fleet: four20s);
      await openRoundings(tester);
      expect(find.byKey(ValueKey('rounding-fleet-$lasers')), findsOneWidget, reason: 'the fleet row is there');
      expect(find.text('Roundings at Windward · 420s · 1'), findsOneWidget,
          reason: 'it opens on the fleet last rounded here');

      // Every fleet's known boat is one tap from here, logged with her own fleet.
      await tap(tester, fleetBoat(lasers, '887'));
      expect((await appended(tester)).single.payload['fleet'], lasers);
      await tap(tester, fleetBoat(four20s, '5'));
      expect((await appended(tester)).last.payload['fleet'], four20s);

      // UNKNOWN is for the fleet the row shows.
      await tap(tester, find.byKey(ValueKey('rounding-fleet-$lasers')));
      await tap(tester, unknown);
      expect((await appended(tester)).last.payload, containsPair('fleet', lasers));
    });

    testWidgets("a tap on another fleet's boat shows her, and UNDO LAST takes her back, not the fleet picked "
        "(#54's second review)", (tester) async {
      final lasers = day.pulledFleet('Lasers');
      final four20s = day.pulledFleet('420s');
      day.rounding('887', fleet: lasers);
      day.rounding('5', fleet: four20s);
      await openRoundings(tester);
      await tap(tester, find.byKey(ValueKey('rounding-fleet-$four20s'))); // the 420s, picked
      await tap(tester, fleetBoat(lasers, '887')); // a Laser, tapped
      final tapped = (await appended(tester)).single;
      expect(find.text('Roundings at Windward · Lasers · 2'), findsOneWidget, reason: 'the row follows the tap');
      expect(row(tapped.ulid), findsOneWidget);
      await tap(tester, undoLast);
      final undo = (await appended(tester)).last;
      expect([undo.kind, undo.correctsUlid], [RoundingKinds.undo, tapped.ulid]);
    });

    testWidgets("a boat typed in never moves a section below it (#54's second review)", (tester) async {
      final lasers = day.pulledFleet('Lasers');
      final four20s = day.pulledFleet('420s');
      for (final s in ['412', '887', '1033']) {
        day.rounding(s, fleet: lasers); // a full row of three
      }
      day.rounding('5', fleet: four20s);
      await openRoundings(tester);
      await tap(tester, find.byKey(ValueKey('rounding-fleet-$lasers')));
      final before = tester.getRect(fleetBoat(four20s, '5'));
      await tap(tester, newBoat);
      await type(tester, '1234');
      await tap(tester, find.byKey(const ValueKey('keypad-save')));
      expect(tester.getRect(fleetBoat(four20s, '5')), before, reason: 'the 420s did not move');
      expect(find.text('Lasers (new)'), findsOneWidget, reason: 'the new Laser is in a section of her own, at the end');
      expect(tester.getTopLeft(fleetBoat(lasers, '1234')).dy, greaterThan(before.top));
    });

    testWidgets("only the day's fleets are offered, and boats with no fleet have a heading (#54's second review)",
        (tester) async {
      final yesterday = day.pulledFleet('Lasers', at: day.now - 24 * 60 * 60 * 1000);
      final optis = day.pulledFleet('Optis');
      day.rounding('412'); // logged with no fleet, before the fleets came
      day.rounding('7', fleet: optis);
      await openRoundings(tester);
      expect(find.byKey(ValueKey('rounding-fleet-$optis')), findsOneWidget);
      expect(find.byKey(ValueKey('rounding-fleet-$yesterday')), findsNothing, reason: "yesterday's fleet");
      expect(find.text('No fleet'), findsOneWidget);
      expect(tester.getTopLeft(find.text('No fleet')).dy, lessThan(tester.getTopLeft(boat('412')).dy));
    });

    testWidgets("a boat of a fleet the row does not show is still 2 taps from the home (#54's review)",
        (tester) async {
      final lasers = day.pulledFleet('Lasers');
      final four20s = day.pulledFleet('420s');
      day.rounding('887', fleet: lasers);
      day.rounding('5', fleet: four20s); // the screen opens on the 420s
      setPhoneSize(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(roundings);
      await tester.pumpAndSettle();
      await tester.ensureVisible(fleetBoat(lasers, '887'));
      await tester.pumpAndSettle();
      await tester.tap(fleetBoat(lasers, '887'));
      await tester.pumpAndSettle();
      final logged = (await appended(tester)).single;
      expect([logged.payload['sail'], logged.payload['fleet']], ['887', lasers], reason: 'two taps: ROUNDINGS, then 887');
    });
  });

  group('criterion 2: an unidentified boat is named later by a correction event', () {
    testWidgets("the row's Sail #, the number, SAVE: one rounding.sail naming the rounding", (tester) async {
      await openRoundings(tester);
      await tap(tester, unknown);
      final rounding = (await appended(tester)).single;
      await tap(tester, sailButton(rounding.ulid));
      expect(find.textContaining('Sail for #1'), findsOneWidget);
      await type(tester, '887');
      await tap(tester, find.byKey(const ValueKey('keypad-save')));

      final logged = await appended(tester);
      expect(logged, hasLength(2));
      final named = logged.last;
      expect([named.kind, named.correctsUlid, named.payload['sail']], [RoundingKinds.sail, rounding.ulid, '887']);
      expect(logged.first.payload['sail'], isNull, reason: 'the rounding is never edited');
      expect(label(tester, sailButton(rounding.ulid)), '887');
    });
  });

  group('criterion 3: ten roundings tapped in 10 s are each shown within 100 ms, in tap order', () {
    testWidgets('a tap a second, ten times: each appended at once and listed within 100 ms', (tester) async {
      for (final s in ['887', '412', '1033', '5', '77']) {
        day.rounding(s);
      }
      day.fixed = true;
      await openRoundings(tester);
      final sails = ['887', '412', '1033', '5', '77', '887', '412', '1033', '5', '77'];
      for (var i = 0; i < sails.length; i++) {
        await tester.tap(boat(sails[i]));
        await tester.pump(const Duration(milliseconds: 100));
        final logged = await appended(tester);
        expect(logged, hasLength(i + 1), reason: 'tap ${i + 1} appended exactly one rounding');
        expect(row(logged.last.ulid), findsOneWidget, reason: 'tap ${i + 1} shown within 100 ms');
        await tester.pump(const Duration(milliseconds: 900));
        day.now += 1000;
      }
      final logged = await appended(tester);
      expect([for (final e in logged) e.payload['sail']], sails, reason: 'stored in tap order');
      expect(logged.last.deviceTs - logged.first.deviceTs, lessThanOrEqualTo(10000));
      expect([for (final e in logged) e.payload['lap']], [2, 2, 2, 2, 2, 3, 3, 3, 3, 3]);
    });
  });

  group('criterion 4: the rounding screen passes the bar-check helper, a known boat in at most 2 taps', () {
    /// A mark boat's day with fleets and boats known in both, and a full list.
    _Day withFleets() {
      final d = _Day();
      final lasers = d.fleet('Lasers');
      final four20s = d.fleet('420s');
      for (var i = 0; i < 12; i++) {
        d.rounding('${100 + i}', fleet: lasers);
      }
      d.rounding('5', fleet: four20s);
      return d;
    }

    _Day singleFleet() {
      final d = _Day();
      for (final s in ['887', '412', '1033']) {
        d.rounding(s);
      }
      return d;
    }

    // The rounding screen's actions, the station's on the home, and none of
    // the finish-at-mark screen's: test/mark_finish_test.dart holds those
    // with finishes to give them.
    const finishAtMark = {'finish-here', 'mark-finish', 'mark-undo-last', 'mark-sail'};
    const heldElsewhere = {...onHomeRaceTimeActionIds, ...finishAtMark};
    for (final scale in [1.0, 2.0]) {
      final pct = '${(scale * 100).round()}%';
      for (final (name, build, actions) in [
        ('with fleets and a full list', withFleets, markBoatRaceTimeActionIds.difference(finishAtMark)),
        // No fleets, so no fleet row.
        ('on a single-fleet day', singleFleet, markBoatRaceTimeActionIds.difference({...finishAtMark, 'rounding-fleet'})),
      ]) {
        testWidgets('the mark-boat home and the screen, $name, at $pct text', (tester) async {
          final violations = await barCheck(
            tester,
            (observer) => app(textScale: scale, on: build(), observer: observer),
            actionIds: actions,
            heldElsewhere: heldElsewhere,
          );
          expect(violations, isEmpty, reason: violations.join('\n'));
        });
        if (scale == 2.0) {
          testWidgets('the mark-boat home and the screen, $name, at $pct text, under the revoked banner (#53)',
              (tester) async {
            final violations = await barCheck(
              tester,
              (observer) {
                final d = build();
                revoked(d.core);
                return app(textScale: scale, on: d, observer: observer);
              },
              actionIds: actions,
              heldElsewhere: heldElsewhere,
            );
            expect(violations, isEmpty, reason: violations.join('\n'));
          });
        }
      }
    }

    testWidgets('a screen reader tells logging a boat from changing a rounding (the semantics tree, the audit)',
        (tester) async {
      final handle = tester.ensureSemantics();
      final first = day.rounding('412');
      final unnamed = day.rounding('');
      await openRoundings(tester);
      expect(tester.getSemantics(boat('412')).label, '412, log a rounding');
      expect(tester.getSemantics(unknown).label, 'Unknown boat, log a rounding');
      expect(tester.getSemantics(newBoat).label, 'New boat, type her sail number');
      expect(tester.getSemantics(sailButton(first.ulid)).label, 'Change sail 412 for 1',
          reason: 'not "412" again: the same words as the grid cell, with the opposite effect');
      expect(tester.getSemantics(sailButton(unnamed.ulid)).label, 'Name the boat for 2');
      handle.dispose();
    });

    testWidgets('the grid is in the order each boat last rounded, and nothing in it moves between taps',
        (tester) async {
      // 887 rounded first and again last: by her last rounding she comes
      // after the others, by her first she would lead.
      for (final s in ['887', '412', '1033', '5', '887']) {
        day.rounding(s);
      }
      await openRoundings(tester);
      final cells = [unknown, newBoat, for (final s in ['887', '412', '1033', '5']) boat(s)];
      Map<Finder, Rect> rects() => {for (final c in cells) c: tester.getRect(c)};
      final before = rects();
      int reading(Offset a, Offset b) => a.dy != b.dy ? a.dy.compareTo(b.dy) : a.dx.compareTo(b.dx);
      final expected = [for (final s in ['412', '1033', '5', '887']) tester.getTopLeft(boat(s))];
      expect([...expected]..sort(reading), expected, reason: '412, 1033, 5, then 887, across and down');
      for (final tapOn in [boat('1033'), boat('887'), unknown, boat('5')]) {
        await tap(tester, tapOn);
        expect(rects(), before, reason: 'a tap moves no cell');
      }
    });
  });

  group('criterion 5: one vibration and one tone per rounding, and UNDO LAST with no confirm', () {
    testWidgets('one of each per rounding the core confirms, on the notification stream', (tester) async {
      day.rounding('887');
      await openRoundings(tester);
      for (var i = 1; i <= 3; i++) {
        await tap(tester, i == 2 ? unknown : boat('887'));
        expect(device.vibrations, i);
        expect(device.tones, List.filled(i, BeepStream.notification));
      }
    });

    testWidgets('UNDO LAST appends a rounding.undo for the latest, at once, with no dialog', (tester) async {
      day.rounding('887');
      await openRoundings(tester);
      expect(label(tester, undoLast), 'UNDO LAST (#1)');
      await tap(tester, boat('887'));
      final rounding = (await appended(tester)).single;
      expect(label(tester, undoLast), 'UNDO LAST (#2)');
      await tap(tester, undoLast);

      expect(popups.opened, isEmpty, reason: 'no confirm dialog');
      final undo = (await appended(tester)).last;
      expect([undo.kind, undo.correctsUlid], [RoundingKinds.undo, rounding.ulid]);
      expect(row(rounding.ulid), findsNothing);
      expect(device.vibrations, 2, reason: 'the undo is confirmed too');
      expect(label(tester, undoLast), 'UNDO LAST (#1)');
    });

    testWidgets("a log that cannot be read says so, offers nothing to log into, and RETRY reads it (#54's review)",
        (tester) async {
      day.rounding('887');
      setPhoneSize(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      day.core.failWith = const CoreException('failed', 'disk unreadable'); // the home read; the screen's fails
      await tap(tester, roundings);
      expect(find.byKey(const ValueKey('rounding-unreadable')), findsOneWidget);
      expect(unknown, findsNothing, reason: 'an empty grid would read as no boats yet');
      expect(tester.widget<ButtonStyleButton>(undoLast).onPressed, isNull);
      day.core.failWith = null;
      await tap(tester, find.byKey(const ValueKey('rounding-retry')));
      expect(boat('887'), findsOneWidget);
      expect(find.byKey(const ValueKey('rounding-unreadable')), findsNothing);
    });

    testWidgets("a double tap on SAVE logs one new boat, not two, while the first is still on its way (#54's review)",
        (tester) async {
      // Held, as a real core's append is across the isolate: with the fake's
      // at once, the keypad had closed before the second tap, and that alone
      // refused it (shape 16 on the mutation round: the guard reddened 0).
      day = _Day(held: true);
      await openRoundings(tester);
      await tap(tester, newBoat);
      await type(tester, '1234');
      final save = find.byKey(const ValueKey('keypad-save'));
      final held = (day.core as _HeldCore).hold = Completer<void>();
      await tester.tap(save);
      await tester.pump();
      await tester.tap(save);
      await tester.pump();
      held.complete();
      await tester.pumpAndSettle();
      expect([for (final e in await appended(tester)) e.payload['sail']], ['1234']);
    });

    testWidgets('a failed append fires nothing and says so, without a dialog', (tester) async {
      day.rounding('887');
      await openRoundings(tester);
      day.core.failWith = const CoreException('failed', 'disk full');
      await tap(tester, boat('887'));
      expect(device.vibrations, 0);
      expect(find.text('Not logged. Tap again.'), findsOneWidget);
      expect(popups.opened, isEmpty);
    });
  });

  testWidgets("another phone's roundings, pulled down by sync, are neither listed nor offered (#64)", (tester) async {
    day.core.seed([
      EventEnvelope(
        ulid: '01J9000000000000000000R001',
        deviceTs: day.now,
        deviceId: '01J8000000000000000000OTHR',
        seq: 1,
        source: 'tap',
        kind: RoundingKinds.rounding,
        payloadVersion: 1,
        payload: const {'fleet': null, 'sail': '999', 'mark': 'windward', 'race': null, 'lap': 1},
      ),
    ]);
    await openRoundings(tester);
    expect(boat('999'), findsNothing);
    expect(find.text('Roundings at Windward · 0'), findsOneWidget);
    expect(label(tester, undoLast), 'Nothing to undo');
  });
}

/// A mark boat's phone stationed at the windward mark, on a fixed day.
/// A fake core whose appends wait for [hold], so a test can tap while one is
/// still on its way to the log.
class _HeldCore extends FakeCore {
  _HeldCore({super.clock});

  Completer<void>? hold;

  @override
  Future<EventEnvelope> append(NewEvent event) async {
    await hold?.future;
    return super.append(event);
  }
}

class _Day {
  _Day({bool station = true, bool held = false}) {
    core = withRole(held ? _HeldCore(clock: _tick) : FakeCore(clock: _tick), Roles.markBoat);
    seeded.add(seededRolePick);
    if (station) add(StationKinds.selected, const {'mark': StandardMarks.windward});
  }

  late final FakeCore core;

  /// The phone's clock, which the app and the core both read.
  int now = DateTime(2026, 10, 27, 14, 30).millisecondsSinceEpoch;

  /// When true the core's clock stands still, and a test moves [now] itself.
  bool fixed = false;
  int _n = 0;

  /// What [add] seeded, as opposed to what the app appended.
  final seeded = <String>{};

  int _tick() => fixed ? now : now += 1000;

  EventEnvelope add(String kind, Map<String, Object?> payload) {
    final e = EventEnvelope(
      ulid: '01J8${(++_n).toString().padLeft(22, '0')}',
      deviceTs: now += 1000,
      deviceId: core.deviceIdValue,
      seq: _n,
      source: 'tap',
      kind: kind,
      payloadVersion: 1,
      role: Roles.markBoat,
      payload: {...payload, 'mark': StandardMarks.windward},
    );
    core.seed([e]);
    seeded.add(e.ulid);
    return e;
  }

  /// Names a fleet, and returns its id.
  String fleet(String name) => add(FleetKinds.defined, {'name': name, 'class': null}).ulid;

  /// A fleet the PRO's phone named, pulled down by sync, and its id. Named
  /// now, or [at].
  String pulledFleet(String name, {int? at}) {
    final e = EventEnvelope(
      ulid: '01J8${(++_n).toString().padLeft(22, '0')}',
      deviceTs: at ?? (now += 1000),
      deviceId: '01J8000000000000000PR0PH0N',
      seq: _n,
      source: 'tap',
      kind: FleetKinds.defined,
      payloadVersion: 1,
      role: Roles.overallPro,
      payload: {'name': name, 'class': null},
    );
    core.seed([e]);
    seeded.add(e.ulid);
    return e.ulid;
  }

  /// A rounding this phone logged earlier, so [sail] is a known boat.
  EventEnvelope rounding(String sail, {String? fleet}) =>
      add(RoundingKinds.rounding, {'fleet': fleet, 'sail': sail, 'race': null, 'lap': 1});
}

class _Popups extends NavigatorObserver {
  final opened = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) opened.add(route);
  }
}
