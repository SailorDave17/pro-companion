import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/fake_confirmation.dart';

void main() {
  testWidgets('renders the app name on the role picker, where a new phone opens', (tester) async {
    await tester.pumpWidget(ProCompanionApp(
      core: FakeCore(),
      confirmation: ConfirmationService(FakeConfirmationDevice()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('PRO Companion'), findsOneWidget);
  });
}
