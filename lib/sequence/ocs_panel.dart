import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../ui/bars.dart';
import '../ui/clock.dart';
import '../ui/fit_label.dart';
import '../ui/sunlight.dart';

/// The OCS panel (#29): the boats over the line at the selected fleet's
/// start. OCS on the sequence card opens it in the card's place, as tapping
/// the gun opens its time keypad, so GUN and UNDO LAST never move (owner's
/// layout, 2026-10-06).
///
/// A boat the day's log already knows is one tap, so OCS then her sail number
/// is two taps from the card. Any other boat is typed. A boat over turns black
/// where she is; tapping her selects her, and CLEARED, once she has come back
/// and started, takes the header's status line (owner's choice: CLEARED only;
/// UNDO LAST takes back a mistake).
///
/// Nothing moves under the next thumb (owner's choice after the renders,
/// 2026-10-06). The boats keep the order the panel opened with, a boat
/// logged stays in her cell, and the header and heading have a fixed height.
/// A boat typed while the panel is open joins the end.
///
/// None of its buttons is a race-time action of its own: the action is OCS,
/// which opens it, as the sail cell is on the finish screen and the keypad's
/// keys are not. The bar check still holds every target and label here to
/// the bar, since it explores the panel OCS opens.
class OcsPanel extends StatelessWidget {
  const OcsPanel({
    super.key,
    required this.gunAt,
    required this.boats,
    required this.over,
    required this.selected,
    required this.onSail,
    required this.onSelect,
    required this.onClear,
    required this.onType,
    required this.onClose,
  });

  /// Boats to a row: four fit a 320 dp phone at the bar's 64 dp.
  static const perRow = 4;

  /// The start's gun time, corrected if it has been.
  final int gunAt;

  /// The sail numbers to show, in the order they keep while the panel is
  /// open: every boat over among them.
  final List<String> boats;

  /// The boats logged over at this start.
  final List<OcsEntry> over;

  /// The boat over that CLEARED clears, once one is selected.
  final OcsEntry? selected;
  final ValueChanged<String> onSail;
  final ValueChanged<OcsEntry> onSelect;
  final VoidCallback onClear;
  final VoidCallback onType;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final label = Theme.of(context).textTheme.bodyMedium;
    final overBySail = {for (final o in over) o.sail: o};
    final stillOver = over.where((o) => !o.cleared).length;

    // Each the bar's size with a label that shrinks to fit, as the keypad's
    // keys are.
    Widget cell(Widget button) =>
        Expanded(child: Padding(padding: const EdgeInsets.all(4), child: SizedBox(height: Bars.minTargetDp, child: button)));
    // Material's own padding left a four-across cell 41 dp for its label, so
    // a four-digit sail number shrank below a two-digit one (measured on the
    // emulator).
    const pad = ButtonStyle(padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6)));
    // Over and selected are drawn as fills, so a screen reader is told in
    // words (as each results row is, #7).
    Widget spoken(String sail, String state) =>
        Semantics(label: '$sail, $state', excludeSemantics: true, child: FitLabel(sail));
    Widget boat(String sail) {
      final key = ValueKey('ocs-sail-$sail');
      return switch (overBySail[sail]) {
        null => OutlinedButton(key: key, style: pad, onPressed: () => onSail(sail), child: FitLabel(sail)),
        final OcsEntry o when o.cleared =>
          OutlinedButton(key: key, style: pad, onPressed: null, child: _ClearedLabel(sail)),
        final OcsEntry o when o.ulid == selected?.ulid => ElevatedButton(
            key: key, style: pad, onPressed: () => onSelect(o), child: spoken(sail, 'over the line, selected')),
        final OcsEntry o =>
          FilledButton(key: key, style: pad, onPressed: () => onSelect(o), child: spoken(sail, 'over the line')),
      };
    }

    final cells = [
      // Type first, so it is in the same place however many boats are known,
      // and never below the fold.
      OutlinedButton(key: const ValueKey('ocs-type'), style: pad, onPressed: onType, child: const FitLabel('Type #')),
      for (final sail in boats) boat(sail),
    ];
    final heading = boats.isEmpty
        ? 'No sail numbers known yet · type one'
        : stillOver == 0
            ? 'Tap the boat over'
            : 'Tap the boat over, or a black one that came back';

    return Container(
      color: SunlightTokens.surface,
      padding: const EdgeInsets.symmetric(horizontal: Bars.screenGutterDp - 4, vertical: 4),
      child: SingleChildScrollView(
        child: Column(
          children: [
            // A fixed-height header, as on the keypad. CLEARED takes the
            // status line's place, so selecting a boat moves nothing.
            SizedBox(
              height: Bars.minTargetDp + 8,
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: switch (selected) {
                        final OcsEntry boat => SizedBox(
                            height: Bars.minTargetDp,
                            child: ElevatedButton(
                              key: const ValueKey('ocs-cleared'),
                              onPressed: onClear,
                              child: FitLabel('CLEARED (${boat.sail})'),
                            ),
                          ),
                        null => FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('OCS · gun ${clockText(gunAt)}', style: label),
                                Text(stillOver == 0 ? 'Nobody over' : '$stillOver over',
                                    style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
                              ],
                            ),
                          ),
                      },
                    ),
                  ),
                  SizedBox(
                    width: 140,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: SizedBox(
                        height: Bars.minTargetDp,
                        child: OutlinedButton(
                          key: const ValueKey('ocs-close'),
                          onPressed: onClose,
                          child: const FitLabel('Close'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // One fixed-height line at any text size: grown at 200%, it took a
            // row of boats' room (measured on the emulator).
            SizedBox(
              height: 32,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Align(alignment: Alignment.centerLeft, child: FitLabel(heading)),
              ),
            ),
            for (var i = 0; i < cells.length; i += perRow)
              Row(children: [
                for (var j = i; j < i + perRow; j++) j < cells.length ? cell(cells[j]) : const Expanded(child: SizedBox()),
              ]),
          ],
        ),
      ),
    );
  }
}

/// A cleared boat: her sail number as big as any other, "cleared" small
/// under it. On one line the number shrank to fit (measured on the
/// emulator).
class _ClearedLabel extends StatelessWidget {
  const _ClearedLabel(this.sail);
  final String sail;

  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(sail, maxLines: 1),
            const Text('cleared', maxLines: 1, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ],
        ),
      );
}
