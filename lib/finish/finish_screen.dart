import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../fleets/fleet_picker_screen.dart';
import '../fleets/fleet_row.dart';
import '../ui/bars.dart';
import '../ui/clock.dart';
import '../ui/digit_keypad.dart';
import '../ui/fit_label.dart';
import '../ui/race_time.dart';
import '../ui/sunlight.dart';

/// Finish capture (#4): one big tap per boat, confirmed by a buzz and a beep,
/// with undo instead of confirm prompts. FINISH is anchored at the bottom and
/// never moves or gets covered; the order runs above it, newest nearest the
/// button (owner's layout, 2026-09-24).
///
/// Fleets (#18): once fleets are named, a row of fleet buttons sits under the
/// title and one tap switches (owner's layout, 2026-09-24). The screen shows
/// the selected fleet's finishes only, each finish carries that fleet, and
/// right after a switch UNDO LAST takes the switch back.
class FinishScreen extends StatefulWidget {
  const FinishScreen({super.key, required this.core, required this.confirmation});

  final CoreClient core;
  final ConfirmationService confirmation;

  @override
  State<FinishScreen> createState() => _FinishScreenState();
}

class _FinishScreenState extends State<FinishScreen> {
  final _events = <EventEnvelope>[];
  final _scroll = ScrollController();
  bool _loaded = false;
  bool _failed = false;
  String? _deviceId;
  String? _expanded;
  String? _keypadFor;
  String _digits = '';

  @override
  void initState() {
    super.initState();
    Future.wait([widget.core.readAll(), widget.core.deviceId()]).then((r) {
      if (!mounted) return;
      setState(() {
        _events.addAll((r[0] as List<EventEnvelope>)
            .where((e) => FinishKinds.all.contains(e.kind) || FleetKinds.all.contains(e.kind)));
        _deviceId = r[1] as String;
        _loaded = true;
      });
      _scrollToNewest();
    }, onError: (Object _) {
      if (mounted) setState(() => _failed = true);
    });
  }

  /// The fleet this phone is finishing, or null on a single-fleet day.
  String? get _fleet => _deviceId == null ? null : selectedFleet(_events, _deviceId!);

  /// Switches this phone to [fleet]: one event, confirmed by a buzz and a
  /// beep. Tapping the fleet already selected does nothing.
  Future<void> _switchTo(String fleet) async {
    if (fleet == _fleet) return;
    await _append(FleetEvents.select(fleet));
  }

  List<String> _recentFleets() => _deviceId == null ? const [] : recentFleets(_events, _deviceId!);

  Future<void> _pickFromAll(List<Fleet> all) async {
    final chosen = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => FleetPickerScreen(fleets: all, current: _fleet),
    ));
    if (chosen != null && mounted) await _switchTo(chosen);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
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
        // A switch, or its undo, changes which fleet's list is showing; a row
        // or keypad open on the other list no longer means anything.
        if (FleetKinds.all.contains(event.kind)) {
          _expanded = null;
          _keypadFor = null;
        }
      });
      if (event.kind == FinishKinds.finish || FleetKinds.all.contains(event.kind)) _scrollToNewest();
      return true;
    } catch (_) {
      if (mounted) setState(() => _failed = true);
      return false;
    }
  }

  /// Saves the typed sail number, then walks on to the next finish in the
  /// order that has none, so naming a fleet after the rush is type, Save,
  /// type, Save (design-bar, owner 2026-09-24). A failed save stays put with
  /// the digits, for the retry.
  Future<void> _saveSail() async {
    final target = _keypadFor;
    if (target == null || _digits.isEmpty) return;
    if (!await _append(FinishEvents.assignSail(target, _digits)) || !mounted) return;
    final order = finishOrder(_events, fleet: _fleet);
    final at = order.indexWhere((e) => e.ulid == target);
    final next = order.skip(at + 1).where((e) => e.sail == null).firstOrNull;
    setState(() {
      _keypadFor = next?.ulid;
      _digits = '';
    });
  }

  /// The keypad's header while a sail number is typed for [e].
  String _sailTitle(FinishEntry? e) =>
      e == null ? 'Sail' : 'Sail for #${e.place} · ${e.missed ? 'missed' : clockText(e.deviceTs!)}';

  void _scrollToNewest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final fleet = _fleet;
    final allFleets = fleets(_events);
    final fleetName = allFleets.where((f) => f.id == fleet).firstOrNull?.name;
    final order = finishOrder(_events, fleet: fleet);
    final height = MediaQuery.sizeOf(context).height;

    // UNDO LAST takes back whichever came last: this fleet's last finish, or
    // the switch that made it this fleet.
    final lastFinish = lastUndoableFinish(_events, fleet: fleet);
    final lastSwitch = _deviceId == null ? null : lastFleetSwitch(_events, _deviceId!);
    final undoSwitch = lastSwitch != null && (lastFinish == null || happened(lastSwitch, lastFinish) > 0);
    final last = lastFinish?.ulid;
    final lastPlace = last == null ? null : order.where((e) => e.ulid == last).firstOrNull?.place;
    final NewEvent? undo = undoSwitch
        ? FleetEvents.undo(lastSwitch.ulid)
        : last == null
            ? null
            : FinishEvents.undo(last);
    final undoLabel = undoSwitch
        ? 'UNDO SWITCH (${fleetName ?? 'fleet'})'
        : last == null
            ? 'Nothing to undo'
            : 'UNDO LAST (#$lastPlace)';

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
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            fleetName == null ? 'Finishes · ${order.length}' : 'Finishes · $fleetName · ${order.length}',
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
                recent: _recentFleets(),
                onSwitch: _switchTo,
                onMore: () => _pickFromAll(allFleets),
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
                      onSave: _digits.isEmpty ? null : _saveSail,
                    )
                  : !_loaded && !_failed
                      ? const Center(child: Text('Reading the log…'))
                      : ListView.builder(
                          controller: _scroll,
                          itemCount: order.length,
                          itemBuilder: (context, i) => _FinishRow(
                            entry: order[i],
                            expanded: _expanded == order[i].ulid,
                            onTapRow: () => setState(
                                () => _expanded = _expanded == order[i].ulid ? null : order[i].ulid),
                            onSail: () => setState(() {
                              _expanded = null;
                              _keypadFor = order[i].ulid;
                              _digits = order[i].sail ?? '';
                            }),
                            onMissedAbove: () {
                              setState(() => _expanded = null);
                              _append(FinishEvents.missed(
                                fleet: fleet,
                                afterUlid: i == 0 ? null : order[i - 1].ulid,
                                beforeUlid: order[i].ulid,
                              ));
                            },
                            onUndo: () {
                              setState(() => _expanded = null);
                              _append(FinishEvents.undo(order[i].ulid));
                            },
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
                id: 'undo-last',
                primary: true,
                child: SizedBox(
                  width: double.infinity,
                  height: Bars.minTargetDp,
                  child: ElevatedButton(
                    onPressed: undo == null ? null : () => _append(undo),
                    child: FitLabel(undoLabel),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, 0, Bars.screenGutterDp, Bars.screenGutterDp),
              child: RaceTimeAction(
                id: 'finish',
                primary: true,
                child: SizedBox(
                  width: double.infinity,
                  height: math.max(120, height * 0.3),
                  child: FilledButton(
                    onPressed: () => _append(FinishEvents.finish(fleet: fleet)),
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
}

class _FinishRow extends StatelessWidget {
  const _FinishRow({
    required this.entry,
    required this.expanded,
    required this.onTapRow,
    required this.onSail,
    required this.onMissedAbove,
    required this.onUndo,
  });

  final FinishEntry entry;
  final bool expanded;
  final VoidCallback onTapRow;
  final VoidCallback onSail;
  final VoidCallback onMissedAbove;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme.bodyLarge;
    return Container(
      color: expanded ? SunlightTokens.surface : null,
      padding: const EdgeInsets.symmetric(horizontal: Bars.screenGutterDp, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  key: ValueKey('row-${entry.ulid}'),
                  onTap: () {
                    final opening = !expanded;
                    onTapRow();
                    // The bottom row's actions open below the fold; bring them
                    // into view, or reaching them would take a swipe
                    // (measured on the emulator with a full list).
                    if (opening) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (context.mounted) {
                          Scrollable.ensureVisible(
                            context,
                            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
                            duration: const Duration(milliseconds: 150),
                          );
                        }
                      });
                    }
                  },
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: Bars.minTargetDp),
                    child: Row(
                      children: [
                        SizedBox(width: 56, child: Text('${entry.place}', style: text?.copyWith(fontWeight: FontWeight.w700))),
                        Expanded(
                          child: Text(
                            entry.missed ? 'missed · time unknown' : clockText(entry.deviceTs!),
                            style: entry.missed ? text?.copyWith(color: SunlightTokens.mutedText, fontStyle: FontStyle.italic) : text,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              RaceTimeAction(
                id: 'sail',
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
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: RaceTimeAction(
                      id: 'missed-above',
                      itemScoped: true,
                      child: ElevatedButton(onPressed: onMissedAbove, child: const FitLabel('Missed above')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: RaceTimeAction(
                      id: 'undo-this',
                      itemScoped: true,
                      child: ElevatedButton(onPressed: onUndo, child: const FitLabel('Undo this')),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
