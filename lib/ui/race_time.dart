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
/// race-time action is added to its role's set below, or it is not held to
/// the bar.
const raceTimeActionIds = {...proRaceTimeActionIds, ...markBoatRaceTimeActionIds};

/// The mark boat's (#26): a station pick, and its undo on the home.
const markBoatRaceTimeActionIds = {'station', 'station-undo'};

/// The race-time actions that sit on a role's home itself, not on a screen
/// it opens: the mark boat's UNDO STATION (#26). From any home, another
/// role's home is two taps away (UNDO ROLE, then a pick), so every check
/// meets these, and only the check from their own home holds them.
const onHomeRaceTimeActionIds = {'station-undo'};

/// The PRO's: everything the PRO's home leads to, which the recorder's is a
/// part of. The whole-app checks open on the PRO's home, so this is what they
/// hold to the bar.
const proRaceTimeActionIds = {
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
  'individual-recall',
  'ocs',
};
