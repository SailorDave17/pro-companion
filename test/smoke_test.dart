import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion_core/testing.dart';

void main() {
  testWidgets('renders the app name on the home screen', (tester) async {
    await tester.pumpWidget(ProCompanionApp(core: FakeCore()));
    expect(find.text('PRO Companion'), findsOneWidget);
  });
}
