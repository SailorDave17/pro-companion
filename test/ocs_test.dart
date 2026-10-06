import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/ui/bars.dart';
import 'package:pro_companion/ui/clock.dart';
import 'package:pro_companion/ui/race_time.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';

/// #29 on the app, driven against the fake core: INDIVIDUAL RECALL and the
/// OCS panel on the sequence card (owner's layout, 2026-10-06). A boat over
/// the line is logged against the start by her sail number, picked from the
/// boats the day's log knows or typed, and CLEARED when she comes back. The
/// core's half is packages/core/test/starts_test.dart.
void main() {
  late int now;
  late FakeCore core;
  late FakeConfirmationDevice device;
  late _Popups popups;

  Finder action(String id) => find.descendant(
        of: find.byWidgetPredicate((w) => w is RaceTimeAction && w.id == id),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      );
  final gunButton = find.widgetWithText(FilledButton, 'GUN');
  final recallButton = find.widgetWithText(OutlinedButton, 'GENERAL RECALL');
  final ocsButton = action('ocs');
  final individualRecallButton = action('individual-recall');
  final card = find.byKey(const ValueKey('start-card'));
  Finder sail(String s) => find.byKey(ValueKey('ocs-sail-$s'));
  final cleared = find.byKey(const ValueKey('ocs-cleared'));
  final typeSail = find.byKey(const ValueKey('ocs-type'));
  final close = find.byKey(const ValueKey('ocs-close'));
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

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  Future<void> openSequence(WidgetTester tester, {double textScale = 1}) async {
    setPhoneSize(tester);
    await tester.pumpWidget(app(textScale: textScale));
    await tester.pumpAndSettle();
    await tap(tester, find.text('SEQUENCE'));
    expect(gunButton, findsOneWidget);
  }

  Future<List<EventEnvelope>> events(WidgetTester tester) async => (await tester.runAsync(core.readAll))!;

  Future<EventEnvelope> append(WidgetTester tester, NewEvent e) async => (await tester.runAsync(() => core.append(e)))!;

  Future<List<String>> defineFleets(WidgetTester tester, List<String> names) async =>
      [for (final n in names) (await append(tester, FleetEvents.define(n))).ulid];

  /// A finish already logged for [fleet], with [sails] given to it in turn.
  Future<void> finished(WidgetTester tester, String? fleet, List<String> sails) async {
    final f = await append(tester, FinishEvents.finish(fleet: fleet));
    for (final s in sails) {
      await append(tester, FinishEvents.assignSail(f.ulid, s));
    }
  }

  /// Taps GUN, and returns the start it logged.
  Future<EventEnvelope> fireGun(WidgetTester tester) async {
    await tap(tester, gunButton);
    return (await events(tester)).lastWhere((e) => e.kind == StartKinds.start);
  }

  Future<void> typeDigits(WidgetTester tester, String digits) async {
    for (final d in digits.split('')) {
      await tester.tap(find.byKey(ValueKey('key-$d')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, Finder f) => tester.widget<ButtonStyleButton>(f).onPressed != null;

  /// What a boat's cell on the OCS panel shows: offered, over (black),
  /// selected for CLEARED, or cleared.
  String cell(WidgetTester tester, String s) => switch (tester.widget<ButtonStyleButton>(sail(s))) {
        final OutlinedButton b when b.onPressed != null => 'offered',
        OutlinedButton() => 'cleared',
        FilledButton() => 'over',
        ElevatedButton() => 'selected',
        final b => '${b.runtimeType}',
      };

  List<EventEnvelope> ofKind(List<EventEnvelope> all, String kind) => all.where((e) => e.kind == kind).toList();

  void noDialog() {
    expect(popups.opened, isEmpty);
    for (final type in const [AlertDialog, Dialog, SimpleDialog, BottomSheet]) {
      expect(find.byType(type), findsNothing);
    }
  }

  group('criterion 1: OCS, then a sail number picked or typed, appends an OCS naming the start and the sail', () {
    testWidgets('picked: the event names the gun, the sail and the fleet, source manual', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await finished(tester, ids[0], ['2201']);
      await openSequence(tester);
      await tap(tester, find.byKey(ValueKey('fleet-switch-${ids[0]}')));
      final gun = await fireGun(tester);

      await tap(tester, ocsButton);
      expect(find.text('OCS · gun ${clockText(gun.deviceTs)}'), findsOneWidget);
      expect(find.text('Nobody over'), findsOneWidget);
      expect(gunButton, findsOneWidget, reason: 'GUN stays where it is while the panel is open');
      await tap(tester, sail('2201'));

      final ocs = ofKind(await events(tester), StartKinds.ocs).single;
      expect(ocs.payload, {'fleet': ids[0], 'start': gun.ulid, 'sail': '2201'});
      expect(ocs.source, 'manual');
      expect(find.text('1 over'), findsOneWidget, reason: 'the panel stays open for the next boat');
      expect(cell(tester, '2201'), 'over');

      await tap(tester, sail('2201'));
      expect(ofKind(await events(tester), StartKinds.ocs), hasLength(1), reason: 'a boat over is not logged twice');
      expect(cell(tester, '2201'), 'selected', reason: 'tapping her again selects her for CLEARED');

      await tap(tester, close);
      expect(card, findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'OCS · 1'), findsOneWidget);
    });

    testWidgets('typed: Type #, the digits, Save; the keypad stays for the next boat, Close goes back',
        (tester) async {
      await openSequence(tester);
      final gun = await fireGun(tester);
      await tap(tester, ocsButton);
      expect(find.text('No sail numbers known yet · type one'), findsOneWidget,
          reason: "the day's first start knows nobody");
      await tap(tester, typeSail);
      expect(enabled(tester, save), isFalse);
      await typeDigits(tester, '45');
      await tap(tester, save);

      final ocs = ofKind(await events(tester), StartKinds.ocs).single;
      expect(ocs.payload, {'fleet': null, 'start': gun.ulid, 'sail': '45'});
      expect(find.text('—'), findsOneWidget, reason: 'cleared for the next boat');
      await typeDigits(tester, '45');
      expect(find.text('45 · already logged'), findsOneWidget);
      expect(enabled(tester, save), isFalse);

      await tap(tester, find.byKey(const ValueKey('keypad-cancel')));
      expect(cell(tester, '45'), 'over');
      expect(ofKind(await events(tester), StartKinds.ocs), hasLength(1));
    });

    testWidgets("only this fleet's boats from today's log are offered, newest first", (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await finished(tester, ids[0], ['22', '2201']); // a typo, then the fix
      await finished(tester, ids[1], ['5150']);
      await finished(tester, ids[0], ['887']);
      await openSequence(tester);
      await tap(tester, find.byKey(ValueKey('fleet-switch-${ids[0]}')));
      await fireGun(tester);
      await tap(tester, ocsButton);
      String? keyOf(Widget w) => w.key is ValueKey<String> ? (w.key! as ValueKey<String>).value : null;
      final offered = [
        for (final e in find.byWidgetPredicate((w) => keyOf(w)?.startsWith('ocs-sail-') ?? false).evaluate())
          keyOf(e.widget)!.substring('ocs-sail-'.length),
      ];
      expect(offered, ['887', '2201']);
    });

    testWidgets('before a gun, and after a general recall, OCS and INDIVIDUAL RECALL do nothing', (tester) async {
      await openSequence(tester);
      expect(enabled(tester, ocsButton), isFalse);
      expect(enabled(tester, individualRecallButton), isFalse);
      await fireGun(tester);
      expect(enabled(tester, ocsButton), isTrue);
      expect(enabled(tester, individualRecallButton), isTrue);
      await tap(tester, recallButton);
      expect(enabled(tester, ocsButton), isFalse);
      expect(enabled(tester, individualRecallButton), isFalse);
    });

    testWidgets('a new GUN while the panel is open puts the card back: the next start begins with nobody over',
        (tester) async {
      await openSequence(tester);
      final first = await fireGun(tester);
      await tap(tester, ocsButton);
      await tap(tester, typeSail);
      await typeDigits(tester, '7');
      await tap(tester, save);
      final second = await fireGun(tester);
      expect(card, findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'OCS'), findsOneWidget);
      await tap(tester, ocsButton);
      expect(find.text('Nobody over'), findsOneWidget);
      await tap(tester, sail('7'));
      final all = await events(tester);
      expect(ocsAt(all, first).map((o) => o.sail), ['7'], reason: "the first start's boat is kept with it");
      expect(ofKind(all, StartKinds.ocs).last.payload['start'], second.ulid, reason: 'the gun that anchors now');
      expect(ocsAt(all, second).map((o) => o.sail), ['7']);
    });
  });

  group('criterion 2: INDIVIDUAL RECALL appends an individual recall naming the start', () {
    testWidgets('one event naming the gun and the fleet, source manual; the gun still anchors', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await openSequence(tester);
      await tap(tester, find.byKey(ValueKey('fleet-switch-${ids[1]}')));
      final gun = await fireGun(tester);
      await tap(tester, individualRecallButton);

      final all = await events(tester);
      final recall = ofKind(all, StartKinds.individualRecall).single;
      expect(recall.payload, {'fleet': ids[1], 'start': gun.ulid});
      expect(recall.source, 'manual');
      expect(elapsedAnchor(all, ids[1])?.ulid, gun.ulid);
      expect(find.text('GUN ${clockText(gun.deviceTs)}'), findsOneWidget);
      expect(find.textContaining('individual recall'), findsOneWidget);
    });
  });

  group('criterion 3: CLEARED appends a correction naming the OCS, and the OCS is kept', () {
    testWidgets('select the boat, CLEARED: the clearance names her OCS, which is untouched', (tester) async {
      await finished(tester, null, ['1234']);
      await finished(tester, null, ['887']);
      await openSequence(tester);
      await fireGun(tester);
      await tap(tester, ocsButton);
      await tap(tester, sail('1234'));
      await tap(tester, sail('887'));
      // The second boat over, so a clearance of whichever boat came first
      // would name the wrong one.
      final ocs = ofKind(await events(tester), StartKinds.ocs).firstWhere((e) => e.payload['sail'] == '887');
      expect(cleared, findsNothing, reason: 'nothing selected yet');

      await tap(tester, sail('887'));
      expect(cell(tester, '887'), 'selected');
      expect(find.text('CLEARED (887)'), findsOneWidget);
      await tap(tester, cleared);

      final all = await events(tester);
      final clearance = ofKind(all, StartKinds.ocsCleared).single;
      expect(clearance.correctsUlid, ocs.ulid);
      expect(clearance.source, 'manual');
      expect(all.singleWhere((e) => e.ulid == ocs.ulid).toWire(), ocs.toWire(), reason: 'kept as logged');
      expect(cell(tester, '887'), 'cleared', reason: 'a cleared boat is not cleared twice');
      expect(find.descendant(of: sail('887'), matching: find.text('cleared')), findsOneWidget);
      expect(cell(tester, '1234'), 'over');
      expect(find.text('1 over'), findsOneWidget);
      expect(cleared, findsNothing);
    });

    testWidgets('a screen reader hears whether a boat is offered, over, selected or cleared', (tester) async {
      final semantics = tester.ensureSemantics();
      await finished(tester, null, ['1234']);
      await finished(tester, null, ['887']);
      await openSequence(tester);
      await fireGun(tester);
      await tap(tester, ocsButton);
      String spoken(String s) => tester.getSemantics(sail(s)).label;
      expect(spoken('887'), '887');
      await tap(tester, sail('887'));
      expect(spoken('887'), '887, over the line');
      await tap(tester, sail('887'));
      expect(spoken('887'), '887, over the line, selected');
      await tap(tester, cleared);
      expect(spoken('887'), contains('cleared'));
      expect(spoken('1234'), '1234');
      semantics.dispose();
    });

    testWidgets('tapping the selected boat again unselects her, and logs nothing', (tester) async {
      await openSequence(tester);
      await fireGun(tester);
      await tap(tester, ocsButton);
      await tap(tester, typeSail);
      await typeDigits(tester, '9');
      await tap(tester, save);
      await tap(tester, find.byKey(const ValueKey('keypad-cancel')));
      await tap(tester, sail('9'));
      expect(cleared, findsOneWidget);
      await tap(tester, sail('9'));
      expect(cleared, findsNothing);
      expect(cell(tester, '9'), 'over');
      expect(ofKind(await events(tester), StartKinds.ocsCleared), isEmpty);
    });
  });

  group('criterion 4: the OCS panel passes the bar-check helper, and a known boat takes at most 2 taps', () {
    /// A race day already on the phone: three fleets, one selected, eight
    /// finishes with sail numbers, then a gun with two boats over, one of
    /// them cleared. So the panel OCS opens has boats over, a cleared boat and
    /// known boats to pick, and every other race-time action can exist too.
    /// ULIDs are real Crockford, so an undo of any of them is accepted.
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
      final fleets = [
        for (final name in ['Lasers', '420s', 'Optis']) event(FleetKinds.defined, {'name': name, 'class': null}),
      ];
      final fleet = fleets.first.ulid;
      final selected = event(FleetKinds.selected, {fleetPayloadKey: fleet});
      final finishes = [for (var i = 0; i < 8; i++) event(FinishKinds.finish, {fleetPayloadKey: fleet})];
      final sails = [
        for (final (i, f) in finishes.indexed) event(FinishKinds.sail, {'finish': f.ulid, 'sail': '${2200 + i}'}),
      ];
      final gun = event(StartKinds.start, {fleetPayloadKey: fleet}, source: 'manual');
      final over = event(StartKinds.ocs, {fleetPayloadKey: fleet, 'start': gun.ulid, 'sail': '2203'}, source: 'manual');
      final back = event(StartKinds.ocs, {fleetPayloadKey: fleet, 'start': gun.ulid, 'sail': '2205'}, source: 'manual');
      day.seed([
        ...fleets,
        selected,
        ...finishes,
        ...sails,
        gun,
        over,
        back,
        event(StartKinds.ocsCleared, const {}, source: 'manual', corrects: back.ulid),
      ]);
      return day;
    }

    for (final scale in [1.0, 2.0]) {
      testWidgets('the whole app, with boats over, cleared and known, at ${(scale * 100).round()}% text',
          (tester) async {
        final violations = await barCheck(
          tester,
          (observer) => app(textScale: scale, on: raceDay(), observer: observer),
        );
        expect(violations, isEmpty, reason: violations.join('\n'));
      });

      // Selecting a boat and typing a sail are each a tap past the panel, so
      // past the whole-app check's depth, as the time keypad's digits are.
      // Their states are checked here directly.
      testWidgets('at ${(scale * 100).round()}% text, CLEARED and the sail keypad meet the bar', (tester) async {
        await finished(tester, null, ['1234']);
        await finished(tester, null, ['887']);
        await openSequence(tester, textScale: scale);
        await fireGun(tester);
        await tap(tester, ocsButton);
        await tap(tester, sail('1234'));
        await tap(tester, sail('1234'));
        expect(cleared.hitTestable(), findsOneWidget, reason: 'CLEARED is on screen without a scroll');
        Future<void> meetsBar(String state) async {
          final targets =
              await const MinimumTapTargetGuideline(size: Size.square(Bars.minTargetDp), link: 'docs/usability-bars.md')
                  .evaluate(tester);
          expect(targets.passed, isTrue, reason: '$state: ${targets.reason}');
          expect(clippedLabels(tester), isEmpty, reason: state);
        }

        await meetsBar('a boat selected');
        // The guideline skips a target on a scrollable's edge, which is where
        // CLEARED can sit; its size is read directly.
        expect(tester.getSize(cleared).height, greaterThanOrEqualTo(Bars.minTargetDp));
        await tap(tester, typeSail);
        await typeDigits(tester, '1234');
        expect(find.text('1234 · already logged'), findsOneWidget);
        await meetsBar('the sail keypad');
        for (final key in ['key-1', 'key-9', 'key-del', 'key-0', 'keypad-save', 'keypad-cancel']) {
          expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget, reason: key);
        }
        noDialog();
      });

      // Rendered on the emulator, the first layout moved every boat after a
      // tap: an "over" row appeared above the grid, and the boat logged left
      // it. The next boat tapped was whatever had moved under the thumb
      // (owner's choice: nothing moves, 2026-10-06).
      testWidgets('at ${(scale * 100).round()}% text, logging, selecting, clearing and undoing move no boat',
          (tester) async {
        final boats = ['501', '502', '503', '504', '505', '506'];
        for (final s in boats) {
          await finished(tester, null, [s]);
        }
        await openSequence(tester, textScale: scale);
        await fireGun(tester);
        await tap(tester, ocsButton);
        final cells = [typeSail, close, for (final s in boats) sail(s)];
        final at = [for (final c in cells) tester.getRect(c)];
        Future<void> still(String step) async {
          for (final (i, c) in cells.indexed) {
            expect(tester.getRect(c), at[i], reason: '$step moved $c');
          }
        }

        await tap(tester, sail('505'));
        await still('logging 505');
        await tap(tester, sail('502'));
        await still('logging 502');
        await tap(tester, sail('505'));
        await still('selecting 505');
        await tap(tester, cleared);
        await still('clearing 505');
        await tap(tester, find.text('UNDO CLEARED (505)'));
        await still('undoing the clearance');
        await tap(tester, find.text('UNDO OCS (502)'));
        await still('undoing 502');
        expect([for (final s in boats) cell(tester, s)], ['offered', 'offered', 'offered', 'offered', 'over', 'offered']);
      });

      testWidgets('at ${(scale * 100).round()}% text, with twenty boats known, Type # is still first and on screen',
          (tester) async {
        for (var i = 0; i < 20; i++) {
          await finished(tester, null, ['${100 + i}']);
        }
        await openSequence(tester, textScale: scale);
        await fireGun(tester);
        await tap(tester, ocsButton);
        expect(typeSail.hitTestable(), findsOneWidget);
        expect(sail('119').hitTestable(), findsOneWidget, reason: 'the newest boat is next to it');
        expect(clippedLabels(tester), isEmpty);
      });
    }

    // On the emulator, Material's own button padding left a four-across cell
    // 41 dp for its label, and 1234 shrank below 77. The test font draws
    // every glyph square, so it cannot show which labels shrink on a phone;
    // what it can show is the room a cell gives its label. A label wider than
    // that room fills it, so these two read it exactly.
    testWidgets('at 100% text a cell gives its label at least 60 dp', (tester) async {
      await finished(tester, null, ['1234']);
      await openSequence(tester);
      await fireGun(tester);
      await tap(tester, ocsButton);
      for (final (cellFinder, label) in [(sail('1234'), '1234'), (typeSail, 'Type #')]) {
        final fitted = find.ancestor(of: find.descendant(of: cellFinder, matching: find.text(label)), matching: find.byType(FittedBox));
        expect(tester.getSize(fitted.first).width, greaterThanOrEqualTo(60), reason: label);
      }
    });

    testWidgets('from the sequence card, a known boat is OCS then her sail number: 2 taps', (tester) async {
      await finished(tester, null, ['2201']);
      await openSequence(tester);
      final gun = await fireGun(tester);
      final before = (await events(tester)).length;

      await tap(tester, ocsButton); // tap 1
      expect((await events(tester)).length, before, reason: 'opening the panel logs nothing');
      await tap(tester, sail('2201')); // tap 2

      final all = await events(tester);
      expect(all, hasLength(before + 1));
      expect(all.last.kind, StartKinds.ocs);
      expect(all.last.payload['start'], gun.ulid);
      expect(all.last.payload['sail'], '2201');
    });

    // The CI emulator is a 320 x 640 dp phone, where the card's space is
    // smallest; the panel scrolls rather than overflows.
    testWidgets('on a 320 x 640 phone at 200% text, the panel lays out and its first row is on screen',
        (tester) async {
      for (var i = 0; i < 6; i++) {
        await finished(tester, null, ['${100 + i}']);
      }
      tester.view.physicalSize = const Size(640, 1280);
      tester.view.devicePixelRatio = 2.0;
      tester.view.padding = const FakeViewPadding(top: 24 * 2.0);
      tester.view.viewPadding = const FakeViewPadding(top: 24 * 2.0);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(textScale: 2));
      await tester.pumpAndSettle();
      await tap(tester, find.text('SEQUENCE'));
      await fireGun(tester);
      await tester.ensureVisible(ocsButton);
      await tester.pumpAndSettle();
      await tap(tester, ocsButton);
      expect(close.hitTestable(), findsOneWidget);
      expect(typeSail.hitTestable(), findsOneWidget);
      expect(gunButton.hitTestable(), findsOneWidget);
    });
  });

  group('criterion 5: an OCS is confirmed by one vibration and one tone', () {
    testWidgets('OCS picked, OCS typed, INDIVIDUAL RECALL, CLEARED and UNDO each fire exactly one of each',
        (tester) async {
      await finished(tester, null, ['2201']);
      await openSequence(tester);
      await fireGun(tester);
      var expected = device.vibrations;
      Future<void> step(Future<void> Function() act) async {
        await act();
        expected++;
        expect(device.vibrations, expected);
        expect(device.tones, List.filled(expected, BeepStream.notification));
      }

      await step(() => tap(tester, individualRecallButton));
      await tap(tester, ocsButton);
      expect(device.vibrations, expected, reason: 'opening the panel logs nothing');
      await step(() => tap(tester, sail('2201')));
      await tap(tester, typeSail);
      await typeDigits(tester, '45');
      expect(device.vibrations, expected, reason: 'typing logs nothing');
      await step(() => tap(tester, save));
      await tap(tester, find.byKey(const ValueKey('keypad-cancel')));
      await tap(tester, sail('2201'));
      expect(device.vibrations, expected, reason: 'selecting a boat logs nothing');
      await step(() => tap(tester, cleared));
      await step(() => tap(tester, find.text('UNDO CLEARED (2201)')));
    });

    testWidgets('an OCS the core refuses fires nothing, says so, and leaves the panel for the retry', (tester) async {
      await finished(tester, null, ['2201']);
      await openSequence(tester);
      await fireGun(tester);
      final fired = device.vibrations;
      await tap(tester, ocsButton);
      core.failWith = const CoreException('failed', 'disk full');
      await tap(tester, sail('2201'));
      expect(device.vibrations, fired);
      expect(device.tones, hasLength(fired));
      expect(find.text('Not logged. Tap again.'), findsOneWidget);
      expect(sail('2201'), findsOneWidget, reason: 'still offered, for the retry');
      core.failWith = null;
      await tap(tester, sail('2201'));
      expect(device.vibrations, fired + 1);
      expect(ofKind(await events(tester), StartKinds.ocs), hasLength(1));
    });
  });

  group('criterion 6: UNDO right after an OCS appends a correction, with no confirm dialog', () {
    testWidgets('UNDO OCS names the OCS, keeps it, and offers the boat again', (tester) async {
      await finished(tester, null, ['2201']);
      await openSequence(tester);
      await fireGun(tester);
      await tap(tester, ocsButton);
      await tap(tester, sail('2201'));
      final ocs = ofKind(await events(tester), StartKinds.ocs).single;

      await tap(tester, find.text('UNDO OCS (2201)'));
      final all = await events(tester);
      final undo = ofKind(all, StartKinds.undo).single;
      expect(undo.correctsUlid, ocs.ulid);
      expect(all.singleWhere((e) => e.ulid == ocs.ulid).toWire(), ocs.toWire(), reason: 'kept as logged');
      expect(cell(tester, '2201'), 'offered', reason: 'offered again, in the same cell');
      expect(find.text('Nobody over'), findsOneWidget);
      noDialog();
    });

    testWidgets('UNDO INDIVIDUAL RECALL takes the recall back', (tester) async {
      await openSequence(tester);
      final gun = await fireGun(tester);
      await tap(tester, individualRecallButton);
      await tap(tester, find.text('UNDO INDIVIDUAL RECALL'));
      expect(individualRecallsOf(await events(tester), gun), isEmpty);
      expect(find.textContaining('individual recall'), findsNothing);
      noDialog();
    });

    testWidgets('every event the OCS panel logs says source=manual; an undo is a tap', (tester) async {
      await finished(tester, null, ['2201']);
      await openSequence(tester);
      await fireGun(tester);
      await tap(tester, individualRecallButton);
      await tap(tester, ocsButton);
      await tap(tester, sail('2201'));
      await tap(tester, sail('2201'));
      await tap(tester, cleared);
      await tap(tester, find.text('UNDO CLEARED (2201)'));
      final all = await events(tester);
      expect({for (final e in all.where((e) => StartKinds.all.contains(e.kind))) e.kind: e.source}, {
        StartKinds.start: 'manual',
        StartKinds.individualRecall: 'manual',
        StartKinds.ocs: 'manual',
        StartKinds.ocsCleared: 'manual',
        StartKinds.undo: 'tap',
      });
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
