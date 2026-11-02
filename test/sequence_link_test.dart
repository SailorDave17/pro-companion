import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/fleets/fleet_picker_screen.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/sequence/link_banner.dart';
import 'package:pro_companion/ui/clock.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';
import 'support/race_timer.dart';
import 'support/roles.dart';

/// #33 on the sequence card, black box through the app and the fake core:
/// what race-timer sent reaches the card by itself, a sequence on the wrong
/// fleet is moved in two taps, and the banner says when the link is quiet
/// while every manual control stays where it was. The core's half is
/// packages/core/test/link_test.dart, the buzz test/core_host_test.dart.
void main() {
  late int now;
  late FakeCore core;
  late FakeConfirmationDevice device;
  late _Popups popups;

  const quiet = Duration(minutes: 10);
  const notLogged = 'Not logged. Tap again.';

  final banner = find.byKey(const ValueKey('link-banner'));
  final card = find.byKey(const ValueKey('start-card'));
  final gunButton = find.widgetWithText(FilledButton, 'GUN');
  final postponeButton = find.widgetWithText(OutlinedButton, 'POSTPONE');
  final recallButton = find.widgetWithText(OutlinedButton, 'GENERAL RECALL');
  final save = find.byKey(const ValueKey('keypad-save'));
  final takeBackRow = find.byKey(const ValueKey('pick-take-back'));
  final fixTimeRow = find.byKey(const ValueKey('pick-fix-time'));

  setUp(() {
    now = DateTime(2026, 11, 1, 14).millisecondsSinceEpoch;
    core = withRole(FakeCore(clock: () => now));
    device = FakeConfirmationDevice();
    popups = _Popups();
  });

  Widget app({double textScale = 1}) => MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: ProCompanionApp(
          core: core,
          confirmation: ConfirmationService(device),
          navigatorObservers: [popups],
          clock: () => now,
        ),
      );

  /// The narrowest phone the bar is held on, with a status bar.
  void setSmallPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(960, 1920);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 72);
    addTearDown(tester.view.reset);
  }

  Future<void> openSequence(WidgetTester tester, {double textScale = 1, bool small = false}) async {
    small ? setSmallPhone(tester) : setPhoneSize(tester);
    await tester.pumpWidget(app(textScale: textScale));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SEQUENCE'));
    await tester.pumpAndSettle();
    expect(gunButton, findsOneWidget);
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  /// The next read of the log: the screen's own timer, by the time it passes.
  Future<void> poll(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  /// race-timer reaches the core host, with this screen open or not. It is
  /// received now, and it fired [ago] before that.
  Future<void> deliver(
    WidgetTester tester,
    String kind,
    String id, {
    Duration ago = const Duration(milliseconds: 11),
    int? receivedMs,
    String sequence = 'seq-1',
    Map<String, Object?> fields = const {},
  }) async {
    final text = linkEvent(kind, id: id, atMs: now - ago.inMilliseconds, sequence: sequence, fields: fields);
    final answer = (await tester.runAsync(() => core.receiveLink(text, receivedMs: receivedMs ?? now)))!;
    expect(answer.status, LinkContract.accepted);
  }

  Future<List<EventEnvelope>> events(WidgetTester tester) async =>
      [for (final e in (await tester.runAsync(core.readAll))!) if (e.ulid != seededRolePick) e];

  /// What race-timer logged that still stands, of [fleet].
  Future<List<EventEnvelope>> standing(WidgetTester tester, String? fleet) async {
    final all = await events(tester);
    final undone = {for (final e in all) if (e.kind == StartKinds.undo) e.correctsUlid};
    return [for (final e in all) if (e.source == raceTimerSource && fleetOf(e) == fleet && !undone.contains(e.ulid)) e];
  }

  Future<List<String>> defineFleets(WidgetTester tester, List<String> names) async => [
        for (final n in names) (await tester.runAsync(() => core.append(FleetEvents.define(n))))!.ulid,
      ];

  Future<void> selectFleet(WidgetTester tester, String fleet) async {
    await tester.runAsync(() => core.append(FleetEvents.select(fleet)));
  }

  Finder pick(String fleet) => find.byKey(ValueKey('pick-$fleet'));

  /// A sequence that landed on [fleet], read onto the card.
  Future<void> sequenceOn(WidgetTester tester, {bool gun = true}) async {
    await deliver(tester, LinkContract.sequenceStart, 'evt-1', fields: {'sequence_name': '5-4-1-0'});
    await deliver(tester, LinkContract.signal, 'evt-2', fields: {'signal': 'warning'});
    if (gun) await deliver(tester, LinkContract.start, 'evt-3');
    await poll(tester);
  }

  group('what race-timer sent reaches the card by itself', () {
    testWidgets('an event received with the card open updates card and UNDO on the next read', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      expect(find.text('NO GUN'), findsOneWidget);
      expect(find.text('UNDO SEQUENCE (Lasers)'), findsNothing);

      await deliver(tester, LinkContract.sequenceStart, 'evt-1', fields: {'sequence_name': '5-4-1-0'});
      await deliver(tester, LinkContract.signal, 'evt-2', ago: Duration.zero, fields: {'signal': 'warning'});
      expect(find.text('NO GUN'), findsOneWidget, reason: 'the core tells no screen: the read does it');
      await poll(tester);

      expect(find.text('NO GUN'), findsNothing);
      expect(find.text('SEQUENCE 5-4-1-0'), findsOneWidget);
      expect(find.text('race-timer · warning · ${clockText(now)}'), findsOneWidget);
      expect(find.text('UNDO SEQUENCE (Lasers)'), findsOneWidget);
    });

    testWidgets('a sequence before its gun on a day with no fleets still shows on the card', (tester) async {
      await openSequence(tester);
      await sequenceOn(tester, gun: false);
      expect(find.text('SEQUENCE 5-4-1-0'), findsOneWidget);
      expect(find.text('Nothing to undo'), findsOneWidget, reason: 'with no fleets, UNDO stays event by event');
    });

    testWidgets('a read brings nothing twice: a boat logged over counts once, however often it is read', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester);
      final gun = (await events(tester)).lastWhere((e) => e.kind == StartKinds.start);
      await tester.runAsync(() => core.append(StartEvents.ocs(gun.ulid, fleet: ids[0], sail: '7')));

      await poll(tester);
      await poll(tester);

      expect(find.widgetWithText(OutlinedButton, 'OCS · 1'), findsOneWidget);
    });

    testWidgets('a polled event fires no vibration and no tone: the core host already did', (tester) async {
      await openSequence(tester);
      await sequenceOn(tester);
      expect(find.textContaining(RegExp('^GUN ')), findsOneWidget, reason: 'the event did reach the screen');
      expect(device.vibrations, 0);
      expect(device.tones, isEmpty);
    });

    testWidgets("a failed read shows no 'Not logged', and the next good one catches up", (tester) async {
      await openSequence(tester);
      await deliver(tester, LinkContract.start, 'evt-1');
      core.failWith = const CoreException('refused', 'the store said no');
      await poll(tester);
      expect(find.text(notLogged), findsNothing);
      expect(find.text('NO GUN'), findsOneWidget, reason: 'the card stays as it was');

      core.failWith = null;
      await poll(tester);
      expect(find.text('NO GUN'), findsNothing);
    });

    testWidgets('a good read does not clear a real append failure', (tester) async {
      await openSequence(tester);
      core.failWith = const CoreException('refused', 'the store said no');
      await tap(tester, gunButton);
      expect(find.text(notLogged), findsOneWidget);

      core.failWith = null;
      await poll(tester);
      expect(find.text(notLogged), findsOneWidget, reason: 'that tap still did not land');

      await tap(tester, gunButton);
      expect(find.text(notLogged), findsNothing);
    });

    testWidgets('what arrived behind the picker is read the moment the card is back on top', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester, gun: false);
      await tap(tester, find.text('UNDO SEQUENCE (Lasers)'));
      await deliver(tester, LinkContract.start, 'evt-3', ago: Duration.zero);
      await tap(tester, find.byTooltip('Back'));
      expect(find.text('GUN ${clockText(now)}'), findsOneWidget);
    });
  });

  group('a race-timer gun on the card and the keypad', () {
    testWidgets('it says race-timer and never tapped', (tester) async {
      await openSequence(tester);
      await deliver(tester, LinkContract.start, 'evt-1', ago: const Duration(milliseconds: 40));
      await poll(tester);
      final fired = now - 40;

      expect(find.text('GUN ${clockText(fired)}'), findsOneWidget);
      expect(find.text('race-timer · tap to fix the time'), findsOneWidget);
      expect(find.textContaining('tapped'), findsNothing);

      await tap(tester, card);
      expect(find.text('Fix gun · race-timer ${clockText(fired)}'), findsOneWidget);
      expect(find.textContaining('tapped'), findsNothing);
    });

    testWidgets('with its time typed over, each still says race-timer and keeps its time', (tester) async {
      await openSequence(tester);
      await deliver(tester, LinkContract.start, 'evt-1', ago: const Duration(seconds: 1));
      await poll(tester);
      final fired = now - 1000;
      await tap(tester, card);
      for (final d in '135940'.split('')) {
        await tester.tap(find.byKey(ValueKey('key-$d')));
        await tester.pump();
      }
      await tap(tester, save);

      expect(find.text('GUN 13:59:40'), findsOneWidget);
      expect(find.text('race-timer ${clockText(fired)} · tap to fix the time'), findsOneWidget);
      expect(find.textContaining('tapped'), findsNothing);

      await tap(tester, card);
      expect(find.text('Fix gun 13:59:40 · race-timer ${clockText(fired)}'), findsOneWidget);
      expect(find.textContaining('tapped'), findsNothing);
    });

    testWidgets('received 2 s or more late, it says when; just under, it does not', (tester) async {
      await openSequence(tester);
      await deliver(tester, LinkContract.start, 'evt-1', ago: const Duration(milliseconds: 1999));
      await poll(tester);
      expect(find.textContaining('received'), findsNothing);

      now += 60000;
      await deliver(tester, LinkContract.start, 'evt-2', ago: const Duration(seconds: 2));
      await poll(tester);
      expect(find.text('race-timer · received ${clockText(now)} · tap to fix the time'), findsOneWidget);
    });

    testWidgets('a polled gun shuts an open keypad: the gun it was fixing no longer anchors', (tester) async {
      await openSequence(tester);
      await tap(tester, gunButton);
      await tap(tester, card);
      expect(save, findsOneWidget);

      now += 60000;
      await deliver(tester, LinkContract.start, 'evt-1', ago: Duration.zero);
      await poll(tester);

      expect(save, findsNothing);
      expect(find.text('GUN ${clockText(now)}'), findsOneWidget);
      expect(device.vibrations, 1, reason: "the manual gun's own, and none for the polled one");
    });
  });

  group('criterion 4: a wrong attribution is corrected in at most 2 taps, with no confirm dialog', () {
    for (final names in [
      ['Lasers', '420s'],
      ['Lasers', '420s', 'Optis', 'Sunfish', 'Finns'],
    ]) {
      testWidgets('UNDO then a fleet, with ${names.length} fleets', (tester) async {
        final ids = await defineFleets(tester, names);
        await selectFleet(tester, ids[0]);
        await openSequence(tester);
        await sequenceOn(tester);
        final right = ids.last;
        final count = (await events(tester)).length;

        // Tap 1.
        await tap(tester, find.text('UNDO SEQUENCE (Lasers)'));
        expect(find.text('Right fleet'), findsOneWidget);
        expect(await events(tester), hasLength(count), reason: 'the first tap writes nothing');
        expect(device.vibrations, 0);
        expect(pick(right).hitTestable(), findsOneWidget, reason: 'the last fleet is on screen, no scroll first');

        // Tap 2.
        await tap(tester, pick(right));
        expect(find.text('Right fleet'), findsNothing);
        expect(await standing(tester, ids[0]), isEmpty);
        expect((await standing(tester, right)).map((e) => e.kind),
            [StartKinds.sequenceStart, StartKinds.signal, StartKinds.start]);

        expect(popups.opened, isEmpty, reason: 'no popup route on the way');
        expect(find.byType(AlertDialog), findsNothing);
        expect([device.vibrations, device.tones.length], [1, 1], reason: 'one confirmation for the one commit');
        expect(find.text('Sequence · ${names.last}'), findsOneWidget, reason: 'the phone moved with it');
        expect(find.textContaining(RegExp('^GUN ')), findsOneWidget, reason: 'and the card shows the moved sequence');
      });
    }

    testWidgets('before the gun too, when a PRO most needs it', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester, gun: false);
      await tap(tester, find.text('UNDO SEQUENCE (Lasers)'));
      await tap(tester, pick(ids[1]));
      expect((await standing(tester, ids[1])), hasLength(2));
      expect(find.text('SEQUENCE 5-4-1-0'), findsOneWidget);
    });

    testWidgets('it shows the fleet it is on as now, and offers to take it back', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester);
      await tap(tester, find.text('UNDO SEQUENCE (Lasers)'));
      expect(find.text('Lasers · now'), findsOneWidget);
      expect(takeBackRow.hitTestable(), findsOneWidget);
    });

    testWidgets('Back logs nothing', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester);
      final before = (await events(tester)).length;

      await tap(tester, find.text('UNDO SEQUENCE (Lasers)'));
      await tap(tester, find.byTooltip('Back'));

      expect(await events(tester), hasLength(before));
      expect(device.vibrations, 0);
      expect(find.text('UNDO SEQUENCE (Lasers)'), findsOneWidget);
    });

    testWidgets('picking the fleet it is on logs nothing', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester);
      final before = (await events(tester)).length;

      await tap(tester, find.text('UNDO SEQUENCE (Lasers)'));
      await tap(tester, pick(ids[0]));

      expect(await events(tester), hasLength(before));
      expect(device.vibrations, 0);
      expect(find.text('Sequence · Lasers'), findsOneWidget);
    });

    testWidgets('take-back removes it, and the card goes back to no gun', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester);

      await tap(tester, find.text('UNDO SEQUENCE (Lasers)'));
      await tap(tester, takeBackRow);

      expect(await standing(tester, ids[0]), isEmpty);
      expect(find.text('NO GUN'), findsOneWidget);
      expect(find.text('Sequence · Lasers'), findsOneWidget, reason: 'the phone stays where it was');
      expect([device.vibrations, device.tones.length], [1, 1]);
    });

    testWidgets('no fleets means no picker: UNDO takes back one event, and the rest stands', (tester) async {
      await openSequence(tester);
      await sequenceOn(tester);
      expect(find.text('UNDO SEQUENCE'), findsNothing);
      final gun = (await events(tester)).singleWhere((e) => e.kind == StartKinds.start);

      await tap(tester, find.textContaining('UNDO GUN'));

      expect(find.text('Right fleet'), findsNothing);
      final undos = [for (final e in await events(tester)) if (e.kind == StartKinds.undo) e.correctsUlid];
      expect(undos, [gun.ulid]);
      expect(await standing(tester, null), hasLength(2));
    });

    testWidgets('fleets but none selected: the picker opens for a sequence on no fleet', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await openSequence(tester);
      await sequenceOn(tester);
      await tap(tester, find.text('UNDO SEQUENCE'));
      await tap(tester, pick(ids[1]));
      expect(await standing(tester, null), isEmpty);
      expect(await standing(tester, ids[1]), hasLength(3));
    });

    testWidgets("a PRO's own OCS boat is undone before the sequence", (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester);
      final gun = (await events(tester)).singleWhere((e) => e.kind == StartKinds.start);
      await tester.runAsync(() => core.append(StartEvents.ocs(gun.ulid, fleet: ids[0], sail: '77')));
      await poll(tester);
      expect(find.text('UNDO OCS (77)'), findsOneWidget);
      expect(find.text('UNDO SEQUENCE (Lasers)'), findsNothing);
    });

    testWidgets('a signal that arrives behind the picker moves too: the core works it out at the pick', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester, gun: false);
      await tap(tester, find.text('UNDO SEQUENCE (Lasers)'));
      await deliver(tester, LinkContract.signal, 'evt-3', fields: {'signal': 'one_minute'});
      await tap(tester, pick(ids[1]));
      expect(await standing(tester, ids[0]), isEmpty);
      expect(await standing(tester, ids[1]), hasLength(3));
    });

    testWidgets("a fix that fails says 'Not logged' and fires nothing", (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester);
      await tap(tester, find.text('UNDO SEQUENCE (Lasers)'));
      core.failWith = const CoreException('refused', 'the store said no');
      await tap(tester, pick(ids[1]));
      expect(find.text(notLogged), findsOneWidget);
      expect(device.vibrations, 0);
    });

    // UNDO reaches the sequence only while nothing was tapped after it, so the
    // card is the fix that is always 2 taps (owner decision at #33's review).
    testWidgets('the card then a fleet, after the gun and two OCS boats, and the boats move with it', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester);
      final gun = (await events(tester)).singleWhere((e) => e.kind == StartKinds.start);
      for (final sail in ['77', '81']) {
        await tester.runAsync(() => core.append(StartEvents.ocs(gun.ulid, fleet: ids[0], sail: sail)));
      }
      await poll(tester);
      expect(find.text('UNDO OCS (81)'), findsOneWidget, reason: 'UNDO still takes back one tap at a time');
      expect(find.text('race-timer · fix fleet or time'), findsOneWidget);
      final count = (await events(tester)).length;

      // Tap 1.
      await tap(tester, card);
      expect(find.text('Right fleet'), findsOneWidget);
      expect(await events(tester), hasLength(count), reason: 'the first tap writes nothing');
      expect(device.vibrations, 0);

      // Tap 2.
      await tap(tester, pick(ids[1]));
      expect(await standing(tester, ids[0]), isEmpty);
      expect(await standing(tester, ids[1]), hasLength(3));
      final all = await events(tester);
      final undone = {for (final e in all) if (e.kind == StartKinds.undo) e.correctsUlid};
      final over = [
        for (final e in all)
          if (e.kind == StartKinds.ocs && !undone.contains(e.ulid)) (fleetOf(e), e.payload['sail']),
      ];
      expect(over, [(ids[1], '77'), (ids[1], '81')], reason: 'the boats over moved with their gun');
      expect(popups.opened, isEmpty);
      expect([device.vibrations, device.tones.length], [1, 1]);
      expect(find.text('Sequence · 420s'), findsOneWidget);
      expect(find.text('OCS · 2'), findsOneWidget);
    });

    testWidgets('before the gun, the card opens the fleets too, with no time to fix', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester, gun: false);
      await tap(tester, card);
      expect(fixTimeRow, findsNothing);
      await tap(tester, pick(ids[1]));
      expect(await standing(tester, ids[1]), hasLength(2));
      expect(find.text('SEQUENCE 5-4-1-0'), findsOneWidget);
    });

    testWidgets("race-timer's gun time is fixed from the card's picker, which writes nothing", (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await deliver(tester, LinkContract.start, 'evt-1', ago: const Duration(seconds: 1));
      await poll(tester);
      final fired = now - 1000;
      final count = (await events(tester)).length;

      await tap(tester, card);
      await tap(tester, fixTimeRow);
      expect(find.text('Fix gun · race-timer ${clockText(fired)}'), findsOneWidget);
      expect(await events(tester), hasLength(count));
      expect(device.vibrations, 0);
      expect(find.text('Sequence · Lasers'), findsOneWidget);
    });

    testWidgets("after race-timer's general recall, its card opens the fleets too", (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await deliver(tester, LinkContract.sequenceStart, 'evt-1');
      await deliver(tester, LinkContract.start, 'evt-2');
      await deliver(tester, LinkContract.generalRecall, 'evt-3', ago: Duration.zero);
      await poll(tester);
      expect(find.text('at ${clockText(now)} · waiting for the next gun'), findsOneWidget);
      await tap(tester, card);
      expect(fixTimeRow, findsNothing, reason: 'no gun anchors after a recall');
      await tap(tester, pick(ids[1]));
      expect(await standing(tester, ids[1]), hasLength(3));
      expect(find.descendant(of: card, matching: find.text('GENERAL RECALL')), findsOneWidget);
    });

    testWidgets("a manual gun's card still opens the keypad in one tap on a day with fleets", (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await tap(tester, gunButton);
      expect(find.text('tap to fix the time'), findsOneWidget);
      await tap(tester, card);
      expect(save, findsOneWidget);
      expect(find.text('Right fleet'), findsNothing);
    });
  });

  group('a backlog race-timer resent out of order', () {
    Future<void> at(WidgetTester tester, String kind, String id, int minutesAgo, String sequence,
            [Map<String, Object?> f = const {}]) =>
        deliver(tester, kind, id, ago: Duration(minutes: minutesAgo), sequence: sequence, fields: f);

    /// Two races on one fleet, resent once the host was back: race 1's gun
    /// and its one-minute signal arrive after race 2's gun.
    Future<void> twoRacesOutOfOrder(WidgetTester tester) async {
      await at(tester, LinkContract.sequenceStart, 'evt-1', 9, 'seq-1');
      await at(tester, LinkContract.sequenceStart, 'evt-4', 4, 'seq-2');
      await at(tester, LinkContract.signal, 'evt-5', 2, 'seq-2', {'signal': 'one_minute'});
      await at(tester, LinkContract.start, 'evt-6', 1, 'seq-2');
      await at(tester, LinkContract.start, 'evt-3', 7, 'seq-1');
      await at(tester, LinkContract.signal, 'evt-2', 8, 'seq-1', {'signal': 'one_minute'});
      await poll(tester);
    }

    testWidgets("race 1's gun resent during race 2's countdown does not end it", (tester) async {
      await openSequence(tester);
      await at(tester, LinkContract.sequenceStart, 'evt-1', 9, 'seq-1');
      await at(tester, LinkContract.sequenceStart, 'evt-4', 4, 'seq-2', {'sequence_name': '3-2-1-0'});
      await at(tester, LinkContract.signal, 'evt-5', 2, 'seq-2', {'signal': 'preparatory'});
      await at(tester, LinkContract.start, 'evt-3', 7, 'seq-1');
      await poll(tester);
      expect(find.text('SEQUENCE 3-2-1-0'), findsOneWidget);
      final recall = find.widgetWithText(OutlinedButton, 'INDIVIDUAL RECALL');
      expect(tester.widget<ButtonStyleButton>(recall).onPressed, isNull);
    });

    testWidgets("the card stays on race 2's gun, and its controls stay live", (tester) async {
      await openSequence(tester);
      await twoRacesOutOfOrder(tester);
      expect(find.text('GUN ${clockText(now - 60000)}'), findsOneWidget);
      expect(find.textContaining('SEQUENCE'), findsNothing);
      final recall = find.widgetWithText(OutlinedButton, 'INDIVIDUAL RECALL');
      expect(tester.widget<ButtonStyleButton>(recall).onPressed, isNotNull);
    });

    testWidgets('UNDO moves race 2, the last to fire, not race 1, the last to arrive', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await twoRacesOutOfOrder(tester);
      await tap(tester, find.text('UNDO SEQUENCE (Lasers)'));
      await tap(tester, pick(ids[1]));
      expect({for (final e in await standing(tester, ids[1])) e.payload[linkSequenceKey]}, {'seq-2'});
      expect(await standing(tester, ids[0]), hasLength(3), reason: 'race 1 stays where it was');
    });
  });

  group('criterion 9: the banner says the link is not active, and the manual controls stay one tap away', () {
    testWidgets('it shows on a card race-timer has not reached', (tester) async {
      await openSequence(tester);
      expect(banner, findsOneWidget);
      expect(find.text(LinkBanner.text), findsOneWidget);
    });

    testWidgets('it hides at 9:59 and returns at 10:00 with the screen open', (tester) async {
      await openSequence(tester);
      final at = now;
      await deliver(tester, LinkContract.signal, 'evt-1');
      await poll(tester);
      expect(banner, findsNothing);

      now = at + const Duration(minutes: 9, seconds: 59).inMilliseconds;
      await poll(tester);
      expect(banner, findsNothing);

      now = at + quiet.inMilliseconds;
      await poll(tester);
      expect(banner, findsOneWidget);
    });

    // Nothing on a day with no fleets can undo a signal, so a countdown
    // race-timer abandoned would otherwise hold the card for good, and race
    // 1's recall, OCS and time fix with it (#33's review).
    testWidgets('a countdown race-timer stopped sending is over when the link goes quiet', (tester) async {
      await openSequence(tester);
      await sequenceOn(tester);
      final at = now;
      await deliver(tester, LinkContract.sequenceStart, 'evt-4', sequence: 'seq-2', fields: {'sequence_name': '3-2-1-0'});
      await deliver(tester, LinkContract.signal, 'evt-5', sequence: 'seq-2', fields: {'signal': 'warning'});
      await poll(tester);
      final recall = find.widgetWithText(OutlinedButton, 'INDIVIDUAL RECALL');
      expect(find.text('SEQUENCE 3-2-1-0'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(recall).onPressed, isNull);

      now = at + const Duration(minutes: 9, seconds: 59).inMilliseconds;
      await poll(tester);
      expect(find.text('SEQUENCE 3-2-1-0'), findsOneWidget, reason: 'race-timer may still send its next signal');

      now = at + quiet.inMilliseconds;
      await poll(tester);
      expect(banner, findsOneWidget);
      expect(find.text('SEQUENCE 3-2-1-0'), findsNothing);
      expect(find.text('GUN ${clockText(at - 11)}'), findsOneWidget, reason: "race 1's gun anchors again");
      expect(tester.widget<ButtonStyleButton>(recall).onPressed, isNotNull);
      expect(tester.widget<ButtonStyleButton>(find.widgetWithText(OutlinedButton, 'OCS')).onPressed, isNotNull);
    });

    testWidgets('it goes by when the event reached the phone, not when the core was free to store it', (tester) async {
      await openSequence(tester);
      final told = now;
      now += quiet.inMilliseconds;
      await deliver(tester, LinkContract.signal, 'evt-1', receivedMs: told);
      await poll(tester);
      expect(banner, findsOneWidget);
    });

    testWidgets('opened with a sequence under way, it is down from the first read', (tester) async {
      await deliver(tester, LinkContract.signal, 'evt-1');
      await openSequence(tester);
      expect(banner, findsNothing);
    });

    testWidgets('an event undone still counts: the link reached the phone', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester);
      await tap(tester, find.text('UNDO SEQUENCE (Lasers)'));
      await tap(tester, takeBackRow);
      expect(banner, findsNothing);
    });

    testWidgets('it stays out of the keypad, which keeps its room', (tester) async {
      await openSequence(tester);
      await tap(tester, gunButton);
      await tap(tester, card);
      expect(save, findsOneWidget);
      expect(banner, findsNothing);
    });

    for (final small in [false, true]) {
      final phone = small ? '320 x 640' : '411 x 891';

      testWidgets('every manual control is enabled and tappable under it, on $phone', (tester) async {
        final ids = await defineFleets(tester, ['Lasers', '420s']);
        await selectFleet(tester, ids[0]);
        await openSequence(tester, small: small);
        expect(banner, findsOneWidget);

        for (final button in [gunButton, postponeButton, recallButton]) {
          expect(button.hitTestable(), findsOneWidget);
          expect(tester.widget<ButtonStyleButton>(button).onPressed, isNotNull);
        }
        await tap(tester, postponeButton);
        await tap(tester, recallButton);
        await tap(tester, gunButton);
        // The banner is what the last read said, so read again after the taps:
        // without it this could not tell a tap from the link (#33's review).
        await poll(tester);
        expect(banner, findsOneWidget, reason: 'a tap is not the link');
        expect(
            (await events(tester)).where((e) => StartKinds.sequence.contains(e.kind)).map((e) => (e.kind, e.source)), [
          (StartKinds.postponement, 'manual'),
          (StartKinds.generalRecall, 'manual'),
          (StartKinds.start, 'manual'),
        ]);
      });

      for (final scale in [1.0, 2.0]) {
        testWidgets('no row moves when it flips, on $phone at ${(scale * 100).round()}% text', (tester) async {
          final ids = await defineFleets(tester, ['Lasers', '420s']);
          await selectFleet(tester, ids[0]);
          await openSequence(tester, textScale: scale, small: small);
          expect(banner, findsOneWidget);
          final rows = [
            postponeButton,
            recallButton,
            find.widgetWithText(OutlinedButton, 'INDIVIDUAL RECALL'),
            find.widgetWithText(OutlinedButton, 'OCS'),
            gunButton,
          ];
          final rects = [for (final row in rows) tester.getRect(row)];
          final top = tester.getRect(banner).top;
          final bottom = tester.getRect(card).bottom;

          void expectNothingMoved() {
            for (var i = 0; i < rows.length; i++) {
              expect(tester.getRect(rows[i]).topLeft - rects[i].topLeft, within(distance: 0.01, from: Offset.zero));
              expect(tester.getSize(rows[i]), rects[i].size);
            }
            expect(tester.getRect(card).bottom, moreOrLessEquals(bottom, epsilon: 0.01));
          }

          await deliver(tester, LinkContract.signal, 'evt-1');
          await poll(tester);
          expect(banner, findsNothing);
          expectNothingMoved();
          expect(tester.getRect(card).top, moreOrLessEquals(top, epsilon: 0.01), reason: 'the card takes the room back');

          now += quiet.inMilliseconds;
          await poll(tester);
          expect(banner, findsOneWidget);
          expectNothingMoved();
        });
      }
    }
  });

  group('a read that failed', () {
    testWidgets('a failed first read recovers by itself, and the card and the banner come back', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await deliver(tester, LinkContract.sequenceStart, 'evt-1', fields: {'sequence_name': '5-4-1-0'});
      setPhoneSize(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      core.failWith = const CoreException('failed', 'the core stopped answering');
      await tap(tester, find.text('SEQUENCE'));
      expect(find.text(notLogged), findsOneWidget);

      core.failWith = null;
      await poll(tester);

      expect(find.text(notLogged), findsNothing);
      expect(find.text('SEQUENCE 5-4-1-0'), findsOneWidget);
      expect(banner, findsNothing);
    });

    testWidgets('a read that throws something else is swallowed too', (tester) async {
      final throwing = _ThrowsOnRead(clock: () => now);
      core = withRole(throwing);
      await openSequence(tester);

      throwing.failing = true;
      await poll(tester);

      expect(tester.takeException(), isNull);
      expect(find.text(notLogged), findsNothing);
    });
  });

  group('a later race on a fleet with a gun already standing', () {
    testWidgets('the card shows the countdown, not the last race\'s gun, and nothing fixes that gun', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester);
      expect(find.textContaining('GUN '), findsOneWidget);

      await deliver(tester, LinkContract.sequenceStart, 'evt-4', sequence: 'seq-2', fields: {'sequence_name': '3-2-1-0'});
      await deliver(tester, LinkContract.signal, 'evt-5', sequence: 'seq-2', fields: {'signal': 'preparatory'});
      await poll(tester);

      expect(find.text('SEQUENCE 3-2-1-0'), findsOneWidget);
      expect(find.textContaining('preparatory'), findsOneWidget);
      expect(find.textContaining('GUN '), findsNothing);
      await tap(tester, card);
      expect(save, findsNothing, reason: "the race's gun is still to come, so there is none to fix");
      expect(fixTimeRow, findsNothing, reason: 'the card opens the fleets, and offers no gun to fix');
      expect(takeBackRow, findsOneWidget);
      await tap(tester, find.byTooltip('Back'));
      final recall = find.widgetWithText(OutlinedButton, 'INDIVIDUAL RECALL');
      final ocs = find.widgetWithText(OutlinedButton, 'OCS');
      expect(tester.widget<ButtonStyleButton>(recall).onPressed, isNull, reason: 'nor one to recall');
      expect(tester.widget<ButtonStyleButton>(ocs).onPressed, isNull, reason: 'nor a boat to log over it');

      await deliver(tester, LinkContract.start, 'evt-6', sequence: 'seq-2');
      await poll(tester);
      expect(find.text('SEQUENCE 3-2-1-0'), findsNothing);
      expect(find.textContaining('GUN '), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(recall).onPressed, isNotNull, reason: 'its own gun is here now');
      expect(tester.widget<ButtonStyleButton>(ocs).onPressed, isNotNull);
    });

    testWidgets('its own signal after its gun does not put the countdown back', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester);

      await deliver(tester, LinkContract.signal, 'evt-4', fields: {'signal': 'clear'});
      await poll(tester);

      expect(find.textContaining('GUN '), findsOneWidget);
    });
  });

  group('the fix after the phone has moved on', () {
    testWidgets('on the wrong fleet: its row, UNDO, then the right fleet', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s', 'Optis']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester);
      await tap(tester, find.widgetWithText(OutlinedButton, '420s'));
      expect(find.text('UNDO SEQUENCE (420s)'), findsNothing, reason: 'nothing of it is on 420s');

      await tap(tester, find.widgetWithText(OutlinedButton, 'Lasers'));
      await tap(tester, find.text('UNDO SEQUENCE (Lasers)'));
      await tap(tester, pick(ids[2]));

      expect(await standing(tester, ids[0]), isEmpty);
      expect(await standing(tester, ids[2]), hasLength(3));
    });

    testWidgets('a fleet with no sequence still offers UNDO SWITCH', (tester) async {
      final ids = await defineFleets(tester, ['Lasers', '420s']);
      await selectFleet(tester, ids[0]);
      await openSequence(tester);
      await sequenceOn(tester);

      await tap(tester, find.widgetWithText(OutlinedButton, '420s'));

      expect(find.text('UNDO SWITCH (420s)'), findsOneWidget);
    });
  });

  group('the bar-check fixture', () {
    testWidgets('raceTimerDay reaches the right-fleet picker in two taps of the role home', (tester) async {
      core = raceTimerDay(now: now);
      await openSequence(tester);
      expect(banner, findsNothing);
      await tap(tester, find.text('UNDO SEQUENCE (Lasers)'));
      expect(find.text('Right fleet'), findsOneWidget);
      expect(find.byType(FleetPickerScreen), findsOneWidget);
    });

    testWidgets('and with the link down, the banner is up', (tester) async {
      core = raceTimerDay(now: now, linkUp: false);
      await openSequence(tester);
      expect(banner, findsOneWidget);
    });
  });
}

/// Throws what no core failure is: a stored event this version cannot decode
/// would surface like this, outside the error path a CoreException takes.
class _ThrowsOnRead extends FakeCore {
  _ThrowsOnRead({super.clock});

  bool failing = false;

  @override
  Future<List<EventEnvelope>> readOwn() async {
    if (failing) throw const FormatException('not an event');
    return super.readOwn();
  }
}

class _Popups extends NavigatorObserver {
  final opened = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) opened.add(route);
  }
}
