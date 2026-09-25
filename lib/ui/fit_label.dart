import 'package:flutter/widgets.dart';

/// A button label that shrinks to fit its button rather than wrap or clip.
/// At large text sizes a fixed-size control otherwise cuts its own label
/// ("Canc/el", "Sail" without its "#") - measured at 200% on the emulator.
class FitLabel extends StatelessWidget {
  const FitLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1));
}
