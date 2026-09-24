import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_companion/main.dart' as app;

/// #16's sample: the smallest test that proves CI's emulator job builds the
/// real app, installs it on an Android emulator and runs a test against it.
/// The instrumented criteria that need a device (force-kill, headless core,
/// manifest) land beside it in their own stories.
///
/// Locally: flutter test integration_test -d DEVICE_ID
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app launches on a device and shows its name', (tester) async {
    app.main();
    await tester.pumpAndSettle();
    expect(find.text('Not the app'), findsOneWidget);
  });
}
