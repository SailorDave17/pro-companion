import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';

/// #18 on the app, driven against the fake core: fleets are named on the
/// FLEETS screen, switched from a row on the finish screen, and every finish
/// carries the fleet it was taken for (owner's layout, 2026-09-24).
void main() {
  late int now;
  late FakeCore core;
  late FakeConfirmationDevice device;
  late _Popups popups;

  final finishButton = find.widgetWithText(FilledButton, 'FINISH');

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
        ),
      );

  Future<void> openHome(WidgetTester tester) async {
    setPhoneSize(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  Future<List<EventEnvelope>> events(WidgetTester tester) async => (await tester.runAsync(core.readAll))!;

  /// Defines [names] through the core, as though named earlier today.
  Future<List<String>> defineFleets(WidgetTester tester, List<String> names) async => [
        for (final n in names) (await tester.runAsync(() => core.append(FleetEvents.define(n))))!.ulid,
      ];

  Finder fleetButton(String id) => find.byKey(ValueKey('fleet-switch-$id'));

  /// Types [text] into the field keyed [key] and lets a frame pass: ADD only
  /// enables on the rebuild the typing schedules, so a tap straight after
  /// enterText lands on a disabled button and does nothing, silently.
  Future<void> type(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(ValueKey(key)), text);
    await tester.pump();
  }

  group('criterion 1: a fleet named on the phone is appended and becomes selectable', () {
    testWidgets('name and class typed, ADD FLEET: one fleet.defined event, and the fleet is on the finish screen',
        (tester) async {
      await openHome(tester);
      await tester.tap(find.text('FLEETS'));
      await tester.pumpAndSettle();
      await type(tester, 'fleet-name', 'Lasers');
      await type(tester, 'fleet-class', 'ILCA 7');
      await tester.tap(find.byKey(const ValueKey('fleet-add')));
      await tester.pumpAndSettle();

      final all = await events(tester);
      final defined = all.singleWhere((e) => e.kind == FleetKinds.defined);
      expect(defined.payload, {'name': 'Lasers', 'class': 'ILCA 7'});
      expect(find.textContaining('Lasers · ILCA 7'), findsOneWidget, reason: 'listed on the FLEETS screen');

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('FINISHES'));
      await tester.pumpAndSettle();
      expect(fleetButton(defined.ulid), findsOneWidget, reason: 'selectable on the finish screen');
    });

    testWidgets('the class is optional', (tester) async {
      await openHome(tester);
      await tester.tap(find.text('FLEETS'));
      await tester.pumpAndSettle();
      await type(tester, 'fleet-name', '420s');
      await tester.tap(find.byKey(const ValueKey('fleet-add')));
      await tester.pumpAndSettle();
      final defined = (await events(tester)).singleWhere((e) => e.kind == FleetKinds.defined);
      expect(defined.payload, {'name': '420s', 'class': null});
    });

    testWidgets("the phone's first fleet is also selected; later ones are not", (tester) async {
      await openHome(tester);
      await tester.tap(find.text('FLEETS'));
      await tester.pumpAndSettle();
      for (final name in ['Lasers', '420s']) {
        await type(tester, 'fleet-name', name);
        await tester.tap(find.byKey(const ValueKey('fleet-add')));
        await tester.pumpAndSettle();
      }
      final all = await events(tester);
      final lasers = all.firstWhere((e) => e.kind == FleetKinds.defined && e.payload['name'] == 'Lasers');
      expect(all.where((e) => e.kind == FleetKinds.selected).map(fleetOf), [lasers.ulid]);
      expect(device.vibrations, 2, reason: 'one buzz per fleet added');
    });

    testWidgets('a name already used is refused, and nothing is appended', (tester) async {
      await defineFleets(tester, ['Lasers']);
      await openHome(tester);
      await tester.tap(find.text('FLEETS'));
      await tester.pumpAndSettle();
      await type(tester, 'fleet-name', ' lasers ');
      await tester.tap(find.byKey(const ValueKey('fleet-add')));
      await tester.pumpAndSettle();
      expect(find.text('lasers is already a fleet'), findsOneWidget);
      expect((await events(tester)).where((e) => e.kind == FleetKinds.defined), hasLength(1));
    });
  });

  group('criterion 2: a fleet selected in at most 2 taps, and every later finish carries it', () {
    testWidgets('three fleets: FINISHES, then the fleet, and the finishes carry it', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s', 'Optis']);
      await openHome(tester);

      await tester.tap(find.text('FINISHES')); // tap 1
      await tester.pumpAndSettle();
      await tester.tap(fleetButton(ids[1])); // tap 2
      await tester.pumpAndSettle();
      expect(selectedFleet(await events(tester), core.deviceIdValue), ids[1]);

      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      await tester.tap(fleetButton(ids[2]));
      await tester.pumpAndSettle();
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      await tester.tap(finishButton);
      await tester.pumpAndSettle();

      final finishes = [for (final e in await events(tester)) if (e.kind == FinishKinds.finish) e];
      expect(finishes.map(fleetOf), [ids[1], ids[2], ids[2]]);
    });

    testWidgets("the screen shows the selected fleet's finishes only, numbered from 1", (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await openHome(tester);
      await tester.tap(find.text('FINISHES'));
      await tester.pumpAndSettle();
      await tester.tap(fleetButton(ids[0]));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await tester.tap(finishButton);
        await tester.pumpAndSettle();
      }
      await tester.tap(fleetButton(ids[1]));
      await tester.pumpAndSettle();
      expect(find.text('Finishes · 420s · 0'), findsOneWidget);
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      expect(find.text('Finishes · 420s · 1'), findsOneWidget);
      await tester.tap(fleetButton(ids[0]));
      await tester.pumpAndSettle();
      expect(find.text('Finishes · Lasers · 3'), findsOneWidget);
    });

    testWidgets('with four fleets, MORE opens every fleet as a screen, not a menu, and picking one switches',
        (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s', 'Optis', 'Toppers']);
      await openHome(tester);
      await tester.tap(find.text('FINISHES'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fleet-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('pick-${ids[3]}')));
      await tester.pumpAndSettle();
      expect(selectedFleet(await events(tester), core.deviceIdValue), ids[3]);
      expect(find.text('Finishes · Toppers · 0'), findsOneWidget);
      expect(popups.opened, isEmpty);
    });
  });

  group('criterion 6: a switch is confirmed by one vibration and one tone', () {
    testWidgets('each switch fires exactly one of each; tapping the fleet already selected fires nothing',
        (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await openHome(tester);
      await tester.tap(find.text('FINISHES'));
      await tester.pumpAndSettle();

      await tester.tap(fleetButton(ids[1]));
      await tester.pumpAndSettle();
      expect(device.vibrations, 1);
      expect(device.tones, [BeepStream.notification]);

      await tester.tap(fleetButton(ids[1]));
      await tester.pumpAndSettle();
      expect(device.vibrations, 1, reason: 'no switch, no event, no buzz');
      expect((await events(tester)).where((e) => e.kind == FleetKinds.selected), hasLength(1));
    });

    testWidgets('a switch the core refuses fires nothing and says so', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await openHome(tester);
      await tester.tap(find.text('FINISHES'));
      await tester.pumpAndSettle();
      core.failWith = const CoreException('failed', 'disk full');
      await tester.tap(fleetButton(ids[1]));
      await tester.pumpAndSettle();
      expect(device.vibrations, 0);
      expect(find.text('Not logged. Tap again.'), findsOneWidget);
    });
  });

  group('criterion 7: a wrong switch is undone by a correction, with no prompt', () {
    testWidgets('UNDO SWITCH appends a correction naming the switch, and the phone is back on its fleet',
        (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await openHome(tester);
      await tester.tap(find.text('FINISHES'));
      await tester.pumpAndSettle();
      await tester.tap(fleetButton(ids[0]));
      await tester.pumpAndSettle();
      await tester.tap(finishButton);
      await tester.pumpAndSettle();

      await tester.tap(fleetButton(ids[1])); // the wrong fleet
      await tester.pumpAndSettle();
      final wrong = (await events(tester)).lastWhere((e) => e.kind == FleetKinds.selected);
      expect(find.text('UNDO SWITCH (420s)'), findsOneWidget);

      await tester.tap(find.text('UNDO SWITCH (420s)'));
      await tester.pumpAndSettle();

      final all = await events(tester);
      final undo = all.singleWhere((e) => e.kind == FleetKinds.undo);
      expect(undo.correctsUlid, wrong.ulid);
      expect(all.singleWhere((e) => e.ulid == wrong.ulid).toWire(), wrong.toWire(), reason: 'the switch is kept');
      expect(selectedFleet(all, core.deviceIdValue), ids[0]);
      expect(find.text('Finishes · Lasers · 1'), findsOneWidget);
      expect(find.text('UNDO LAST (#1)'), findsOneWidget, reason: 'the next undo is the finish again');
      expect(popups.opened, isEmpty);
      for (final type in const [AlertDialog, Dialog, SimpleDialog, BottomSheet]) {
        expect(find.byType(type), findsNothing);
      }
    });

    testWidgets('after a finish in the new fleet, UNDO LAST takes the finish first, then the switch',
        (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await openHome(tester);
      await tester.tap(find.text('FINISHES'));
      await tester.pumpAndSettle();
      await tester.tap(fleetButton(ids[1]));
      await tester.pumpAndSettle();
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      expect(find.text('UNDO LAST (#1)'), findsOneWidget);
      await tester.tap(find.text('UNDO LAST (#1)'));
      await tester.pumpAndSettle();
      expect(find.text('UNDO SWITCH (420s)'), findsOneWidget);
    });
  });

  group('criterion 5: the fleet switcher passes the bar-check helper', () {
    /// A fleet day already on the phone: fleets named, one selected, and a
    /// full list of its finishes, so the row, the rows and scrolling all exist.
    FakeCore fleetDay(List<String> names) {
      var t = DateTime(2026, 9, 26, 14, 30).millisecondsSinceEpoch;
      var seq = 0;
      final day = FakeCore(clock: () => t += 1000);
      EventEnvelope event(String kind, Map<String, Object?> payload, String tail) => EventEnvelope(
            ulid: '01J8${kind.replaceAll('.', '').toUpperCase().padRight(14, '0').substring(0, 14)}$tail',
            deviceTs: t += 1000,
            deviceId: day.deviceIdValue,
            seq: ++seq,
            source: 'tap',
            kind: kind,
            payloadVersion: 1,
            payload: payload,
          );
      final ids = <String>[];
      for (var i = 0; i < names.length; i++) {
        final e = event(FleetKinds.defined, {'name': names[i], 'class': null}, 'F${i.toString().padLeft(7, '0')}');
        ids.add(e.ulid);
        day.seed([e]);
      }
      day.seed([event(FleetKinds.selected, {fleetPayloadKey: ids.first}, 'S0000000')]);
      for (var i = 0; i < 12; i++) {
        day.seed([event(FinishKinds.finish, {fleetPayloadKey: ids.first}, 'X${i.toString().padLeft(7, '0')}')]);
      }
      return day;
    }

    for (final names in [
      ['Lasers', '420s', 'Optis'],
      ['Lasers', '420s', 'Optis', 'Toppers'],
    ]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('${names.length} fleets at ${(scale * 100).round()}% text', (tester) async {
          final violations = await barCheck(
            tester,
            (observer) => app(textScale: scale, on: fleetDay(names), observer: observer),
          );
          expect(violations, isEmpty, reason: violations.join('\n'));
        });
      }
    }
  });
}

class _Popups extends NavigatorObserver {
  final opened = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) opened.add(route);
  }
}
