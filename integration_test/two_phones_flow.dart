import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_companion/core_bootstrap.dart';
import 'package:pro_companion/core_host.dart' show SyncConfig;
import 'package:pro_companion/main.dart' as app;
import 'package:pro_companion_core/core.dart';

import 'sync_flow.dart' show pumpUntil, say, tapKey, typeInto, waitFor;

/// #113 criterion 9 (#68 criterion 1 and #54's fleet half end to end): two committee phones on two
/// emulators, each running sync in its own core host against the local stack, with nothing fake
/// between them. One is the PRO, with two fleets and a gun for each; the other a mark boat,
/// stationed at windward. The mark boat's rounding screen offers the PRO's fleets, pulled down by
/// sync, and the boats it taps reach the PRO's RUNNING ORDER under those fleets.
///
/// Not named *_test.dart: integration_test/two_phones.sh runs it on both phones at once, as
/// TWO_PHONES_ROLE=pro on one and TWO_PHONES_ROLE=mark on the other, with the race day's codes.
const role = String.fromEnvironment('TWO_PHONES_ROLE');
const code = String.fromEnvironment('TWO_PHONES_CODE');

/// The PRO's two fleets, by name, and a boat of each the mark boat logs.
const fleetBoats = {'Lasers': '887', '420s': '5'};

/// Joins this fresh phone with the race day's code, and opens its role's home.
Future<void> join(WidgetTester tester) async {
  await app.main();
  await tester.pump(const Duration(seconds: 2));
  await tapKey(tester, 'join-with-code');
  await typeInto(tester, 'join-code', code);
  await tapKey(tester, 'join');
  await pumpUntil(tester, find.byKey(const ValueKey('open-home')),
      within: const Duration(seconds: 30), reason: 'the code admitted the phone');
  await tapKey(tester, 'open-home');
}

/// The fleet ids another phone defined, by name, as this phone's core holds them.
Future<Map<String, String>> othersFleets(CoreClient core) async {
  final own = await core.deviceId();
  return {
    for (final e in await core.readAll())
      if (e.kind == FleetKinds.defined && e.deviceId != own) e.payload['name'] as String: e.ulid,
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('two phones, no fake core between them: the PRO\'s fleets reach the mark boat, and its roundings '
      'reach the PRO\'s running order', (tester) async {
    expect(SyncConfig.compiled, isNotNull, reason: 'built without the defines file: run two_phones.sh');
    expect(['pro', 'mark'], contains(role), reason: 'run two_phones.sh');
    await join(tester);
    final core = await startCore();

    if (role == 'pro') {
      await pumpUntil(tester, find.text('SEQUENCE'), within: const Duration(seconds: 10), reason: "the PRO's home");
      final fleets = <String, String>{};
      for (final name in fleetBoats.keys) {
        fleets[name] = (await core.append(FleetEvents.define(name))).ulid;
        await core.append(StartEvents.start(fleet: fleets[name], source: 'tap'));
      }
      say('PRO_READY ${fleets.length} fleets, a gun each');

      // Below the fold on a 320 x 640 phone: a tap without the scroll misses (measured).
      await tester.ensureVisible(find.text('RUNNING ORDER'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('RUNNING ORDER'));
      // The screen draws a section for each fleet the day defines, roundings or none.
      await pumpUntil(tester, find.byKey(ValueKey('running-${fleets['Lasers']}')),
          within: const Duration(seconds: 10), reason: 'RUNNING ORDER opened, with the Lasers section');
      // Each boat the mark boat taps, under the PRO's own fleet.
      for (final MapEntry(key: name, value: sail) in fleetBoats.entries) {
        await pumpUntil(
            tester,
            find.descendant(
                of: find.byKey(ValueKey('running-${fleets[name]}')),
                matching: find.byKey(ValueKey('running-entry-$sail'))),
            // The mark boat's build starts once this phone is ready (two_phones.sh).
            within: const Duration(minutes: 8),
            reason: "the mark boat's $sail under the PRO's $name");
      }
      say('PRO_SAW both boats under their fleets');
      return;
    }

    // The mark boat: stationed at windward, then the PRO's fleets, pulled down by sync.
    await pumpUntil(tester, find.text('STATION'), within: const Duration(seconds: 10), reason: "the mark boat's home");
    await tester.ensureVisible(find.text('STATION'));
    await tester.tap(find.text('STATION'));
    await tester.pump(const Duration(milliseconds: 500));
    await tapKey(tester, 'station-${StandardMarks.windward}');
    await pumpUntil(tester, find.byKey(const ValueKey('roundings')),
        within: const Duration(seconds: 10), reason: "the mark boat's home");
    final pulled = await () async {
      late Map<String, String> found;
      await waitFor(tester, () async => (found = await othersFleets(core)).length == fleetBoats.length,
          within: const Duration(minutes: 2), reason: "the PRO's fleets pulled down");
      return found;
    }();
    say('MARK_PULLED ${pulled.keys.join(', ')}');

    await tapKey(tester, 'roundings');
    for (final MapEntry(key: name, value: sail) in fleetBoats.entries) {
      // The screen offers the PRO's fleet, by the PRO's own id.
      await tapKey(tester, 'rounding-fleet-${pulled[name]}');
      await tapKey(tester, 'rounding-type');
      for (final d in sail.split('')) {
        await tapKey(tester, 'key-$d');
      }
      await tapKey(tester, 'keypad-save');
      await waitFor(
          tester,
          () async => (await core.readOwn())
              .any((e) => e.kind == RoundingKinds.rounding && e.payload['sail'] == sail && e.payload['fleet'] == pulled[name]),
          within: const Duration(seconds: 10),
          reason: "$sail logged under the PRO's $name");
    }
    say('MARK_TAPPED');
    // Until the PRO has seen them: this phone's run ends here, and its engine with it.
    await waitFor(tester, () async => (await core.uploadStatus()).pending == 0,
        within: const Duration(seconds: 60), reason: 'the roundings uploaded');
    await tester.pump(const Duration(seconds: 90));
  });
}
