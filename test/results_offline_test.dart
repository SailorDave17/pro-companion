import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/fake_confirmation.dart';
import 'support/network_tripwire.dart';
import 'support/race_day_flow.dart';

/// #7 criterion 2, the host half: a whole race day through to provisional
/// results, with the network tripwire armed on HTTP clients and sockets (its
/// doc lists what it cannot see). The device half, on the real core with the phone in
/// airplane mode, is integration_test/offline_results_flow.dart.
void main() {
  late NetworkTripwire wire;

  setUp(() {
    wire = NetworkTripwire();
    addTearDown(wire.disarm);
  });

  testWidgets('criterion 2: a race day through to provisional results reaches for no network', (tester) async {
    wire.arm();
    var now = DateTime(2026, 9, 26, 14, 30).millisecondsSinceEpoch;
    final core = FakeCore(clock: () => now += 1000);
    await tester.pumpWidget(ProCompanionApp(core: core, confirmation: ConfirmationService(FakeConfirmationDevice())));
    await tester.pumpAndSettle();

    await raceDayToResults(tester, core);

    expect(wire.attempts, isEmpty);
  });

  // The test above passes by the tripwire staying silent, so it means
  // something only if the tripwire can speak.
  group('the tripwire', () {
    test('trips on an HttpClient', () {
      wire.arm();
      expect(HttpClient.new, throwsA(isA<SocketException>()));
      expect(wire.attempts, ['HttpClient created']);
    });

    test('trips on a socket, one started, and a bound server socket', () async {
      wire.arm();
      await expectLater(Socket.connect('192.0.2.1', 80), throwsA(isA<SocketException>()));
      await expectLater(Socket.startConnect('192.0.2.2', 81), throwsA(isA<SocketException>()));
      await expectLater(ServerSocket.bind(InternetAddress.loopbackIPv4, 0), throwsA(isA<SocketException>()));
      expect(wire.attempts, [
        'socket to 192.0.2.1:80',
        'socket to 192.0.2.2:81',
        'server socket on ${InternetAddress.loopbackIPv4}:0',
      ]);
    });

    test('puts both overrides it replaced back when disarmed', () {
      final http = HttpOverrides.current;
      final io = IOOverrides.current;
      wire.arm();
      expect(IOOverrides.current, isNot(same(io)), reason: 'control: arming replaced it');
      wire.disarm();
      expect(HttpOverrides.current, same(http));
      expect(IOOverrides.current, same(io));
    });
  });
}
