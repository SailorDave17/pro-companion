import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../ui/bars.dart';
import '../ui/race_time.dart';

/// A fleet's button: filled for the fleet this phone is finishing, outlined
/// for the rest. The label shrinks to fit rather than wrap or clip.
///
/// [finishingHere] marks a fleet whose course a mark boat has shortened to
/// its station (#30) with a finish flag, and says so, since a flag alone is
/// not read out.
Widget fleetButton({
  required Key key,
  required bool current,
  required String label,
  required VoidCallback onPressed,
  bool finishingHere = false,
}) {
  final child = FittedBox(
    fit: BoxFit.scaleDown,
    child: finishingHere
        ? Builder(
            builder: (context) => Semantics(
              label: '$label, finishing here',
              excludeSemantics: true,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                // An icon does not follow the text size on its own (#19).
                Icon(Icons.sports_score, size: MediaQuery.textScalerOf(context).scale(22)),
                const SizedBox(width: 4),
                Text(label, maxLines: 1),
              ]),
            ),
          )
        : Text(label, maxLines: 1),
  );
  // A fixed side padding: Material shrinks a button's padding as the text
  // grows, which left the label touching the border at 200% (emulator, #18).
  const style = ButtonStyle(padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)));
  return current
      ? FilledButton(key: key, style: style, onPressed: onPressed, child: child)
      : OutlinedButton(key: key, style: style, onPressed: onPressed, child: child);
}

/// Every fleet, one full-width button each, for a day with more fleets than
/// the finish screen's row has room for (#18). A full screen, not a sheet or
/// a menu: the wet-hands bar allows no popup on a race-time route. Pops with
/// the chosen fleet's id, or null for Back.
///
/// A finish-at-mark screen opens it too (#30), as its own action, with the
/// fleets already finishing there flagged.
class FleetPickerScreen extends StatelessWidget {
  const FleetPickerScreen({
    super.key,
    required this.fleets,
    required this.current,
    this.title = 'Switch fleet',
    this.actionId = 'fleet-switch',
    this.finishingHere = const {},
  });

  final List<Fleet> fleets;
  final String? current;
  final String title;

  /// The race-time action a pick here is.
  final String actionId;

  /// The fleets a mark boat's station is the finish for (#30).
  final Set<String> finishingHere;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        leadingWidth: 80,
        leading: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: IconButton(
            tooltip: 'Back',
            iconSize: 32,
            style: IconButton.styleFrom(minimumSize: const Size.square(Bars.minTargetDp)),
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        title: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Bars.screenGutterDp),
          children: [
            for (final f in fleets)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: RaceTimeAction(
                  id: actionId,
                  primary: true,
                  child: SizedBox(
                    width: double.infinity,
                    height: Bars.minTargetDp + 8,
                    child: fleetButton(
                      key: ValueKey('pick-${f.id}'),
                      current: f.id == current,
                      label: f.id == current ? '${f.name} · now' : f.name,
                      onPressed: () => Navigator.of(context).pop(f.id),
                      finishingHere: finishingHere.contains(f.id),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
