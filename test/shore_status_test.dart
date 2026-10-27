import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/finish/finish_screen.dart';
import 'package:pro_companion/finish/mark_finish_screen.dart';
import 'package:pro_companion/fleets/fleets_screen.dart';
import 'package:pro_companion/log/log_screen.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/results/results_screen.dart';
import 'package:pro_companion/roles/roles.dart';
import 'package:pro_companion/sequence/sequence_screen.dart';
import 'package:pro_companion/shore/shore_status.dart';
import 'package:pro_companion/stations/station_screen.dart';
import 'package:pro_companion/ui/race_time.dart';
import 'package:pro_companion/ui/sunlight.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';
import 'support/roles.dart';

/// #66: each phone shows what has reached shore, what waits and what was refused - an app-bar
/// chip on every race-time screen, a row on each role's home, and a full screen behind both. What
/// the core counts is the core's (packages/core/test/uploads_test.dart), so these set the fake
/// core's answer.
void main() {
  final quiet = ConfirmationService(FakeConfirmationDevice());
  final up = DateTime(2026, 10, 26, 14, 32, 10).millisecondsSinceEpoch;
  final down = DateTime(2026, 10, 26, 14, 33, 40).millisecondsSinceEpoch;
  String ulid(int n) => '01J9${'$n'.padLeft(22, '0')}';

  /// Criterion 1's phone: 10 events, 6 of them acknowledged.
  final fourWaiting = UploadStatus(
    pending: 4,
    accepted: 6,
    neverAdmitted: 0,
    refused: const [],
    lastAcceptedAt: up,
    waitingByKind: const {FinishKinds.finish: 3, StartKinds.start: 1},
  );
  final pulled = PullStatus(lastPulledAt: down, lastRun: PullRun(state: PullRunState.done, at: down));

  final chip = find.byKey(const ValueKey('shore-indicator'));
  final row = find.byKey(const ValueKey('shore-row'));
  Finder inChip(String text) => find.descendant(of: chip, matching: find.text(text));
  Finder inRow(String text) => find.descendant(of: row, matching: find.text(text));
  Finder icon(IconData data) => find.byKey(ValueKey('shore-icon-${data.codePoint}'));
  final finishButton = find.widgetWithText(FilledButton, 'FINISH');

  /// The home's row, at the foot of the home, scrolled to where a short phone needs it.
  Future<void> tapRow(WidgetTester tester) async {
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  FakeCore core0(UploadStatus upload, [PullStatus pull = PullStatus.empty]) => withRole(FakeCore())
    ..uploadStatusValue = upload
    ..pullStatusValue = pull;

  Widget app(FakeCore core, {double scale = 1.0, int Function()? clock, List<NavigatorObserver> observers = const []}) =>
      MediaQuery.withClampedTextScaling(
        minScaleFactor: scale,
        maxScaleFactor: scale,
        child: ProCompanionApp(
          confirmation: quiet,
          core: core,
          clock: clock ?? () => down,
          navigatorObservers: observers,
        ),
      );

  /// Every screen a home opens that carries the chip, each built on its own.
  final screens = <String, Widget Function(CoreClient core)>{
    'finishes': (core) => FinishScreen(core: core, confirmation: quiet),
    'finish at mark': (core) => MarkFinishScreen(core: core, confirmation: quiet, mark: StandardMarks.windward),
    'sequence': (core) => SequenceScreen(core: core, confirmation: quiet, clock: () => down),
    'station': (core) => StationScreen(core: core, confirmation: quiet, current: null),
    'fleets': (core) => FleetsScreen(core: core, confirmation: quiet),
    'results': (core) => ResultsScreen(core: core, confirmation: quiet),
    'log': (core) => LogScreen(core: core),
  };

  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    setPhoneSize(tester);
    await tester.pumpWidget(MaterialApp(theme: sunlightTheme(), home: screen));
    await tester.pumpAndSettle();
  }

  group('criterion 1: 4 waiting of 10, and the times of the last upload and the last pull', () {
    for (final MapEntry(key: name, value: build) in screens.entries) {
      testWidgets('on the $name screen', (tester) async {
        final core = core0(fourWaiting, pulled);
        await pumpScreen(tester, build(core));
        expect(inChip('4 waiting'), findsOneWidget);
        expect(inChip('14:32'), findsOneWidget, reason: 'the last successful upload');
        expect(inChip('14:33'), findsOneWidget, reason: 'the last pull');
        expect(core.calls['uploadStatus'], greaterThanOrEqualTo(1));
        expect(core.calls['pullStatus'], greaterThanOrEqualTo(1));
      });
    }

    testWidgets("on each role's home, in words", (tester) async {
      for (final role in pickableRoles) {
        setPhoneSize(tester);
        await tester.pumpWidget(app(withRole(FakeCore(), role)
          ..uploadStatusValue = fourWaiting
          ..pullStatusValue = pulled));
        await tester.pumpAndSettle();
        expect(inRow('4 waiting'), findsOneWidget, reason: role);
        expect(inRow('Upload 14:32 · Pull 14:33'), findsOneWidget, reason: role);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('before the first sync, it says so rather than showing times', (tester) async {
      await pumpScreen(tester, FinishScreen(core: core0(fourWaiting.copyWithTimes()), confirmation: quiet));
      expect(inChip('4 waiting'), findsOneWidget);
      expect(inChip('not synced'), findsOneWidget);
    });

    testWidgets('a screen reader hears every part in words', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpScreen(tester, FinishScreen(core: core0(fourWaiting, pulled), confirmation: quiet));
      expect(
        tester.getSemantics(chip),
        matchesSemantics(
          label: '4 waiting. Last upload 14:32. Last pull 14:33. Shows what has reached shore',
          isButton: true,
          hasTapAction: true,
          isFocusable: true,
          hasFocusAction: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );
      semantics.dispose();
    });
  });

  group('criterion 2: every event acknowledged', () {
    final onShore = UploadStatus(pending: 0, accepted: 10, neverAdmitted: 0, refused: const [], lastAcceptedAt: up);

    testWidgets('shows the all-on-shore state by its own shape and its own words', (tester) async {
      await pumpScreen(tester, FinishScreen(core: core0(onShore, pulled), confirmation: quiet));
      expect(inChip('All on shore'), findsOneWidget);
      expect(find.descendant(of: chip, matching: icon(Icons.cloud_done)), findsOneWidget);
      final shown = IconTheme.of(tester.element(icon(Icons.cloud_done))).color;

      await pumpScreen(tester, FinishScreen(core: core0(fourWaiting, pulled), confirmation: quiet));
      expect(inChip('All on shore'), findsNothing);
      expect(find.descendant(of: chip, matching: icon(Icons.cloud_upload)), findsOneWidget);
      expect(IconTheme.of(tester.element(icon(Icons.cloud_upload))).color, shown,
          reason: 'not colour: the two states are drawn in the same colour');
    });

    test('every state has a shape of its own', () {
      final readings = {
        'offline': ShoreReading(fourWaiting, const PullStatus(lastRun: PullRun(state: PullRunState.unreachable, at: 1))),
        'refused': ShoreReading(
            const UploadStatus(pending: 0, accepted: 1, neverAdmitted: 0, refused: [
              RefusedUpload(ulid: 'U', reason: 'revoked', mayBeOnShore: false),
            ]),
            PullStatus.empty),
        'waiting': ShoreReading(fourWaiting, PullStatus.empty),
        'all on shore': ShoreReading(onShore, PullStatus.empty),
        'nothing sent': ShoreReading(UploadStatus.empty, PullStatus.empty),
      };
      expect({for (final r in readings.values) shoreIcon(r)}, hasLength(readings.length));
      expect({for (final r in readings.values) shoreHeadline(r)}, hasLength(readings.length));
    });

    test('nothing sent is not all on shore: with nothing accepted, the shore holds nothing of this phone', () {
      final kept = ShoreReading(const UploadStatus(pending: 0, accepted: 0, neverAdmitted: 1, refused: []), PullStatus.empty);
      expect([kept.allOnShore, shoreHeadline(kept)], [false, 'Nothing sent']);
    });

    test('events kept on the phone never hold back the all-on-shore state (owner decision)', () {
      final r = ShoreReading(
          UploadStatus(pending: 0, accepted: 10, neverAdmitted: 1, held: 2, refused: const [], lastAcceptedAt: up),
          PullStatus.empty);
      expect([r.allOnShore, r.kept, shoreHeadline(r)], [true, 3, 'All on shore']);
    });
  });

  group('criterion 3: no connectivity', () {
    final offlineUpload = UploadStatus(
      pending: 4,
      accepted: 6,
      neverAdmitted: 0,
      refused: const [],
      lastAcceptedAt: up,
      lastRun: UploadRun(state: UploadRunState.unreachable, at: down + 5000),
      waitingByKind: const {FinishKinds.finish: 4},
    );

    testWidgets('shows offline with the age of the last sync', (tester) async {
      await pumpScreen(
          tester,
          SequenceScreen(
            core: core0(offlineUpload, pulled),
            confirmation: quiet,
            clock: () => down + 12 * 60000 + 30000,
          ));
      expect(inChip('Offline · 4 waiting'), findsOneWidget);
      expect(inChip('last sync 12 min ago'), findsOneWidget, reason: 'the later of the last upload and the last pull');
      expect(find.descendant(of: chip, matching: icon(Icons.cloud_off)), findsOneWidget);

      setPhoneSize(tester);
      await tester.pumpWidget(app(core0(offlineUpload, pulled), clock: () => down + 2 * 3600000));
      await tester.pumpAndSettle();
      expect(inRow('Offline · 4 waiting'), findsOneWidget);
      expect(inRow('last sync 2 h ago'), findsOneWidget);
    });

    testWidgets('a phone offline that never reached the shore says never synced', (tester) async {
      final never = UploadStatus(
          pending: 1,
          accepted: 0,
          neverAdmitted: 0,
          refused: const [],
          lastRun: UploadRun(state: UploadRunState.unreachable, at: down));
      await pumpScreen(tester, SequenceScreen(core: core0(never), confirmation: quiet, clock: () => down));
      expect(inChip('Offline · 1 waiting'), findsOneWidget);
      expect(inChip('never synced'), findsOneWidget);
    });

    test('the latest run decides: a pull that reached the server after an unreachable upload is not offline', () {
      final upload = UploadStatus(
          pending: 1, accepted: 0, neverAdmitted: 0, refused: const [], lastRun: UploadRun(state: UploadRunState.unreachable, at: 10));
      expect(ShoreReading(upload, const PullStatus(lastRun: PullRun(state: PullRunState.done, at: 11))).offline, isFalse);
      expect(ShoreReading(upload, const PullStatus(lastRun: PullRun(state: PullRunState.done, at: 9))).offline, isTrue);
      expect(ShoreReading(upload, PullStatus.empty).offline, isTrue);
      expect(ShoreReading(UploadStatus.empty, const PullStatus(lastRun: PullRun(state: PullRunState.unreachable, at: 3))).offline,
          isTrue);
      expect(ShoreReading(UploadStatus.empty, PullStatus.empty).offline, isFalse, reason: 'no run yet is not offline');
    });

    testWidgets('appends are never blocked by it: offline, a finish logs', (tester) async {
      final core = core0(offlineUpload, pulled);
      await pumpScreen(tester, FinishScreen(core: core, confirmation: quiet));
      expect(inChip('Offline · 4 waiting'), findsOneWidget, reason: 'control: the chip says offline');
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      expect(core.calls['append'], 1);
      expect(find.text('Finishes · 1'), findsOneWidget);
    });

    testWidgets('appends are never blocked by it: with its reads never answered, a finish logs', (tester) async {
      final core = _StuckStatusCore();
      withRole(core);
      await pumpScreen(tester, FinishScreen(core: core, confirmation: quiet));
      expect(inChip('Reading…'), findsOneWidget, reason: 'control: the chip is still waiting on the core');
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      expect(core.calls['append'], 1);
      expect(find.text('Finishes · 1'), findsOneWidget);
    });
  });

  group('criterion 4: events the server refused', () {
    final withRefusals = UploadStatus(
      pending: 2,
      accepted: 5,
      neverAdmitted: 0,
      refused: [
        RefusedUpload(ulid: ulid(1), reason: 'revoked', mayBeOnShore: true, kind: FinishKinds.finish),
        RefusedUpload(ulid: ulid(2), reason: 'ulid_conflict', mayBeOnShore: false, kind: StartKinds.generalRecall),
        RefusedUpload(ulid: ulid(3), reason: 'inconsistent_canonical', mayBeOnShore: false),
      ],
      lastAcceptedAt: up,
      waitingByKind: const {FinishKinds.finish: 2},
    );

    testWidgets('are counted apart from what waits, on the chip', (tester) async {
      await pumpScreen(tester, FinishScreen(core: core0(withRefusals, pulled), confirmation: quiet));
      expect(inChip('2 waiting · 3 refused'), findsOneWidget);
      expect(find.descendant(of: chip, matching: icon(Icons.report)), findsOneWidget);
    });

    testWidgets('each shows its reason category, with its kind, behind the chip', (tester) async {
      await pumpScreen(tester, FinishScreen(core: core0(withRefusals, pulled), confirmation: quiet));
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.text('Refused · 3'), findsOneWidget);
      expect(find.text('Waiting · 2'), findsOneWidget, reason: 'counted apart');
      Finder refusal(int n, String text) =>
          find.descendant(of: find.byKey(ValueKey('refused-${ulid(n)}')), matching: find.text(text));
      expect(refusal(1, 'Finish'), findsOneWidget);
      expect(refusal(1, 'Refused: revoked'), findsOneWidget);
      expect(refusal(1, 'It may be on shore all the same'), findsOneWidget);
      expect(refusal(2, 'Start general recall'), findsOneWidget);
      expect(refusal(2, 'Refused: another text under its ULID'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(ValueKey('refused-${ulid(3)}')), 200);
      expect(refusal(3, 'Unreadable event'), findsOneWidget, reason: 'a body that names no kind');
      expect(refusal(3, 'Refused: inconsistent text'), findsOneWidget);
    });
  });

  group('criterion 5: a tap opens the list of what waits and what was refused, by kind', () {
    final full = UploadStatus(
      pending: 4,
      accepted: 6,
      neverAdmitted: 1,
      held: 2,
      refused: [RefusedUpload(ulid: ulid(1), reason: 'revoked', mayBeOnShore: false, kind: FinishKinds.sail)],
      lastAcceptedAt: up,
      waitingByKind: const {FinishKinds.finish: 3, StartKinds.start: 1},
    );

    void expectTheList(String why) {
      expect(find.text('Sent to shore'), findsOneWidget, reason: why);
      Finder waiting(String kind, String text) =>
          find.descendant(of: find.byKey(ValueKey('waiting-$kind')), matching: find.text(text));
      expect(find.text('Waiting · 4'), findsOneWidget, reason: why);
      expect(waiting(FinishKinds.finish, 'Finish'), findsOneWidget, reason: why);
      expect(waiting(FinishKinds.finish, '3 waiting'), findsOneWidget, reason: why);
      expect(waiting(StartKinds.start, 'Start'), findsOneWidget, reason: why);
      expect(waiting(StartKinds.start, '1 waiting'), findsOneWidget, reason: why);
      expect(find.text('Refused · 1'), findsOneWidget, reason: why);
      expect(find.text('Finish sail'), findsOneWidget, reason: why);
    }

    testWidgets("in one tap from each role's home", (tester) async {
      for (final role in pickableRoles) {
        setPhoneSize(tester);
        await tester.pumpWidget(app(withRole(FakeCore(), role)
          ..uploadStatusValue = full
          ..pullStatusValue = pulled));
        await tester.pumpAndSettle();
        await tapRow(tester);
        expectTheList(role);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    for (final MapEntry(key: name, value: build) in screens.entries) {
      testWidgets('in one tap from the $name screen, and back', (tester) async {
        await pumpScreen(tester, build(core0(full, pulled)));
        await tester.tap(chip);
        await tester.pumpAndSettle();
        expectTheList(name);
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(chip, findsOneWidget, reason: 'back on the $name screen');
      });
    }

    testWidgets('it lists what stays on the phone apart, and the two times in full', (tester) async {
      setPhoneSize(tester);
      await tester.pumpWidget(app(core0(full, pulled), clock: () => down + 90000));
      await tester.pumpAndSettle();
      await tapRow(tester);
      await tester.scrollUntilVisible(find.text('Kept on this phone · 3'), 200);
      expect(find.text('1 before admission'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('2 after removal'), 200);
      expect(find.text('2 after removal'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('shore-pull')), 200);
      expect(find.text('On shore · 6'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('shore-times')), matching: find.text('14:32:10, 3 min ago')),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('shore-pull')), matching: find.text('14:33:40, 1 min ago')),
          findsOneWidget);
    });

    testWidgets('the list follows the core while open', (tester) async {
      final core = core0(full, pulled);
      setPhoneSize(tester);
      await tester.pumpWidget(app(core));
      await tester.pumpAndSettle();
      await tapRow(tester);
      expect(find.text('Waiting · 4'), findsOneWidget);
      core.uploadStatusValue = UploadStatus(pending: 0, accepted: 10, neverAdmitted: 0, refused: const [], lastAcceptedAt: up);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Waiting · 0'), findsOneWidget);
      expect(find.text('Nothing waiting'), findsOneWidget);
    });
  });

  group('the chip reads the core', () {
    testWidgets('every 5 s while its screen shows, not while covered, and at once when it shows again',
        (tester) async {
      final core = core0(fourWaiting, pulled);
      setPhoneSize(tester);
      await tester.pumpWidget(app(core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('FINISHES'));
      await tester.pumpAndSettle();
      final before = core.calls['uploadStatus']!;
      await tester.pump(const Duration(seconds: 10));
      expect(core.calls['uploadStatus']! - before, 2, reason: "FINISHES' chip twice; the home under it never");

      core.uploadStatusValue = UploadStatus(pending: 0, accepted: 10, neverAdmitted: 0, refused: const [], lastAcceptedAt: up);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(inRow('All on shore'), findsOneWidget, reason: 'read as the home showed again, before any tick');
    });

    testWidgets('a read that fails before any worked says so, and the screen works on', (tester) async {
      final core = core0(fourWaiting, pulled)..failWith = const CoreException('io', 'disk');
      await pumpScreen(tester, LogScreen(core: core));
      expect(inChip('Not read'), findsOneWidget);
    });
  });

  group('criterion 6: the chip, the row and the list pass the bar-check helper', () {
    // From the PRO's home, whose whole-app check holds every PRO action, so the day has a gun and
    // named finishes, as the log's check does. The list is fuller than a screen, so its check
    // judges a scrolled view's first screenful too.
    for (final scale in [1.0, 2.0]) {
      testWidgets('at ${(scale * 100).round()}% text', (tester) async {
        late Widget Function(NavigatorObserver observer) build;
        final violations = await barCheck(
            tester, actionIds: proRaceTimeActionIds.difference({'fleet-switch'}), build = (observer) {
          var t = DateTime(2026, 10, 26, 14, 30).millisecondsSinceEpoch;
          final core = withRole(FakeCore(clock: () => t += 1000));
          var seq = 0;
          EventEnvelope event(String id, String kind, Map<String, Object?> payload) => EventEnvelope(
                ulid: id,
                deviceTs: t += 1000,
                deviceId: core.deviceIdValue,
                seq: ++seq,
                source: 'tap',
                kind: kind,
                payloadVersion: 1,
                payload: payload,
              );
          core.seed([event(ulid(200), StartKinds.start, const {'fleet': null})]);
          for (var boat = 0; boat < 3; boat++) {
            final f = ulid(201 + 2 * boat);
            core.seed([
              event(f, FinishKinds.finish, const {'fleet': null}),
              event(ulid(202 + 2 * boat), FinishKinds.sail, {'finish': f, 'sail': '${1000 + boat}'}),
            ]);
          }
          core
            ..uploadStatusValue = UploadStatus(
              pending: 12,
              accepted: 6,
              neverAdmitted: 1,
              held: 2,
              refused: [
                for (var n = 0; n < 6; n++)
                  RefusedUpload(ulid: ulid(300 + n), reason: 'ulid_conflict', mayBeOnShore: n.isEven, kind: FinishKinds.finish),
              ],
              lastAcceptedAt: up,
              waitingByKind: const {
                FinishKinds.finish: 6,
                FinishKinds.sail: 3,
                StartKinds.generalRecall: 1,
                ClockKinds.offset: 1,
                UploadStatus.noKind: 1,
              },
            )
            ..pullStatusValue = pulled;
          return app(core, scale: scale, observers: [observer]);
        });
        expect(violations, isEmpty, reason: violations.join('\n'));

        // A check passes over what is not there, so the app it checked must have held the row, the
        // chip and the list: removing the indicator left the check itself green (the mutation round).
        setPhoneSize(tester);
        await tester.pumpWidget(build(NavigatorObserver()));
        await tester.pumpAndSettle();
        await tapRow(tester);
        expect(find.text('Waiting · 12').hitTestable(), findsOneWidget,
            reason: 'control: the list, one tap from home, what waits on its first screen');
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('FINISHES'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('FINISHES'));
        await tester.pumpAndSettle();
        expect(inChip('12 waiting · 6 refused'), findsOneWidget, reason: "control: the chip, on FINISHES' app bar");
      });
    }

    // The CI emulator's 320 x 640 phone, at 200%: the chip shrinks to fit beside the title rather
    // than overflow or clip.
    testWidgets("on a 320 x 640 phone at 200% text the chip fits FINISHES' app bar", (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final refused = UploadStatus(
        pending: 12,
        accepted: 6,
        neverAdmitted: 0,
        refused: const [RefusedUpload(ulid: 'U', reason: 'revoked', mayBeOnShore: false)],
        lastAcceptedAt: up,
        // After the pull's run: the latest run decides.
        lastRun: UploadRun(state: UploadRunState.unreachable, at: down + 5000),
      );
      await tester.pumpWidget(MediaQuery.withClampedTextScaling(
        minScaleFactor: 2,
        maxScaleFactor: 2,
        child: MaterialApp(theme: sunlightTheme(), home: FinishScreen(core: core0(refused, pulled), confirmation: quiet)),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(inChip('Offline · 12 waiting · 1 refused'), findsOneWidget);
      final size = tester.getSize(chip);
      expect(size.width, lessThanOrEqualTo(320 * 0.4 + 0.5));
      expect(size.height, greaterThanOrEqualTo(64));
      expect(size.width, greaterThanOrEqualTo(64));
      expect(clippedLabels(tester), isEmpty);
    });
  });

  group('words', () {
    test('ages round down, in the largest unit', () {
      const m = 60000;
      expect([ageText(0, 59999), ageText(0, m), ageText(0, 59 * m), ageText(0, 60 * m), ageText(0, 24 * 60 * m)],
          ['just now', '1 min ago', '59 min ago', '1 h ago', '1 d ago']);
    });

    test('kinds read as words', () {
      expect([kindText('finish'), kindText('start.general_recall'), kindText(UploadStatus.noKind)],
          ['Finish', 'Start general recall', 'Unreadable event']);
    });
  });
}

extension on UploadStatus {
  /// This status with no upload time: a phone sync has never answered.
  UploadStatus copyWithTimes() => UploadStatus(
        pending: pending,
        accepted: accepted,
        neverAdmitted: neverAdmitted,
        refused: refused,
        held: held,
        waitingByKind: waitingByKind,
      );
}

/// A core whose status reads never answer, as a core busy or wedged in its upload tables might.
class _StuckStatusCore extends FakeCore {
  @override
  Future<UploadStatus> uploadStatus() => Completer<UploadStatus>().future;

  @override
  Future<PullStatus> pullStatus() => Completer<PullStatus>().future;
}
