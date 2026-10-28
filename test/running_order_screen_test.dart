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

/// #68 on the app, driven against the fake core: RUNNING ORDER on a role's
/// home lists each fleet's boats as far round as the mark boats' roundings,
/// pulled down by sync (#64), say they are, reads again while it is open, and
/// names a mark it has heard nothing from as waiting. The rule's half, and
/// the committed vectors, are packages/core/test/running_order_test.dart and
/// running_order_vectors_test.dart.
void main() {
  late _Committee day;

  setUp(() => day = _Committee());

  Widget app(_Committee d, {double scale = 1, List<NavigatorObserver> observers = const []}) =>
      MediaQuery.withClampedTextScaling(
        minScaleFactor: scale,
        maxScaleFactor: scale,
        child: ProCompanionApp(
          core: d.core,
          confirmation: ConfirmationService(FakeConfirmationDevice()),
          navigatorObservers: observers,
          clock: () => d.now,
        ),
      );

  Future<void> openRunningOrder(WidgetTester tester, {_Committee? on}) async {
    setPhoneSize(tester);
    await tester.pumpWidget(app(on ?? day));
    await tester.pumpAndSettle();
    final button = find.text('RUNNING ORDER');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Running order'), findsOneWidget);
  }

  /// The sails listed under [fleet], top to bottom.
  List<String> listed(WidgetTester tester, {String? fleet}) {
    final section = find.byKey(ValueKey('running-${fleet ?? 'none'}'));
    final rows = find.descendant(of: section, matching: find.byWidgetPredicate(
      (w) => w is Semantics && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('running-entry-'),
    ));
    final found = [
      for (final e in rows.evaluate())
        ((e.widget.key! as ValueKey<String>).value.substring('running-entry-'.length), tester.getTopLeft(find.byWidget(e.widget)).dy),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final (sail, _) in found) sail];
  }

  /// Another five seconds: the screen reads the log again.
  Future<void> refresh(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  group("criterion 1: roundings pulled from a mark boat list each fleet's boats in rounding order", () {
    testWidgets("the PRO's RUNNING ORDER: two fleets, each in the order its boats rounded", (tester) async {
      final lasers = day.fleet('Lasers');
      final four20s = day.fleet('420s');
      day.gun(lasers);
      day.gun(four20s);
      day.station(_Committee.mark1, 'mark_1');
      day.round(_Committee.mark1, '412', fleet: lasers);
      day.round(_Committee.mark1, '22', fleet: four20s);
      day.round(_Committee.mark1, '887', fleet: lasers);
      day.round(_Committee.mark1, '1033', fleet: lasers);
      day.round(_Committee.mark1, '7', fleet: four20s);
      await openRunningOrder(tester);

      expect(find.text('Lasers'), findsOneWidget);
      expect(find.text('420s'), findsOneWidget);
      expect(listed(tester, fleet: lasers), ['412', '887', '1033']);
      expect(listed(tester, fleet: four20s), ['22', '7']);
      expect(tester.getTopLeft(find.text('Lasers')).dy, lessThan(tester.getTopLeft(find.text('420s')).dy),
          reason: 'fleets in the order the day defined them');
      final first = tester.getSemantics(find.byKey(const ValueKey('running-entry-412')));
      expect(first.label, startsWith('1, sail 412, last rounded Mark 1 at '));
    });

    testWidgets('a single-fleet day needs no heading, and says when a mark has no roundings at all', (tester) async {
      day.gun(null);
      await openRunningOrder(tester);
      expect(find.text('No roundings yet'), findsOneWidget);
      day.round(_Committee.mark1, '887');
      await refresh(tester);
      expect(listed(tester), ['887']);
      expect(find.text('No roundings yet'), findsNothing);
    });

    testWidgets('a boat level at a gate on unmatched clocks is flagged', (tester) async {
      day.gun(null);
      day.round(_Committee.mark1, '887', mark: 'gate_left');
      day.round(_Committee.mark2, '412', mark: 'gate_right');
      await openRunningOrder(tester);
      expect(listed(tester), ['887', '412']);
      expect(find.text("Level at a gate: in each phone's own clock order"), findsOneWidget);
      expect(tester.getTopLeft(find.textContaining('Level at a gate')).dy,
          greaterThan(tester.getTopLeft(find.byKey(const ValueKey('running-entry-412'))).dy),
          reason: 'below the places it qualifies');
    });

    testWidgets('at 200% text the order itself is on the first screen, under a waiting mark and a gate', (tester) async {
      // A bar check cannot see this: rows of text hold no targets. The
      // emulator showed two notes filling the first screen at 200%.
      day.gun(null);
      day.station(_Committee.mark1, 'gate_left');
      day.station(_Committee.mark2, 'gate_right');
      day.station('01K0MARK3PH0NE000000000003', 'mark_3');
      day.round(_Committee.mark1, '887', mark: 'gate_left');
      day.round(_Committee.mark2, '412', mark: 'gate_right');
      setPhoneSize(tester);
      await tester.pumpWidget(app(day, scale: 2));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('RUNNING ORDER'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('RUNNING ORDER'));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for Mark 3'), findsOneWidget);
      expect(find.byKey(const ValueKey('running-entry-887')).hitTestable(), findsOneWidget);
    });

    testWidgets("the recorder's and the mark boat's homes open it too (owner decision at pickup)", (tester) async {
      for (final role in [Roles.recorder, Roles.markBoat]) {
        final d = _Committee(role: role);
        d.round(_Committee.mark1, '887');
        await openRunningOrder(tester, on: d);
        expect(listed(tester), ['887'], reason: role);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });

  group('criterion 2: a later mark puts the boats that rounded it ahead, once its roundings arrive', () {
    testWidgets('the order moves while the screen is open', (tester) async {
      day.gun(null);
      day.station(_Committee.mark1, 'mark_1');
      day.station(_Committee.mark2, 'mark_2');
      for (final s in ['412', '887', '1033', '5']) {
        day.round(_Committee.mark1, s);
      }
      await openRunningOrder(tester);
      expect(listed(tester), ['412', '887', '1033', '5']);

      day.round(_Committee.mark2, '1033', mark: 'mark_2');
      day.round(_Committee.mark2, '887', mark: 'mark_2');
      await refresh(tester);
      expect(listed(tester), ['1033', '887', '412', '5'], reason: 'the furthest mark each boat has rounded');
      expect(tester.getSemantics(find.byKey(const ValueKey('running-entry-1033'))).label,
          contains('last rounded Mark 2'));
    });
  });

  group('criterion 3: a rounding correction moves the order to the corrected sail number', () {
    testWidgets('a wrong number corrected, and an unidentified boat named', (tester) async {
      day.gun(null);
      final wrong = day.round(_Committee.mark1, '878');
      final unknown = day.round(_Committee.mark1, null);
      day.round(_Committee.mark1, '412');
      await openRunningOrder(tester);
      expect(listed(tester), ['878', '412']);
      expect(find.text('1 rounding not yet named'), findsOneWidget);

      day.add(_Committee.mark1, RoundingKinds.sail, {'sail': '887'}, corrects: wrong.ulid);
      day.add(_Committee.mark1, RoundingKinds.sail, {'sail': '1033'}, corrects: unknown.ulid);
      await refresh(tester);
      expect(listed(tester), ['887', '1033', '412']);
      expect(find.textContaining('not yet named'), findsNothing);
    });
  });

  group('criterion 4: a mark with no roundings synced is named as waiting, not shown as current', () {
    testWidgets('a stationed mark with nothing from it says so, until its roundings arrive', (tester) async {
      day.gun(null);
      day.station(_Committee.mark1, 'mark_1');
      day.station(_Committee.mark2, 'mark_2');
      day.round(_Committee.mark1, '412');
      day.round(_Committee.mark1, '887');
      await openRunningOrder(tester);
      expect(find.text('Waiting for Mark 2'), findsOneWidget, reason: 'and not for Mark 1, which has roundings');
      expect(tester.getTopLeft(find.textContaining('Waiting for Mark 2')).dy,
          lessThan(tester.getTopLeft(find.byKey(const ValueKey('running-entry-412'))).dy),
          reason: 'above the order it qualifies');

      day.round(_Committee.mark2, '887', mark: 'mark_2');
      await refresh(tester);
      expect(find.textContaining('Waiting for'), findsNothing);
      expect(listed(tester), ['887', '412']);
    });
  });

  testWidgets("a fleet's heading, its notes and its count are each their own screen-reader node (the audit)",
      (tester) async {
    final handle = tester.ensureSemantics();
    final lasers = day.fleet('Lasers');
    // A fleet with no roundings: only its heading's own node keeps "No
    // roundings yet" out of it, since every note is a node already (shape 16
    // on the first mutation round: the Lasers heading alone reddened nothing).
    day.fleet('420s');
    day.gun(lasers);
    day.station(_Committee.mark1, 'gate_left');
    day.station(_Committee.mark2, 'gate_right');
    day.station('01K0MARK3PH0NE000000000003', 'mark_3');
    day.round(_Committee.mark1, '887', fleet: lasers, mark: 'gate_left');
    day.round(_Committee.mark2, '412', fleet: lasers, mark: 'gate_right');
    day.round(_Committee.mark2, null, fleet: lasers, mark: 'gate_right');
    await openRunningOrder(tester);
    final heading = tester.getSemantics(find.text('Lasers'));
    expect(heading.label, 'Lasers', reason: 'left to merge, it read every note and line under it');
    expect(heading.getSemanticsData().flagsCollection.isHeader, isTrue);
    await tester.ensureVisible(find.text('420s'));
    await tester.pumpAndSettle();
    expect(tester.getSemantics(find.text('420s')).label, '420s');
    expect(tester.getSemantics(find.text('No roundings yet')).label, isNot(contains('420s')));
    expect(tester.getSemantics(find.text('Waiting for Mark 3')).label, 'Waiting for Mark 3');
    expect(tester.getSemantics(find.text("Level at a gate: in each phone's own clock order")).label,
        "Level at a gate: in each phone's own clock order");
    expect(tester.getSemantics(find.text('1 rounding not yet named')).label, '1 rounding not yet named');
    handle.dispose();
  });

  group('criterion 6: the running order passes the bar-check helper', () {
    // Not a race-time route, but reachable from the role home, so held to the
    // bar: from the PRO's home, whose whole-app check holds every registered
    // action, so the day has a gun and named finishes, as the committee log's
    // check does. With no fleet named, the fleet row cannot exist. On it a
    // waiting mark, unmatched clocks, an unnamed rounding and a list longer
    // than the screen.
    for (final scale in [1.0, 2.0]) {
      testWidgets('from the PRO home at ${(scale * 100).round()}% text', (tester) async {
        final violations = await barCheck(tester, actionIds: proRaceTimeActionIds.difference({'fleet-switch'}),
            (observer) {
          final d = _Committee();
          d.gun(null, own: true);
          for (var boat = 0; boat < 3; boat++) {
            final f = d.add(d.core.deviceIdValue, FinishKinds.finish, const {'fleet': null});
            d.add(d.core.deviceIdValue, FinishKinds.sail, {'finish': f.ulid, 'sail': '${1000 + boat}'});
          }
          d.station(_Committee.mark1, 'gate_left');
          d.station(_Committee.mark2, 'gate_right');
          d.station('01K0MARK3PH0NE000000000003', 'mark_3');
          for (var i = 0; i < 20; i++) {
            d.round(i.isEven ? _Committee.mark1 : _Committee.mark2, '${200 + i}', mark: i.isEven ? 'gate_left' : 'gate_right');
          }
          d.round(_Committee.mark1, null, mark: 'gate_left');
          return app(d, scale: scale, observers: [observer]);
        });
        expect(violations, isEmpty, reason: violations.join('\n'));
      });
    }
  });
}

/// The PRO's phone (or [role]'s), holding what sync pulled down from the
/// committee's mark boats, on a fixed day.
class _Committee {
  _Committee({String role = Roles.overallPro}) {
    core = withRole(FakeCore(clock: () => now += 1000), role);
  }

  static const mark1 = '01K0MARK1PH0NE000000000001';
  static const mark2 = '01K0MARK2PH0NE000000000002';

  late final FakeCore core;

  /// The phone's clock, which the app and the core both read.
  int now = DateTime(2026, 10, 27, 14, 30).millisecondsSinceEpoch;
  int _n = 0;
  final _seqs = <String, int>{};

  EventEnvelope add(String device, String kind, Map<String, Object?> payload, {String? corrects}) {
    final e = EventEnvelope(
      ulid: '01J8${(++_n).toString().padLeft(22, '0')}',
      deviceTs: now += 1000,
      deviceId: device,
      seq: _seqs[device] = (_seqs[device] ?? 0) + 1,
      source: 'tap',
      kind: kind,
      payloadVersion: 1,
      correctsUlid: corrects,
      payload: payload,
    );
    core.seed([e]);
    return e;
  }

  /// A fleet the PRO named on its own phone, by id.
  String fleet(String name) => add(core.deviceIdValue, FleetKinds.defined, {'name': name, 'class': null}).ulid;

  /// [fleet]'s gun, fired by the PRO: on this phone when [own], else pulled
  /// from another PRO phone.
  EventEnvelope gun(String? fleet, {bool own = true}) =>
      add(own ? core.deviceIdValue : '01K0PR0PH0NE00000000000000', StartKinds.start, {'fleet': fleet});

  EventEnvelope station(String device, String mark) => add(device, StationKinds.selected, {'mark': mark});

  /// A rounding pulled down from [device]'s phone.
  EventEnvelope round(String device, String? sail, {String? fleet, String mark = 'mark_1'}) =>
      add(device, RoundingKinds.rounding, {'fleet': fleet, 'sail': sail, 'mark': mark, 'race': null, 'lap': 1});
}
