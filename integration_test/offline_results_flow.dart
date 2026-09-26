import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion_core/host.dart';

import '../test/support/network_tripwire.dart';
import '../test/support/race_day_flow.dart';

/// #7 criterion 2 on a device: a whole race day through to provisional
/// results on the real core, with the phone in airplane mode and the network
/// tripwire armed on HTTP clients and sockets. The host half
/// is test/results_offline_test.dart.
///
/// Not named *_test.dart, so a plain `flutter test integration_test` never
/// runs it: it needs airplane mode, which only the host can turn on.
/// integration_test/offline_results.sh drives it twice:
///
///   EXPECT_NETWORK=true   airplane mode off: the probe alone, which must
///                         connect. Without this, a phone with no network at
///                         all would pass the next run for the wrong reason.
///   (unset)               airplane mode on: the probe must fail to connect,
///                         then the race day runs with the tripwire armed.
const expectNetwork = bool.fromEnvironment('EXPECT_NETWORK');

/// Tries one connection out, and says what happened.
Future<String> probe() async {
  try {
    final s = await Socket.connect('1.1.1.1', 443, timeout: const Duration(seconds: 5));
    s.destroy();
    return 'connected';
  } on SocketException catch (e) {
    return 'SocketException: ${e.osError?.message ?? e.message}';
  } on TimeoutException {
    return 'timed out';
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (expectNetwork) {
    testWidgets('control: with airplane mode off, the probe connects', (tester) async {
      final seen = await probe();
      // ignore: avoid_print
      print('OFFLINE_RESULTS_CONTROL $seen');
      expect(seen, 'connected', reason: 'this phone has no network, so airplane mode would prove nothing');
    });
    return;
  }

  testWidgets('a race day through to provisional results, in airplane mode, reaches for no network', (tester) async {
    // The premise first: nothing on this phone can reach the network. A
    // connect that succeeds means the script's airplane mode did not hold.
    final seen = await probe();
    // ignore: avoid_print
    print('OFFLINE_RESULTS_PROBE $seen');
    expect(seen, isNot('connected'), reason: 'the network is up: run this through integration_test/offline_results.sh');

    final wire = NetworkTripwire()..arm();
    addTearDown(wire.disarm);

    // A log of its own, so the day's results are this run's alone: the app's
    // real log keeps every other test's finishes.
    final dir = await (await getTemporaryDirectory()).createTemp('offline_results_');
    final core = await spawnCore('${dir.path}${Platform.pathSeparator}core.db');
    addTearDown(core.close);

    await tester.pumpWidget(ProCompanionApp(
      core: core,
      confirmation: ConfirmationService(const PlatformConfirmationDevice()),
    ));
    await tester.pumpAndSettle();

    await raceDayToResults(tester, core);

    // ignore: avoid_print
    print('OFFLINE_RESULTS_ATTEMPTS ${wire.attempts.length} ${wire.attempts}');
    expect(wire.attempts, isEmpty);
  });
}
