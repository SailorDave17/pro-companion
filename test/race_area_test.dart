import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/roles/race_area.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';
import 'support/roles.dart';

/// #74 on the app, against the fake core: a phone works on the race area its
/// role binds (course PRO, recorder, mark boat) or its PRO picks (overall PRO,
/// scorer, safety), and a phone never admitted has one implicit race area, as
/// in milestone 1. The core's half (what is kept, and the course stamped into
/// a `fleet.defined`) is packages/core/test/race_areas_test.dart, and the
/// fetch is packages/sync/test/race_areas_test.dart.
void main() {
  const admission = '00000000-0000-4000-8000-0000000000a1';
  const alpha = RaceArea(id: '00000000-0000-4000-8000-00000000c0a1', name: 'Alpha');
  const bravo = RaceArea(id: '00000000-0000-4000-8000-00000000c0b2', name: 'Bravo');

  late int now;
  late FakeCore core;
  late FakeConfirmationDevice device;

  final status = find.byKey(const ValueKey('race-area-status'));
  final header = find.byKey(const ValueKey('race-area-header'));
  final raceAreaButton = find.byKey(const ValueKey('race-area'));

  setUp(() {
    now = DateTime(2026, 11, 5, 10).millisecondsSinceEpoch;
    core = FakeCore(clock: () => now += 1000);
    device = FakeConfirmationDevice();
  });

  /// [on] admitted as [role], on race area [course] for a bound role, with the
  /// race day's race areas kept and a pick of [role] seeded.
  FakeCore admitted(FakeCore on, String role, {String? course, List<RaceArea> areas = const [alpha, bravo]}) {
    on.seedAdmission(admission);
    on.grants[admission] = (role: role, course: course);
    on.raceAreaList.addAll(areas);
    return withRole(on, role);
  }

  Widget app({double textScale = 1, CoreClient? on, NavigatorObserver? observer}) => MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: ProCompanionApp(
          core: on ?? core,
          confirmation: ConfirmationService(device),
          navigatorObservers: [?observer],
        ),
      );

  Future<void> openApp(WidgetTester tester) async {
    setPhoneSize(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) => tap(tester, find.byTooltip('Back'));

  Future<List<EventEnvelope>> events(WidgetTester tester) async => (await tester.runAsync(core.readAll))!;

  String text(WidgetTester tester, Finder f) => switch (tester.widget(f)) {
        RaceAreaText(:final text) => text,
        final Text t => t.data!,
        final w => throw StateError('$w is not a line of text'),
      };

  group('criterion 1: a bound phone shows its race area in the header and offers no picker', () {
    for (final (role, screen) in [
      (Roles.coursePro, 'SEQUENCE'),
      (Roles.recorder, 'FINISHES'),
      (Roles.markBoat, 'STATION'),
    ]) {
      testWidgets('$role: on its home and on $screen, with no RACE AREA', (tester) async {
        admitted(core, role, course: bravo.id);
        await openApp(tester);
        expect(text(tester, status), 'Race area · Bravo');
        expect(raceAreaButton, findsNothing);
        await tap(tester, find.text(screen));
        expect(text(tester, header), 'Race area · Bravo');
        expect(raceAreaButton, findsNothing);
      });
    }

    testWidgets('a screen pushed from a screen still names it: FINISHES, then the fleet picker', (tester) async {
      admitted(core, Roles.recorder, course: alpha.id);
      // Enough fleets that the finish screen's row ends in the full picker.
      for (final name in ['A', 'B', 'C', 'D', 'E']) {
        await core.append(FleetEvents.define(name));
      }
      await openApp(tester);
      await tap(tester, find.text('FINISHES'));
      final more = find.byKey(const ValueKey('fleet-more'));
      expect(more, findsOneWidget, reason: 'control: the row opens the picker');
      await tap(tester, more);
      expect(text(tester, header), 'Race area · Alpha');
    });

    // The render: a FittedBox drew a long name about 13 px tall in the title
    // slot, at 200% text as at 100%. Shrunk, but never below 16 px.
    testWidgets('a long race-area name at 200% text is never drawn below 16 px', (tester) async {
      const long = RaceArea(id: '00000000-0000-4000-8000-00000000c0c3', name: 'Charlie inner trapezoid north');
      admitted(core, Roles.recorder, course: long.id, areas: const [long]);
      setPhoneSize(tester);
      await tester.pumpWidget(app(textScale: 2));
      await tester.pumpAndSettle();
      await tap(tester, find.text('FINISHES'));
      final drawn = tester.widget<Text>(find.descendant(of: header, matching: find.byType(Text)));
      expect(drawn.data, 'Race area · ${long.name}', reason: 'the whole name, for a screen reader');
      expect(drawn.style!.fontSize, greaterThanOrEqualTo(RaceAreaText.minFontSize));
      expect(drawn.overflow, TextOverflow.ellipsis);
    });

    testWidgets('UNDO ROLE, then a pick: the next home names the race area again', (tester) async {
      admitted(core, Roles.recorder, course: bravo.id);
      await openApp(tester);
      await tap(tester, find.byKey(const ValueKey('undo-role')));
      expect(find.text('Pick your role'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('pick-${Roles.recorder}')));
      expect(text(tester, status), 'Race area · Bravo', reason: 'the admission is still bound to Bravo');
    });
  });

  group('criterion 2: an event-wide phone picks from the cached race areas', () {
    for (final role in [Roles.overallPro, Roles.scorer, Roles.safety]) {
      testWidgets('$role: RACE AREA is on its home, and the picker lists the race day\'s race areas', (tester) async {
        admitted(core, role);
        await openApp(tester);
        expect(text(tester, status), 'Race area · none picked');
        await tap(tester, raceAreaButton);
        expect(find.byKey(ValueKey('race-area-${alpha.id}')), findsOneWidget);
        expect(find.byKey(ValueKey('race-area-${bravo.id}')), findsOneWidget);
        expect(find.text('Race area · none yet'), findsOneWidget);
      });
    }

    testWidgets('one tap picks, with one buzz and one tone, and every header follows', (tester) async {
      admitted(core, Roles.overallPro);
      await openApp(tester);
      await tap(tester, raceAreaButton);
      final before = (await events(tester)).length;
      await tap(tester, find.byKey(ValueKey('race-area-${bravo.id}')));
      final logged = (await events(tester)).skip(before).toList();
      expect([for (final e in logged) (e.kind, e.payload[coursePayloadKey], e.admissionId)],
          [(RaceAreaKinds.selected, bravo.id, admission)]);
      expect(device.vibrations, 1);
      expect(device.tones, [BeepStream.notification]);
      expect(text(tester, status), 'Race area · Bravo');
      await tap(tester, find.text('SEQUENCE'));
      expect(text(tester, header), 'Race area · Bravo');
    });

    testWidgets('picking the race area in force logs nothing, and the next pick moves it', (tester) async {
      admitted(core, Roles.overallPro);
      await openApp(tester);
      await tap(tester, raceAreaButton);
      await tap(tester, find.byKey(ValueKey('race-area-${alpha.id}')));
      await tap(tester, raceAreaButton);
      final before = (await events(tester)).length;
      await tap(tester, find.byKey(ValueKey('race-area-${alpha.id}')));
      expect((await events(tester)).length, before);
      expect(device.vibrations, 1);
      await tap(tester, raceAreaButton);
      await tap(tester, find.byKey(ValueKey('race-area-${bravo.id}')));
      expect(text(tester, status), 'Race area · Bravo');
    });

    testWidgets('a pick that does not log says so on the picker and fires nothing', (tester) async {
      admitted(core, Roles.overallPro);
      await openApp(tester);
      await tap(tester, raceAreaButton);
      core.failWith = const CoreException('failed', 'disk full');
      await tap(tester, find.byKey(ValueKey('race-area-${bravo.id}')));
      core.failWith = null;
      expect(find.text('Not logged. Tap again.'), findsOneWidget);
      expect(device.vibrations, 0);
      expect(device.tones, isEmpty);
    });

    testWidgets('with no race areas kept yet, the picker says they arrive with signal', (tester) async {
      admitted(core, Roles.overallPro, areas: const []);
      await openApp(tester);
      await tap(tester, raceAreaButton);
      expect(find.byKey(const ValueKey('race-areas-none')), findsOneWidget);
    });

    testWidgets("FLEETS lists the race area's fleets and those that name none", (tester) async {
      admitted(core, Roles.overallPro);
      core.seed([
        for (final (i, (name, course)) in [('On Alpha', alpha.id), ('On Bravo', bravo.id), ('Older', null)].indexed)
          EventEnvelope(
            ulid: '01J8${'${i + 1}'.padLeft(22, '0')}',
            deviceTs: 1 + i,
            deviceId: core.deviceIdValue,
            seq: 1 + i,
            source: 'tap',
            kind: FleetKinds.defined,
            payloadVersion: 1,
            payload: {'name': name, 'class': null, coursePayloadKey: ?course},
          ),
      ]);
      await openApp(tester);
      await tap(tester, raceAreaButton);
      await tap(tester, find.byKey(ValueKey('race-area-${bravo.id}')));
      await tap(tester, find.text('FLEETS'));
      expect(find.textContaining('On Bravo'), findsOneWidget);
      expect(find.textContaining('Older'), findsOneWidget);
      expect(find.textContaining('On Alpha'), findsNothing);
      expect(text(tester, header), 'Race area · Bravo');
    });
  });

  group('criterion 3: a fleet defined on the phone carries its race area', () {
    testWidgets("an event-wide phone's fleet names the race area it picked", (tester) async {
      admitted(core, Roles.overallPro);
      await openApp(tester);
      await tap(tester, raceAreaButton);
      await tap(tester, find.byKey(ValueKey('race-area-${alpha.id}')));
      await tap(tester, find.text('FLEETS'));
      await tester.enterText(find.byKey(const ValueKey('fleet-name')), 'Lasers');
      await tap(tester, find.byKey(const ValueKey('fleet-add')));
      final defined = (await events(tester)).singleWhere((e) => e.kind == FleetKinds.defined);
      expect(defined.payload[coursePayloadKey], alpha.id);
    });

    testWidgets("a bound phone's fleet names its own race area", (tester) async {
      admitted(core, Roles.recorder, course: bravo.id);
      await openApp(tester);
      await tap(tester, find.text('FLEETS'));
      await tester.enterText(find.byKey(const ValueKey('fleet-name')), 'Lasers');
      await tap(tester, find.byKey(const ValueKey('fleet-add')));
      final defined = (await events(tester)).singleWhere((e) => e.kind == FleetKinds.defined);
      expect(defined.payload[coursePayloadKey], bravo.id);
    });
  });

  group('criterion 4: a phone never admitted has one implicit race area', () {
    testWidgets('no race area on its home or headers, no picker, and fleets as #18 made them', (tester) async {
      withRole(core);
      await openApp(tester);
      expect(status, findsNothing);
      expect(raceAreaButton, findsNothing);
      await tap(tester, find.text('FLEETS'));
      expect(header, findsNothing);
      await tester.enterText(find.byKey(const ValueKey('fleet-name')), 'Lasers');
      await tap(tester, find.byKey(const ValueKey('fleet-add')));
      final defined = (await events(tester)).singleWhere((e) => e.kind == FleetKinds.defined);
      expect(defined.payload, {'name': 'Lasers', 'class': null});
      await back(tester);
      await tap(tester, find.text('FINISHES'));
      expect(header, findsNothing);
    });

    testWidgets('an admitted phone whose grant sync has not learned shows none either', (tester) async {
      await core.setAdmissionId(admission);
      withRole(core);
      await openApp(tester);
      expect(status, findsNothing);
      expect(raceAreaButton, findsNothing);
    });
  });

  group('criterion 5: the picker passes the bar check, 2 taps from an event-wide home', () {
    for (final scale in [1.0, 2.0]) {
      final pct = '${(scale * 100).round()}%';
      // From the safety home, whose only actions are set-up: RACE AREA, then
      // a race area, is 2 taps. Set-up, so it holds no race-time action.
      testWidgets('the safety home, RACE AREA and the picker, at $pct text', (tester) async {
        Widget build(NavigatorObserver observer) =>
            app(textScale: scale, on: admitted(FakeCore(), Roles.safety), observer: observer);
        final violations = await barCheck(tester, build, actionIds: const {});
        expect(violations, isEmpty, reason: violations.join('\n'));
        // The premise, in the app the check explored: RACE AREA is on that home.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(build(NavigatorObserver()));
        await tester.pumpAndSettle();
        expect(raceAreaButton, findsOneWidget);
      });

      testWidgets('a bound home names its race area and still passes, at $pct text', (tester) async {
        Widget build(NavigatorObserver observer) =>
            app(textScale: scale, on: admitted(FakeCore(), Roles.markBoat, course: bravo.id), observer: observer);
        final violations = await barCheck(tester, build, actionIds: const {'station', 'station-undo'});
        expect(violations, isEmpty, reason: violations.join('\n'));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(build(NavigatorObserver()));
        await tester.pumpAndSettle();
        expect(text(tester, status), 'Race area · Bravo');
      });
    }
  });
}
