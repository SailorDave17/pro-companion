import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_companion/main.dart' as app;

/// #16's sample: the smallest test that proves CI's emulator job builds the
/// real app, installs it on an Android emulator and runs a test against it.
/// Since #24 it also proves the real app starts the real core on the device
/// and reads the log through it.
///
/// Locally: flutter test integration_test -d DEVICE_ID
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app launches on a device, starts the core and shows its log count',
      (tester) async {
    await app.main();
    await tester.pumpAndSettle();
    expect(find.text('PRO Companion'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d+ events? on this phone$')), findsOneWidget);
  });
}
