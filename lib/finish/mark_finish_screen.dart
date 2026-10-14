import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../fleets/fleet_picker_screen.dart';
import '../fleets/fleet_row.dart';
import '../stations/station_screen.dart';
import '../ui/bars.dart';
import '../ui/clock.dart';
import '../ui/digit_keypad.dart';
import '../ui/fit_label.dart';
import '../ui/race_time.dart';
import '../ui/sunlight.dart';

/// Finishing at a mark (#30): when the course is shortened, a mark boat's
/// station becomes a fleet's finish and the boats are tapped here. Laid out
/// as the line's finish screen (#4, #18): the fleets in a row under the
/// title, the order above UNDO LAST, and FINISH anchored at the bottom
/// (owner's choice at pickup, 2026-10-14).
///
/// A tap on a fleet not yet finishing here makes the mark its finish, which
/// logs a shortened course. A tap on one that already is shows its finishes
/// and logs nothing. On a single-fleet day the row is one FINISH HERE button.
/// FINISH is off until the fleet shown finishes here.
///
/// Elapsed time is not worked out on this phone: it needs the gun, which
/// another phone logs, and a clock reference across phones (groom decision
/// G10). So the screen says it is pending reconciliation.
class MarkFinishScreen extends StatefulWidget {
  const MarkFinishScreen({super.key, required this.core, required this.confirmation, required this.mark});

  final CoreClient core;
  final ConfirmationService confirmation;

  /// The phone's station. The core stamps it into every event logged here.
  final String mark;

  @override
  State<MarkFinishScreen> createState() => _MarkFinishScreenState();
}

class _MarkFinishScreenState extends State<MarkFinishScreen> {
  final _events = <EventEnvelope>[];
  final _scroll = ScrollController();
  bool _loaded = false;
  bool _failed = false;
  bool _shortening = false;
  String? _deviceId;
  String? _keypadFor;
  String _digits = '';

  /// The fleet chosen in the row, while it finishes here. A record, because
  /// the single-fleet day's fleet is null.
  ({String? fleet})? _chosen;

  @override
  void initState() {
    super.initState();
    Future.wait([widget.core.readAll(), widget.core.deviceId()]).then((r) {
      if (!mounted) return;
      setState(() {
        _events.addAll((r[0] as List<EventEnvelope>).where((e) =>
            FinishKinds.all.contains(e.kind) || FleetKinds.all.contains(e.kind) || CourseKinds.all.contains(e.kind)));
        _deviceId = r[1] as String;
        _loaded = true;
      });
      _scrollToNewest();
    }, onError: (Object _) {
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// This phone's shortened courses in force at the mark, by fleet.
  Map<String?, EventEnvelope> get _inForce =>
      _deviceId == null ? const {} : shortenedAt(_events, deviceId: _deviceId!, mark: widget.mark);

  /// The fleet shown: the one chosen, or else the one this phone last
  /// shortened or finished a boat for here. Null when none finishes here.
  ({String? fleet})? get _shown {
    final chosen = _chosen;
    if (chosen != null && _inForce.containsKey(chosen.fleet)) return chosen;
    return _deviceId == null ? null : lastMarkFleet(_events, deviceId: _deviceId!, mark: widget.mark);
  }

  /// Appends [event] and, once the core confirms it, shows it. A failed
  /// append shows "Not logged" and fires no confirmation. True when logged.
  Future<bool> _append(NewEvent event) async {
    try {
      final stored = await widget.confirmation.confirm(() => widget.core.append(event));
      if (!mounted) return true;
      setState(() {
        _events.add(stored);
        _failed = false;
      });
      if (event.kind == FinishKinds.atMark) _scrollToNewest();
      return true;
    } catch (_) {
      if (mounted) setState(() => _failed = true);
      return false;
    }
  }

  /// A tap on [fleet] in the row: shows it if the mark is already its finish,
  /// and otherwise makes the mark its finish, a shortened course.
  Future<void> _finishHere(String? fleet) async {
    if (_inForce.containsKey(fleet)) {
      if (_shown?.fleet != fleet) setState(() => _show(fleet));
      return;
    }
    if (_shortening) return; // A second tap while the first is in flight is the same tap.
    _shortening = true;
    try {
      if (await _append(CourseEvents.shortened(fleet: fleet)) && mounted) setState(() => _show(fleet));
    } finally {
      _shortening = false;
    }
  }

  // A keypad open on another fleet's finish no longer means anything.
  void _show(String? fleet) {
    _chosen = (fleet: fleet);
    _keypadFor = null;
    _scrollToNewest();
  }

  Future<void> _pickFromAll(List<Fleet> all, String? current) async {
    final chosen = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => FleetPickerScreen(
        fleets: all,
        current: current,
        title: 'Finish here for',
        actionId: 'finish-here',
        finishingHere: {for (final f in _inForce.keys) ?f},
      ),
    ));
    if (chosen != null && mounted) await _finishHere(chosen);
  }

  /// Saves the typed sail number, then walks on to the next finish that has
  /// none, as on the line (#4).
  Future<void> _saveSail(String? fleet) async {
    final target = _keypadFor;
    if (target == null || _digits.isEmpty) return;
    if (!await _append(FinishEvents.assignSail(target, _digits)) || !mounted) return;
    final order = markFinishOrder(_events, fleet: fleet, mark: widget.mark);
    final at = order.indexWhere((e) => e.ulid == target);
    final next = order.skip(at + 1).where((e) => e.sail == null).firstOrNull;
    setState(() {
      _keypadFor = next?.ulid;
      _digits = '';
    });
  }

  void _scrollToNewest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final inForce = _inForce;
    final shown = _shown;
    final fleet = shown?.fleet;
    final allFleets = fleets(_events);
    final fleetName = allFleets.where((f) => f.id == fleet).firstOrNull?.name;
    final order = shown == null ? const <FinishEntry>[] : markFinishOrder(_events, fleet: fleet, mark: widget.mark);
    final height = MediaQuery.sizeOf(context).height;

    // UNDO LAST takes back whichever came last: the fleet's last finish
    // here, or the shortened course that made the mark its finish.
    final lastFinish = shown == null ? null : lastUndoableMarkFinish(_events, fleet: fleet, mark: widget.mark);
    final shortened = shown == null ? null : inForce[fleet];
    final undoShortened = shortened != null && (lastFinish == null || happened(shortened, lastFinish) > 0);
    final lastPlace = lastFinish == null ? null : order.where((e) => e.ulid == lastFinish.ulid).firstOrNull?.place;
    final NewEvent? undo = undoShortened
        ? CourseEvents.undo(shortened.ulid)
        : lastFinish == null
            ? null
            : FinishEvents.undo(lastFinish.ulid);
    final undoLabel = undoShortened
        ? fleetName == null
            ? 'UNDO FINISH HERE'
            : 'UNDO FINISH HERE ($fleetName)'
        : lastFinish == null
            ? 'Nothing to undo'
            : 'UNDO LAST (#$lastPlace)';

    final where = 'Finish at ${markName(widget.mark)}';
    final status = shown != null
        ? 'Elapsed: pending reconciliation'
        : allFleets.isEmpty
            ? 'Not a finish yet: tap FINISH HERE'
            : 'Not a finish yet: tap a fleet';

    return Scaffold(
      // Nothing here is typed with the system keyboard (as the line's, #25).
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
          child: Text(
            [where, ?fleetName, if (shown != null) '${order.length}'].join(' · '),
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (allFleets.isNotEmpty)
              FleetRow(
                fleets: allFleets,
                current: fleet,
                recent: [
                  for (final e in inForce.values.toList()..sort((a, b) => happened(b, a)))
                    if (fleetOf(e) case final String id) id,
                ],
                onSwitch: _finishHere,
                onMore: () => _pickFromAll(allFleets, fleet),
                actionId: 'finish-here',
                finishingHere: {for (final f in inForce.keys) ?f},
              )
            else
              _SingleFleetFinishHere(
                finishing: inForce.containsKey(null),
                onPressed: () => _finishHere(null),
              ),
            // One fixed line, so nothing below it moves when the mark becomes
            // a finish.
            Padding(
              padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, 8, Bars.screenGutterDp, 4),
              child: SizedBox(
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(status, key: const ValueKey('mark-finish-status'), style: Theme.of(context).textTheme.titleMedium),
                ),
              ),
            ),
            Expanded(
              child: _keypadFor != null
                  ? DigitKeypad(
                      title: _sailTitle(order.where((e) => e.ulid == _keypadFor).firstOrNull),
                      display: _digits.isEmpty ? '—' : _digits,
                      onDigit: (d) => setState(() {
                        if (_digits.length < 7) _digits += d;
                      }),
                      onDelete: () => setState(() => _digits = _digits.isEmpty ? '' : _digits.substring(0, _digits.length - 1)),
                      onClose: () => setState(() => _keypadFor = null),
                      onSave: _digits.isEmpty ? null : () => _saveSail(fleet),
                    )
                  : !_loaded && !_failed
                      ? const Center(child: Text('Reading the log…'))
                      : ListView.builder(
                          controller: _scroll,
                          itemCount: order.length,
                          itemBuilder: (context, i) => _MarkFinishRow(
                            entry: order[i],
                            onSail: () => setState(() {
                              _keypadFor = order[i].ulid;
                              _digits = order[i].sail ?? '';
                            }),
                          ),
                        ),
            ),
            if (_failed)
              Semantics(
                liveRegion: true,
                child: Container(
                  width: double.infinity,
                  color: SunlightTokens.danger,
                  padding: const EdgeInsets.all(16),
                  child: const Text('Not logged. Tap again.',
                      style: TextStyle(color: SunlightTokens.onDanger, fontSize: 22, fontWeight: FontWeight.w700)),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, 8, Bars.screenGutterDp, 8),
              child: RaceTimeAction(
                id: 'mark-undo-last',
                primary: true,
                child: SizedBox(
                  width: double.infinity,
                  height: Bars.minTargetDp,
                  child: ElevatedButton(
                    key: const ValueKey('mark-undo-last'),
                    onPressed: undo == null ? null : () => _append(undo),
                    child: FitLabel(undoLabel),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, 0, Bars.screenGutterDp, Bars.screenGutterDp),
              child: RaceTimeAction(
                id: 'mark-finish',
                primary: true,
                child: SizedBox(
                  width: double.infinity,
                  height: math.max(120, height * 0.3),
                  child: FilledButton(
                    key: const ValueKey('mark-finish'),
                    onPressed: shown == null ? null : () => _append(FinishEvents.atMark(fleet: fleet)),
                    style: FilledButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 44, fontWeight: FontWeight.w900, letterSpacing: 2),
                    ),
                    child: const FitLabel('FINISH'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The keypad's header while a sail number is typed for [e].
  String _sailTitle(FinishEntry? e) => e == null ? 'Sail' : 'Sail for #${e.place} · ${clockText(e.deviceTs!)}';
}

/// A single-fleet day's one button in the fleet row's place: FINISH HERE
/// makes the mark the finish, and FINISHING HERE, filled, says it is.
class _SingleFleetFinishHere extends StatelessWidget {
  const _SingleFleetFinishHere({required this.finishing, required this.onPressed});

  final bool finishing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = FitLabel(finishing ? 'FINISHING HERE' : 'FINISH HERE');
    const key = ValueKey('finish-here');
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, 8, Bars.screenGutterDp, 8),
          child: RaceTimeAction(
            id: 'finish-here',
            primary: true,
            child: SizedBox(
              width: double.infinity,
              height: Bars.minTargetDp,
              child: finishing
                  ? FilledButton(key: key, onPressed: onPressed, child: label)
                  : OutlinedButton(key: key, onPressed: onPressed, child: label),
            ),
          ),
        ),
        const Divider(height: 2, thickness: 2, color: SunlightTokens.mutedText),
      ],
    );
  }
}

/// [text] on one line, shrunk to fit its width rather than wrapped.
class _OneLine extends StatelessWidget {
  const _OneLine(this.text, {this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(text, maxLines: 1, softWrap: false, style: style),
      );
}

class _MarkFinishRow extends StatelessWidget {
  const _MarkFinishRow({required this.entry, required this.onSail});

  final FinishEntry entry;
  final VoidCallback onSail;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme.bodyLarge;
    final time = clockText(entry.deviceTs!);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Bars.screenGutterDp, vertical: 4),
      child: Row(
        children: [
          Expanded(
            // The line under the title says it once; each row says it to a
            // screen reader, which does not read that line with the row.
            child: Semantics(
              label: '${entry.place}, $time, elapsed pending reconciliation',
              excludeSemantics: true,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: Bars.minTargetDp),
                // Each on one line, shrunk to fit: at 200% text on a 393 dp
                // phone the time wrapped mid-number (the emulator render).
                child: Row(
                  children: [
                    SizedBox(width: 56, child: _OneLine('${entry.place}', style: text?.copyWith(fontWeight: FontWeight.w700))),
                    Expanded(child: _OneLine(time, style: text)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          RaceTimeAction(
            id: 'mark-sail',
            child: SizedBox(
              width: 132,
              height: Bars.minTargetDp,
              child: OutlinedButton(
                key: ValueKey('sail-${entry.ulid}'),
                onPressed: onSail,
                child: FitLabel(entry.sail ?? 'Sail #'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
