import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/stations/mark_list_screen.dart';
import 'package:pro_companion/ui/bars.dart';
import 'package:pro_companion/ui/fit_label.dart';
import 'package:pro_companion/ui/sunlight.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';
import 'support/roles.dart';

/// #78 on the app, against the fake core: a PRO on a race area sends a custom
/// mark list, and a mark-boat phone on that race area stations at its marks.
/// The list's rules (ids, superseding, which race area) are
/// packages/core/test/mark_lists_test.dart.
void main() {
  const admission = '00000000-0000-4000-8000-0000000000a1';
  const alpha = RaceArea(id: '00000000-0000-4000-8000-00000000c0a1', name: 'Alpha');
  const bravo = RaceArea(id: '00000000-0000-4000-8000-00000000c0b2', name: 'Bravo');
  const proPhone = '01J8PR0PH0NE00000000000001';
  const pin = CustomMark(id: 'custom_00000000pn', name: 'Pin', colour: MarkColours.orange, shape: MarkShapes.cone);
  const spreader = CustomMark(id: 'custom_00spreader', name: 'Spreader');

  late int now;
  late FakeCore core;
  late FakeConfirmationDevice device;

  final marksButton = find.byKey(const ValueKey('marks'));
  final send = find.byKey(const ValueKey('mark-send'));
  final undo = find.byKey(const ValueKey('mark-undo'));
  final stationStatus = find.byKey(const ValueKey('station-status'));
  Finder station(String id) => find.byKey(ValueKey('station-$id'));

  setUp(() {
    now = DateTime(2026, 11, 5, 10).millisecondsSinceEpoch;
    core = FakeCore(clock: () => now += 1000);
    device = FakeConfirmationDevice();
  });

  FakeCore admitted(FakeCore on, String role, {String? course}) {
    on.seedAdmission(admission);
    on.grants[admission] = (role: role, course: course);
    on.raceAreaList.addAll(const [alpha, bravo]);
    return withRole(on, role);
  }

  var n = 0;

  /// A list another PRO phone sent, pulled down by sync.
  EventEnvelope pulledList(String course, List<CustomMark> marks, {int at = 100}) {
    final e = MarkListEvents.send(course: course, marks: marks);
    return EventEnvelope(
      ulid: '01J8${(++n).toString().padLeft(22, '0')}',
      deviceTs: at,
      deviceId: proPhone,
      seq: n,
      source: e.source,
      kind: e.kind,
      payloadVersion: 1,
      payload: e.payload,
    );
  }

  Widget app({double textScale = 1, CoreClient? on, NavigatorObserver? observer}) => MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: ProCompanionApp(
          core: on ?? core,
          confirmation: ConfirmationService(device),
          navigatorObservers: [?observer],
        ),
      );

  Future<void> openApp(WidgetTester tester) async {
    setPhoneSize(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  /// Brings [f] into the tree and on screen. The editor and the picker are
  /// `ListView(children:)`, which builds lazily: a row scrolled away is not in
  /// the tree at all (#71's join screen met the same).
  Future<void> reveal(WidgetTester tester, Finder f) async {
    final scrollable = find.byType(Scrollable);
    if (f.evaluate().isEmpty && scrollable.evaluate().isNotEmpty) {
      // Back to the top first, then down until it is built.
      await tester.drag(scrollable.first, const Offset(0, 5000));
      await tester.pumpAndSettle();
      if (f.evaluate().isEmpty) await tester.scrollUntilVisible(f, 80, scrollable: scrollable.first);
    }
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await reveal(tester, f);
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  Future<void> addMark(WidgetTester tester, String name, {String? colour, String? shape}) async {
    final field = find.byKey(const ValueKey('mark-name'));
    await reveal(tester, field);
    await tester.enterText(field, name);
    await tester.pumpAndSettle();
    if (colour != null) await tap(tester, find.byKey(ValueKey('mark-colour-$colour')));
    if (shape != null) await tap(tester, find.byKey(ValueKey('mark-shape-$shape')));
    await tap(tester, find.byKey(const ValueKey('mark-add')));
  }

  Future<List<EventEnvelope>> events(WidgetTester tester) async => (await tester.runAsync(core.readAll))!;
  Future<List<EventEnvelope>> lists(WidgetTester tester) async =>
      [for (final e in await events(tester)) if (MarkListKinds.all.contains(e.kind)) e];

  Future<String> text(WidgetTester tester, Finder f) async {
    await reveal(tester, f);
    return (tester.widget(f) as Text).data!;
  }

  Future<bool> enabled(WidgetTester tester, Finder f) async {
    await reveal(tester, f);
    return (tester.widget(f) as ButtonStyleButton).onPressed != null;
  }

  Future<void> seen(WidgetTester tester, Finder f) async {
    await reveal(tester, f);
    expect(f, findsOneWidget);
  }

  /// [f] is in no part of the screen's list: a lazy list leaves a row below
  /// the fold out of the tree, so `findsNothing` at the top alone proves
  /// nothing.
  Future<void> absent(WidgetTester tester, Finder f, {String? reason}) async {
    final scrollable = find.byType(Scrollable);
    for (final dy in [5000.0, -5000.0]) {
      if (scrollable.evaluate().isNotEmpty) {
        await tester.drag(scrollable.first, Offset(0, dy));
        await tester.pumpAndSettle();
      }
      expect(f, findsNothing, reason: reason);
    }
  }

  group('criterion 1: a PRO on a race area sends a list carrying it, with custom ids', () {
    testWidgets('a course PRO names two marks and sends them, once, with one buzz and one tone', (tester) async {
      admitted(core, Roles.coursePro, course: alpha.id);
      await openApp(tester);
      await tap(tester, marksButton);
      await addMark(tester, 'Pin', colour: MarkColours.orange, shape: MarkShapes.cone);
      await addMark(tester, 'Spreader');
      expect(device.vibrations, 0, reason: 'adding to the draft logs nothing');
      await tap(tester, send);
      final sent = await lists(tester);
      expect(sent, hasLength(1));
      expect(sent.single.payload[coursePayloadKey], alpha.id);
      final marks = sent.single.payload['marks'] as List;
      expect([for (final m in marks) ((m as Map)['name'], m['colour'], m['shape'])],
          [('Pin', 'orange', 'cone'), ('Spreader', null, null)]);
      expect([for (final m in marks) isCustomMarkId((m as Map)['id'] as String)], [true, true]);
      expect(device.vibrations, 1);
      expect(device.tones, [BeepStream.notification]);
      expect(await text(tester, find.byKey(const ValueKey('mark-list-status'))), 'Sent: 2 custom marks');
    });

    testWidgets("an overall PRO's MARKS is off until it picks a race area, then the list carries the pick", (tester) async {
      admitted(core, Roles.overallPro);
      await openApp(tester);
      expect(await enabled(tester, marksButton), isFalse);
      await tap(tester, find.byKey(const ValueKey('race-area')));
      await tap(tester, find.byKey(ValueKey('race-area-${bravo.id}')));
      await tap(tester, marksButton);
      await addMark(tester, 'Pin');
      await tap(tester, send);
      expect((await lists(tester)).single.payload[coursePayloadKey], bravo.id);
    });

    testWidgets('a mark that has a standard name is refused, and so is a name twice', (tester) async {
      admitted(core, Roles.coursePro, course: alpha.id);
      await openApp(tester);
      await tap(tester, marksButton);
      await addMark(tester, 'windward');
      await seen(tester, find.text('windward is already a mark'));
      await addMark(tester, 'Pin');
      await addMark(tester, 'pin');
      await seen(tester, find.text('pin is already a mark'));
    });

    testWidgets('a phone never admitted offers no MARKS', (tester) async {
      withRole(core);
      await openApp(tester);
      expect(marksButton, findsNothing);
    });
  });

  group('criterion 2: a mark boat on that race area offers the list, and one elsewhere does not', () {
    testWidgets('on Alpha: the standard set, then PIN; one tap stations there, and the home names it', (tester) async {
      admitted(core, Roles.markBoat, course: alpha.id);
      core.seed([pulledList(alpha.id, [pin, spreader])]);
      await openApp(tester);
      await tap(tester, find.text('STATION'));
      for (final id in StandardMarks.all) {
        await seen(tester, station(id));
      }
      await seen(tester, station(pin.id));
      expect(tester.getTopLeft(station(pin.id)).dy, greaterThan(tester.getTopLeft(station(StandardMarks.offset)).dy),
          reason: 'after the standard set');
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Pin, orange cone'), findsOneWidget, reason: 'its colour and shape are said');
      semantics.dispose();
      await tap(tester, station(pin.id));
      final picked = (await events(tester)).lastWhere((e) => e.kind == StationKinds.selected);
      expect(picked.payload[markPayloadKey], pin.id);
      expect(await text(tester, stationStatus), 'Station: Pin');
    });

    testWidgets('on Bravo: the standard set alone', (tester) async {
      admitted(core, Roles.markBoat, course: bravo.id);
      core.seed([pulledList(alpha.id, [pin])]);
      await openApp(tester);
      await tap(tester, find.text('STATION'));
      await seen(tester, station(StandardMarks.offset));
      await absent(tester, station(pin.id));
    });
  });

  group('criterion 3: with no list, the standard set still works', () {
    testWidgets('a mark boat that has pulled nothing stations at a standard mark', (tester) async {
      admitted(core, Roles.markBoat, course: alpha.id);
      await openApp(tester);
      await tap(tester, find.text('STATION'));
      await absent(
          tester,
          find.byWidgetPredicate(
              (w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('station-custom_')));
      await tap(tester, station(StandardMarks.windward));
      expect(await text(tester, stationStatus), 'Station: Windward');
    });

    testWidgets('a phone never admitted offers the standard set and reads no lists', (tester) async {
      withRole(core, Roles.markBoat);
      core.seed([pulledList(alpha.id, [pin])]);
      await openApp(tester);
      await tap(tester, find.text('STATION'));
      await seen(tester, station(StandardMarks.offset));
      await absent(tester, station(pin.id));
    });
  });

  group('criterion 4: a superseding list keeps earlier ids valid and readable', () {
    testWidgets('a boat stationed at a mark the new list dropped still reads it by name', (tester) async {
      admitted(core, Roles.markBoat, course: alpha.id);
      core.seed([pulledList(alpha.id, [pin], at: 100), pulledList(alpha.id, [spreader], at: 200)]);
      await openApp(tester);
      await tap(tester, find.text('STATION'));
      await seen(tester, station(spreader.id));
      await absent(tester, station(pin.id), reason: 'superseded');
      // Stationed at Pin under the first list: still valid and named.
      await tester.runAsync(() => core.append(StationEvents.select(pin.id)));
      await tap(tester, find.byTooltip('Back'));
      await tester.pumpWidget(const SizedBox.shrink());
      await openApp(tester);
      expect(await text(tester, stationStatus), 'Station: Pin');
      await tap(tester, find.text('STATION'));
      expect(find.text('Station · Pin'), findsOneWidget);
    });

    testWidgets('the editor opens on the list in force, and a mark left as it was keeps its id', (tester) async {
      admitted(core, Roles.coursePro, course: alpha.id);
      core.seed([pulledList(alpha.id, [pin])]);
      await openApp(tester);
      await tap(tester, marksButton);
      await seen(tester, find.byKey(ValueKey('mark-row-${pin.id}')));
      expect(await enabled(tester, send), isFalse, reason: 'nothing changed yet');
      await addMark(tester, 'Spreader');
      await tap(tester, send);
      final mine = (await lists(tester)).where((e) => e.deviceId == core.deviceIdValue).single;
      final ids = [for (final m in mine.payload['marks'] as List) (m as Map)['id']];
      expect(ids.first, pin.id);
      expect(ids, hasLength(2));
    });
  });

  group('criterion 5: the editor and the picker pass the bar, and Undo needs no confirm', () {
    testWidgets('UNDO LIST appends a correction at once, with one buzz and one tone, and no dialog', (tester) async {
      admitted(core, Roles.coursePro, course: alpha.id);
      final sent = pulledList(alpha.id, [pin]);
      core.seed([sent]);
      await openApp(tester);
      await tap(tester, marksButton);
      await tap(tester, undo);
      expect(find.byType(Dialog), findsNothing);
      final last = (await lists(tester)).last;
      expect((last.kind, last.correctsUlid), (MarkListKinds.undo, sent.ulid));
      expect(device.vibrations, 1);
      expect(device.tones, [BeepStream.notification]);
      expect(await enabled(tester, undo), isFalse);
      await absent(tester, find.byKey(ValueKey('mark-row-${pin.id}')), reason: 'back to no list');
    });

    for (final scale in [1.0, 2.0]) {
      final pct = '${(scale * 100).round()}%';
      testWidgets('the editor, with a list in force, two taps deep, at $pct text', (tester) async {
        FakeCore fixture() => admitted(FakeCore(), Roles.coursePro, course: alpha.id)..seed([pulledList(alpha.id, [pin])]);
        Widget build(NavigatorObserver observer) => MediaQuery.withClampedTextScaling(
              minScaleFactor: scale,
              maxScaleFactor: scale,
              child: MaterialApp(
                theme: sunlightTheme(),
                navigatorObservers: [observer],
                home: _UnderMarks(core: fixture(), confirmation: ConfirmationService(device), course: alpha.id),
              ),
            );
        final violations = await barCheck(tester, build, actionIds: const {});
        expect(violations, isEmpty, reason: violations.join('\n'));
        // The premise, in the app the check explored: the editor holds the list.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(build(NavigatorObserver()));
        await tester.pumpAndSettle();
        await tap(tester, find.byKey(const ValueKey('open-marks')));
        await seen(tester, find.byKey(ValueKey('mark-row-${pin.id}')));
      });

      testWidgets('the mark boat home and its picker, with a list, at $pct text', (tester) async {
        Widget build(NavigatorObserver observer) => app(
            textScale: scale,
            on: admitted(FakeCore(), Roles.markBoat, course: alpha.id)..seed([pulledList(alpha.id, [pin, spreader])]),
            observer: observer);
        final violations = await barCheck(tester, build, actionIds: const {'station', 'station-undo'});
        expect(violations, isEmpty, reason: violations.join('\n'));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(build(NavigatorObserver()));
        await tester.pumpAndSettle();
        await tap(tester, find.text('STATION'));
        await seen(tester, station(pin.id));
      });
    }
  });
}

/// One button that pushes the editor, so the bar check's Back has a screen to
/// return to (join_test.dart's stand-in, #71).
class _UnderMarks extends StatelessWidget {
  const _UnderMarks({required this.core, required this.confirmation, required this.course});

  final CoreClient core;
  final ConfirmationService confirmation;
  final String course;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Bars.screenGutterDp),
            child: Center(
              child: SizedBox(
                width: double.infinity,
                height: Bars.minTargetDp + 8,
                child: OutlinedButton(
                  key: const ValueKey('open-marks'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<Object?>(
                    builder: (_) => MarkListScreen(core: core, confirmation: confirmation, course: course),
                  )),
                  child: const FitLabel('MARKS'),
                ),
              ),
            ),
          ),
        ),
      );
}
