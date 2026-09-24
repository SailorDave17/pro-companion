import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'bars.dart';

/// Colour tokens for reading a phone in direct sun (groom decision G3). Every
/// text colour is paired with the background it is drawn on, and each pair is
/// held to [Bars.minTextContrast] by test, computed from these values.
abstract final class SunlightTokens {
  static const background = Color(0xFFFFFFFF);
  static const text = Color(0xFF000000);
  static const mutedText = Color(0xFF3A3A3A);

  /// FINISH: the one control that must never be missed.
  static const primary = Color(0xFF000000);
  static const onPrimary = Color(0xFFFFFFFF);

  /// Undo, keypad confirm, and the other secondary actions.
  static const secondary = Color(0xFF1B3A8C);
  static const onSecondary = Color(0xFFFFFFFF);

  /// Rows being edited, the keypad.
  static const surface = Color(0xFFF2F2F2);
  static const onSurface = Color(0xFF000000);

  /// A control with nothing to do yet. Still readable in sun.
  static const disabled = Color(0xFFE0E0E0);
  static const onDisabled = Color(0xFF333333);

  /// "Not logged" - a failed append.
  static const danger = Color(0xFF8B0000);
  static const onDanger = Color(0xFFFFFFFF);

  /// Every (text, background) pair the screens draw.
  static const textPairs = <String, (Color, Color)>{
    'text on background': (text, background),
    'muted text on background': (mutedText, background),
    'on-primary on primary': (onPrimary, primary),
    'on-secondary on secondary': (onSecondary, secondary),
    'on-surface on surface': (onSurface, surface),
    'on-disabled on disabled': (onDisabled, disabled),
    'on-danger on danger': (onDanger, danger),
  };
}

/// WCAG 2 contrast ratio between two opaque colours, 1 to 21.
double contrastRatio(Color a, Color b) {
  double channel(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  double luminance(Color c) => 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  final la = luminance(a);
  final lb = luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The theme every race-time screen renders in, built only from the tokens.
ThemeData sunlightTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: SunlightTokens.primary,
    onPrimary: SunlightTokens.onPrimary,
    secondary: SunlightTokens.secondary,
    onSecondary: SunlightTokens.onSecondary,
    error: SunlightTokens.danger,
    onError: SunlightTokens.onDanger,
    surface: SunlightTokens.background,
    onSurface: SunlightTokens.text,
    surfaceContainerHighest: SunlightTokens.surface,
    onSurfaceVariant: SunlightTokens.mutedText,
  );
  const minTarget = Size(Bars.minTargetDp, Bars.minTargetDp);
  ButtonStyle buttons(Color bg, Color fg) => ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(minTarget),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8)))),
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? SunlightTokens.disabled : bg),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? SunlightTokens.onDisabled : fg),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: SunlightTokens.background,
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 20, color: SunlightTokens.text),
      bodyLarge: TextStyle(fontSize: 22, color: SunlightTokens.text),
      titleLarge: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: SunlightTokens.text),
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttons(SunlightTokens.primary, SunlightTokens.onPrimary)),
    elevatedButtonTheme:
        ElevatedButtonThemeData(style: buttons(SunlightTokens.secondary, SunlightTokens.onSecondary)),
    // Outlined controls (sail cells, keypad keys) sit on the page's own
    // background, and still hold 7:1 when disabled.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: buttons(Colors.transparent, SunlightTokens.text).copyWith(
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? SunlightTokens.disabled : Colors.transparent),
        side: WidgetStateProperty.resolveWith((s) => BorderSide(
            color: s.contains(WidgetState.disabled) ? SunlightTokens.onDisabled : SunlightTokens.text, width: 2)),
      ),
    ),
  );
}

/// True when [theme]'s colours are the sunlight tokens.
bool usesSunlightTokens(ThemeData theme) {
  final s = theme.colorScheme;
  return s.primary == SunlightTokens.primary &&
      s.onPrimary == SunlightTokens.onPrimary &&
      s.secondary == SunlightTokens.secondary &&
      s.onSecondary == SunlightTokens.onSecondary &&
      s.surface == SunlightTokens.background &&
      s.onSurface == SunlightTokens.text &&
      s.error == SunlightTokens.danger &&
      theme.scaffoldBackgroundColor == SunlightTokens.background;
}
