import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/main.dart';

void main() {
  testWidgets('renders the app name on the home screen', (tester) async {
    await tester.pumpWidget(const ProCompanionApp());
    expect(find.text('PRO Companion'), findsOneWidget);
  });
}
