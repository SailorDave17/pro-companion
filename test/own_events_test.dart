import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';
import 'support/roles.dart';

/// #64, the screens' half (owner decision at pickup, 2026-10-24): once sync pulls the other
/// committee phones' events down, every screen still reads this phone's own events only, through
/// CoreClient.readOwn, and behaves exactly as before. Stories built for the committee's view (#66
/// to #69, #76) read readAll on purpose.
///
/// Each case seeds another phone's events of exactly the kinds its screen reads, and holds the
/// screen to what it shows with no other phone at all. Read through readAll, the home's count and
/// the finish, sequence, fleets, results and mark-finish screens would each differ (proven by
/// mutation on #64). The role gate's case would not: currentRolePick already filters by device, as
/// currentStationPick does for the home's station read. Those two reads are held to readOwn by the
/// tests that pin the core calls a screen makes (home_screen_test, results_screen_test), and the
/// role gate's case here holds only that the picker still opens.
void main() {
  const otherDevice = '01J8000000000000000000OTHR';
  late int now;
  late FakeConfirmationDevice device;

  setUp(() {
    now = DateTime(2026, 10, 24, 14, 30).millisecondsSinceEpoch;
    device = FakeConfirmationDevice();
  });

  /// Another committee phone in [role], logging [events] on the same clock: what sync would have
  /// pulled down. Its envelopes carry its own device id, as pulled events do.
  Future<List<EventEnvelope>> otherPhone(WidgetTester tester, List<NewEvent> events, {String role = Roles.overallPro}) async {
    final other = withRole(FakeCore(deviceIdValue: otherDevice, clock: () => now += 1000), role);
    return (await tester.runAsync(() async {
      for (final e in events) {
        await other.append(e);
      }
      return other.readAll();
    }))!;
  }

  Future<void> openApp(WidgetTester tester, FakeCore core) async {
    setPhoneSize(tester);
    await tester.pumpWidget(ProCompanionApp(core: core, confirmation: ConfirmationService(device)));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  testWidgets("the role gate: another phone's role pick does not open a home here", (tester) async {
    final core = FakeCore(clock: () => now);
    core.seed(await otherPhone(tester, const []));
    await openApp(tester, core);
    expect(find.text('Pick your role'), findsOneWidget);
  });

  testWidgets("the home counts this phone's events, not another phone's", (tester) async {
    final core = withRole(FakeCore(clock: () => now));
    core.seed(await otherPhone(tester, [
      for (var i = 0; i < 4; i++) const NewEvent(kind: 'note', source: 'tap'),
    ]));
    await openApp(tester, core);
    expect(find.text('1 event on this phone'), findsOneWidget, reason: 'its own role pick only');
  });

  testWidgets("the finish screen: another phone's finishes are not listed, and UNDO LAST never takes one",
      (tester) async {
    final core = withRole(FakeCore(clock: () => now));
    core.seed(await otherPhone(tester, [FinishEvents.finish(fleet: null), FinishEvents.finish(fleet: null)]));
    await openApp(tester, core);
    await tap(tester, find.text('FINISHES'));
    expect(find.text('Finishes · 0'), findsOneWidget);
    expect(find.text('Nothing to undo'), findsOneWidget);

    await tap(tester, find.widgetWithText(FilledButton, 'FINISH'));
    expect(find.text('Finishes · 1'), findsOneWidget);
    await tap(tester, find.text('UNDO LAST (#1)'));
    final undo = (await tester.runAsync(core.readOwn))!.singleWhere((e) => e.kind == FinishKinds.undo);
    final mine = (await tester.runAsync(core.readOwn))!.singleWhere((e) => e.kind == FinishKinds.finish);
    expect(undo.correctsUlid, mine.ulid, reason: "this phone's own finish, not another phone's later one");
  });

  testWidgets("the sequence card: another phone's gun is not this phone's", (tester) async {
    final core = withRole(FakeCore(clock: () => now));
    core.seed(await otherPhone(tester, [StartEvents.start(fleet: null, source: 'tap')]));
    await openApp(tester, core);
    await tap(tester, find.text('SEQUENCE'));
    expect(find.text('NO GUN'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^GUN \d')), findsNothing, reason: "no gun time: another phone's is not shown");
  });

  testWidgets("the fleets screen: another phone's fleet is not listed, and the name is free here", (tester) async {
    final core = withRole(FakeCore(clock: () => now));
    core.seed(await otherPhone(tester, [FleetEvents.define('Lasers', klass: 'ILCA 7')]));
    await openApp(tester, core);
    await tap(tester, find.text('FLEETS'));
    expect(find.text('No fleets yet. Name the first one below.'), findsOneWidget);
    expect(find.text('Lasers'), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'Lasers');
    await tester.pump();
    await tap(tester, find.widgetWithText(FilledButton, 'ADD FLEET'));
    expect(find.text('Lasers is already a fleet'), findsNothing);
    expect(
        (await tester.runAsync(core.readOwn))!.where((e) => e.kind == FleetKinds.defined).map((e) => e.payload['name']),
        ['Lasers']);
  });

  testWidgets("results: another phone's finishes are not scored here", (tester) async {
    final core = withRole(FakeCore(clock: () => now));
    core.seed(await otherPhone(tester, [
      StartEvents.start(fleet: null, source: 'tap'),
      FinishEvents.finish(fleet: null),
      FinishEvents.finish(fleet: null),
    ]));
    await openApp(tester, core);
    await tap(tester, find.text('RESULTS'));
    expect(find.text('No finishes yet.'), findsOneWidget);
  });

  testWidgets("finish at a mark: another mark boat's finishes there are not listed", (tester) async {
    final core = withRole(FakeCore(clock: () => now += 1000), Roles.markBoat);
    await tester.runAsync(() => core.append(StationEvents.select(StandardMarks.windward)));
    core.seed(await otherPhone(
      tester,
      [
        StationEvents.select(StandardMarks.windward),
        CourseEvents.shortened(fleet: null),
        FinishEvents.atMark(fleet: null),
        FinishEvents.atMark(fleet: null),
      ],
      role: Roles.markBoat,
    ));
    await openApp(tester, core);
    await tap(tester, find.byKey(const ValueKey('finish-at-mark')));
    expect(find.text('Not a finish yet: tap FINISH HERE'), findsOneWidget,
        reason: "another phone's shortened course is not this phone's");
    await tap(tester, find.byKey(const ValueKey('finish-here')));
    expect(find.text('Finish at Windward · 0'), findsOneWidget);
  });
}
