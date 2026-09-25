import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/ui/bars.dart';
import 'package:pro_companion/ui/clock.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';

/// #25 on the app, driven against the fake core: the sequence card logs a
/// gun, a postponement and a general recall by hand as source=manual, a late
/// gun is fixed by tapping it and typing the time, and UNDO takes the last one
/// back (owner's layout and time entry, 2026-09-25). The core's half is
/// packages/core/test/starts_test.dart.
void main() {
  late int now;
  late FakeCore core;
  late FakeConfirmationDevice device;
  late _Popups popups;

  final gunButton = find.widgetWithText(FilledButton, 'GUN');
  final postponeButton = find.widgetWithText(OutlinedButton, 'POSTPONE');
  final recallButton = find.widgetWithText(OutlinedButton, 'GENERAL RECALL');
  final card = find.byKey(const ValueKey('start-card'));
  final save = find.byKey(const ValueKey('keypad-save'));

  setUp(() {
    now = DateTime(2026, 9, 26, 14, 30).millisecondsSinceEpoch;
    core = FakeCore(clock: () => now += 1000);
    device = FakeConfirmationDevice();
    popups = _Popups();
  });

  Widget app({double textScale = 1, FakeCore? on, NavigatorObserver? observer}) => MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: ProCompanionApp(
          core: on ?? core,
          confirmation: ConfirmationService(device),
          navigatorObservers: [observer ?? popups],
          clock: () => now,
        ),
      );

  Future<void> openSequence(WidgetTester tester, {double textScale = 1}) async {
    setPhoneSize(tester);
    await tester.pumpWidget(app(textScale: textScale));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SEQUENCE'));
    await tester.pumpAndSettle();
    expect(gunButton, findsOneWidget);
  }

  Future<List<EventEnvelope>> events(WidgetTester tester) async => (await tester.runAsync(core.readAll))!;

  Future<List<String>> defineFleets(WidgetTester tester, List<String> names) async => [
        for (final n in names) (await tester.runAsync(() => core.append(FleetEvents.define(n))))!.ulid,
      ];

  Finder fleetButton(String id) => find.byKey(ValueKey('fleet-switch-$id'));

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  /// Taps GUN, and returns the time the fake core stamps it with.
  Future<int> fireGun(WidgetTester tester) async {
    final at = now + 1000; // the fake core's clock ticks once per append
    await tap(tester, gunButton);
    return at;
  }

  Future<void> typeDigits(WidgetTester tester, String digits) async {
    for (final d in digits.split('')) {
      await tester.tap(find.byKey(ValueKey('key-$d')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  bool saveEnabled(WidgetTester tester) => tester.widget<OutlinedButton>(save).onPressed != null;

  group('criterion 1: GUN appends a start with source manual, the device time and the fleet, and anchors it', () {
    testWidgets('three fleets, one selected: one start event, and the card shows it as the anchor', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s', 'Optis']);
      await openSequence(tester);
      await tap(tester, fleetButton(ids[1]));
      final tappedAt = await fireGun(tester);

      final all = await events(tester);
      final gun = all.singleWhere((e) => e.kind == StartKinds.start);
      expect(gun.source, 'manual');
      expect(gun.deviceTs, tappedAt);
      expect(fleetOf(gun), ids[1]);
      expect(elapsedAnchor(all, ids[1])?.ulid, gun.ulid);
      expect(elapsedAnchor(all, ids[0]), isNull, reason: 'the other fleets have not started');
      expect(find.text('Sequence · 420s'), findsOneWidget);
      expect(find.text('GUN ${clockText(tappedAt)}'), findsOneWidget);
    });

    testWidgets('a single-fleet day: the gun carries no fleet and anchors the day', (tester) async {
      await openSequence(tester);
      expect(find.text('Sequence'), findsOneWidget);
      expect(find.text('NO GUN'), findsOneWidget);
      final tappedAt = await fireGun(tester);
      final gun = (await events(tester)).singleWhere((e) => e.kind == StartKinds.start);
      expect(gun.payload, {'fleet': null});
      expect(find.text('GUN ${clockText(tappedAt)}'), findsOneWidget);
    });
  });

  group('criterion 2: a postponement and a general recall are each their own row', () {
    testWidgets('POSTPONE appends one postponement, source manual, and the card says so', (tester) async {
      await openSequence(tester);
      final at = now + 1000;
      await tap(tester, postponeButton);
      final all = await events(tester);
      final ap = all.singleWhere((e) => e.kind == StartKinds.postponement);
      expect(ap.source, 'manual');
      expect(ap.payload, {'fleet': null});
      expect(all, hasLength(1));
      expect(find.text('POSTPONED'), findsOneWidget);
      expect(find.text('at ${clockText(at)}'), findsOneWidget);
    });

    testWidgets('GENERAL RECALL appends its own row and clears the anchor until the next GUN', (tester) async {
      await openSequence(tester);
      await fireGun(tester);
      await tap(tester, recallButton);
      var all = await events(tester);
      final recall = all.singleWhere((e) => e.kind == StartKinds.generalRecall);
      expect(recall.source, 'manual');
      expect(elapsedAnchor(all, null), isNull);
      expect(find.descendant(of: card, matching: find.text('GENERAL RECALL')), findsOneWidget);
      expect(find.textContaining('waiting for the next gun'), findsOneWidget);

      final second = await fireGun(tester);
      all = await events(tester);
      expect(all.where((e) => e.kind == StartKinds.start), hasLength(2), reason: 'the recalled gun is kept');
      expect(elapsedAnchor(all, null)?.deviceTs, second);
      expect(find.text('GUN ${clockText(second)}'), findsOneWidget);
    });
  });

  group('criterion 3: a corrected time is a correction naming the gun, and the gun is kept', () {
    testWidgets('tap the gun, type the time, Save: a correction event, and the card shows the fixed time',
        (tester) async {
      await openSequence(tester);
      final tappedAt = await fireGun(tester);
      final gun = (await events(tester)).singleWhere((e) => e.kind == StartKinds.start);

      await tap(tester, card);
      expect(find.text('Fix gun · tapped ${clockText(tappedAt)}'), findsOneWidget);
      expect(gunButton, findsOneWidget, reason: 'GUN stays where it is while the keypad is open');
      await typeDigits(tester, '1430');
      expect(find.text('14:30:__'), findsOneWidget, reason: 'the digits read as a time while they are typed');
      expect(saveEnabled(tester), isFalse);
      await typeDigits(tester, '00');
      expect(saveEnabled(tester), isTrue);
      await tap(tester, save);

      final real = DateTime(2026, 9, 26, 14, 30).millisecondsSinceEpoch;
      final all = await events(tester);
      final fix = all.singleWhere((e) => e.kind == StartKinds.timeCorrected);
      expect(fix.correctsUlid, gun.ulid);
      expect(fix.payload, {'time': real});
      expect(fix.source, 'manual');
      expect(all.singleWhere((e) => e.ulid == gun.ulid).toWire(), gun.toWire(), reason: 'kept as tapped');
      expect(anchorTime(all, null), real);
      expect(find.text('GUN 14:30:00'), findsOneWidget);
      expect(find.textContaining('tapped ${clockText(tappedAt)}'), findsOneWidget);
      expect(save, findsNothing, reason: 'the keypad shuts once the fix is logged');
    });

    testWidgets('a time that is not a time, or is later than now, cannot be saved', (tester) async {
      await openSequence(tester);
      await fireGun(tester);
      await tap(tester, card);
      await typeDigits(tester, '147500');
      expect(find.text('14:75:00 · not a time'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byKey(const ValueKey('key-del')));
        await tester.pump();
      }
      await typeDigits(tester, '235959');
      expect(find.text('23:59:59 · later than now'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);
      expect((await events(tester)).where((e) => e.kind == StartKinds.timeCorrected), isEmpty);
    });

    testWidgets('Close shuts the keypad and logs nothing', (tester) async {
      await openSequence(tester);
      await fireGun(tester);
      await tap(tester, card);
      await typeDigits(tester, '1430');
      await tap(tester, find.byKey(const ValueKey('keypad-cancel')));
      expect(save, findsNothing);
      expect((await events(tester)).where((e) => e.kind == StartKinds.timeCorrected), isEmpty);
    });

    testWidgets('a fix the core refuses keeps the keypad and its digits, for the retry', (tester) async {
      await openSequence(tester);
      await fireGun(tester);
      await tap(tester, card);
      await typeDigits(tester, '143000');
      core.failWith = const CoreException('failed', 'disk full');
      await tap(tester, save);
      expect(find.text('Not logged. Tap again.'), findsOneWidget);
      expect(find.text('14:30:00'), findsOneWidget, reason: 'the digits are still there');
      core.failWith = null;
      await tap(tester, save);
      expect((await events(tester)).where((e) => e.kind == StartKinds.timeCorrected), hasLength(1));
    });

    testWidgets('a new GUN while the keypad is open shuts it: the gun being fixed no longer anchors', (tester) async {
      await openSequence(tester);
      await fireGun(tester);
      await tap(tester, card);
      final second = await fireGun(tester);
      expect(save, findsNothing);
      expect(find.text('GUN ${clockText(second)}'), findsOneWidget);
    });
  });

  group('criterion 4: every event logged by hand on the card says source=manual', () {
    testWidgets('gun, postponement, general recall and a time fix are all manual; an undo is a tap', (tester) async {
      await openSequence(tester);
      await tap(tester, postponeButton);
      await fireGun(tester);
      await tap(tester, recallButton);
      await fireGun(tester);
      await tap(tester, card);
      await typeDigits(tester, '143000');
      await tap(tester, save);
      await tap(tester, find.text('UNDO TIME FIX'));
      final all = await events(tester);
      expect({for (final e in all) e.kind: e.source}, {
        StartKinds.postponement: 'manual',
        StartKinds.start: 'manual',
        StartKinds.generalRecall: 'manual',
        StartKinds.timeCorrected: 'manual',
        StartKinds.undo: 'tap',
      });
    });
  });

  group('criterion 5: the sequence card passes the bar-check helper', () {
    /// A race day already on the phone, three fleets named and one selected:
    /// its gun with the time fixed, and a full list of finishes, so every
    /// race-time action in the app can exist. ULIDs are real Crockford, so an
    /// undo of any of them is accepted by the core, as on a phone.
    FakeCore raceDay() {
      var t = DateTime(2026, 9, 26, 14, 30).millisecondsSinceEpoch;
      var seq = 0;
      final day = FakeCore(clock: () => t += 1000);
      EventEnvelope event(String kind, Map<String, Object?> payload, {String source = 'tap', String? corrects}) =>
          EventEnvelope(
            ulid: '01J8${(seq + 1).toString().padLeft(22, '0')}',
            deviceTs: t += 1000,
            deviceId: day.deviceIdValue,
            seq: ++seq,
            source: source,
            kind: kind,
            payloadVersion: 1,
            payload: payload,
            correctsUlid: corrects,
          );
      final ids = [
        for (final name in ['Lasers', '420s', 'Optis']) event(FleetKinds.defined, {'name': name, 'class': null}),
      ];
      day.seed(ids);
      final fleet = ids.first.ulid;
      final selected = event(FleetKinds.selected, {fleetPayloadKey: fleet});
      final gun = event(StartKinds.start, {fleetPayloadKey: fleet}, source: 'manual');
      day.seed([
        selected,
        gun,
        event(StartKinds.timeCorrected, {'time': gun.deviceTs - 3000}, source: 'manual', corrects: gun.ulid),
        for (var i = 0; i < 12; i++) event(FinishKinds.finish, {fleetPayloadKey: fleet}),
      ]);
      return day;
    }

    for (final scale in [1.0, 2.0]) {
      testWidgets('three fleets, a gun with its time fixed, at ${(scale * 100).round()}% text', (tester) async {
        final violations = await barCheck(
          tester,
          (observer) => app(textScale: scale, on: raceDay(), observer: observer),
        );
        expect(violations, isEmpty, reason: violations.join('\n'));
      });

      // After a recall no gun anchors, so there is nothing to fix until the
      // next GUN, and the whole-app check above cannot hold this state: it
      // would find the fix one tap past its limit. So the state's own targets
      // and labels are checked directly.
      testWidgets('after a general recall at ${(scale * 100).round()}% text, every target meets the bar',
          (tester) async {
        await openSequence(tester, textScale: scale);
        await fireGun(tester);
        await tap(tester, recallButton);
        expect(find.descendant(of: card, matching: find.text('GENERAL RECALL')), findsOneWidget);
        final targets =
            await const MinimumTapTargetGuideline(size: Size.square(Bars.minTargetDp), link: 'docs/usability-bars.md')
                .evaluate(tester);
        expect(targets.passed, isTrue, reason: targets.reason);
        expect(clippedLabels(tester), isEmpty);
      });

      testWidgets('at ${(scale * 100).round()}% text, "Not logged" leaves every control on screen', (tester) async {
        final ids = await defineFleets(tester, ['Lasers', '420s']);
        await openSequence(tester, textScale: scale);
        await tap(tester, fleetButton(ids[0]));
        await fireGun(tester);
        core.failWith = const CoreException('failed', 'disk full');
        await tap(tester, gunButton);
        expect(find.text('Not logged. Tap again.'), findsOneWidget);
        for (final control in [card, postponeButton, recallButton, gunButton, find.textContaining('UNDO GUN')]) {
          expect(control.hitTestable(), findsOneWidget, reason: '$control');
        }
      });

      if (scale == 2.0) {
        testWidgets('on a short phone at 200% text, "Not logged" makes the card scroll rather than overflow',
            (tester) async {
          final ids = await defineFleets(tester, ['Lasers', '420s']);
          tester.view.physicalSize = const Size(720, 1280); // 360 x 640 dp
          tester.view.devicePixelRatio = 2.0;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(app(textScale: 2));
          await tester.pumpAndSettle();
          await tap(tester, find.text('SEQUENCE'));
          await tap(tester, fleetButton(ids[0]));
          core.failWith = const CoreException('failed', 'disk full');
          await tap(tester, gunButton);
          expect(find.text('Not logged. Tap again.'), findsOneWidget);
          core.failWith = null;
          await tester.ensureVisible(recallButton);
          await tester.pumpAndSettle();
          await tap(tester, recallButton);
          expect((await events(tester)).where((e) => e.kind == StartKinds.generalRecall), hasLength(1));
        });
      }

      testWidgets('at ${(scale * 100).round()}% text every keypad key can be tapped without scrolling', (tester) async {
        final ids = await defineFleets(tester, ['Lasers', '420s']);
        await openSequence(tester, textScale: scale);
        await tap(tester, fleetButton(ids[0]));
        await fireGun(tester);
        await tap(tester, card);
        for (final key in ['key-1', 'key-9', 'key-del', 'key-0', 'keypad-save', 'keypad-cancel']) {
          expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget, reason: key);
        }
        expect(gunButton.hitTestable(), findsOneWidget);
      });

      testWidgets('at ${(scale * 100).round()}% text no button label is clipped or broken', (tester) async {
        final ids = await defineFleets(tester, ['Lasers', '420s', 'Optis']);
        await openSequence(tester, textScale: scale);
        expect(clippedLabels(tester), isEmpty, reason: 'no gun yet');
        await tap(tester, fleetButton(ids[2]));
        await fireGun(tester);
        await tap(tester, card);
        await typeDigits(tester, '14295');
        expect(clippedLabels(tester), isEmpty, reason: 'the keypad');
        await typeDigits(tester, '9');
        await tap(tester, save);
        await tap(tester, postponeButton);
        expect(clippedLabels(tester), isEmpty, reason: 'a fixed gun, postponed after');
        expect(find.textContaining('tapped'), findsOneWidget);
      });
    }
  });

  group('criterion 6: every sequence event is confirmed by one vibration and one tone', () {
    testWidgets('GUN, POSTPONE, GENERAL RECALL, a time fix and UNDO each fire exactly one of each', (tester) async {
      await openSequence(tester);
      var expected = 0;
      Future<void> step(Future<void> Function() act) async {
        await act();
        expected++;
        expect(device.vibrations, expected);
        expect(device.tones, List.filled(expected, BeepStream.notification));
      }

      await step(() => tap(tester, postponeButton));
      await step(() => fireGun(tester));
      await step(() => tap(tester, recallButton));
      await step(() => fireGun(tester));
      await tap(tester, card);
      await typeDigits(tester, '143000');
      expect(device.vibrations, expected, reason: 'opening the keypad and typing log nothing');
      await step(() => tap(tester, save));
      await step(() => tap(tester, find.text('UNDO TIME FIX')));
    });

    testWidgets('a sequence event the core refuses fires nothing and says so', (tester) async {
      await openSequence(tester);
      core.failWith = const CoreException('failed', 'disk full');
      await tap(tester, gunButton);
      expect(device.vibrations, 0);
      expect(device.tones, isEmpty);
      expect(find.text('Not logged. Tap again.'), findsOneWidget);
      expect(popups.opened, isEmpty);
      core.failWith = null;
      await tap(tester, gunButton);
      expect(device.vibrations, 1);
      expect(find.text('Not logged. Tap again.'), findsNothing);
    });
  });

  group('criterion 7: UNDO appends a correction, the anchor reverts, and no dialog appears', () {
    void noDialog() {
      expect(popups.opened, isEmpty);
      for (final type in const [AlertDialog, Dialog, SimpleDialog, BottomSheet]) {
        expect(find.byType(type), findsNothing);
      }
    }

    testWidgets('gun, recall, gun: UNDO GUN, then UNDO RECALL, walk the anchor back to the first gun',
        (tester) async {
      await openSequence(tester);
      final first = await fireGun(tester);
      await tap(tester, recallButton);
      final second = await fireGun(tester);
      final secondGun = (await events(tester)).lastWhere((e) => e.kind == StartKinds.start);

      await tap(tester, find.text('UNDO GUN (${clockText(second)})'));
      var all = await events(tester);
      final undo = all.singleWhere((e) => e.kind == StartKinds.undo);
      expect(undo.correctsUlid, secondGun.ulid);
      expect(all.singleWhere((e) => e.ulid == secondGun.ulid).toWire(), secondGun.toWire(), reason: 'kept');
      expect(elapsedAnchor(all, null), isNull, reason: 'back to after the recall');
      expect(find.descendant(of: card, matching: find.text('GENERAL RECALL')), findsOneWidget);

      await tap(tester, find.text('UNDO RECALL'));
      all = await events(tester);
      expect(elapsedAnchor(all, null)?.deviceTs, first, reason: 'the first gun anchors again');
      expect(find.text('GUN ${clockText(first)}'), findsOneWidget);
      expect(find.text('UNDO GUN (${clockText(first)})'), findsOneWidget);
      noDialog();
    });

    testWidgets('UNDO TIME FIX puts the gun back to the time it was tapped', (tester) async {
      await openSequence(tester);
      final tappedAt = await fireGun(tester);
      await tap(tester, card);
      await typeDigits(tester, '143000');
      await tap(tester, save);
      expect(find.text('GUN 14:30:00'), findsOneWidget);
      await tap(tester, find.text('UNDO TIME FIX'));
      expect(anchorTime(await events(tester), null), tappedAt);
      expect(find.text('GUN ${clockText(tappedAt)}'), findsOneWidget);
      noDialog();
    });

    testWidgets('UNDO POSTPONE takes the postponement back', (tester) async {
      await openSequence(tester);
      await tap(tester, postponeButton);
      await tap(tester, find.text('UNDO POSTPONE'));
      expect(sequenceOf(await events(tester), null), isEmpty);
      expect(find.text('NO GUN'), findsOneWidget);
      expect(find.text('Nothing to undo'), findsOneWidget);
    });

    testWidgets('after a fleet switch, UNDO takes the switch back first, as on the finish screen', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await openSequence(tester);
      await tap(tester, fleetButton(ids[0]));
      await fireGun(tester);
      await tap(tester, fleetButton(ids[1])); // the wrong fleet
      expect(find.text('UNDO SWITCH (420s)'), findsOneWidget);
      await tap(tester, find.text('UNDO SWITCH (420s)'));
      expect(selectedFleet(await events(tester), core.deviceIdValue), ids[0]);
      expect(find.textContaining('UNDO GUN'), findsOneWidget, reason: "then the fleet's own gun");
      noDialog();
    });
  });

  // The CI emulator is a 320 x 640 dp phone. Back from FLEETS the keyboard
  // is still up while a race-time screen lays out, and the fixed rows
  // overflowed what it left (PR #94's emulator job, 61 px on FINISHES).
  testWidgets('on a 320 x 640 phone with the keyboard still up, the sequence card lays out', (tester) async {
    final ids = await defineFleets(tester, ['Lasers', '420s']);
    tester.view.physicalSize = const Size(640, 1280);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 24 * 2.0);
    tester.view.viewPadding = const FakeViewPadding(top: 24 * 2.0);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tap(tester, find.text('SEQUENCE'));
    await tap(tester, fleetButton(ids[0]));
    tester.view.viewInsets = const FakeViewPadding(bottom: 243 * 2.0);
    await tester.pumpAndSettle();
    expect(gunButton, findsOneWidget);
  });

  group('#18 criterion 2, the start half: a fleet selected in at most 2 taps, and later sequence events carry it',
      () {
    testWidgets('three fleets: SEQUENCE, then the fleet; the gun, postponement and recall carry it', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s', 'Optis']);
      setPhoneSize(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tap(tester, find.text('SEQUENCE')); // tap 1
      await tap(tester, fleetButton(ids[1])); // tap 2
      expect(selectedFleet(await events(tester), core.deviceIdValue), ids[1]);

      await fireGun(tester);
      await tap(tester, fleetButton(ids[2]));
      await tap(tester, postponeButton);
      await tap(tester, recallButton);
      final sequence = [for (final e in await events(tester)) if (StartKinds.sequence.contains(e.kind)) e];
      expect(sequence.map((e) => (e.kind, fleetOf(e))), [
        (StartKinds.start, ids[1]),
        (StartKinds.postponement, ids[2]),
        (StartKinds.generalRecall, ids[2]),
      ]);
    });

    testWidgets('a fleet switched on the sequence card is the one the finish screen finishes', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await openSequence(tester);
      await tap(tester, fleetButton(ids[1]));
      await tap(tester, find.byTooltip('Back'));
      await tap(tester, find.text('FINISHES'));
      expect(find.text('Finishes · 420s · 0'), findsOneWidget);
    });
  });
}

class _Popups extends NavigatorObserver {
  final opened = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) opened.add(route);
  }
}
