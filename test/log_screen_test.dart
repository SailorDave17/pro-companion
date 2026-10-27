import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/log/log_screen.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/ui/race_time.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';
import 'support/roles.dart';

/// #67, the screen's half: the committee log, opened from the PRO's home, shows each other
/// phone's log as the core classified it, and this phone's own broken chain as a banner. The
/// classification itself is the core's (packages/core/test/chain_status_test.dart), so these set
/// the fake core's answer.
void main() {
  final quiet = ConfirmationService(FakeConfirmationDevice());
  const day = 'b3c7e9a1-2d4f-4b6a-8c0e-1f2a3b4c5d6e';
  final at = DateTime(2026, 10, 26, 14, 32, 5).millisecondsSinceEpoch;
  String device(int n) => '01J8${'$n'.padLeft(22, '0')}';
  String ulid(int n) => '01J9${'$n'.padLeft(22, '0')}';

  final catchingUp = DeviceChain(
    eventId: day,
    raceDayName: 'Saturday series',
    deviceId: device(1),
    role: Roles.recorder,
    state: DeviceChainStates.catchingUp,
    first: 2,
    last: 9,
    missing: 3,
    lastVerified: ChainPoint(seq: 4, ulid: ulid(4), deviceTs: at),
  );
  final altered = DeviceChain(
    eventId: day,
    raceDayName: 'Saturday series',
    deviceId: device(2),
    role: Roles.markBoat,
    mark: StandardMarks.windward,
    state: DeviceChainStates.altered,
    first: 1,
    last: 6,
    breakAt: ChainBreak(
      at: ChainPoint(seq: 4, ulid: ulid(14), deviceTs: at + 61000),
      afterSeq: 3,
      reason: "its previous hash is not seq 3's: one of the two was altered",
    ),
  );
  final refused = DeviceChain(
    eventId: day,
    raceDayName: 'Saturday series',
    deviceId: device(3),
    role: Roles.overallPro,
    state: DeviceChainStates.refused,
    first: 3,
    last: 12,
    lastVerified: ChainPoint(seq: 12, ulid: ulid(12), deviceTs: at),
    refusals: [ChainRefusal(deviceId: device(3), seq: 7, hash: 'a' * 64, reason: 'revoked')],
  );
  final verified = DeviceChain(
    eventId: day,
    raceDayName: 'Saturday series',
    deviceId: device(4),
    role: Roles.safety,
    state: DeviceChainStates.verified,
    first: 1,
    last: 40,
    lastVerified: ChainPoint(seq: 40, ulid: ulid(40), deviceTs: at),
  );
  final ownBroken = ChainBreak(at: ChainPoint(seq: 12, ulid: ulid(112), deviceTs: at + 3000), reason: 'r');

  Widget app(FakeCore core, {double scale = 1.0, List<NavigatorObserver> observers = const []}) =>
      MediaQuery.withClampedTextScaling(
        minScaleFactor: scale,
        maxScaleFactor: scale,
        child: ProCompanionApp(confirmation: quiet, core: core, navigatorObservers: observers),
      );

  /// The PRO's home on the bar's reference phone, then LOG, its last button.
  Future<void> tapLog(WidgetTester tester) async {
    await tester.ensureVisible(find.text('LOG'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('LOG'));
    await tester.pumpAndSettle();
  }

  Future<FakeCore> openLog(WidgetTester tester, ChainStatus status) async {
    setPhoneSize(tester);
    final core = withRole(FakeCore())..chainStatusValue = status;
    await tester.pumpWidget(app(core));
    await tester.pumpAndSettle();
    await tapLog(tester);
    return core;
  }

  Finder row(DeviceChain d) => find.byKey(ValueKey('chain-${d.eventId}-${d.deviceId}'));
  Finder inRow(DeviceChain d, String text) => find.descendant(of: row(d), matching: find.text(text));

  testWidgets("LOG on the PRO's home opens the committee log, read through the core", (tester) async {
    final core = await openLog(tester, ChainStatus(devices: [verified]));
    expect(find.text('Committee log'), findsOneWidget);
    expect(find.text('Saturday series'), findsOneWidget, reason: "the race day's name heads its phones");
    expect(core.calls['chainStatus'], 1);
    expect(core.calls.containsKey('readAll'), isFalse, reason: "it shows no other phone's events, only their status");
  });

  testWidgets('criterion 1: a gapped chain reads as catching up, with the count missing and the last verified event',
      (tester) async {
    await openLog(tester, ChainStatus(devices: [catchingUp]));
    expect(inRow(catchingUp, 'Catching up'), findsOneWidget);
    expect(inRow(catchingUp, '3 events missing'), findsOneWidget);
    expect(inRow(catchingUp, 'Verified to event 4, logged 14:32:05'), findsOneWidget);
    expect(inRow(catchingUp, 'Recorder · phone …0001'), findsOneWidget);
  });

  testWidgets("criterion 2: a broken chain reads as altered and names the first bad event's time", (tester) async {
    await openLog(tester, ChainStatus(devices: [altered]));
    expect(inRow(altered, 'Altered'), findsOneWidget);
    expect(inRow(altered, 'First bad event: event 4, logged 14:33:06'), findsOneWidget);
    expect(inRow(altered, 'Event 3, before it, may be the one changed'), findsOneWidget);
    expect(inRow(altered, 'Mark boat at Windward · phone …0002'), findsOneWidget);
  });

  testWidgets("criterion 3: a refusal reads as 'refused at N' with the stub's reason category", (tester) async {
    await openLog(tester, ChainStatus(devices: [refused]));
    expect(inRow(refused, 'Refused at 7'), findsOneWidget);
    expect(inRow(refused, 'Event 7 refused: revoked'), findsOneWidget);
    expect(inRow(refused, 'Events 3 to 12, every link holds'), findsOneWidget, reason: 'verified past N');
  });

  testWidgets('a refusal under a worse status is still listed beneath it', (tester) async {
    final both = DeviceChain(
      eventId: day,
      deviceId: device(5),
      state: DeviceChainStates.catchingUp,
      first: 1,
      last: 9,
      missing: 1,
      lastVerified: const ChainPoint(seq: 5),
      refusals: [ChainRefusal(deviceId: device(5), seq: 5, hash: 'b' * 64, reason: 'not_admitted')],
    );
    await openLog(tester, ChainStatus(devices: [both]));
    expect(inRow(both, 'Catching up'), findsOneWidget);
    expect(inRow(both, 'Verified to event 5 (refused)'), findsOneWidget);
    expect(inRow(both, 'Event 5 refused: not admitted'), findsOneWidget);
    expect(inRow(both, 'Phone …0005'), findsOneWidget, reason: 'a phone with no role held is named by its id');
    expect(find.text('Unnamed race day'), findsOneWidget);
  });

  testWidgets('criterion 4: when a pull fills the gap, the open screen moves from catching up to verified',
      (tester) async {
    final core = await openLog(tester, ChainStatus(devices: [catchingUp]));
    expect(inRow(catchingUp, 'Catching up'), findsOneWidget);
    final filled = DeviceChain(
      eventId: day,
      raceDayName: 'Saturday series',
      deviceId: device(1),
      role: Roles.recorder,
      state: DeviceChainStates.verified,
      first: 2,
      last: 9,
      lastVerified: ChainPoint(seq: 9, ulid: ulid(9), deviceTs: at),
    );
    core.chainStatusValue = ChainStatus(devices: [filled]);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(inRow(filled, 'Verified'), findsOneWidget);
    expect(inRow(filled, 'Events 2 to 9, every link holds'), findsOneWidget);
    expect(find.text('Catching up'), findsNothing);
  });

  testWidgets("criterion 5: this phone's own broken chain is a banner naming the first bad event", (tester) async {
    await openLog(tester, ChainStatus(ownBreak: ownBroken, devices: [verified]));
    final banner = find.byKey(const ValueKey('own-chain-broken'));
    expect(find.descendant(of: banner, matching: find.text("This phone's log has been altered")), findsOneWidget);
    expect(find.descendant(of: banner, matching: find.text('First bad event: event 12, logged 14:32:08')),
        findsOneWidget);
    expect(tester.getTopLeft(banner).dy, lessThan(tester.getTopLeft(row(verified)).dy), reason: 'above the rows');
  });

  testWidgets('no banner while its own chain stands', (tester) async {
    await openLog(tester, ChainStatus(devices: [verified]));
    expect(find.byKey(const ValueKey('own-chain-broken')), findsNothing);
  });

  testWidgets("before any pull, it says there is nothing from other phones", (tester) async {
    await openLog(tester, ChainStatus.empty);
    expect(find.text("No other phone's events on this phone yet."), findsOneWidget);
  });

  testWidgets('a core that cannot be read is said so', (tester) async {
    setPhoneSize(tester);
    final core = withRole(FakeCore());
    await tester.pumpWidget(app(core));
    await tester.pumpAndSettle();
    core.failWith = const CoreException('failed', 'disk gone');
    await tapLog(tester);
    expect(find.text('The log on this phone could not be read'), findsOneWidget);
    expect(find.text("No other phone's events on this phone yet."), findsNothing);
  });

  testWidgets('it stops asking once it is closed', (tester) async {
    final core = await openLog(tester, ChainStatus(devices: [verified]));
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    final asked = core.calls['chainStatus'];
    await tester.pump(const Duration(seconds: 20));
    expect(core.calls['chainStatus'], asked);
  });

  group('criterion 6: altered, refused and catching up are told apart by shape and text, not colour alone', () {
    final rows = [altered, catchingUp, refused, verified];

    test('each status has its own icon and its own words', () {
      expect({for (final d in rows) chainStateIcon(d.state)}, hasLength(4));
      expect({for (final d in rows) chainStateText(d)}, hasLength(4));
    });

    testWidgets('each row draws its own icon, and a screen reader hears its status first', (tester) async {
      await openLog(tester, ChainStatus(devices: rows));
      for (final d in rows) {
        await tester.scrollUntilVisible(row(d), 100);
        final icon = tester.widget<Icon>(find.descendant(of: row(d), matching: find.byType(Icon)));
        expect(icon.icon, chainStateIcon(d.state), reason: d.state);
        expect(tester.getSemantics(row(d)).label, startsWith('${chainStateText(d)}. '), reason: d.state);
      }
    });

    // Not a race-time route, but reachable from the role home, so held to the bar, with every
    // status and a list longer than the screen on it. The whole-app check holds every registered
    // action, so the day has a gun and named finishes, as the results screen's check does (the
    // overlay); with no fleet named, the fleet row cannot exist.
    //
    // The check judges what is built, and a list builds only its first screenful. At 200% the
    // banner fills that, so a check with it judged no row at all (measured: a swipe planted on every
    // row reddened the 100% check and not the 200% one). So the rows are checked without the banner
    // too, where they are the first screenful.
    for (final (scale, banner) in [(1.0, true), (2.0, true), (1.0, false), (2.0, false)]) {
      testWidgets('the committee log passes the bar-check helper at ${(scale * 100).round()}% text, '
          '${banner ? 'with' : 'without'} the broken-chain banner', (tester) async {
        final violations = await barCheck(tester, actionIds: proRaceTimeActionIds.difference({'fleet-switch'}),
            (observer) {
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
          core.chainStatusValue = ChainStatus(ownBreak: banner ? ownBroken : null, devices: [
              ...rows,
              for (var n = 10; n < 20; n++)
                DeviceChain(
                  eventId: day,
                  raceDayName: 'Saturday series',
                  deviceId: device(n),
                  role: Roles.recorder,
                  state: DeviceChainStates.verified,
                  first: 1,
                  last: n,
                ),
            ]);
          return app(core, scale: scale, observers: [observer]);
        });
        expect(violations, isEmpty, reason: violations.join('\n'));
      });
    }
  });
}
