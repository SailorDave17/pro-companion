import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/sequence/link_banner.dart';
import 'package:pro_companion/ui/sunlight.dart';

/// #33 criterion 9, the banner alone on the narrowest phone: a fixed height at
/// any text size, one line, read out once, and nothing to tap. When it shows,
/// and that no row moves when it does, is test/sequence_link_test.dart.
void main() {
  final banner = find.byKey(const ValueKey('link-banner'));

  Future<void> show(WidgetTester tester, double textScale) async {
    tester.view.physicalSize = const Size(960, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MediaQuery.withClampedTextScaling(
      minScaleFactor: textScale,
      maxScaleFactor: textScale,
      child: MaterialApp(
        theme: sunlightTheme(),
        home: const Scaffold(body: Align(alignment: Alignment.topCenter, child: LinkBanner())),
      ),
    ));
  }

  /// The banner's text as laid out.
  RenderParagraph paragraph(WidgetTester tester) => tester.renderObject<RenderParagraph>(find.text(LinkBanner.text));

  for (final scale in [1.0, 2.0]) {
    final percent = '${(scale * 100).round()}%';

    testWidgets('at $percent text, on a 320 wide phone: 32 dp and the width of the screen', (tester) async {
      await show(tester, scale);
      expect(LinkBanner.height, 32);
      expect(tester.getSize(banner), const Size(320, 32));
    });

    testWidgets('at $percent text: one line, with its text whole', (tester) async {
      await show(tester, scale);
      final text = paragraph(tester);
      expect(text.didExceedMaxLines, isFalse);
      expect(text.getMaxIntrinsicHeight(text.size.width), lessThanOrEqualTo(text.size.height + 0.5), reason: 'not wrapped');
      expect(text.size.width, greaterThanOrEqualTo(text.getMaxIntrinsicWidth(double.infinity) - 0.5), reason: 'not cut');
      final box = tester.getRect(banner);
      final drawn = tester.getRect(find.text(LinkBanner.text));
      expect(box.contains(drawn.topLeft) && box.contains(drawn.bottomRight), isTrue, reason: '$drawn in $box');
    });

    testWidgets('at $percent text: one live semantics node, and nothing tappable', (tester) async {
      final semantics = tester.ensureSemantics();
      await show(tester, scale);

      expect(find.bySemanticsLabel(LinkBanner.text), findsOneWidget);
      final data = tester.getSemantics(find.bySemanticsLabel(LinkBanner.text)).getSemanticsData();
      expect(data.flagsCollection.isLiveRegion, isTrue);
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      expect(data.hasAction(SemanticsAction.longPress), isFalse);
      expect(find.descendant(of: banner, matching: find.byType(GestureDetector)), findsNothing);
      expect(find.descendant(of: banner, matching: find.byType(InkWell)), findsNothing);
      semantics.dispose();
    });
  }

  test('it says the link is not active, in words that are not an error', () {
    expect(LinkBanner.text, 'race-timer link not active');
  });

  testWidgets('it is not the danger colour, which means "Not logged", and an icon carries it as well', (tester) async {
    await show(tester, 1);
    final box = tester.widget<Container>(banner);
    expect(box.color, isNot(SunlightTokens.danger));
    expect(find.descendant(of: banner, matching: find.byIcon(Icons.link_off)), findsOneWidget);
  });
}
