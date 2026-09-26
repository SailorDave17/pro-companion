import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/ui/bars.dart';
import 'package:pro_companion/ui/race_time.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';

/// #7 criterion 1 on the results screen, driven against the fake core: the
/// PRO opens provisional results from home and reads each boat's points in
/// each race, scored on the phone by the core's engine. The races, boats and
/// points themselves are proven in packages/core/test/results_test.dart; this
/// proves the screen shows them, and the owner's three decisions (races by
/// starts, placeholders with a warning, a discard count the PRO sets).
void main() {
  late int now;
  late FakeCore core;
  late FakeConfirmationDevice device;

  setUp(() {
    now = DateTime(2026, 9, 26, 14, 30).millisecondsSinceEpoch;
    core = FakeCore(clock: () => now);
    device = FakeConfirmationDevice();
  });

  Future<EventEnvelope> add(WidgetTester tester, NewEvent e) async {
    final stored = (await tester.runAsync(() => core.append(e)))!;
    now += 1000;
    return stored;
  }

  Future<void> gun(WidgetTester tester, {String? fleet}) => add(tester, StartEvents.start(fleet: fleet, source: 'manual'));

  Future<EventEnvelope> finish(WidgetTester tester, String? sail, {String? fleet}) async {
    final f = await add(tester, FinishEvents.finish(fleet: fleet));
    if (sail != null) await add(tester, FinishEvents.assignSail(f.ulid, sail));
    return f;
  }

  Future<void> openResults(WidgetTester tester, {double textScale = 1}) async {
    setPhoneSize(tester);
    await tester.pumpWidget(MediaQuery.withClampedTextScaling(
      minScaleFactor: textScale,
      maxScaleFactor: textScale,
      child: ProCompanionApp(core: core, confirmation: ConfirmationService(device)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RESULTS'));
    await tester.pumpAndSettle();
    expect(find.text('Provisional results'), findsOneWidget);
  }

  Finder standing(String boat) => find.byKey(ValueKey('standing-$boat'));

  /// Every text in [boat]'s line, in order.
  List<String> line(WidgetTester tester, String boat) => [
        for (final t in tester.widgetList<Text>(find.descendant(of: standing(boat), matching: find.byType(Text))))
          t.data!,
      ];

  List<String> boatsShown(WidgetTester tester) => [
        for (final e in find
            .byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('standing-'))
            .evaluate())
          (e.widget.key as ValueKey<String>).value.substring('standing-'.length),
      ];

  group('criterion 1: per-race points, computed on the phone, shown after the last finish', () {
    testWidgets('each boat shows her rank, her series points and each race\'s points', (tester) async {
      await gun(tester);
      await finish(tester, '11');
      await finish(tester, '22');
      await finish(tester, '33');
      await gun(tester);
      await finish(tester, '33');
      await finish(tester, '11');
      await openResults(tester);

      expect(find.text('2 races · provisional'), findsOneWidget);
      expect(boatsShown(tester), ['11', '33', '22']);
      // Race 2: 22 did not finish it, so DNC = 3 boats + 1.
      expect(line(tester, '11'), ['1', '11', '3', 'R1 1', 'R2 2']);
      expect(line(tester, '33'), ['2', '33', '4', 'R1 3', 'R2 1']);
      expect(line(tester, '22'), ['3', '22', '6', 'R1 2', 'R2 DNC 4']);
    });

    testWidgets('reads the log once, through the core, and needs nothing else', (tester) async {
      await finish(tester, '11');
      core.calls.clear();
      await openResults(tester);
      expect(core.calls, {'count': 1, 'readAll': 1}, reason: "home's count, then the results screen's one read");
    });

    testWidgets('a day with nothing finished says so', (tester) async {
      await gun(tester);
      await openResults(tester);
      expect(find.text('No finishes yet.'), findsOneWidget);
      expect(boatsShown(tester), isEmpty);
    });

    testWidgets('each fleet is scored and shown on its own, under its name', (tester) async {
      final lasers = (await add(tester, FleetEvents.define('Lasers'))).ulid;
      final opti = (await add(tester, FleetEvents.define('Optimists'))).ulid;
      await finish(tester, '11', fleet: lasers);
      await finish(tester, '501', fleet: opti);
      await finish(tester, '22', fleet: lasers);
      await openResults(tester);

      expect(find.text('Lasers'), findsOneWidget);
      expect(find.text('Optimists'), findsOneWidget);
      expect(line(tester, '11'), ['1', '11', '1', 'R1 1']);
      expect(line(tester, '22'), ['2', '22', '2', 'R1 2']);
      expect(line(tester, '501'), ['1', '501', '1', 'R1 1'], reason: "the Lasers' finishes take no place from her");
      expect(find.text('No fleet'), findsNothing, reason: 'nothing was logged without a fleet');
    });

    testWidgets('a fleet\'s name is a heading, so a screen reader can jump between fleets', (tester) async {
      final semantics = tester.ensureSemantics();
      final lasers = (await add(tester, FleetEvents.define('Lasers'))).ulid;
      await finish(tester, '11', fleet: lasers);
      await openResults(tester);
      expect(tester.getSemantics(find.text('Lasers')).getSemanticsData().flagsCollection.isHeader, isTrue);
      semantics.dispose();
    });

    testWidgets('finishes logged before any fleet was named get a section of their own', (tester) async {
      await finish(tester, '7');
      await add(tester, FleetEvents.define('Lasers'));
      await openResults(tester);
      expect(find.text('No fleet'), findsOneWidget);
      expect(line(tester, '7'), ['1', '7', '1', 'R1 1']);
    });

    testWidgets('a core that fails is said so', (tester) async {
      await openResultsWithFailingRead(tester, core, device);
      expect(find.text('The log on this phone could not be read'), findsOneWidget);
    });
  });

  group('a finish with no sail number (owner decision on #7)', () {
    testWidgets('is shown where it finished, and the standings say they are incomplete', (tester) async {
      await finish(tester, '11');
      await finish(tester, null);
      await finish(tester, '33');
      await openResults(tester);

      expect(find.text('1 finish has no sail number, so these standings are incomplete. Name them on the finish screen.'),
          findsOneWidget);
      expect(line(tester, placeholderId(1, 2)), ['2', 'No sail # · race 1, #2', '2', 'R1 2']);
      expect(line(tester, '33'), ['3', '33', '3', 'R1 3'], reason: 'the boat behind it keeps her place');
    });

    testWidgets('says nothing of the sort once every finish is named', (tester) async {
      await finish(tester, '11');
      await openResults(tester);
      expect(find.textContaining('no sail number'), findsNothing);
    });
  });

  testWidgets('a sail number on two finishes in one race is named, and nothing is scored', (tester) async {
    await finish(tester, '11');
    await finish(tester, '11');
    await openResults(tester);
    expect(
      find.text('Sail 11 is on two finishes in race 1. Fix the sail number on the finish screen, or, if a gun was '
          'missed, log it on the sequence screen with the time it really went.'),
      findsOneWidget,
    );
    expect(boatsShown(tester), isEmpty);
  });

  // Owner decision on #7: a missed finish placed between two races is scored
  // in the later one, and the standings say so and name her.
  testWidgets('a missed finish placed between two races is flagged, and so is her line', (tester) async {
    final semantics = tester.ensureSemantics();
    await gun(tester);
    await finish(tester, '11');
    final lastOfRace1 = await finish(tester, '22');
    await gun(tester);
    final firstOfRace2 = await finish(tester, '33');
    final m = await add(tester, FinishEvents.missed(fleet: null, afterUlid: lastOfRace1.ulid, beforeUlid: firstOfRace2.ulid));
    await add(tester, FinishEvents.assignSail(m.ulid, '55'));
    await openResults(tester);

    expect(
      find.text('Sail 55 was placed between race 1 and race 2, so she is scored in race 2. If she finished race 1, '
          'these standings are wrong.'),
      findsOneWidget,
    );
    // Four boats, so DNC = 5. 55 and 11 tie on 6; A8.2 gives it to 55, who won race 2.
    expect(line(tester, '55'), ['1', '55', '6', 'R1 DNC 5', 'R2 1 · between races']);
    expect(tester.getSemantics(standing('55')).label, contains('Race 2, 1, placed between races.'));
    expect(line(tester, '33'), ['3', '33', '7', 'R1 DNC 5', 'R2 2'], reason: 'only her line is flagged');
    semantics.dispose();
  });

  group('the discard count the PRO sets (owner decision on #7)', () {
    Future<void> threeRaces(WidgetTester tester) async {
      for (final order in [
        ['11', '22'],
        ['22', '11'],
        ['22', '11'],
      ]) {
        await gun(tester);
        for (final sail in order) {
          await finish(tester, sail);
        }
      }
    }

    final less = find.byKey(const ValueKey('discards-less-null'));
    final more = find.byKey(const ValueKey('discards-more-null'));

    testWidgets('starts at none, and one tap on + logs a discard and rescores', (tester) async {
      await threeRaces(tester);
      await openResults(tester);
      expect(find.text('No discards'), findsOneWidget);
      expect(line(tester, '11'), ['2', '11', '5', 'R1 1', 'R2 2', 'R3 2']);

      await tester.tap(more);
      await tester.pumpAndSettle();

      final logged = [for (final e in (await tester.runAsync(core.readAll))!) if (e.kind == ResultsKinds.discards) e];
      expect(logged, hasLength(1));
      expect(logged.single.payload, {'fleet': null, 'count': 1});
      expect(device.vibrations, 1, reason: 'a logged change is confirmed like any other');
      expect(find.text('Discards: 1'), findsOneWidget);
      // 11 drops race 2, the earliest of her two 2s.
      expect(line(tester, '11'), ['2', '11', '3', 'R1 1', 'R2 (2)', 'R3 2']);
    });

    testWidgets('cannot go below none, nor discard every race', (tester) async {
      await threeRaces(tester);
      await openResults(tester);
      expect(tester.widget<OutlinedButton>(less).onPressed, isNull);
      await tester.tap(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('Discards: 2'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(more).onPressed, isNull, reason: 'three races leave at most two to discard');
      await tester.tap(less);
      await tester.pumpAndSettle();
      expect(find.text('Discards: 1'), findsOneWidget);
    });

    // The bar check sees only the first screenful, and at 200% text the
    // warning pushes these below it: a 40 dp button there passed the whole-
    // app check (measured by mutation on #7). So they are held here directly.
    for (final scale in [1.0, 2.0]) {
      testWidgets('its buttons hold the ${Bars.minTargetDp.round()} dp bar at ${(scale * 100).round()}% text', (tester) async {
        await finish(tester, null);
        await threeRaces(tester);
        await openResults(tester, textScale: scale);
        await tester.ensureVisible(more);
        await tester.pumpAndSettle();
        for (final button in [less, more]) {
          final size = tester.getSize(button);
          expect(size.width, greaterThanOrEqualTo(Bars.minTargetDp), reason: '$button');
          expect(size.height, greaterThanOrEqualTo(Bars.minTargetDp), reason: '$button');
        }
      });
    }

    // Found by the accessibility pass on #7: without its own node, a fleet's
    // standings were one announcement, the brackets that mark a discard were
    // never spoken, and the stepper's tooltip was read inside the list.
    testWidgets('a screen reader reads each boat as her own line, a discard by name', (tester) async {
      final semantics = tester.ensureSemantics();
      await threeRaces(tester);
      await openResults(tester);
      await tester.tap(more);
      await tester.pumpAndSettle();

      final node = tester.getSemantics(standing('11'));
      expect(node.label, 'Rank 2, sail 11, 3 points. Race 1, 1. Race 2, 2, discarded. Race 3, 2.');
      expect(node.tooltip, isEmpty);
      final section = tester.getSemantics(find.text('Discards: 1'));
      expect(section.label, isNot(contains('sail 11')), reason: 'the boats are not part of the discard line');
      expect(section.tooltip, isEmpty, reason: "the stepper's tooltip is for sight; its buttons carry the label");
      semantics.dispose();
    });

    testWidgets('is not offered with one race, which has nothing to discard', (tester) async {
      await finish(tester, '11');
      await openResults(tester);
      expect(more, findsNothing);
    });

    testWidgets('a count that failed to save says so and changes nothing', (tester) async {
      await threeRaces(tester);
      await openResults(tester);
      core.failWith = const CoreException('failed', 'disk gone');
      await tester.tap(more);
      await tester.pumpAndSettle();
      // Beside the stepper that was tapped, not at the top of the list, where
      // a fleet scrolled into view would never show it.
      expect(
        find.descendant(of: find.byKey(const ValueKey('discards-null')), matching: find.text('Not saved. Tap again.')),
        findsOneWidget,
      );
      expect(find.text('No discards'), findsOneWidget);
      core.failWith = null;
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('Not saved. Tap again.'), findsNothing, reason: 'a save that worked clears it');
    });

    testWidgets('a second tap while the first is still being logged is ignored, not counted from a stale value',
        (tester) async {
      await threeRaces(tester);
      final held = _HeldCore(core);
      setPhoneSize(tester);
      await tester.pumpWidget(ProCompanionApp(core: held, confirmation: ConfirmationService(device)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('RESULTS'));
      await tester.pumpAndSettle();

      held.hold = Completer<void>();
      await tester.tap(more);
      await tester.pump();
      await tester.tap(more);
      await tester.pump();
      held.hold!.complete();
      await tester.pumpAndSettle();

      final logged = [for (final e in (await tester.runAsync(core.readAll))!) if (e.kind == ResultsKinds.discards) e];
      expect([for (final e in logged) e.payload['count']], [1], reason: 'one step logged, not two of the same');
      expect(device.vibrations, 1, reason: 'one confirmation for one step');
      expect(find.text('Discards: 1'), findsOneWidget);
    });
  });

  // Not a race-time route, but reachable from the role home, so every screen
  // reachable from it is held to the bar (as FLEETS is).
  for (final scale in [1.0, 2.0]) {
    testWidgets('the results screen passes the bar-check helper at ${(scale * 100).round()}% text', (tester) async {
      final violations = await barCheck(tester, actionIds: raceTimeActionIds.difference({'fleet-switch'}), (observer) {
        var t = DateTime(2026, 9, 26, 14, 30).millisecondsSinceEpoch;
        final seeded = FakeCore(clock: () => t += 1000);
        var seq = 0;
        EventEnvelope event(String ulid, String kind, Map<String, Object?> payload) => EventEnvelope(
              ulid: ulid,
              deviceTs: t += 1000,
              deviceId: seeded.deviceIdValue,
              seq: ++seq,
              source: 'tap',
              kind: kind,
              payloadVersion: 1,
              payload: payload,
            );
        String id(int n) => '01J8${n.toString().padLeft(22, '0')}';
        // Three races of eight, one finish unnamed: the stepper, the warning
        // and a list longer than the screen all exist.
        var n = 0;
        for (var race = 0; race < 3; race++) {
          seeded.seed([event(id(++n), StartKinds.start, const {'fleet': null})]);
          for (var boat = 0; boat < 8; boat++) {
            final f = id(++n);
            seeded.seed([event(f, FinishKinds.finish, const {'fleet': null})]);
            if (race + boat > 0) {
              seeded.seed([event(id(++n), FinishKinds.sail, {'finish': f, 'sail': '${1000 + (boat * 7 + race) % 8}'})]);
            }
          }
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
      expect(violations, isEmpty);
    });
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
  Future<void> close() => _inner.close();
}

Future<void> openResultsWithFailingRead(WidgetTester tester, FakeCore core, FakeConfirmationDevice device) async {
  setPhoneSize(tester);
  await tester.pumpWidget(ProCompanionApp(core: core, confirmation: ConfirmationService(device)));
  await tester.pumpAndSettle();
  core.failWith = const CoreException('failed', 'disk gone');
  await tester.tap(find.text('RESULTS'));
  await tester.pumpAndSettle();
}
