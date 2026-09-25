import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../ui/bars.dart';
import '../ui/fit_label.dart';
import '../ui/race_time.dart';
import '../ui/sunlight.dart';
import 'fleet_picker_screen.dart';

/// The fleet buttons under a race-time screen's title (#18; the sequence
/// screen's too, #25): every fleet when there are three or fewer, otherwise
/// the two this phone used last and MORE. One tap on a fleet switches to it.
/// The selection is the phone's, so a switch on one screen holds on the other.
class FleetRow extends StatelessWidget {
  const FleetRow({
    super.key,
    required this.fleets,
    required this.current,
    required this.recent,
    required this.onSwitch,
    required this.onMore,
  });

  static const _roomFor = 3;

  final List<Fleet> fleets;
  final String? current;

  /// Fleets this phone switched to, most recent first.
  final List<String> recent;
  final ValueChanged<String> onSwitch;
  final VoidCallback onMore;

  List<Fleet> _shown() {
    if (fleets.length <= _roomFor) return fleets;
    final byId = {for (final f in fleets) f.id: f};
    final ids = <String>[
      ?current,
      for (final id in recent)
        if (id != current && byId.containsKey(id)) id,
      for (final f in fleets) f.id,
    ];
    return ids.toSet().take(_roomFor - 1).map((id) => byId[id]!).toList();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown();
    final cells = <Widget>[
      for (final f in shown)
        RaceTimeAction(
          id: 'fleet-switch',
          child: SizedBox(
            height: Bars.minTargetDp,
            child: fleetButton(
              key: ValueKey('fleet-switch-${f.id}'),
              current: f.id == current,
              label: f.name,
              onPressed: () => onSwitch(f.id),
            ),
          ),
        ),
      if (shown.length < fleets.length)
        SizedBox(
          height: Bars.minTargetDp,
          child: OutlinedButton(key: const ValueKey('fleet-more'), onPressed: onMore, child: const FitLabel('MORE')),
        ),
    ];
    // A rule under the row, so a finish scrolled partly away reads as passing
    // beneath a header rather than as tucked under the buttons (emulator, #18).
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, 8, Bars.screenGutterDp, 8),
          child: Row(
            children: [
              for (var i = 0; i < cells.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: cells[i]),
              ],
            ],
          ),
        ),
        const Divider(height: 2, thickness: 2, color: SunlightTokens.mutedText),
      ],
    );
  }
}
