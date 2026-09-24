import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';

/// #4 criteria 4-9 on the finish screen, driven against the fake core with a
/// fake clock. The core has no network path at all (#24's import boundary),
/// so every test here is an airplane-mode test.
void main() {
  late int now;
  late FakeCore core;
  late FakeConfirmationDevice device;
  late _Popups popups;

  final finishButton = find.widgetWithText(FilledButton, 'FINISH');

  setUp(() {
    now = DateTime(2026, 9, 26, 14, 30).millisecondsSinceEpoch;
    core = FakeCore(clock: () => now);
    device = FakeConfirmationDevice();
    popups = _Popups();
  });

  Future<void> openFinishScreen(WidgetTester tester, {double textScale = 1}) async {
    setPhoneSize(tester);
    await tester.pumpWidget(MediaQuery.withClampedTextScaling(
      minScaleFactor: textScale,
      maxScaleFactor: textScale,
      child: ProCompanionApp(
        core: core,
        confirmation: ConfirmationService(device),
        navigatorObservers: [popups],
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FINISHES'));
    await tester.pumpAndSettle();
    expect(finishButton, findsOneWidget);
  }

  Future<List<EventEnvelope>> events(WidgetTester tester) async => (await tester.runAsync(core.readAll))!;

  Future<List<EventEnvelope>> finishes(WidgetTester tester) async =>
      [for (final e in await events(tester)) if (e.kind == FinishKinds.finish) e];

  Finder row(String ulid) => find.byKey(ValueKey('row-$ulid'));

  // Look events up by kind or ULID, never by position: two events in one
  // millisecond read back in ULID order, whose tail is random.
  EventEnvelope only(List<EventEnvelope> all, String kind) => all.singleWhere((e) => e.kind == kind);
  EventEnvelope byUlid(List<EventEnvelope> all, String ulid) => all.singleWhere((e) => e.ulid == ulid);

  group('criterion 4: every tap is one finish, shown within 100 ms', () {
    testWidgets('taps 300 ms apart: each appends one finish and shows in the list within 100 ms',
        (tester) async {
      await openFinishScreen(tester);
      for (var i = 1; i <= 6; i++) {
        await tester.tap(finishButton);
        await tester.pump(const Duration(milliseconds: 100));
        final logged = await finishes(tester);
        expect(logged, hasLength(i), reason: 'tap $i appended exactly one finish');
        expect(row(logged.last.ulid), findsOneWidget, reason: 'tap $i shown within 100 ms');
        await tester.pump(const Duration(milliseconds: 200));
        now += 300;
      }
      expect(find.text('Finishes · 6'), findsOneWidget);
    });

    testWidgets('two taps with no gap at all are two finishes, not one', (tester) async {
      await openFinishScreen(tester);
      await tester.tap(finishButton);
      await tester.tap(finishButton);
      await tester.pump(const Duration(milliseconds: 100));
      final logged = await finishes(tester);
      expect(logged, hasLength(2), reason: 'none dropped or coalesced');
      for (final f in logged) {
        expect(row(f.ulid), findsOneWidget);
      }
    });
  });

  group('criterion 5: one vibration and one tone per committed append, none for a failure', () {
    testWidgets('each logged finish fires exactly one of each, on the notification stream', (tester) async {
      await openFinishScreen(tester);
      expect(device.vibrations, 0);
      for (var i = 1; i <= 3; i++) {
        await tester.tap(finishButton);
        await tester.pumpAndSettle();
        expect(device.vibrations, i);
        expect(device.tones, List.filled(i, BeepStream.notification));
      }
    });

    testWidgets('a failed append fires nothing and says so, without a dialog', (tester) async {
      await openFinishScreen(tester);
      core.failWith = const CoreException('failed', 'disk full');
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      expect(device.vibrations, 0);
      expect(device.tones, isEmpty);
      expect(find.text('Not logged. Tap again.'), findsOneWidget);
      expect(popups.opened, isEmpty);

      core.failWith = null;
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      expect(device.vibrations, 1);
      expect(find.text('Not logged. Tap again.'), findsNothing);
      expect(await finishes(tester), hasLength(1));
    });

    testWidgets('a buzzer that fails does not unlog a finish', (tester) async {
      await openFinishScreen(tester);
      device.vibrateThrows = StateError('no vibrator');
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      final logged = await finishes(tester);
      expect(logged, hasLength(1));
      expect(row(logged.single.ulid), findsOneWidget);
      expect(device.tones, [BeepStream.notification], reason: 'the beep still fires');
      expect(find.text('Not logged. Tap again.'), findsNothing);
    });
  });

  group('criterion 6: undo is a correction, never an edit, and never a prompt', () {
    testWidgets('Undo last appends a correction naming the last finish; the original is unchanged',
        (tester) async {
      await openFinishScreen(tester);
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      now += 5000;
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      final before = await finishes(tester);
      final last = before[1];

      await tester.tap(find.text('UNDO LAST (#2)'));
      await tester.pumpAndSettle();

      final after = await events(tester);
      expect(after, hasLength(3));
      final undo = only(after, FinishKinds.undo);
      expect(undo.correctsUlid, last.ulid);
      for (final f in before) {
        expect(byUlid(after, f.ulid).toWire(), f.toWire(), reason: 'the original is unchanged');
      }
      expect(row(last.ulid), findsNothing);
      expect(find.text('Finishes · 1'), findsOneWidget);
      expect(device.vibrations, 3, reason: 'the undo is confirmed like any other action');
      expect(popups.opened, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('Undo this, on a row, undoes that row only', (tester) async {
      await openFinishScreen(tester);
      for (var i = 0; i < 3; i++) {
        await tester.tap(finishButton);
        await tester.pumpAndSettle();
        now += 1000;
      }
      final logged = await finishes(tester);
      await tester.tap(row(logged[1].ulid));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo this'));
      await tester.pumpAndSettle();

      final undo = only(await events(tester), FinishKinds.undo);
      expect(undo.correctsUlid, logged[1].ulid);
      expect(row(logged[0].ulid), findsOneWidget);
      expect(row(logged[1].ulid), findsNothing);
      expect(row(logged[2].ulid), findsOneWidget);
      expect(popups.opened, isEmpty);
    });

    testWidgets('with nothing to undo, Undo last says so and does nothing', (tester) async {
      await openFinishScreen(tester);
      expect(find.text('Nothing to undo'), findsOneWidget);
      await tester.tap(find.text('Nothing to undo'));
      await tester.pumpAndSettle();
      expect(await events(tester), isEmpty);
    });
  });

  testWidgets('criterion 7: a missed finish goes between A and B with a gap marker; A and B stay',
      (tester) async {
    await openFinishScreen(tester);
    await tester.tap(finishButton);
    await tester.pumpAndSettle();
    now += 4000;
    await tester.tap(finishButton);
    await tester.pumpAndSettle();
    final before = await finishes(tester);
    final (a, b) = (before[0], before[1]);

    await tester.tap(row(b.ulid));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Missed above'));
    await tester.pumpAndSettle();

    final all = await events(tester);
    final missed = only(all, FinishKinds.missed);
    expect(missed.payload, {'gap': true, 'after': a.ulid, 'before': b.ulid});
    expect(byUlid(all, a.ulid).toWire(), a.toWire());
    expect(byUlid(all, b.ulid).toWire(), b.toWire());

    final ys = [for (final u in [a.ulid, missed.ulid, b.ulid]) tester.getTopLeft(row(u)).dy];
    expect(ys, orderedEquals([...ys]..sort()), reason: 'shown between A and B');
    expect(find.text('missed · time unknown'), findsOneWidget);
    expect(find.text('Finishes · 3'), findsOneWidget);
    expect(popups.opened, isEmpty);
  });

  group('criterion 8: a sail number is a new event, then or later', () {
    Future<void> typeSail(WidgetTester tester, String ulid, String digits) async {
      await tester.tap(find.byKey(ValueKey('sail-$ulid')));
      await tester.pumpAndSettle();
      for (final d in digits.split('')) {
        await tester.tap(find.byKey(ValueKey('key-$d')));
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('keypad-save')));
      await tester.pumpAndSettle();
      // The keypad may have walked on to the next unnamed finish; leave it.
      final close = find.byKey(const ValueKey('keypad-cancel'));
      if (close.evaluate().isNotEmpty) {
        await tester.tap(close);
        await tester.pumpAndSettle();
      }
    }

    testWidgets('assigned straight after the tap', (tester) async {
      await openFinishScreen(tester);
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      final a = (await finishes(tester)).single;

      await typeSail(tester, a.ulid, '123');

      final all = await events(tester);
      expect(all, hasLength(2));
      expect(only(all, FinishKinds.sail).payload, {'finish': a.ulid, 'sail': '123'});
      expect(byUlid(all, a.ulid).toWire(), a.toWire(), reason: 'the finish is not rewritten');
      expect(find.widgetWithText(OutlinedButton, '123'), findsOneWidget);
    });

    testWidgets('assigned later, and changed again: every assignment is kept', (tester) async {
      await openFinishScreen(tester);
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      final a = (await finishes(tester)).single;
      now += 1000;
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      await typeSail(tester, a.ulid, '45');
      final firstAssignment = only(await events(tester), FinishKinds.sail);
      now += 1000;
      await typeSail(tester, a.ulid, '6');

      final all = await events(tester);
      final sails = [for (final e in all) if (e.kind == FinishKinds.sail) e];
      expect(all.where((e) => e.kind == FinishKinds.finish), hasLength(2));
      expect(sails, hasLength(2), reason: 'a change is a second event, not an edit');
      expect(byUlid(all, firstAssignment.ulid).toWire(), firstAssignment.toWire(),
          reason: 'the earlier assignment is kept');
      expect(sails.singleWhere((e) => e.ulid != firstAssignment.ulid).payload['sail'], '456',
          reason: 'the keypad opens on the current number');
      expect(find.widgetWithText(OutlinedButton, '456'), findsOneWidget);
    });

    testWidgets('FINISH still works while the keypad is open', (tester) async {
      await openFinishScreen(tester);
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      final a = (await finishes(tester)).single;
      await tester.tap(find.byKey(ValueKey('sail-${a.ulid}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('key-1')), findsOneWidget);

      now += 700;
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      expect(await finishes(tester), hasLength(2), reason: 'a boat crossing mid-typing is not lost');
    });

    // The design-bar criterion (owner, 2026-09-24): naming after the rush is
    // type, Save, type, Save - the keypad walks the unnamed finishes in order.
    group('the keypad walks the unnamed finishes', () {
      Future<List<EventEnvelope>> logFinishes(WidgetTester tester, int n) async {
        for (var i = 0; i < n; i++) {
          await tester.tap(finishButton);
          await tester.pumpAndSettle();
          now += 1000;
        }
        return finishes(tester);
      }

      Future<void> type(WidgetTester tester, String digits) async {
        for (final d in digits.split('')) {
          await tester.tap(find.byKey(ValueKey('key-$d')));
          await tester.pump();
        }
        await tester.tap(find.byKey(const ValueKey('keypad-save')));
        await tester.pumpAndSettle();
      }

      String sailOf(List<EventEnvelope> all, String finishUlid) => all
          .lastWhere((e) => e.kind == FinishKinds.sail && e.payload['finish'] == finishUlid)
          .payload['sail'] as String;

      testWidgets('after Save it opens on the next finish without a number, and closes after the last',
          (tester) async {
        await openFinishScreen(tester);
        final f = await logFinishes(tester, 4);
        await tester.tap(find.byKey(ValueKey('sail-${f[0].ulid}')));
        await tester.pumpAndSettle();
        for (var i = 0; i < 4; i++) {
          expect(find.textContaining('Sail for #${i + 1} '), findsOneWidget, reason: 'on finish ${i + 1}');
          await type(tester, '${i + 1}${i + 1}');
        }
        expect(find.byKey(const ValueKey('key-1')), findsNothing, reason: 'closed after the last');
        final all = await events(tester);
        for (var i = 0; i < 4; i++) {
          expect(sailOf(all, f[i].ulid), '${i + 1}${i + 1}');
        }
      });

      testWidgets('it skips a finish that already has a number', (tester) async {
        await openFinishScreen(tester);
        final f = await logFinishes(tester, 3);
        await tester.tap(find.byKey(ValueKey('sail-${f[1].ulid}')));
        await tester.pumpAndSettle();
        await type(tester, '22');
        expect(find.byKey(const ValueKey('key-1')), findsOneWidget, reason: '#3 is next');
        await tester.tap(find.byKey(const ValueKey('keypad-cancel')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(ValueKey('sail-${f[0].ulid}')));
        await tester.pumpAndSettle();
        await type(tester, '11');
        expect(find.textContaining('Sail for #3 '), findsOneWidget, reason: '#2 is named, so #3');
      });

      testWidgets('a failed save stays on the same finish with the digits', (tester) async {
        await openFinishScreen(tester);
        final f = await logFinishes(tester, 2);
        await tester.tap(find.byKey(ValueKey('sail-${f[0].ulid}')));
        await tester.pumpAndSettle();
        core.failWith = const CoreException('failed', 'disk full');
        await type(tester, '42');
        expect(find.text('Not logged. Tap again.'), findsOneWidget);
        expect(find.textContaining('Sail for #1 '), findsOneWidget);
        expect(find.textContaining('42'), findsWidgets, reason: 'the digits are kept for the retry');
        core.failWith = null;
        await tester.tap(find.byKey(const ValueKey('keypad-save')));
        await tester.pumpAndSettle();
        expect(sailOf(await events(tester), f[0].ulid), '42');
        expect(find.textContaining('Sail for #2 '), findsOneWidget);
      });

      testWidgets('a boat finishing mid-walk joins the walk', (tester) async {
        await openFinishScreen(tester);
        final f = await logFinishes(tester, 1);
        await tester.tap(find.byKey(ValueKey('sail-${f[0].ulid}')));
        await tester.pumpAndSettle();
        await tester.tap(finishButton);
        await tester.pumpAndSettle();
        await type(tester, '7');
        expect(find.textContaining('Sail for #2 '), findsOneWidget);
      });
    });

    testWidgets('Cancel appends nothing', (tester) async {
      await openFinishScreen(tester);
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      final a = (await finishes(tester)).single;
      await tester.tap(find.byKey(ValueKey('sail-${a.ulid}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('key-7')));
      await tester.tap(find.byKey(const ValueKey('keypad-cancel')));
      await tester.pumpAndSettle();
      expect(await events(tester), hasLength(1));
    });
  });

  group('what rendering it on a device showed, with every test above green', () {
    Future<void> logFinishes(WidgetTester tester, int n) async {
      for (var i = 0; i < n; i++) {
        await tester.tap(finishButton);
        await tester.pumpAndSettle();
        now += 1000;
      }
    }

    Finder lastRow() => find
        .byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('row-'))
        .hitTestable()
        .last;

    testWidgets('expanding the bottom row of a full list brings its actions into view', (tester) async {
      await openFinishScreen(tester);
      await logFinishes(tester, 12);
      await tester.tap(lastRow());
      await tester.pumpAndSettle();
      expect(find.text('Missed above').hitTestable(), findsOneWidget);
      expect(find.text('Undo this').hitTestable(), findsOneWidget);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('at ${(scale * 100).round()}% text every keypad key can be tapped without scrolling',
          (tester) async {
        await openFinishScreen(tester, textScale: scale);
        await logFinishes(tester, 3);
        await tester.tap(find.widgetWithText(OutlinedButton, 'Sail #').hitTestable().last);
        await tester.pumpAndSettle();
        for (final key in ['key-1', 'key-9', 'key-del', 'key-0', 'keypad-save', 'keypad-cancel']) {
          expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget, reason: key);
        }
      });

      testWidgets('at ${(scale * 100).round()}% text no button label is clipped or broken', (tester) async {
        await openFinishScreen(tester, textScale: scale);
        await logFinishes(tester, 8);
        expect(clippedLabels(tester), isEmpty, reason: 'the list');
        await tester.tap(lastRow());
        await tester.pumpAndSettle();
        expect(clippedLabels(tester), isEmpty, reason: 'an expanded row');
        await tester.tap(find.widgetWithText(OutlinedButton, 'Sail #').hitTestable().first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('key-4')));
        await tester.pumpAndSettle();
        expect(clippedLabels(tester), isEmpty, reason: 'the keypad');
      });
    }
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('criterion 9: the finish screen passes the bar-check helper at ${(scale * 100).round()}% text',
        (tester) async {
      final violations = await barCheck(tester, (observer) {
        var t = DateTime(2026, 9, 26, 14, 30).millisecondsSinceEpoch;
        final seeded = FakeCore(clock: () => t += 1000);
        // A full list already on the phone, so rows, their actions and the
        // scrolling all exist.
        for (var i = 0; i < 12; i++) {
          seeded.seed([
            EventEnvelope(
              ulid: '01J8FINISH00000000000000${i.toString().padLeft(2, '0')}',
              deviceTs: t += 1000,
              deviceId: seeded.deviceIdValue,
              seq: i + 1,
              source: 'tap',
              kind: FinishKinds.finish,
              payloadVersion: 1,
              payload: const {},
            ),
          ]);
        }
        return MediaQuery.withClampedTextScaling(
          minScaleFactor: scale,
          maxScaleFactor: scale,
          child: ProCompanionApp(
            core: seeded,
            confirmation: ConfirmationService(FakeConfirmationDevice()),
            navigatorObservers: [observer],
          ),
        );
      });
      expect(violations, isEmpty, reason: violations.join('\n'));
    });
  }
}

class _Popups extends NavigatorObserver {
  final opened = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) opened.add(route);
  }
}
