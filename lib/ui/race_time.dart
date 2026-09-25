import 'package:flutter/widgets.dart';

/// Marks a control as a race-time action, so the bar-check helper can hold
/// it to the wet-hands bar. Renders [child] unchanged.
class RaceTimeAction extends StatelessWidget {
  const RaceTimeAction({
    super.key,
    required this.id,
    required this.child,
    this.primary = false,
    this.itemScoped = false,
  });

  /// One of [raceTimeActionIds].
  final String id;

  /// A primary action spans the screen's width (groom decision G3).
  final bool primary;

  /// A correction to one item: reached by selecting the item, then acting,
  /// so it may take one tap more than a screen-level action (owner decision
  /// 2026-09-24, #4).
  final bool itemScoped;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Every race-time action the app has. The bar-check helper fails when one of
/// these cannot be reached within the tap limit from the role home. A new
/// race-time action is added here, or it is not held to the bar.
const raceTimeActionIds = {
  'finish',
  'undo-last',
  'sail',
  'missed-above',
  'undo-this',
  'fleet-switch',
  'gun',
  'postpone',
  'general-recall',
  'fix-gun-time',
  'sequence-undo',
};
