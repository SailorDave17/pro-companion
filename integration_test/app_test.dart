import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_companion/main.dart' as app;

import 'pro_home.dart';

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
    // Since #20 a phone with no role opens on the role picker, and one with a
    // role on that role's home, which shows the count.
    await openProHome(tester);
    expect(find.textContaining(RegExp(r'^\d+ events? on this phone$')), findsOneWidget);
  });
}
