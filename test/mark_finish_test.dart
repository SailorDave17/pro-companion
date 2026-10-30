import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/ui/clock.dart';
import 'package:pro_companion/ui/race_time.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';
import 'support/revoked.dart';
import 'support/roles.dart';

/// #30 on the app, driven against the fake core: the mark-boat home's FINISH
/// AT MARK opens the finish-at-mark screen. A fleet in its row (FINISH HERE on
/// a single-fleet day) makes the station that fleet's finish, then FINISH
/// logs each boat there (owner's choices at pickup, 2026-10-14). The core's
/// half is packages/core/test/mark_finishes_test.dart.
void main() {
  late _Day day;
  late FakeConfirmationDevice device;
  late _Popups popups;

  final finishAtMark = find.byKey(const ValueKey('finish-at-mark'));
  final finishHere = find.byKey(const ValueKey('finish-here'));
  final finish = find.byKey(const ValueKey('mark-finish'));
  final undoLast = find.byKey(const ValueKey('mark-undo-last'));
  final status = find.byKey(const ValueKey('mark-finish-status'));
  Finder fleetButton(String id) => find.byKey(ValueKey('finish-here-$id'));

  setUp(() {
    day = _Day();
    device = FakeConfirmationDevice();
    popups = _Popups();
  });

  Widget app({double textScale = 1, CoreClient? on, NavigatorObserver? observer}) => MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: ProCompanionApp(
          core: on ?? day.core,
          confirmation: ConfirmationService(device),
          navigatorObservers: [observer ?? popups],
        ),
      );

  Future<void> openApp(WidgetTester tester, {CoreClient? on}) async {
    setPhoneSize(tester);
    await tester.pumpWidget(app(on: on));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  /// What the app appended: everything after the seeded day.
  Future<List<EventEnvelope>> appended(WidgetTester tester) async =>
      [for (final e in (await tester.runAsync(day.core.readAll))!) if (!day.seeded.contains(e.ulid)) e];

  String statusText(WidgetTester tester) => tester.widget<Text>(status).data!;
  String undoLabel(WidgetTester tester) =>
      tester.widget<Text>(find.descendant(of: undoLast, matching: find.byType(Text))).data!;
  bool enabled(WidgetTester tester, Finder f) => tester.widget<ButtonStyleButton>(f).onPressed != null;

  group("criterion 1: the station becomes a fleet's finish in at most 2 taps from the home", () {
    testWidgets('FINISH AT MARK is off until the phone has a station', (tester) async {
      await openApp(tester, on: withRole(FakeCore(), Roles.markBoat));
      expect(enabled(tester, finishAtMark), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await openApp(tester);
      expect(enabled(tester, finishAtMark), isTrue);
    });

    testWidgets('a single-fleet day: FINISH AT MARK, then FINISH HERE, logs one shortened course', (tester) async {
      await openApp(tester);
      await tap(tester, finishAtMark);
      expect(await appended(tester), isEmpty, reason: 'opening the screen logs nothing');
      expect(statusText(tester), 'Not a finish yet: tap FINISH HERE');
      expect(enabled(tester, finish), isFalse, reason: 'not a finish until it is made one');

      await tap(tester, finishHere);
      final all = await appended(tester);
      expect(all, hasLength(1), reason: 'two taps, one event');
      expect([all.single.kind, all.single.payload, all.single.role, all.single.deviceId],
          [CourseKinds.shortened, {'fleet': null, 'mark': 'windward'}, Roles.markBoat, day.core.deviceIdValue]);
      expect(find.text('FINISHING HERE'), findsOneWidget);
      expect(statusText(tester), 'Elapsed: pending reconciliation');
      expect(enabled(tester, finish), isTrue);
      expect(find.text('Finish at Windward · 0'), findsOneWidget);
    });

    testWidgets('with fleets: FINISH AT MARK, then the fleet, logs one shortened course naming both',
        (tester) async {
      final lasers = day.fleet('Lasers');
      day.fleet('420s');
      await openApp(tester);
      await tap(tester, finishAtMark);
      expect(statusText(tester), 'Not a finish yet: tap a fleet');
      expect(enabled(tester, finish), isFalse);

      await tap(tester, fleetButton(lasers));
      final all = await appended(tester);
      expect(all, hasLength(1), reason: 'two taps, one event');
      expect([all.single.kind, all.single.payload], [CourseKinds.shortened, {'fleet': lasers, 'mark': 'windward'}]);
      expect(find.text('Finish at Windward · Lasers · 0'), findsOneWidget);
      expect(find.bySemanticsLabel('Lasers, finishing here'), findsOneWidget);
      expect(find.bySemanticsLabel('420s, finishing here'), findsNothing);
    });

    testWidgets('a tap on a fleet already finishing here shows it and logs nothing', (tester) async {
      final lasers = day.fleet('Lasers');
      final fours = day.fleet('420s');
      await openApp(tester);
      await tap(tester, finishAtMark);
      await tap(tester, fleetButton(lasers));
      await tap(tester, fleetButton(fours));
      expect(find.text('Finish at Windward · 420s · 0'), findsOneWidget);

      await tap(tester, fleetButton(lasers));
      expect(await appended(tester), hasLength(2), reason: 'one shortened course each, and no more');
      expect(device.vibrations, 2, reason: 'showing a fleet logs nothing, so confirms nothing');
      expect(find.text('Finish at Windward · Lasers · 0'), findsOneWidget);
    });

    testWidgets('a second tap while the shortened course is still being logged is the same tap', (tester) async {
      day = _Day(make: _HeldCore.new);
      final held = day.core as _HeldCore;
      await openApp(tester);
      await tap(tester, finishAtMark);
      held.hold = Completer<void>();
      await tester.tap(finishHere);
      await tester.pump();
      await tester.tap(finishHere);
      await tester.pump();
      held.hold!.complete();
      await tester.pumpAndSettle();
      expect([for (final e in await appended(tester)) e.kind], [CourseKinds.shortened]);
    });

    testWidgets('with more fleets than the row holds, MORE lists them, the ones finishing here flagged',
        (tester) async {
      final ids = [for (final name in ['Lasers', '420s', 'Optimists', 'Toppers']) day.fleet(name)];
      await openApp(tester);
      await tap(tester, finishAtMark);
      await tap(tester, fleetButton(ids[0]));
      await tap(tester, find.byKey(const ValueKey('fleet-more')));
      expect(find.text('Finish here for'), findsOneWidget);
      expect(find.bySemanticsLabel('Lasers · now, finishing here'), findsOneWidget);

      await tap(tester, find.byKey(ValueKey('pick-${ids[3]}')));
      expect([for (final e in await appended(tester)) fleetOf(e)], [ids[0], ids[3]]);
      expect(find.text('Finish at Windward · Toppers · 0'), findsOneWidget);
    });

    testWidgets('a restart opens on the fleet finishing here, its finishes read back from the log', (tester) async {
      final lasers = day.fleet('Lasers');
      await openApp(tester);
      await tap(tester, finishAtMark);
      await tap(tester, fleetButton(lasers));
      await tap(tester, finish);
      await tester.pumpWidget(const SizedBox.shrink());
      await openApp(tester);
      await tap(tester, finishAtMark);
      expect(find.text('Finish at Windward · Lasers · 1'), findsOneWidget);
      expect(enabled(tester, finish), isTrue);
    });
  });

  group('criterion 2: a finish carries the mark id, fleet and device id; elapsed time is pending', () {
    testWidgets('FINISH logs a finish at the mark, and the boat takes her place in the list', (tester) async {
      final lasers = day.fleet('Lasers');
      await openApp(tester);
      await tap(tester, finishAtMark);
      await tap(tester, fleetButton(lasers));
      await tap(tester, finish);

      final logged = (await appended(tester)).last;
      expect([logged.kind, logged.payload, logged.deviceId, logged.role],
          [FinishKinds.atMark, {'fleet': lasers, 'mark': 'windward'}, day.core.deviceIdValue, Roles.markBoat]);
      expect(find.text('Finish at Windward · Lasers · 1'), findsOneWidget);
      expect(find.text(clockText(logged.deviceTs)), findsOneWidget);
    });

    testWidgets('with the gun on this phone too, no elapsed time is worked out; it is pending', (tester) async {
      final lasers = day.fleet('Lasers');
      day.add(StartKinds.start, {fleetPayloadKey: lasers}, at: DateTime(2026, 10, 14, 14, 30, 20));
      await openApp(tester);
      await tap(tester, finishAtMark);
      await tap(tester, fleetButton(lasers));
      day.next = DateTime(2026, 10, 14, 14, 37, 13);
      await tap(tester, finish);

      expect(find.text('14:37:13'), findsOneWidget, reason: 'the time of day is shown');
      // 6 min 53 s after the gun. The time of day does not contain it.
      expect(find.textContaining('6:53'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('6:53')), findsNothing);
      expect(statusText(tester), 'Elapsed: pending reconciliation');
      expect(find.bySemanticsLabel('1, 14:37:13, elapsed pending reconciliation'), findsOneWidget);
    });

    testWidgets('at 200% text on a 393 dp phone, each place and time stays on one line and clear of Sail #',
        (tester) async {
      // The emulator render (Pixel 5 profile: 1080 px at 440 dpi) showed the
      // time wrapped mid-number. Ten finishes, so a two-digit place is held too.
      day.add(CourseKinds.shortened, {fleetPayloadKey: null});
      for (var i = 0; i < 10; i++) {
        day.add(FinishKinds.atMark, {fleetPayloadKey: null});
      }
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(textScale: 2));
      await tester.pumpAndSettle();
      await tap(tester, finishAtMark);

      final rows = find.bySemanticsLabel(RegExp(r'elapsed pending reconciliation$'));
      expect(rows, findsWidgets);
      var checked = 0;
      for (final paragraph in find.descendant(of: find.byType(ListView), matching: find.byType(RichText)).evaluate()) {
        final r = paragraph.renderObject! as RenderParagraph;
        final text = r.text.toPlainText();
        if (!RegExp(r'^(\d+|\d\d:\d\d:\d\d)$').hasMatch(text)) continue;
        expect(r.size.width + 0.5, greaterThanOrEqualTo(r.getMaxIntrinsicWidth(double.infinity)),
            reason: '"$text" laid out narrower than its one line, so it wrapped');
        checked++;
      }
      expect(checked, greaterThanOrEqualTo(4), reason: 'the places and times on screen were all looked at');
      expect(find.text('10'), findsOneWidget, reason: 'a two-digit place is on screen');
      for (final sail in find.text('Sail #').evaluate()) {
        final row = find.ancestor(of: find.byWidget(sail.widget), matching: find.byType(Row)).last;
        final time = find.descendant(of: row, matching: find.textContaining(':'));
        if (time.evaluate().isEmpty) continue;
        expect(tester.getRect(time.first).right, lessThanOrEqualTo(tester.getRect(find.byWidget(sail.widget)).left),
            reason: 'the time is drawn clear of Sail #');
      }
    });

    testWidgets("a finish at the mark is not on the line's FINISHES when the phone becomes the PRO", (tester) async {
      await openApp(tester);
      await tap(tester, finishAtMark);
      await tap(tester, finishHere);
      await tap(tester, finish);
      await tap(tester, find.byTooltip('Back'));
      await tap(tester, find.byKey(const ValueKey('undo-role')));
      await tap(tester, find.byKey(ValueKey('pick-${Roles.overallPro}')));
      await tap(tester, find.text('FINISHES'));
      expect(find.text('Finishes · 0'), findsOneWidget);
    });

    testWidgets('Sail # names a finish here, then walks on to the next one with none', (tester) async {
      await openApp(tester);
      await tap(tester, finishAtMark);
      await tap(tester, finishHere);
      await tap(tester, finish);
      await tap(tester, finish);
      final [first, second] = [for (final e in await appended(tester)) if (e.kind == FinishKinds.atMark) e];

      await tap(tester, find.byKey(ValueKey('sail-${first.ulid}')));
      for (final d in ['2', '2', '0', '7']) {
        await tap(tester, find.byKey(ValueKey('key-$d')));
      }
      await tap(tester, find.byKey(const ValueKey('keypad-save')));
      final named = (await appended(tester)).last;
      expect([named.kind, named.payload['finish'], named.payload['sail']], [FinishKinds.sail, first.ulid, '2207']);
      expect(find.textContaining('Sail for #2'), findsOneWidget, reason: 'on to the next with none');
      await tap(tester, find.byKey(const ValueKey('keypad-cancel')));
      expect(find.descendant(of: find.byKey(ValueKey('sail-${first.ulid}')), matching: find.text('2207')),
          findsOneWidget);
      expect(find.byKey(ValueKey('sail-${second.ulid}')), findsOneWidget);
    });
  });

  group('criterion 3: the finish-at-mark screen passes the bar-check helper', () {
    /// A mark boat's day with fleets, Lasers finishing here, and a full list,
    /// so the row, the list, its sail numbers and scrolling all exist.
    FakeCore withFleets() {
      final d = _Day();
      final lasers = d.fleet('Lasers');
      d.fleet('420s');
      d.add(CourseKinds.shortened, {fleetPayloadKey: lasers});
      for (var i = 0; i < 12; i++) {
        d.add(FinishKinds.atMark, {fleetPayloadKey: lasers});
      }
      return d.core;
    }

    FakeCore singleFleet() {
      final d = _Day();
      d.add(CourseKinds.shortened, {fleetPayloadKey: null});
      for (var i = 0; i < 3; i++) {
        d.add(FinishKinds.atMark, {fleetPayloadKey: null});
      }
      return d.core;
    }

    // The rounding screen (#54) is two taps from the same home. Its actions
    // are held to the bar by test/rounding_screen_test.dart, whose fixtures
    // have boats to tap; these have none.
    final actions = markBoatRaceTimeActionIds.difference(roundingActionIds);
    const heldElsewhere = {...onHomeRaceTimeActionIds, ...roundingActionIds};
    for (final scale in [1.0, 2.0]) {
      final pct = '${(scale * 100).round()}%';
      for (final (name, build) in [('with fleets and a full list', withFleets), ('on a single-fleet day', singleFleet)]) {
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
              (observer) => app(textScale: scale, on: revoked(build()), observer: observer),
              actionIds: actions,
              heldElsewhere: heldElsewhere,
            );
            expect(violations, isEmpty, reason: violations.join('\n'));
          });
        }
      }
    }
  });

  group('criterion 4: a finish the core confirms fires one vibration and one tone', () {
    testWidgets('one of each, on the notification stream', (tester) async {
      await openApp(tester);
      await tap(tester, finishAtMark);
      await tap(tester, finishHere);
      expect(device.vibrations, 1, reason: 'the shortened course, confirmed');
      await tap(tester, finish);
      expect(device.vibrations, 2);
      expect(device.tones, [BeepStream.notification, BeepStream.notification]);
    });

    testWidgets('a finish that does not log fires neither, and says so', (tester) async {
      await openApp(tester);
      await tap(tester, finishAtMark);
      await tap(tester, finishHere);
      day.core.failWith = const CoreException('failed', 'disk gone');
      await tap(tester, finish);
      expect([device.vibrations, device.tones.length], [1, 1], reason: 'only the shortened course');
      expect(find.text('Not logged. Tap again.'), findsOneWidget);

      day.core.failWith = null;
      await tap(tester, finish);
      expect(device.vibrations, 2);
      expect(find.text('Not logged. Tap again.'), findsNothing);
      expect(find.text('Finish at Windward · 1'), findsOneWidget);
    });
  });

  group('criterion 5: Undo appends a correction, with no confirm dialog', () {
    testWidgets('UNDO LAST after a finish takes it back at once', (tester) async {
      await openApp(tester);
      await tap(tester, finishAtMark);
      await tap(tester, finishHere);
      await tap(tester, finish);
      await tap(tester, finish);
      final finished = [for (final e in await appended(tester)) if (e.kind == FinishKinds.atMark) e];
      expect(undoLabel(tester), 'UNDO LAST (#2)');

      await tap(tester, undoLast);
      final undo = (await appended(tester)).last;
      expect([undo.kind, undo.correctsUlid, undo.payload['mark']], [FinishKinds.undo, finished.last.ulid, 'windward']);
      expect(popups.opened, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expect(device.vibrations, 4, reason: 'the shortened course, two finishes and the undo, each confirmed');
      expect(find.text('Finish at Windward · 1'), findsOneWidget);
      expect(undoLabel(tester), 'UNDO LAST (#1)');
    });

    testWidgets('with no finish since, UNDO LAST takes back the shortened course', (tester) async {
      final lasers = day.fleet('Lasers');
      await openApp(tester);
      await tap(tester, finishAtMark);
      expect(enabled(tester, undoLast), isFalse, reason: 'nothing to undo yet');
      await tap(tester, fleetButton(lasers));
      await tap(tester, finish);
      await tap(tester, undoLast);
      expect(undoLabel(tester), 'UNDO FINISH HERE (Lasers)');

      await tap(tester, undoLast);
      final [shortened, ..., undo] = await appended(tester);
      expect([undo.kind, undo.correctsUlid], [CourseKinds.undo, shortened.ulid]);
      expect(popups.opened, isEmpty);
      expect(statusText(tester), 'Not a finish yet: tap a fleet');
      expect(enabled(tester, finish), isFalse);
      expect(find.bySemanticsLabel('Lasers, finishing here'), findsNothing);
    });

    testWidgets('nothing the thumb reaches for moves when the mark becomes a finish or a boat finishes',
        (tester) async {
      await openApp(tester);
      await tap(tester, finishAtMark);
      List<double> edges() => [
            for (final r in [tester.getRect(finishHere), tester.getRect(undoLast), tester.getRect(finish)])
              ...[r.left, r.top, r.right, r.bottom],
          ];
      Matcher unmoved(List<double> before) =>
          pairwiseCompare<double, double>(before, (e, a) => (e - a).abs() < 0.01, 'within 0.01 dp of');
      final before = edges();
      await tap(tester, finishHere);
      expect(edges(), unmoved(before), reason: 'after the shortened course');
      await tap(tester, finish);
      expect(edges(), unmoved(before), reason: 'after a finish');
    });
  });
}

/// A mark boat's phone at Windward, seeded event by event as the real core
/// would have stored them: one second apart, each stamped with the station.
class _Day {
  _Day({FakeCore Function({int Function()? clock}) make = FakeCore.new}) {
    core = withRole(make(clock: _tick), Roles.markBoat);
    seeded.add(seededRolePick);
    add(StationKinds.selected, const {'mark': StandardMarks.windward});
  }

  late final FakeCore core;
  int _t = DateTime(2026, 10, 14, 14, 30).millisecondsSinceEpoch;
  int _n = 0;

  /// When set, the next event the app logs is at this time.
  DateTime? next;

  /// What [add] seeded, as opposed to what the app appended.
  final seeded = <String>{};

  int _tick() {
    final at = next;
    next = null;
    return _t = at?.millisecondsSinceEpoch ?? _t + 1000;
  }

  EventEnvelope add(String kind, Map<String, Object?> payload, {DateTime? at}) {
    final e = EventEnvelope(
      ulid: '01J8${(++_n).toString().padLeft(22, '0')}',
      deviceTs: at?.millisecondsSinceEpoch ?? (_t += 1000),
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
}

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

class _Popups extends NavigatorObserver {
  final opened = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) opened.add(route);
  }
}
