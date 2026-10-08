import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../ui/bars.dart';
import '../ui/fit_label.dart';
import '../ui/race_time.dart';
import '../ui/sunlight.dart';

/// What the standard mark [id] is called on screen (docs/marks.md). An id
/// outside the set shows as it is stored.
String markName(String id) => switch (id) {
      StandardMarks.mark1 => 'Mark 1',
      StandardMarks.mark2 => 'Mark 2',
      StandardMarks.mark3 => 'Mark 3',
      StandardMarks.mark4 => 'Mark 4',
      StandardMarks.windward => 'Windward',
      StandardMarks.leeward => 'Leeward',
      StandardMarks.gateLeft => 'Gate left',
      StandardMarks.gateRight => 'Gate right',
      StandardMarks.offset => 'Offset',
      _ => id,
    };

/// The station picker (#26): the standard mark set, one tap on a mark logs
/// this phone's station there and returns to the mark boat's home, which
/// holds UNDO STATION (owner's choice, 2026-10-08). A full screen, not a sheet
/// or a menu: the wet-hands bar allows no popup on a race-time route.
///
/// The marks never move: the station in force is filled in its own cell.
/// Pops with the stored pick, or with nothing for Back or for the station the
/// phone is already at, which logs nothing.
class StationScreen extends StatefulWidget {
  const StationScreen({super.key, required this.core, required this.confirmation, required this.current});

  final CoreClient core;
  final ConfirmationService confirmation;

  /// The station in force, or null when there is none.
  final String? current;

  @override
  State<StationScreen> createState() => _StationScreenState();
}

class _StationScreenState extends State<StationScreen> {
  bool _busy = false;
  bool _notLogged = false;

  /// Logs a pick of [mark] and, once the core confirms it, returns home. A
  /// failed append says "Not logged" here and fires nothing.
  Future<void> _pick(String mark) async {
    if (_busy) return; // A second tap while the first is in flight is the same tap.
    if (mark == widget.current) {
      Navigator.of(context).pop();
      return;
    }
    _busy = true;
    try {
      final stored = await widget.confirmation.confirm(() => widget.core.append(StationEvents.select(mark)));
      if (mounted) Navigator.of(context).pop(stored);
    } catch (_) {
      if (mounted) setState(() => _notLogged = true);
    } finally {
      _busy = false;
    }
  }

  Widget _mark(String mark) {
    final current = mark == widget.current;
    final label = markName(mark);
    // The station in force is drawn as a fill alone, so it is said too.
    final child = Semantics(
      label: current ? '$label, current station' : label,
      excludeSemantics: true,
      child: FitLabel(label.toUpperCase()),
    );
    const style = ButtonStyle(padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)));
    return RaceTimeAction(
      id: 'station',
      child: SizedBox(
        height: Bars.minTargetDp + 8,
        child: current
            ? FilledButton(key: ValueKey('station-$mark'), style: style, onPressed: () => _pick(mark), child: child)
            : OutlinedButton(key: ValueKey('station-$mark'), style: style, onPressed: () => _pick(mark), child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.current;
    final marks = StandardMarks.all;
    return Scaffold(
      // Nothing here is typed.
      resizeToAvoidBottomInset: false,
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
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(current == null ? 'Station · none yet' : 'Station · ${markName(current)}',
              style: Theme.of(context).textTheme.titleLarge),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Bars.screenGutterDp),
          children: [
            if (_notLogged)
              Semantics(
                liveRegion: true,
                child: Container(
                  width: double.infinity,
                  color: SunlightTokens.danger,
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 12),
                  child: const Text('Not logged. Tap again.',
                      style: TextStyle(color: SunlightTokens.onDanger, fontSize: 22, fontWeight: FontWeight.w700)),
                ),
              ),
            // Two to a row, in the set's order; the odd one out spans the row.
            for (var i = 0; i < marks.length; i += 2)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: i + 1 < marks.length
                    ? Row(
                        children: [
                          Expanded(child: _mark(marks[i])),
                          const SizedBox(width: 12),
                          Expanded(child: _mark(marks[i + 1])),
                        ],
                      )
                    : SizedBox(width: double.infinity, child: _mark(marks[i])),
              ),
          ],
        ),
      ),
    );
  }
}
