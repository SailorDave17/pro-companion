import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/ui/race_time.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';
import 'support/roles.dart';

/// #76 on the app, against the fake core: fleets two phones each named "Lasers" on one race area
/// are one fleet in the views that read every phone (the running order, the rounding grid), and a
/// name another race area also has is marked on FLEETS and in the running order, never merged. The
/// rule is packages/core/test/fleet_merge_test.dart; the cross-phone timing, race_times_test.dart.
void main() {
  const admission = '00000000-0000-4000-8000-0000000000a1';
  const alpha = RaceArea(id: '00000000-0000-4000-8000-00000000c0a1', name: 'Alpha');
  const bravo = RaceArea(id: '00000000-0000-4000-8000-00000000c0b2', name: 'Bravo');
  const otherPhone = '01K0MARK1PH0NE000000000001';

  late int now;
  var n = 0;
  final seqs = <String, int>{};

  setUp(() {
    now = DateTime(2026, 11, 5, 14, 30).millisecondsSinceEpoch;
    n = 0;
    seqs.clear();
  });

  /// [device]'s event, as this phone holds it: its own, or pulled down by sync.
  EventEnvelope seeded(FakeCore core, String device, String kind, Map<String, Object?> payload) {
    final e = EventEnvelope(
      ulid: '01J8${(++n).toString().padLeft(22, '0')}',
      deviceTs: now += 1000,
      deviceId: device,
      seq: seqs[device] = (seqs[device] ?? 0) + 1,
      source: 'tap',
      kind: kind,
      payloadVersion: 1,
      payload: payload,
    );
    core.seed([e]);
    return e;
  }

  String define(FakeCore core, String device, String name, {RaceArea? on}) =>
      seeded(core, device, FleetKinds.defined, {'name': name, 'class': null, coursePayloadKey: ?on?.id}).ulid;

  /// A recorder bound to [on]'s race area, with the race day's race areas kept.
  FakeCore recorder(RaceArea on) {
    final core = FakeCore(clock: () => now += 1000);
    core.seedAdmission(admission);
    core.grants[admission] = (role: Roles.recorder, course: on.id);
    core.raceAreaList.addAll(const [alpha, bravo]);
    return withRole(core, Roles.recorder);
  }

  Widget app(FakeCore core, {double scale = 1, NavigatorObserver? observer}) => MediaQuery.withClampedTextScaling(
        minScaleFactor: scale,
        maxScaleFactor: scale,
        child: ProCompanionApp(
          core: core,
          confirmation: ConfirmationService(FakeConfirmationDevice()),
          navigatorObservers: [?observer],
          clock: () => now,
        ),
      );

  Future<void> open(WidgetTester tester, FakeCore core, String button, {double scale = 1}) async {
    setPhoneSize(tester);
    await tester.pumpWidget(app(core, scale: scale));
    await tester.pumpAndSettle();
    final f = find.text(button);
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  group('criterion 4 on FLEETS: a name another race area also has is marked, by that race area', () {
    for (final scale in [1.0, 2.0]) {
      testWidgets('a recorder on Alpha, whose Lasers Bravo also has, at ${(scale * 100).round()}% text',
          (tester) async {
        final core = recorder(alpha);
        final mine = define(core, core.deviceIdValue, 'Lasers', on: alpha);
        define(core, otherPhone, 'Lasers', on: bravo);
        await open(tester, core, 'FLEETS', scale: scale);
        final note = find.byKey(ValueKey('fleet-conflict-$mine'));
        expect(note, findsOneWidget);
        expect((tester.widget(note) as Text).data, 'Bravo also has a fleet named Lasers');
        expect(find.textContaining('Lasers'), findsNWidgets(2), reason: "the other phone's fleet is not listed (#64)");
        expect(clippedLabels(tester), isEmpty);
      });
    }

    testWidgets('the same name on the same race area is one fleet, and nothing is marked', (tester) async {
      final core = recorder(alpha);
      define(core, core.deviceIdValue, 'Lasers', on: alpha);
      define(core, otherPhone, 'Lasers', on: alpha);
      await open(tester, core, 'FLEETS');
      expect(find.byWidgetPredicate((w) => '${w.key}'.contains('fleet-conflict')), findsNothing);
    });

    testWidgets('with no race areas kept, the other race area is still named as one', (tester) async {
      final core = recorder(alpha)..raceAreaList.clear();
      final mine = define(core, core.deviceIdValue, 'Lasers', on: alpha);
      define(core, otherPhone, 'Lasers', on: bravo);
      await open(tester, core, 'FLEETS');
      expect((tester.widget(find.byKey(ValueKey('fleet-conflict-$mine'))) as Text).data,
          'Another race area also has a fleet named Lasers');
    });
  });

  group('criterion 2 on the committee views: two phones\' Lasers are one fleet', () {
    testWidgets('RUNNING ORDER lists one Lasers, with both phones\' roundings in it', (tester) async {
      final core = withRole(FakeCore(clock: () => now += 1000), Roles.overallPro);
      final mine = define(core, core.deviceIdValue, 'Lasers');
      final theirs = define(core, otherPhone, 'Lasers');
      final gun = seeded(core, core.deviceIdValue, StartKinds.start, {'fleet': mine});
      seeded(core, otherPhone, StationKinds.selected, {'mark': 'mark_1'});
      for (final (sail, fleet) in [('412', theirs), ('887', mine)]) {
        seeded(core, otherPhone, RoundingKinds.rounding,
            {'fleet': fleet, 'sail': sail, 'mark': 'mark_1', 'race': gun.ulid, 'lap': 1});
      }
      await open(tester, core, 'RUNNING ORDER');
      expect(find.byKey(ValueKey('running-$mine')), findsOneWidget);
      expect(find.byKey(ValueKey('running-$theirs')), findsNothing, reason: 'no second Lasers section');
      expect(find.text('Lasers'), findsOneWidget);
      expect(find.byKey(const ValueKey('running-entry-412')), findsOneWidget);
      expect(find.byKey(const ValueKey('running-entry-887')), findsOneWidget);
    });

    testWidgets('a mark boat\'s rounding grid offers one Lasers, and a boat tapped there names it', (tester) async {
      final core = withRole(FakeCore(clock: () => now += 1000), Roles.markBoat);
      await tester.runAsync(() => core.append(StationEvents.select(StandardMarks.windward)));
      define(core, '01K0PR0PH0NE00000000000000', 'Lasers');
      define(core, '01K0PR0PH0NE00000000000002', 'Lasers');
      define(core, '01K0PR0PH0NE00000000000002', 'Optimists');
      await open(tester, core, 'ROUNDINGS');
      expect(find.text('Lasers'), findsOneWidget, reason: 'one Lasers on the fleet row');
      expect(find.text('Optimists'), findsOneWidget);
    });
  });

  group('criterion 4 in the running order: a name on two race areas is two fleets, each marked', () {
    for (final scale in [1.0, 2.0]) {
      testWidgets('each headed with its race area, at ${(scale * 100).round()}% text', (tester) async {
        // An event-wide PRO, admitted, keeping the race day's race areas.
        final core = FakeCore(clock: () => now += 1000);
        core.seedAdmission(admission);
        core.grants[admission] = (role: Roles.overallPro, course: null);
        core.raceAreaList.addAll(const [alpha, bravo]);
        withRole(core, Roles.overallPro);
        final mine = define(core, core.deviceIdValue, 'Lasers', on: alpha);
        final theirs = define(core, otherPhone, 'Lasers', on: bravo);
        await open(tester, core, 'RUNNING ORDER', scale: scale);
        expect(find.byKey(ValueKey('running-$mine')), findsOneWidget);
        expect(find.text('Lasers · Alpha'), findsOneWidget, reason: 'two identical headings read as one fleet twice');
        expect(find.text('Bravo also has a fleet named Lasers'), findsOneWidget);
        await tester.scrollUntilVisible(find.byKey(ValueKey('running-$theirs')), 80,
            scrollable: find.byType(Scrollable).first);
        expect(find.text('Lasers · Bravo', skipOffstage: false), findsOneWidget);
        expect(find.text('Alpha also has a fleet named Lasers', skipOffstage: false), findsOneWidget);
        expect(find.byKey(const ValueKey('fleet-conflict'), skipOffstage: false), findsNWidgets(2));
        expect(clippedLabels(tester), isEmpty);
      });
    }

    testWidgets('with no race areas kept, the heading is the name and the note says another race area',
        (tester) async {
      final core = withRole(FakeCore(clock: () => now += 1000), Roles.overallPro);
      define(core, core.deviceIdValue, 'Lasers', on: alpha);
      define(core, otherPhone, 'Lasers', on: bravo);
      await open(tester, core, 'RUNNING ORDER');
      expect(find.text('Lasers'), findsNWidgets(2));
      expect(find.text('Another race area also has a fleet named Lasers', skipOffstage: false), findsNWidgets(2));
    });
  });

  group('the bar, from the PRO home with a name on two race areas', () {
    for (final scale in [1.0, 2.0]) {
      testWidgets('at ${(scale * 100).round()}% text', (tester) async {
        final violations = await barCheck(tester, actionIds: proRaceTimeActionIds.difference({'fleet-switch'}),
            (observer) {
          final core = withRole(FakeCore(clock: () => now += 1000), Roles.overallPro);
          define(core, otherPhone, 'Lasers', on: alpha);
          define(core, '01K0PR0PH0NE00000000000002', 'Lasers', on: bravo);
          seeded(core, core.deviceIdValue, StartKinds.start, {'fleet': null});
          // Finishes with sail numbers, so a finish's own corrections are there to reach (as the
          // running order's whole-app check seeds them).
          for (var boat = 0; boat < 3; boat++) {
            final f = seeded(core, core.deviceIdValue, FinishKinds.finish, const {'fleet': null});
            seeded(core, core.deviceIdValue, FinishKinds.sail, {'finish': f.ulid, 'sail': '${1000 + boat}'});
          }
          return app(core, scale: scale, observer: observer);
        });
        expect(violations, isEmpty, reason: violations.join('\n'));
      });
    }
  });
}
