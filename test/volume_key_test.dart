import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/ui/race_time.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';
import 'support/fake_volume_keys.dart';

/// #19 above MainActivity: what the app does with a volume-down press the
/// phone reports, and when it asks the phone for the key. Criteria 2, 4, 5 and
/// 8 are about the key itself and run on a device, in
/// android/app/src/androidTest (integration_test/volume_key.sh).
void main() {
  late int now;
  late FakeCore core;
  late FakeConfirmationDevice device;
  late FakeVolumeKeyCapture keys;
  late _Popups popups;

  final finishButton = find.widgetWithText(FilledButton, 'FINISH');
  final armedLabel = find.text('or volume down');

  setUp(() {
    now = DateTime(2026, 10, 6, 14, 30).millisecondsSinceEpoch;
    core = FakeCore(clock: () => now);
    device = FakeConfirmationDevice();
    keys = FakeVolumeKeyCapture();
    popups = _Popups();
  });

  Future<void> openApp(WidgetTester tester, {double textScale = 1}) async {
    setPhoneSize(tester);
    await tester.pumpWidget(MediaQuery.withClampedTextScaling(
      minScaleFactor: textScale,
      maxScaleFactor: textScale,
      child: ProCompanionApp(
        core: core,
        confirmation: ConfirmationService(device),
        navigatorObservers: [popups],
        volumeKeys: keys,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openFinishScreen(WidgetTester tester, {double textScale = 1}) async {
    await openApp(tester, textScale: textScale);
    await tester.tap(find.text('FINISHES'));
    await tester.pumpAndSettle();
    expect(finishButton, findsOneWidget);
  }

  void back(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator)).pop();

  Future<List<EventEnvelope>> events(WidgetTester tester) async => (await tester.runAsync(core.readAll))!;

  Future<List<EventEnvelope>> finishes(WidgetTester tester) async =>
      [for (final e in await events(tester)) if (e.kind == FinishKinds.finish) e];

  group('criterion 1: on the finish screen one press is one finish, as a tap would be', () {
    testWidgets('a press appends exactly one finish, logged by the volume key, and shows it', (tester) async {
      await openFinishScreen(tester);
      expect(keys.press(), isTrue);
      await tester.pumpAndSettle();

      final logged = await finishes(tester);
      expect(logged, hasLength(1));
      expect(logged.single.source, FinishSources.volumeKey);
      expect(find.byKey(ValueKey('row-${logged.single.ulid}')), findsOneWidget);
      expect(find.text('Finishes · 1'), findsOneWidget);
    });

    testWidgets('it is the finish FINISH appends, but for its source', (tester) async {
      await openFinishScreen(tester);
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      now += 1000;
      keys.press();
      await tester.pumpAndSettle();

      final logged = await finishes(tester);
      final tap = logged.singleWhere((e) => e.source == FinishSources.tap);
      final key = logged.singleWhere((e) => e.source == FinishSources.volumeKey);
      // All but what makes each event its own: identity, time, chain place, source.
      Map<String, Object?> asLogged(EventEnvelope e) => Map.of(e.toWire())
        ..removeWhere((k, _) => const {'ulid', 'device_ts', 'seq', 'prev_hash', 'source'}.contains(k));
      expect(asLogged(key), asLogged(tap));
      expect(find.text('Finishes · 2'), findsOneWidget);
    });

    testWidgets('on a day with fleets it is logged for the fleet selected', (tester) async {
      final lasers = (await core.append(FleetEvents.define('Lasers'))).ulid;
      now += 1000;
      await core.append(FleetEvents.define('Opti'));
      now += 1000;
      await core.append(FleetEvents.select(lasers));
      now += 1000;
      await openFinishScreen(tester);
      keys.press();
      await tester.pumpAndSettle();

      expect(fleetOf((await finishes(tester)).single), lasers);
      expect(find.text('Finishes · Lasers · 1'), findsOneWidget);
    });

    testWidgets('two presses with no gap at all are two finishes', (tester) async {
      await openFinishScreen(tester);
      keys.press();
      keys.press();
      await tester.pump(const Duration(milliseconds: 100));
      expect(await finishes(tester), hasLength(2), reason: 'none dropped or coalesced');
    });

    testWidgets('a press while a sail number is being typed is still a finish', (tester) async {
      await openFinishScreen(tester);
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Sail #'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('key-1')), findsOneWidget);

      now += 700;
      expect(keys.press(), isTrue, reason: 'the keypad is part of the finish screen');
      await tester.pumpAndSettle();
      expect(await finishes(tester), hasLength(2));
    });
  });

  group('criterion 3: the key is the finish screen\'s only while it is the screen showing', () {
    testWidgets('home and every other screen leave the key to the system', (tester) async {
      await openApp(tester);
      expect(keys.armed, isFalse, reason: 'home');
      for (final screen in ['SEQUENCE', 'RESULTS', 'FLEETS']) {
        await tester.tap(find.text(screen));
        await tester.pumpAndSettle();
        expect(keys.armed, isFalse, reason: screen);
        expect(keys.press(), isFalse, reason: '$screen: the press goes to the system');
        back(tester);
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('FINISHES'));
      await tester.pumpAndSettle();
      expect(keys.armed, isTrue, reason: 'the finish screen takes it');
      back(tester);
      await tester.pumpAndSettle();
      expect(keys.armed, isFalse, reason: 'and gives it back on leaving');
      expect(await finishes(tester), isEmpty);
    });

    testWidgets('a screen opened over the finish screen has the key until it closes', (tester) async {
      await openFinishScreen(tester);
      expect(keys.armed, isTrue);

      Navigator.of(tester.element(finishButton))
          .push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('over the finishes'))));
      await tester.pumpAndSettle();
      expect(keys.armed, isFalse);
      expect(keys.press(), isFalse);

      back(tester);
      await tester.pumpAndSettle();
      expect(keys.armed, isTrue);
      expect(armedLabel, findsOneWidget);
      expect(await finishes(tester), isEmpty);
    });
  });

  group('criterion 6: with the key armed the bar check passes, and the screen says it is armed', () {
    for (final scale in [1.0, 2.0]) {
      final pct = '${(scale * 100).round()}%';

      testWidgets('the bar-check helper passes at $pct text with the volume key armed', (tester) async {
        // A single-fleet day, as #4's bar check: no fleet switch to reach.
        final violations = await barCheck(tester, actionIds: raceTimeActionIds.difference({'fleet-switch'}), (observer) {
          var t = DateTime(2026, 10, 6, 14, 30).millisecondsSinceEpoch;
          final seeded = FakeCore(clock: () => t += 1000);
          String ulid(int n) => '01J8${n.toString().padLeft(22, '0')}';
          // The day's gun, so the sequence screen has a gun time to fix (#25),
          // then a full list, so rows, their actions and the scrolling exist.
          seeded.seed([
            EventEnvelope(
              ulid: ulid(1),
              deviceTs: t += 1000,
              deviceId: seeded.deviceIdValue,
              seq: 1,
              source: 'manual',
              kind: StartKinds.start,
              payloadVersion: 1,
              payload: const {'fleet': null},
            ),
            for (var i = 0; i < 12; i++)
              EventEnvelope(
                ulid: ulid(i + 2),
                deviceTs: t += 1000,
                deviceId: seeded.deviceIdValue,
                seq: i + 2,
                source: i.isEven ? FinishSources.tap : FinishSources.volumeKey,
                kind: FinishKinds.finish,
                payloadVersion: 1,
                payload: const {'fleet': null},
              ),
          ]);
          return MediaQuery.withClampedTextScaling(
            minScaleFactor: scale,
            maxScaleFactor: scale,
            child: ProCompanionApp(
              core: seeded,
              confirmation: ConfirmationService(FakeConfirmationDevice()),
              navigatorObservers: [observer],
              volumeKeys: FakeVolumeKeyCapture(),
            ),
          );
        });
        expect(violations, isEmpty, reason: violations.join('\n'));
      });

      testWidgets('at $pct text FINISH shows the key, unclipped, and a screen reader hears it', (tester) async {
        final semantics = tester.ensureSemantics();
        await openFinishScreen(tester, textScale: scale);
        expect(armedLabel, findsOneWidget);
        final icon = find.descendant(of: finishButton, matching: find.byIcon(Icons.volume_down));
        expect(icon, findsOneWidget);
        // It grows with its words: a fixed size drew at half their height at 200% (the render).
        expect(tester.widget<Icon>(icon).size, 28 * scale);
        expect(clippedLabels(tester), isEmpty);
        expect(find.bySemanticsLabel(RegExp(r'^FINISH\s+or volume down$')), findsOneWidget);
        semantics.dispose();
      });
    }

    testWidgets('a phone that cannot take the key shows none', (tester) async {
      keys = FakeVolumeKeyCapture(canArm: false);
      await openFinishScreen(tester);
      expect(armedLabel, findsNothing);
      expect(find.byIcon(Icons.volume_down), findsNothing);
    });
  });

  group('criterion 7: a volume-key finish is confirmed and undone as a tapped one is', () {
    testWidgets('one vibration and one tone once the core has it, and UNDO LAST corrects it with no dialog',
        (tester) async {
      await openFinishScreen(tester);
      keys.press();
      await tester.pumpAndSettle();
      expect(device.vibrations, 1);
      expect(device.tones, [BeepStream.notification]);
      final finish = (await finishes(tester)).single;

      await tester.tap(find.text('UNDO LAST (#1)'));
      await tester.pumpAndSettle();

      final undo = (await events(tester)).singleWhere((e) => e.kind == FinishKinds.undo);
      expect(undo.correctsUlid, finish.ulid);
      expect(find.text('Finishes · 0'), findsOneWidget);
      expect(device.vibrations, 2, reason: 'the undo is confirmed like any other action');
      expect(popups.opened, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a press the core does not log fires nothing and says so', (tester) async {
      await openFinishScreen(tester);
      core.failWith = const CoreException('failed', 'disk full');
      keys.press();
      await tester.pumpAndSettle();
      expect(device.vibrations, 0);
      expect(device.tones, isEmpty);
      expect(find.text('Not logged. Tap again.'), findsOneWidget);
      expect(popups.opened, isEmpty);
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
