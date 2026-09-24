import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/ui/bars.dart';
import 'package:pro_companion/ui/sunlight.dart';

/// #4 criterion 3: text in the sunlight theme holds 7:1 against its
/// background, asserted from the tokens.
void main() {
  group('the contrast formula', () {
    // Known answers, so the ratio every other test trusts is itself checked.
    test('black on white is 21:1', () {
      expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
    });
    test('a colour on itself is 1:1', () {
      expect(contrastRatio(const Color(0xFF1B3A8C), const Color(0xFF1B3A8C)), closeTo(1, 0.001));
    });
    test('#767676 on white is the AA edge, 4.54:1', () {
      expect(contrastRatio(const Color(0xFF767676), Colors.white), closeTo(4.54, 0.01));
    });
    test('order does not matter', () {
      expect(contrastRatio(Colors.white, const Color(0xFF8B0000)),
          closeTo(contrastRatio(const Color(0xFF8B0000), Colors.white), 1e-9));
    });
  });

  test('every text/background token pair is at least 7:1', () {
    for (final MapEntry(key: name, value: (fg, bg)) in SunlightTokens.textPairs.entries) {
      expect(contrastRatio(fg, bg), greaterThanOrEqualTo(Bars.minTextContrast), reason: name);
    }
  });

  test('the theme draws text only from token pairs', () {
    final theme = sunlightTheme();
    final s = theme.colorScheme;
    final pairs = {
      'onSurface on surface': (s.onSurface, s.surface),
      'onPrimary on primary': (s.onPrimary, s.primary),
      'onSecondary on secondary': (s.onSecondary, s.secondary),
      'onError on error': (s.onError, s.error),
      'onSurfaceVariant on surface': (s.onSurfaceVariant, s.surface),
      'body text on the page': (theme.textTheme.bodyMedium!.color!, theme.scaffoldBackgroundColor),
    };
    for (final MapEntry(key: name, value: (fg, bg)) in pairs.entries) {
      expect(contrastRatio(fg, bg), greaterThanOrEqualTo(Bars.minTextContrast), reason: name);
    }
    expect(usesSunlightTokens(theme), isTrue);
  });

  test('disabled buttons still hold 7:1', () {
    final style = sunlightTheme().elevatedButtonTheme.style!;
    const disabled = {WidgetState.disabled};
    expect(
      contrastRatio(style.foregroundColor!.resolve(disabled)!, style.backgroundColor!.resolve(disabled)!),
      greaterThanOrEqualTo(Bars.minTextContrast),
    );
  });
}
