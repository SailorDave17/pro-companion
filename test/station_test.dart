import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/stations/station_screen.dart';
import 'package:pro_companion/ui/race_time.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';
import 'support/network_tripwire.dart';
import 'support/roles.dart';
import 'support/station_flow.dart';

/// #26 on the app, driven against the fake core: the mark boat's home holds
/// STATION, which opens the standard mark set, and one tap there logs the
/// phone's station and returns home, where UNDO STATION takes it back (owner's
/// choice, 2026-10-08). The core's half, the stamp every later event carries,
/// is packages/core/test/stations_test.dart.
void main() {
  late int now;
  late FakeCore core;
  late FakeConfirmationDevice device;
  late _Popups popups;

  final stationButton = find.widgetWithText(ElevatedButton, 'STATION');
  final undoStation = find.byKey(const ValueKey('undo-station'));
  final status = find.byKey(const ValueKey('station-status'));
  Finder mark(String id) => find.byKey(ValueKey('station-$id'));

  setUp(() {
    now = DateTime(2026, 10, 8, 14, 30).millisecondsSinceEpoch;
    core = withRole(FakeCore(clock: () => now += 1000), Roles.markBoat);
    device = FakeConfirmationDevice();
    popups = _Popups();
  });

  Widget app({double textScale = 1, CoreClient? on, NavigatorObserver? observer}) => MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: ProCompanionApp(
          core: on ?? core,
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

  Future<List<EventEnvelope>> events(WidgetTester tester) async => (await tester.runAsync(core.readAll))!;

  /// What the app appended: everything but the seeded role pick.
  Future<List<EventEnvelope>> appended(WidgetTester tester) async =>
      [for (final e in await events(tester)) if (e.ulid != seededRolePick) e];

  String statusText(WidgetTester tester) => tester.widget<Text>(status).data!;

  group('criterion 1: from the mark-boat home, a station from the standard set in 2 taps', () {
    testWidgets('the home says there is no station yet, and STATION opens the nine marks in order',
        (tester) async {
      await openApp(tester);
      expect(statusText(tester), 'No station yet');
      await tap(tester, stationButton);

      // Named here, not read from StandardMarks.all: a mark dropped from the
      // set would drop its own check with it.
      const shown = [
        ('mark_1', 'MARK 1'), ('mark_2', 'MARK 2'), ('mark_3', 'MARK 3'), ('mark_4', 'MARK 4'),
        ('windward', 'WINDWARD'), ('leeward', 'LEEWARD'), ('gate_left', 'GATE LEFT'),
        ('gate_right', 'GATE RIGHT'), ('offset', 'OFFSET'),
      ];
      for (final (id, label) in shown) {
        expect(find.descendant(of: mark(id), matching: find.text(label)), findsOneWidget, reason: id);
      }
      // Two to a row, left then right, top to bottom.
      final at = [for (final (id, _) in shown) tester.getTopLeft(mark(id))];
      for (var i = 0; i + 1 < at.length; i++) {
        final sameRow = i.isEven;
        expect(sameRow ? at[i + 1].dy == at[i].dy && at[i + 1].dx > at[i].dx : at[i + 1].dy > at[i].dy, isTrue,
            reason: '${shown[i].$1} then ${shown[i + 1].$1}');
      }
      expect(find.text('Station · none yet'), findsOneWidget);
    });

    for (final id in StandardMarks.all) {
      testWidgets('$id: STATION, then the mark, logs one station pick and returns home', (tester) async {
        await openApp(tester);
        await tap(tester, stationButton);
        await tap(tester, mark(id));

        final all = await appended(tester);
        expect(all, hasLength(1), reason: 'two taps, one event');
        expect([all.single.kind, all.single.payload, all.single.role],
            [StationKinds.selected, {'mark': id}, Roles.markBoat]);
        expect(stationButton, findsOneWidget, reason: 'back on the home');
        expect(statusText(tester), 'Station: ${markName(id)}');
      });
    }

    testWidgets('the station in force is filled in its own cell and said, and tapping it logs nothing',
        (tester) async {
      await openApp(tester);
      await tap(tester, stationButton);
      await tap(tester, mark(StandardMarks.windward));
      await tap(tester, stationButton);

      expect(find.text('Station · Windward'), findsOneWidget);
      expect(tester.widget(mark(StandardMarks.windward)), isA<FilledButton>());
      expect(tester.widget(mark(StandardMarks.leeward)), isA<OutlinedButton>());
      expect(find.bySemanticsLabel('Windward, current station'), findsOneWidget);
      expect(find.bySemanticsLabel('Leeward'), findsOneWidget);

      await tap(tester, mark(StandardMarks.windward));
      expect(await appended(tester), hasLength(1), reason: 'the station it is already at: nothing new');
      expect(device.vibrations, 1);
      expect(statusText(tester), 'Station: Windward');
    });

    testWidgets('a new pick moves the station', (tester) async {
      await openApp(tester);
      await tap(tester, stationButton);
      await tap(tester, mark(StandardMarks.mark1));
      await tap(tester, stationButton);
      await tap(tester, mark(StandardMarks.gateRight));
      expect([for (final e in await appended(tester)) markOf(e)], [StandardMarks.mark1, StandardMarks.gateRight]);
      expect(statusText(tester), 'Station: Gate right');
    });

    testWidgets('Back from the marks logs nothing', (tester) async {
      await openApp(tester);
      await tap(tester, stationButton);
      await tap(tester, find.byTooltip('Back'));
      expect(await appended(tester), isEmpty);
      expect(statusText(tester), 'No station yet');
    });

    testWidgets('a restart shows the station, read back from the log', (tester) async {
      await openApp(tester);
      await tap(tester, stationButton);
      await tap(tester, mark(StandardMarks.offset));
      await tester.pumpWidget(const SizedBox.shrink());
      await openApp(tester);
      expect(statusText(tester), 'Station: Offset');
    });

    testWidgets('a role picked again starts with no station', (tester) async {
      await openApp(tester);
      await tap(tester, stationButton);
      await tap(tester, mark(StandardMarks.leeward));
      await tap(tester, find.byKey(const ValueKey('undo-role')));
      await tap(tester, find.byKey(ValueKey('pick-${Roles.markBoat}')));
      expect(statusText(tester), 'No station yet');
    });
  });

  group('criterion 3: with no server and no PRO, on one phone', () {
    // The host half: the network tripwire armed on HTTP clients and sockets
    // (its doc lists what it cannot see), and a phone that holds nothing but
    // its own role pick: no admission, no fleets, nothing from a PRO. The
    // device half, in airplane mode on the real core, is
    // integration_test/offline_results_flow.dart.
    testWidgets('a station pick and its undo reach for no network and need nothing else', (tester) async {
      final wire = NetworkTripwire()..arm();
      addTearDown(wire.disarm);
      final alone = FakeCore(clock: () => now += 1000);
      setPhoneSize(tester);
      await tester.pumpWidget(ProCompanionApp(core: alone, confirmation: ConfirmationService(device)));
      await tester.pumpAndSettle();

      await markBoatStationFlow(tester, alone);

      expect(device.vibrations, 3, reason: 'the role pick, the station pick and its undo, each confirmed on the phone alone');
      expect(wire.attempts, isEmpty);
    });
  });

  group('criterion 4: the station picked on the home is the one later events carry', () {
    testWidgets('a rounding or finish-here appended after a pick carries its mark id', (tester) async {
      await openApp(tester);
      await tap(tester, stationButton);
      await tap(tester, mark(StandardMarks.windward));

      // Neither kind exists yet (#54, #30): the core stamps any kind.
      final rounding = (await tester.runAsync(() => core.append(const NewEvent(kind: 'rounding', source: 'tap'))))!;
      final finishHere =
          (await tester.runAsync(() => core.append(const NewEvent(kind: 'course.shortened', source: 'tap'))))!;
      expect([markOf(rounding), markOf(finishHere)], [StandardMarks.windward, StandardMarks.windward]);
    });

    testWidgets('after UNDO STATION, they carry the station before it', (tester) async {
      await openApp(tester);
      await tap(tester, stationButton);
      await tap(tester, mark(StandardMarks.mark2));
      await tap(tester, stationButton);
      await tap(tester, mark(StandardMarks.mark3));
      await tap(tester, undoStation);
      final rounding = (await tester.runAsync(() => core.append(const NewEvent(kind: 'rounding', source: 'tap'))))!;
      expect(markOf(rounding), StandardMarks.mark2);
    });
  });

  group('criterion 5: the bar, one buzz and one tone per pick, and UNDO STATION with no confirm', () {
    /// A mark boat's phone with its station already set, so UNDO STATION is
    /// live and the picker shows a station in force.
    FakeCore stationed() {
      var t = DateTime(2026, 10, 8, 14, 30).millisecondsSinceEpoch;
      final day = withRole(FakeCore(clock: () => t += 1000), Roles.markBoat);
      return day
        ..seed([
          EventEnvelope(
            ulid: '01J8${'1'.padLeft(22, '0')}',
            deviceTs: t += 1000,
            deviceId: day.deviceIdValue,
            seq: 1,
            source: 'tap',
            kind: StationKinds.selected,
            payloadVersion: 1,
            role: Roles.markBoat,
            payload: const {'mark': StandardMarks.gateRight},
          ),
        ]);
    }

    for (final scale in [1.0, 2.0]) {
      final pct = '${(scale * 100).round()}%';
      for (final (name, build) in [('no station yet', () => withRole(FakeCore(), Roles.markBoat)), ('a station set', stationed)]) {
        testWidgets('the mark-boat home and the marks, $name, at $pct text', (tester) async {
          final violations = await barCheck(
            tester,
            (observer) => app(textScale: scale, on: build(), observer: observer),
            actionIds: markBoatRaceTimeActionIds,
          );
          expect(violations, isEmpty, reason: violations.join('\n'));
        });
      }
    }

    testWidgets('a pick the core confirms fires one vibration and one tone', (tester) async {
      await openApp(tester);
      await tap(tester, stationButton);
      expect(device.vibrations, 0, reason: 'opening the marks logs nothing');
      await tap(tester, mark(StandardMarks.leeward));
      expect(device.vibrations, 1);
      expect(device.tones, [BeepStream.notification]);
    });

    testWidgets('a pick that does not log fires neither, stays on the marks, and says so', (tester) async {
      await openApp(tester);
      await tap(tester, stationButton);
      core.failWith = const CoreException('failed', 'disk gone');
      await tap(tester, mark(StandardMarks.leeward));
      expect([device.vibrations, device.tones], [0, isEmpty]);
      expect(mark(StandardMarks.leeward), findsOneWidget, reason: 'still on the marks');
      expect(find.text('Not logged. Tap again.'), findsOneWidget);

      core.failWith = null;
      await tap(tester, mark(StandardMarks.leeward));
      expect(device.vibrations, 1);
      expect(statusText(tester), 'Station: Leeward');
      expect(find.text('Not logged. Tap again.'), findsNothing);
    });

    testWidgets('a second tap while the first is still being logged is the same pick, not a second one',
        (tester) async {
      final held = _HeldCore(core);
      await openApp(tester, on: held);
      await tap(tester, stationButton);
      held.hold = Completer<void>();
      await tester.tap(mark(StandardMarks.mark4));
      await tester.pump();
      await tester.tap(mark(StandardMarks.offset));
      await tester.pump();
      held.hold!.complete();
      await tester.pumpAndSettle();

      expect([for (final e in await appended(tester)) markOf(e)], [StandardMarks.mark4]);
      expect(device.vibrations, 1);
    });

    testWidgets('UNDO STATION logs a correction of the pick at once, with no dialog, sheet or menu',
        (tester) async {
      await openApp(tester);
      expect(tester.widget<OutlinedButton>(undoStation).onPressed, isNull, reason: 'nothing to undo yet');
      await tap(tester, stationButton);
      await tap(tester, mark(StandardMarks.windward));
      final picked = (await appended(tester)).single;

      await tap(tester, undoStation);
      final all = await appended(tester);
      expect(all, hasLength(2), reason: 'the undo is one event and nothing else');
      expect([all.last.kind, all.last.correctsUlid], [StationKinds.undo, picked.ulid]);
      expect(markOf(all.last), StandardMarks.windward, reason: 'logged at the station it undoes');
      expect(statusText(tester), 'No station yet');
      expect(popups.opened, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expect(device.vibrations, 2, reason: 'the pick and the undo, each confirmed');
      expect(device.tones, [BeepStream.notification, BeepStream.notification]);
      expect(tester.widget<OutlinedButton>(undoStation).onPressed, isNull, reason: 'nothing left to undo');
    });

    testWidgets("the home's event count includes the undo", (tester) async {
      // The emulator render showed "2 events" after a pick and its undo: the
      // home re-read its count only when a screen it opened came back.
      await openApp(tester);
      await tap(tester, stationButton);
      await tap(tester, mark(StandardMarks.windward));
      expect(find.text('2 events on this phone'), findsOneWidget, reason: 'the seeded role pick and the station');
      await tap(tester, undoStation);
      expect(find.text('3 events on this phone'), findsOneWidget);
    });

    testWidgets('an undo returns to the station before, one pick at a time', (tester) async {
      await openApp(tester);
      for (final id in [StandardMarks.mark1, StandardMarks.windward]) {
        await tap(tester, stationButton);
        await tap(tester, mark(id));
      }
      await tap(tester, undoStation);
      expect(statusText(tester), 'Station: Mark 1');
      await tap(tester, undoStation);
      expect(statusText(tester), 'No station yet');
    });

    testWidgets('an undo that does not log fires neither, keeps the station, and says so', (tester) async {
      final failing = stationed();
      await openApp(tester, on: failing);
      expect(statusText(tester), 'Station: Gate right');
      failing.failWith = const CoreException('failed', 'disk gone');
      await tap(tester, undoStation);
      expect([device.vibrations, device.tones], [0, isEmpty]);
      expect(statusText(tester), 'Station: Gate right');
      expect(find.text('Not logged. Tap again.'), findsOneWidget);

      failing.failWith = null;
      await tap(tester, undoStation);
      expect(statusText(tester), 'No station yet');
      expect(find.text('Not logged. Tap again.'), findsNothing);
    });

    testWidgets('nothing on the home moves when a station is picked or undone', (tester) async {
      await openApp(tester);
      List<double> edges() => [
            for (final r in [tester.getRect(stationButton), tester.getRect(undoStation)]) ...[r.left, r.top, r.right, r.bottom],
          ];
      // A pick moved each edge 2.3e-13 dp (measured), layout arithmetic; a
      // thumb cannot feel it, so equality is held to 0.01 dp.
      Matcher unmoved(List<double> before) =>
          pairwiseCompare<double, double>(before, (e, a) => (e - a).abs() < 0.01, 'within 0.01 dp of');
      final before = edges();
      await tap(tester, stationButton);
      await tap(tester, mark(StandardMarks.gateLeft));
      expect(edges(), unmoved(before), reason: 'after a pick');
      await tap(tester, undoStation);
      expect(edges(), unmoved(before), reason: 'after an undo');
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

/// A core whose appends wait for [hold], so a test can tap while one is still
/// on its way to the log.
class _HeldCore implements CoreClient {
  _HeldCore(this._inner);

  final FakeCore _inner;
  Completer<void>? hold;

  @override
  Future<EventEnvelope> append(NewEvent event) async {
    await hold?.future;
    return _inner.append(event);
  }

  @override
  Future<List<EventEnvelope>> readAll() => _inner.readAll();

  @override
  Future<int> count() => _inner.count();

  @override
  Future<String> deviceId() => _inner.deviceId();

  @override
  Future<String?> admissionId() => _inner.admissionId();

  @override
  Future<void> setAdmissionId(String admissionId) => _inner.setAdmissionId(admissionId);

  @override
  Future<UploadStatus> uploadStatus() => _inner.uploadStatus();

  @override
  Future<void> close() => _inner.close();
}
