import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/ui/bars.dart';

/// #4 criterion 1: docs/usability-bars.md and the shared constants state the
/// same bar - 64dp targets, full-width primary actions, 7:1 contrast - so
/// one cannot change without the other.
void main() {
  final doc = File('docs/usability-bars.md').readAsStringSync();

  String dp(double v) => '**${v.toStringAsFixed(0)} dp**';

  test('the doc states the constants', () {
    expect(doc, contains(dp(Bars.minTargetDp)), reason: 'minimum target');
    expect(doc, contains('**Full width**'), reason: 'primary actions');
    expect(doc, contains(dp(Bars.screenGutterDp)), reason: 'the full-width gutter');
    expect(doc, contains('**${Bars.minTextContrast.toStringAsFixed(0)}:1** minimum'), reason: 'contrast');
    expect(doc, contains('**${Bars.maxTapsFromRoleHome}** at most'), reason: 'taps from the role home');
  });

  test('the constants are the ratified values (groom decision G3)', () {
    expect(Bars.minTargetDp, 64);
    expect(Bars.minTextContrast, 7.0);
    expect(Bars.maxTapsFromRoleHome, 2);
  });

  test('the doc says whether the field session has confirmed them', () {
    expect(doc, contains('Not yet confirmed on the water'),
        reason: 'until amended #8 marks each value confirmed or adjusted');
  });
}
