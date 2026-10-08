import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/roles/roles.dart';
import 'package:pro_companion/ui/race_time.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';
import 'support/roles.dart';

/// #20 on the app, driven against the fake core: a phone picks the committee
/// role it runs as and opens that role's home, which offers that role's job
/// and nothing else, and UNDO ROLE takes a wrong pick back. The core's half of
/// criterion 2, every later event carrying the role, is
/// packages/core/test/roles_test.dart.
void main() {
  late int now;
  late FakeCore core;
  late FakeConfirmationDevice device;
  late _Popups popups;

  final picker = find.text('Pick your role');
  final undoRole = find.byKey(const ValueKey('undo-role'));
  Finder pick(String role) => find.byKey(ValueKey('pick-$role'));

  setUp(() {
    now = DateTime(2026, 10, 6, 14, 30).millisecondsSinceEpoch;
    core = FakeCore(clock: () => now += 1000);
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

  /// The label of every button on screen.
  Set<String> buttons(WidgetTester tester) => {
        for (final b in find.byWidgetPredicate((w) => w is ButtonStyleButton).hitTestable().evaluate())
          [
            for (final t in find.descendant(of: find.byWidget(b.widget), matching: find.byType(Text)).evaluate())
              (t.widget as Text).data!,
          ].join(' '),
      };

  group('criterion 1: a phone with no role opens on the picker, and one tap picks', () {
    // Named here, not read from pickableRoles: a role dropped from that list
    // would drop its own test with it (measured, mutation M15 on #20).
    const offered = [Roles.overallPro, Roles.recorder, Roles.markBoat, Roles.safety];

    testWidgets('the picker offers PRO, recorder, mark boat and safety, in that order', (tester) async {
      await openApp(tester);
      expect(picker, findsOneWidget);
      expect(buttons(tester), {'PRO', 'RECORDER', 'MARK BOAT', 'SAFETY'});
      final tops = [for (final r in offered) tester.getTopLeft(pick(r)).dy];
      expect(tops, [...tops]..sort(), reason: 'top to bottom in the order listed');
      expect(pickableRoles, offered, reason: 'course PRO arrives with #74, the scorer with its own home');
    });

    for (final role in offered) {
      testWidgets('$role: the tap logs one role pick and opens its home', (tester) async {
        await openApp(tester);
        await tap(tester, pick(role));

        final all = await events(tester);
        expect(all, hasLength(1), reason: 'one tap, one event');
        expect([all.single.kind, all.single.payload, all.single.role], [RoleKinds.assigned, {'role': role}, role]);
        expect(picker, findsNothing);
        expect(find.text(roleName(role)), findsOneWidget, reason: "the home names the role it is");
        expect(undoRole, findsOneWidget);
      });
    }

    testWidgets("a restart opens the picked role's home, read back from the log", (tester) async {
      await openApp(tester);
      await tap(tester, pick(Roles.recorder));
      await tester.pumpWidget(const SizedBox.shrink());
      await openApp(tester);
      expect(picker, findsNothing);
      expect(find.text('Recorder'), findsOneWidget);
    });

    testWidgets('a pick that names no role opens the picker rather than failing', (tester) async {
      await tester.runAsync(() => core.append(const NewEvent(kind: RoleKinds.assigned, source: 'tap')));
      await openApp(tester);
      expect(picker, findsOneWidget);
    });

    testWidgets("another phone's pick, synced in, leaves this phone on the picker", (tester) async {
      core.seed([
        EventEnvelope(
          ulid: '01J70000000000000000R01EPZ',
          deviceTs: now,
          deviceId: '01J8PH0NE00000000000000002',
          seq: 1,
          source: 'tap',
          kind: RoleKinds.assigned,
          payloadVersion: 1,
          role: Roles.overallPro,
          payload: const {'role': Roles.overallPro},
        ),
      ]);
      await openApp(tester);
      expect(picker, findsOneWidget);
    });
  });

  group('criterion 2: once a role is picked, the events the app logs carry it', () {
    testWidgets('a recorder\'s fleet and finishes', (tester) async {
      await openApp(tester);
      await tap(tester, pick(Roles.recorder));

      await tap(tester, find.text('FLEETS'));
      await tester.enterText(find.byKey(const ValueKey('fleet-name')), 'Lasers');
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const ValueKey('fleet-add')));
      await tap(tester, find.byTooltip('Back'));

      await tap(tester, find.text('FINISHES'));
      await tap(tester, find.widgetWithText(FilledButton, 'FINISH'));
      await tap(tester, find.widgetWithText(FilledButton, 'FINISH'));

      final all = await events(tester);
      expect([for (final e in all) e.kind],
          [RoleKinds.assigned, FleetKinds.defined, FleetKinds.selected, FinishKinds.finish, FinishKinds.finish]);
      expect([for (final e in all) e.role], everyElement(Roles.recorder));
    });

    testWidgets("a PRO's gun", (tester) async {
      await openApp(tester);
      await tap(tester, pick(Roles.overallPro));
      await tap(tester, find.text('SEQUENCE'));
      await tap(tester, find.widgetWithText(FilledButton, 'GUN'));
      final gun = (await events(tester)).singleWhere((e) => e.kind == StartKinds.start);
      expect(gun.role, Roles.overallPro);
    });
  });

  group("criterion 3: each role's home offers that role's job and nothing else", () {
    const expected = {
      Roles.overallPro: {'UNDO ROLE', 'FLEETS', 'SEQUENCE', 'FINISHES', 'RESULTS'},
      Roles.recorder: {'UNDO ROLE', 'FLEETS', 'FINISHES'},
      // The mark boat's station (#26); its roundings and finish-here come
      // with #54 and #30.
      Roles.markBoat: {'UNDO ROLE', 'STATION', 'UNDO STATION'},
      Roles.safety: {'UNDO ROLE'},
    };

    for (final MapEntry(key: role, value: labels) in expected.entries) {
      testWidgets('$role: ${labels.join(', ')}', (tester) async {
        await openApp(tester, on: withRole(core, role));
        expect(find.text(roleName(role)), findsOneWidget);
        expect(buttons(tester), labels);
      });
    }

    testWidgets('the mark-boat home has no line-finish or start controls', (tester) async {
      await openApp(tester, on: withRole(core, Roles.markBoat));
      for (final label in ['FINISHES', 'FINISH', 'SEQUENCE', 'GUN', 'FLEETS', 'RESULTS']) {
        expect(find.text(label), findsNothing, reason: label);
      }
      expect(find.text('No actions for this role yet.'), findsNothing, reason: 'it has its station (#26)');
    });

    testWidgets('the safety home says it has nothing yet', (tester) async {
      await openApp(tester, on: withRole(core, Roles.safety));
      expect(find.text('No actions for this role yet.'), findsOneWidget);
    });

    testWidgets("the recorder's FINISHES opens the finish screen, and its home has no start controls",
        (tester) async {
      await openApp(tester, on: withRole(core, Roles.recorder));
      for (final label in ['SEQUENCE', 'RESULTS']) {
        expect(find.text(label), findsNothing, reason: label);
      }
      await tap(tester, find.text('FINISHES'));
      expect(find.widgetWithText(FilledButton, 'FINISH'), findsOneWidget);
    });
  });

  group('criterion 4: the picker and each role home pass the bar-check helper', () {
    /// A recorder's day already on the phone: two fleets named, one selected,
    /// and a full list of its finishes, so the fleet row, the rows, their
    /// corrections and the scrolling all exist.
    FakeCore recorderDay() {
      var t = DateTime(2026, 10, 6, 14, 30).millisecondsSinceEpoch;
      var seq = 0;
      final day = withRole(FakeCore(clock: () => t += 1000), Roles.recorder);
      EventEnvelope event(String kind, Map<String, Object?> payload) => EventEnvelope(
            ulid: '01J8${(seq + 1).toString().padLeft(22, '0')}',
            deviceTs: t += 1000,
            deviceId: day.deviceIdValue,
            seq: ++seq,
            source: 'tap',
            kind: kind,
            payloadVersion: 1,
            payload: payload,
          );
      final lasers = event(FleetKinds.defined, {'name': 'Lasers', 'class': null});
      day.seed([lasers, event(FleetKinds.defined, {'name': '420s', 'class': null})]);
      day.seed([event(FleetKinds.selected, {fleetPayloadKey: lasers.ulid})]);
      for (var i = 0; i < 12; i++) {
        day.seed([event(FinishKinds.finish, {fleetPayloadKey: lasers.ulid})]);
      }
      return day;
    }

    // What a recorder's flow can reach: the finish screen's actions. The bar
    // check also fails on any other race-time action it meets, so this holds
    // the recorder away from the start sequence too.
    const recorderActions = {'finish', 'undo-last', 'sail', 'missed-above', 'undo-this', 'fleet-switch'};

    for (final scale in [1.0, 2.0]) {
      final pct = '${(scale * 100).round()}%';

      // A role pick is set-up, done before racing, as naming fleets is, so it
      // is not a race-time action and holds none. The check explores the
      // picker and the home each pick opens, one tap deep; each home's own
      // flow is checked below, from that home. The mark boat's home holds
      // UNDO STATION itself, which the check lets by (onHomeRaceTimeActionIds)
      // and the mark boat's own check holds (#26).
      testWidgets('the picker, and the home each pick opens, at $pct text', (tester) async {
        final violations = await barCheck(
          tester,
          (observer) => app(textScale: scale, on: FakeCore(), observer: observer),
          actionIds: const {},
          maxTaps: 1,
        );
        expect(violations, isEmpty, reason: violations.join('\n'));
      });

      // The PRO's home is the app's whole-app checks: #4's, #18's, #25's,
      // #29's, #7's and #19's each open on it, with a PRO pick seeded.

      testWidgets("the recorder's home and its flow, with fleets, at $pct text", (tester) async {
        final violations = await barCheck(
          tester,
          (observer) => app(textScale: scale, on: recorderDay(), observer: observer),
          actionIds: recorderActions,
        );
        expect(violations, isEmpty, reason: violations.join('\n'));
      });

      // With no station yet. test/station_test.dart checks it with one set.
      for (final (role, actions) in [(Roles.markBoat, markBoatRaceTimeActionIds), (Roles.safety, const <String>{})]) {
        testWidgets("the $role home at $pct text", (tester) async {
          final violations = await barCheck(
            tester,
            (observer) => app(textScale: scale, on: withRole(FakeCore(), role), observer: observer),
            actionIds: actions,
          );
          expect(violations, isEmpty, reason: violations.join('\n'));
        });
      }
    }
  });

  group('criterion 5: a pick the core confirms fires one vibration and one tone', () {
    testWidgets('one of each, on the notification stream', (tester) async {
      await openApp(tester);
      await tap(tester, pick(Roles.safety));
      expect(device.vibrations, 1);
      expect(device.tones, [BeepStream.notification]);
    });

    testWidgets('a pick that does not log fires neither, stays on the picker, and says so', (tester) async {
      await openApp(tester);
      core.failWith = const CoreException('failed', 'disk gone');
      await tap(tester, pick(Roles.recorder));
      expect([device.vibrations, device.tones], [0, isEmpty]);
      expect(picker, findsOneWidget);
      expect(find.text('Not logged. Tap again.'), findsOneWidget);

      core.failWith = null;
      await tap(tester, pick(Roles.recorder));
      expect(device.vibrations, 1);
      expect(find.text('Recorder'), findsOneWidget);
      expect(find.text('Not logged. Tap again.'), findsNothing, reason: 'a pick that worked clears it');
    });

    testWidgets('a second tap while the first is still being logged is the same pick, not a second one',
        (tester) async {
      final held = _HeldCore(core);
      await openApp(tester, on: held);
      held.hold = Completer<void>();
      await tester.tap(pick(Roles.overallPro));
      await tester.pump();
      await tester.tap(pick(Roles.overallPro));
      await tester.pump();
      held.hold!.complete();
      await tester.pumpAndSettle();

      expect([for (final e in await events(tester)) e.kind], [RoleKinds.assigned]);
      expect(device.vibrations, 1);
      expect(find.text('PRO'), findsOneWidget);
    });
  });

  group('criterion 6: UNDO ROLE takes a wrong pick back, with no confirm dialog', () {
    testWidgets('it logs a correction of the pick and the picker returns', (tester) async {
      await openApp(tester);
      await tap(tester, pick(Roles.markBoat));
      final picked = (await events(tester)).single;

      await tap(tester, undoRole);
      final all = await events(tester);
      expect(all, hasLength(2), reason: 'the undo is one event and nothing else');
      expect([all.last.kind, all.last.correctsUlid], [RoleKinds.undo, picked.ulid]);
      expect(picker, findsOneWidget);
      expect(popups.opened, isEmpty, reason: 'no dialog, sheet or menu');
      expect(find.byType(AlertDialog), findsNothing);
      expect(device.vibrations, 2, reason: 'the pick and the undo, each confirmed');
    });

    testWidgets('the right role picked next is the one later events carry', (tester) async {
      await openApp(tester);
      await tap(tester, pick(Roles.markBoat));
      await tap(tester, undoRole);
      await tap(tester, pick(Roles.recorder));
      await tap(tester, find.text('FINISHES'));
      await tap(tester, find.widgetWithText(FilledButton, 'FINISH'));
      final finish = (await events(tester)).singleWhere((e) => e.kind == FinishKinds.finish);
      expect(finish.role, Roles.recorder);
    });

    testWidgets('an undo that does not log stays on the home and says so', (tester) async {
      await openApp(tester, on: withRole(core, Roles.recorder));
      core.failWith = const CoreException('failed', 'disk gone');
      await tap(tester, undoRole);
      expect([device.vibrations, device.tones], [0, isEmpty]);
      expect(find.text('Recorder'), findsOneWidget);
      expect(find.text('Not logged. Tap again.'), findsOneWidget);
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
/// on its way to the log. The fake core answers in a microtask, too soon to
/// tap between.
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
