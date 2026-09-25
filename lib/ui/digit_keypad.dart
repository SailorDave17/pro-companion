import 'package:flutter/material.dart';

import 'bars.dart';
import 'fit_label.dart';
import 'sunlight.dart';

/// A keypad for typing digits on a race-time screen: a sail number (#4), or a
/// gun's corrected time (#25). A fixed-height header holds what is being typed
/// for and the digits so far; every key is the bar's size with a label that
/// shrinks to fit, so the keypad takes the same space at any text size and the
/// screen's big button never has to move.
class DigitKeypad extends StatelessWidget {
  const DigitKeypad({
    super.key,
    required this.title,
    required this.display,
    required this.onDigit,
    required this.onDelete,
    required this.onClose,
    required this.onSave,
  });

  /// What the digits are for.
  final String title;

  /// The digits typed so far, as the screen formats them.
  final String display;
  final ValueChanged<String> onDigit;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  /// Null while there is nothing that can be saved.
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    Widget key(String label, VoidCallback? onPressed, {Key? k}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: SizedBox(
              height: Bars.minTargetDp,
              child: OutlinedButton(
                key: k,
                onPressed: onPressed,
                style: const ButtonStyle(
                  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
                ),
                child: FitLabel(label),
              ),
            ),
          ),
        );
    return Container(
      color: SunlightTokens.surface,
      padding: const EdgeInsets.symmetric(horizontal: Bars.screenGutterDp - 4, vertical: 4),
      child: SingleChildScrollView(
        child: Column(
          children: [
            // A fixed-height header, so the keypad below it fits in the same
            // space at any text size and the big button never has to move.
            SizedBox(
              height: Bars.minTargetDp + 8,
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: Theme.of(context).textTheme.bodyMedium),
                            Text(display, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // "Close", not "Cancel": numbers saved on the way stay saved.
                  SizedBox(width: 140, child: Row(children: [key('Close', onClose, k: const ValueKey('keypad-cancel'))])),
                ],
              ),
            ),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              Row(children: [for (final d in row) key(d, () => onDigit(d), k: ValueKey('key-$d'))]),
            Row(children: [
              key('⌫', onDelete, k: const ValueKey('key-del')),
              key('0', () => onDigit('0'), k: const ValueKey('key-0')),
              key('Save', onSave, k: const ValueKey('keypad-save')),
            ]),
          ],
        ),
      ),
    );
  }
}
