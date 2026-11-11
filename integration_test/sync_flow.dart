import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_companion/core_bootstrap.dart';
import 'package:pro_companion/core_host.dart' show SyncConfig;
import 'package:pro_companion/main.dart' as app;
import 'package:pro_companion_core/core.dart';

/// #113 on a phone: the app's own core host runs sync, against the local stack, with no fake core
/// anywhere between sync and the screens. Criteria 4 (signal cut and restored), 5's device half
/// (SEND LINK mails a link, opening it signs the phone in, the role code admits it), 7 (#53's
/// revoked banner end to end) and 8 (#66's shore row end to end).
///
/// Not named *_test.dart, so a plain `flutter test integration_test` never runs it: it needs the
/// host to read the mailed link, cut and restore the path to the stack, and revoke the phone.
/// integration_test/sync_flow.sh drives it, and the two talk by the `SYNC_FLOW` lines this prints.
///
/// The cut is the host's, not airplane mode: the phone reaches the stack at its own 127.0.0.1
/// through adb's reverse forward, which airplane mode leaves up. The script removes the forward and
/// pauses the stack's gateway, since sync's keep-alive connection outlives the forward alone
/// (measured: every "cut" event uploaded). Its controls are this phone's own connect to the
/// stack's port, refused while cut and accepted once restored, and the host's request to the
/// gateway, unanswered while cut.
const email = String.fromEnvironment('SYNC_FLOW_EMAIL');
const code = String.fromEnvironment('SYNC_FLOW_CODE');
const raceDay = String.fromEnvironment('SYNC_FLOW_EVENT');
const stackPort = int.fromEnvironment('SYNC_FLOW_PORT', defaultValue: 54421);

void say(String line) {
  // ignore: avoid_print
  print('SYNC_FLOW $line');
}

/// Whether this phone can open a connection to the stack's API right now.
Future<bool> stackReachable() async {
  try {
    final socket = await Socket.connect('127.0.0.1', stackPort, timeout: const Duration(seconds: 2));
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  } on TimeoutException {
    return false;
  }
}

/// Pumps until [finder] finds something, or fails after [within]. The app's timers (the shore row's
/// clock among them) never let it settle, so this pumps in steps rather than settling.
Future<void> pumpUntil(WidgetTester tester, Finder finder, {required Duration within, String? reason}) async {
  final deadline = DateTime.now().add(within);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('${reason ?? finder.describeMatch(Plurality.zero)} within $within (shore row: ${rowText()})');
    }
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// Waits, off the widget tree, until [condition] holds, or fails after [within].
Future<Duration> waitFor(WidgetTester tester, Future<bool> Function() condition,
    {required Duration within, required String reason}) async {
  final started = DateTime.now();
  while (!await condition()) {
    if (DateTime.now().difference(started) > within) fail('$reason within $within');
    await tester.pump(const Duration(milliseconds: 250));
  }
  return DateTime.now().difference(started);
}

/// Scrolls [key]'s widget into view and taps it: the role picker and the screens run past the fold
/// on a 320 x 640 phone.
Future<void> tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await pumpUntil(tester, target, within: const Duration(seconds: 15), reason: '$key on screen');
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 300));
}

/// Waits for [key]'s field, then types [text] into it.
Future<void> typeInto(WidgetTester tester, String key, String text) async {
  final field = find.byKey(ValueKey(key));
  await pumpUntil(tester, field, within: const Duration(seconds: 15), reason: '$key on screen');
  await tester.enterText(field, text);
  await tester.pump(const Duration(milliseconds: 300));
}

/// Every text the shore row draws now, and whether its route is the current one, for a failure's
/// message.
String rowText() {
  final row = find.byKey(const ValueKey('shore-row'), skipOffstage: false).evaluate();
  final route = row.isEmpty ? null : ModalRoute.of(row.first);
  final texts = find
      .descendant(of: find.byKey(const ValueKey('shore-row')), matching: find.byType(Text))
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .join(' | ');
  return '$texts; route ${route?.settings.name ?? route.runtimeType} current ${route?.isCurrent}';
}

Finder onShoreRow(String text) =>
    find.descendant(of: find.byKey(const ValueKey('shore-row')), matching: find.textContaining(text));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a fresh phone signs in by the mailed link, joins, syncs on its own, catches up after a cut, '
      'and is told when it is revoked', (tester) async {
    // The premises: this build names a project, the host gave this run its inputs, and the stack is
    // reachable before anything is cut. Without the last, the cut below would prove nothing.
    expect(SyncConfig.compiled, isNotNull, reason: 'built without sync.defines.json: run sync_flow.sh');
    expect([email, code, raceDay].every((v) => v.isNotEmpty), isTrue, reason: 'run sync_flow.sh');
    expect(await stackReachable(), isTrue, reason: 'the control: the stack is reachable before the cut');

    await app.main();
    await tester.pump(const Duration(seconds: 2));
    await pumpUntil(tester, find.byKey(const ValueKey('sign-in-by-email')),
        within: const Duration(seconds: 30), reason: 'a fresh phone opens on the role picker');

    // Criterion 5: SEND LINK mails a link. The host reads it and opens it on this phone.
    await tapKey(tester, 'sign-in-by-email');
    await typeInto(tester, 'sign-in-email', email);
    await tapKey(tester, 'send-link');
    await pumpUntil(tester, find.byKey(const ValueKey('link-sent')),
        within: const Duration(seconds: 20), reason: 'SEND LINK said the link was sent');
    expect(find.textContaining('no server'), findsNothing);
    say('LINK_SENT');
    await pumpUntil(tester, find.byKey(const ValueKey('signed-in-as')),
        within: const Duration(seconds: 90), reason: 'the link the host opened signed the phone in');
    expect(find.text(email), findsOneWidget);

    // The role's code admits this phone under the volunteer's account, through the host's join.
    await tapKey(tester, 'enter-role-code');
    await typeInto(tester, 'join-code', code);
    await tapKey(tester, 'join');
    await pumpUntil(tester, find.byKey(const ValueKey('open-home')),
        within: const Duration(seconds: 30), reason: 'the code admitted the phone');
    expect(find.textContaining('no server'), findsNothing);
    await tapKey(tester, 'open-home');
    await pumpUntil(tester, find.text('SEQUENCE'), within: const Duration(seconds: 10), reason: "the PRO's home");
    say('ADMITTED');

    // Sync runs on its own: the role pick reaches shore with nothing here asking.
    await pumpUntil(tester, onShoreRow('All on shore'),
        within: const Duration(seconds: 30), reason: 'the role pick uploaded on its own');

    // Criterion 4: the host cuts the path to the stack, and this phone sees it cut.
    say('CUT_NOW');
    await waitFor(tester, () async => !await stackReachable(),
        within: const Duration(seconds: 60), reason: 'the control: the cut cut the path to the stack');
    say('CUT_SEEN');

    // Events wait while cut. Criterion 8: the row shows the count waiting, then offline with the age
    // of the last sync, once a run has failed for want of the server.
    final core = await startCore();
    final before = (await core.uploadStatus()).pending;
    for (var i = 0; i < 3; i++) {
      await core.append(NewEvent(kind: 'note', source: 'tap', payload: {'text': 'cut $i'}));
    }
    final waiting = (await core.uploadStatus()).pending;
    say('WAITING $waiting (was $before)');
    expect(waiting, before + 3, reason: 'the three taps wait while cut');
    await pumpUntil(tester, onShoreRow('$waiting waiting'),
        within: const Duration(seconds: 15), reason: 'the row counts $waiting waiting');
    await pumpUntil(tester, onShoreRow('Offline'), within: const Duration(seconds: 40), reason: 'the row says offline');
    expect(onShoreRow('last sync'), findsOneWidget, reason: 'offline, with the age of the last sync: ${rowText()}');
    expect((await core.uploadStatus()).pending, waiting, reason: 'nothing went up while cut');

    // The host restores the path. The upload starts on its own within 30 s of the stack coming back.
    say('RESTORE_NOW');
    await waitFor(tester, stackReachable,
        within: const Duration(seconds: 60), reason: 'the control: the restore reopened the path');
    say('RESTORED');
    final took = await waitFor(tester, () async => (await core.uploadStatus()).pending == 0,
        within: const Duration(seconds: 30), reason: 'the waiting events went up on their own');
    say('UPLOADED after ${took.inMilliseconds} ms');
    await pumpUntil(tester, onShoreRow('All on shore'), within: const Duration(seconds: 10), reason: 'the row says all on shore');

    // Criterion 7: the host revokes this phone. Its next append is refused for revocation, and the
    // banner comes up naming the race day. Taps go on until it does, since only the refusal tells.
    say('REVOKE_NOW');
    final revokedBy = DateTime.now().add(const Duration(seconds: 90));
    var taps = 0;
    while (find.byKey(const ValueKey('revoked-banner')).evaluate().isEmpty) {
      if (DateTime.now().isAfter(revokedBy)) fail('no revoked banner within 90 s of $taps taps');
      await core.append(NewEvent(kind: 'note', source: 'tap', payload: {'text': 'after revoke $taps'}));
      taps++;
      await tester.pump(const Duration(seconds: 2));
    }
    expect(find.descendant(of: find.byKey(const ValueKey('revoked-banner')), matching: find.textContaining(raceDay)),
        findsOneWidget, reason: 'the banner names the race day');
    say('REVOKED_SEEN after $taps taps');
  });
}
