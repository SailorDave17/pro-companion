import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../roles/race_area.dart';
import '../shore/shore_status.dart';
import '../ui/bars.dart';
import '../ui/fit_label.dart';
import '../ui/race_time.dart';
import '../ui/sunlight.dart';

/// What mark [id] is called on screen (docs/marks.md): a standard mark by its
/// name, a custom one (#78) by the name the latest list naming it gave it in
/// [custom] (`customMarksEver`), or "Custom mark" where the screen holds no
/// lists. Any other id shows as it is stored.
String markName(String id, [Map<String, CustomMark> custom = const {}]) => switch (id) {
      StandardMarks.mark1 => 'Mark 1',
      StandardMarks.mark2 => 'Mark 2',
      StandardMarks.mark3 => 'Mark 3',
      StandardMarks.mark4 => 'Mark 4',
      StandardMarks.windward => 'Windward',
      StandardMarks.leeward => 'Leeward',
      StandardMarks.gateLeft => 'Gate left',
      StandardMarks.gateRight => 'Gate right',
      StandardMarks.offset => 'Offset',
      _ when isCustomMarkId(id) => custom[id]?.name ?? 'Custom mark',
      _ => id,
    };

/// A custom mark's colour and shape in words, or null when it has neither.
String? markLooks(CustomMark m) {
  final looks = [?m.colour, ?m.shape];
  return looks.isEmpty ? null : looks.join(' ');
}

/// The station picker (#26): the standard mark set, one tap on a mark logs
/// this phone's station there and returns to the mark boat's home, which
/// holds UNDO STATION (owner's choice, 2026-10-08). A full screen, not a sheet
/// or a menu: the wet-hands bar allows no popup on a race-time route.
///
/// The marks never move: the station in force is filled in its own cell.
/// Pops with the stored pick, or with nothing for Back or for the station the
/// phone is already at, which logs nothing.
///
/// After the standard set come the custom marks a PRO sent for this phone's
/// race area (#78), in the order sent. A phone that has none, has not pulled
/// a list, or is on another race area offers the standard set alone.
class StationScreen extends StatefulWidget {
  const StationScreen({
    super.key,
    required this.core,
    required this.confirmation,
    required this.current,
    this.course,
  });

  final CoreClient core;
  final ConfirmationService confirmation;

  /// The station in force, or null when there is none.
  final String? current;

  /// The course id of the phone's race area, whose custom marks it offers,
  /// or null for a phone with one implicit race area, which has none.
  final String? course;

  @override
  State<StationScreen> createState() => _StationScreenState();
}

class _StationScreenState extends State<StationScreen> {
  bool _busy = false;
  bool _notLogged = false;

  // Every phone's mark lists (#78), read when the picker opens, since a
  // PRO's list arrives by pull. The standard set shows at once and needs
  // none of them: a phone that cannot read them still stations (criterion 3).
  final _lists = <EventEnvelope>[];

  List<CustomMark> get _custom => currentMarkList(_lists, widget.course);

  @override
  void initState() {
    super.initState();
    if (widget.course == null) return;
    widget.core.readAll().then((events) {
      if (mounted) setState(() => _lists.addAll(events.where((e) => MarkListKinds.all.contains(e.kind))));
    }, onError: (Object _) {});
  }

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
    final custom = _custom.where((m) => m.id == mark).firstOrNull;
    final label = custom?.name ?? markName(mark);
    final looks = custom == null ? null : markLooks(custom);
    final said = looks == null ? label : '$label, $looks';
    // The station in force is drawn as a fill alone, so it is said too.
    final child = Semantics(
      label: current ? '$said, current station' : said,
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
    return Scaffold(
      // Nothing here is typed.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        toolbarHeight: 72,
        leadingWidth: 80,
        actions: [ShoreIndicator(core: widget.core)],
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
        title: RaceAreaTitle(
          title: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(current == null ? 'Station · none yet' : 'Station · ${markName(current, customMarksEver(_lists))}',
                style: Theme.of(context).textTheme.titleLarge),
          ),
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
            // The PRO's custom marks start rows of their own (#78), so the
            // standard set never moves when a list arrives.
            for (final group in [StandardMarks.all, [for (final m in _custom) m.id]])
              for (var i = 0; i < group.length; i += 2)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: i + 1 < group.length
                      ? Row(
                          children: [
                            Expanded(child: _mark(group[i])),
                            const SizedBox(width: 12),
                            Expanded(child: _mark(group[i + 1])),
                          ],
                        )
                      : SizedBox(width: double.infinity, child: _mark(group[i])),
                ),
          ],
        ),
      ),
    );
  }
}
