import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../fleets/fleet_picker_screen.dart';
import '../fleets/fleet_row.dart';
import '../shore/shore_status.dart';
import '../stations/station_screen.dart';
import '../ui/bars.dart';
import '../ui/clock.dart';
import '../ui/digit_keypad.dart';
import '../ui/fit_label.dart';
import '../ui/race_time.dart';
import '../ui/sunlight.dart';

/// Roundings (#54): a mark boat taps each boat as she rounds its station. The
/// boats this phone has logged today are a grid of their own, so a known boat
/// is ROUNDINGS on the home, then her number: 2 taps. UNKNOWN logs a boat the
/// operator could not identify, and her number is named later from the list
/// above, by a correction event. NEW BOAT types a number not yet in the grid.
///
/// On a day of several fleets the grid holds every fleet's known boats, a
/// section each, and a tap logs the boat with her own fleet: so every known
/// boat is 2 taps, whichever fleet the row shows (#54's review: a boat of
/// another fleet had been 3). The fleet row picks the fleet the list, UNKNOWN
/// and NEW BOAT are for.
///
/// Nothing in the grid moves between taps: the boats are in the order each
/// last rounded when the screen opened (oldest first, so a lap's boats come in
/// the order they came round on the one before), and a boat typed in joins
/// the end of her fleet's section. As the OCS panel (#29), after a grid that
/// reflowed on tap moved the next target.
///
/// The core stamps the station, the race and the boat's lap into each
/// rounding. The screen reads this phone's own events, as every race-time
/// screen does (#64), and one thing more: the day's fleets, which the PRO's
/// phone names and sync pulls down. A mark-boat phone names none of its own,
/// so without them every rounding on a day of several fleets would carry no
/// fleet (owner decision on #54's review escalation, 2026-10-27).
class RoundingScreen extends StatefulWidget {
  const RoundingScreen({
    super.key,
    required this.core,
    required this.confirmation,
    required this.mark,
    this.clock = systemClock,
  });

  final CoreClient core;
  final ConfirmationService confirmation;

  /// The phone's station. The core stamps it into every rounding.
  final String mark;

  /// The phone's clock: today is its local date.
  final int Function() clock;

  @override
  State<RoundingScreen> createState() => _RoundingScreenState();
}

/// What the keypad is typing for: a new boat, or the boat of one rounding.
sealed class _KeypadFor {
  const _KeypadFor();
}

class _NewBoat extends _KeypadFor {
  const _NewBoat();
}

class _Naming extends _KeypadFor {
  const _Naming(this.ulid);
  final String ulid;
}

class _RoundingScreenState extends State<RoundingScreen> {
  final _events = <EventEnvelope>[];
  bool _loaded = false;

  /// The last append did not log.
  bool _failed = false;

  /// The log could not be read, so the screen offers nothing to tap but
  /// RETRY: an empty grid would read as no boats yet, and a tap on it would
  /// log a rounding with no fleet (#54's review).
  bool _unreadable = false;

  /// A SAVE in flight: a second tap on it is the same tap (#54's review).
  bool _saving = false;

  /// The fleet shown, once the operator picks one on the row or taps one of
  /// its boats. A record, because the single-fleet day's fleet is null.
  ({String? fleet})? _chosen;

  /// The grid's sections, frozen the first time the grid is drawn.
  List<_GridSection>? _sections;

  _KeypadFor? _keypad;
  String _digits = '';

  int get _today => widget.clock();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final read = await Future.wait([widget.core.readAll(), widget.core.deviceId()]);
      final me = read[1] as String;
      if (!mounted) return;
      setState(() {
        _events
          ..clear()
          ..addAll((read[0] as List<EventEnvelope>).where((e) =>
              e.kind == FleetKinds.defined ||
              (e.deviceId == me &&
                  (RoundingKinds.all.contains(e.kind) ||
                      FleetKinds.all.contains(e.kind) ||
                      FinishKinds.all.contains(e.kind)))));
        _loaded = true;
        _unreadable = false;
      });
    } catch (_) {
      if (mounted) setState(() => _unreadable = true);
    }
  }

  /// The day's fleets: those defined on the phone's date of today, or every
  /// fleet the log holds when none was, as for a series named on its first
  /// day. Every day's would offer yesterday's fleets beside today's (#54's
  /// second review).
  List<Fleet> get _fleets {
    final today = DateTime.fromMillisecondsSinceEpoch(_today);
    bool onToday(EventEnvelope e) {
      final t = DateTime.fromMillisecondsSinceEpoch(e.deviceTs);
      return t.year == today.year && t.month == today.month && t.day == today.day;
    }

    final definedToday = [for (final e in _events) if (e.kind == FleetKinds.defined && onToday(e)) e];
    return fleets(definedToday.isEmpty ? _events : definedToday);
  }

  /// The fleet shown: the one picked or last tapped, else the fleet this
  /// phone last logged a rounding for here, else the day's first. Null on a
  /// single-fleet day.
  String? get _fleet {
    final chosen = _chosen;
    if (chosen != null) return chosen.fleet;
    final all = _fleets;
    if (all.isEmpty) return null;
    final ids = {for (final f in all) f.id};
    for (final e in _events.reversed) {
      if (e.kind == RoundingKinds.rounding && markOf(e) == widget.mark && ids.contains(fleetOf(e))) return fleetOf(e);
    }
    return all.first.id;
  }

  /// The grid's sections: each of the day's fleets with a known boat, in the
  /// order defined, then boats known with no fleet, or the one section of a
  /// single-fleet day. Frozen when first drawn; a boat typed in later joins
  /// only the last section, so no section above ever moves (#54's second
  /// review: a typed boat that wrapped a middle section pushed the ones below).
  List<_GridSection> get _gridSections {
    final all = _fleets;
    List<String> known(String? fleet) => knownRoundingSails(_events, fleet: fleet, day: _today);
    return _sections ??= all.isEmpty
        ? [_GridSection(null, known(null))]
        : [
            for (final f in [for (final f in all) f.id, null])
              if (known(f) case final sails when sails.isNotEmpty) _GridSection(f, sails),
          ];
  }

  /// Appends [event] and, once the core confirms it, shows it. A failed
  /// append shows "Not logged" and fires no confirmation. The stored event,
  /// or null when it was not logged.
  Future<EventEnvelope?> _append(NewEvent event) async {
    try {
      final stored = await widget.confirmation.confirm(() => widget.core.append(event));
      if (!mounted) return stored;
      setState(() {
        _events.add(stored);
        _failed = false;
      });
      return stored;
    } catch (_) {
      if (mounted) setState(() => _failed = true);
      return null;
    }
  }

  /// A rounding of [sail] (null for an unidentified boat) for [fleet]. The
  /// row moves to that fleet, so the list and UNDO LAST always show the boat
  /// just tapped (#54's second review: a tap into another fleet's section was
  /// shown nowhere, and UNDO LAST took back the shown fleet's instead).
  Future<void> _round(String? fleet, String? sail) async {
    _gridSections; // frozen before this rounding can change it
    if (_fleets.isNotEmpty) setState(() => _chosen = (fleet: fleet));
    await _append(RoundingEvents.rounding(fleet: fleet, sail: sail));
  }

  void _switch(String? fleet) => setState(() {
        _chosen = (fleet: fleet);
        _keypad = null;
      });

  Future<void> _pickFromAll(List<Fleet> all, String? current) async {
    final chosen = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => FleetPickerScreen(fleets: all, current: current, title: 'Roundings for', actionId: 'rounding-fleet'),
    ));
    if (chosen != null && mounted) _switch(chosen);
  }

  /// SAVE on the keypad: a new boat rounds now, or a rounding gets its
  /// boat's number.
  Future<void> _save() async {
    final keypad = _keypad;
    final digits = _digits;
    if (keypad == null || digits.isEmpty || _saving) return;
    final fleet = _fleet;
    _saving = true;
    try {
      switch (keypad) {
        case _NewBoat():
          final sections = _gridSections;
          if (await _append(RoundingEvents.rounding(fleet: fleet, sail: digits)) == null || !mounted) return;
          setState(() {
            final known = sections.any((s) => s.fleet == fleet && s.sails.contains(digits));
            if (!known) {
              if (sections.isNotEmpty && sections.last.fleet == fleet) {
                sections.last.sails.add(digits);
              } else {
                sections.add(_GridSection(fleet, [digits], added: true));
              }
            }
            _keypad = null;
            _digits = '';
          });
        case _Naming(:final ulid):
          if (await _append(RoundingEvents.assignSail(ulid, digits)) == null || !mounted) return;
          setState(() {
            _keypad = null;
            _digits = '';
          });
      }
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fleet = _fleet;
    final allFleets = _fleets;
    String? nameOf(String? id) => allFleets.where((f) => f.id == id).firstOrNull?.name;
    final fleetName = nameOf(fleet);
    final today = _today;
    final list = roundingsAt(_events, fleet: fleet, mark: widget.mark, day: today);
    final last = lastUndoableRounding(_events, fleet: fleet, mark: widget.mark, day: today);
    final lastAt = last == null ? null : list.indexWhere((r) => r.ulid == last.ulid) + 1;
    final keypad = _keypad;

    return Scaffold(
      // Nothing here is typed with the system keyboard (as the line's, #25).
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
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            ['Roundings at ${markName(widget.mark)}', ?fleetName, '${list.length}'].join(' · '),
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
                recent: const [],
                onSwitch: _switch,
                onMore: () => _pickFromAll(allFleets, fleet),
                actionId: 'rounding-fleet',
              ),
            Expanded(
              child: keypad != null
                  ? DigitKeypad(
                      title: switch (keypad) {
                        _NewBoat() => 'New boat',
                        _Naming(:final ulid) => _namingTitle(list, ulid),
                      },
                      display: _digits.isEmpty ? '—' : _digits,
                      onDigit: (d) => setState(() {
                        if (_digits.length < 7) _digits += d;
                      }),
                      onDelete: () =>
                          setState(() => _digits = _digits.isEmpty ? '' : _digits.substring(0, _digits.length - 1)),
                      onClose: () => setState(() {
                        _keypad = null;
                        _digits = '';
                      }),
                      onSave: _digits.isEmpty ? null : _save,
                    )
                  : _unreadable
                      ? _Unreadable(onRetry: _load)
                      : !_loaded
                      ? const Center(child: Text('Reading the log…'))
                      : Column(
                          children: [
                            Expanded(
                              flex: 2,
                              // Anchored at the bottom, newest last, just above
                              // the grid: a new rounding shows in the frame its
                              // tap is confirmed in, with no scroll to wait for
                              // (criterion 3's 100 ms).
                              child: ListView.builder(
                                key: const ValueKey('rounding-list'),
                                reverse: true,
                                itemCount: list.length,
                                itemBuilder: (context, i) {
                                  final at = list.length - 1 - i;
                                  return _RoundingRow(
                                    place: at + 1,
                                    entry: list[at],
                                    onSail: () => setState(() {
                                      _keypad = _Naming(list[at].ulid);
                                      _digits = list[at].sail ?? '';
                                    }),
                                  );
                                },
                              ),
                            ),
                            const Divider(height: 2, thickness: 2, color: SunlightTokens.mutedText),
                            Expanded(
                              flex: 3,
                              child: _BoatGrid(
                                sections: [
                                  for (final s in _gridSections)
                                    (
                                      fleet: s.fleet,
                                      // A heading on a day of fleets, the no-fleet
                                      // boats' too (#54's second review).
                                      name: allFleets.isEmpty
                                          ? null
                                          : [s.fleet == null ? 'No fleet' : nameOf(s.fleet) ?? 'Fleet', if (s.added) '(new)']
                                              .join(' '),
                                      sails: s.sails,
                                    ),
                                ],
                                onRound: _round,
                                onUnknown: () => _round(fleet, null),
                                onNew: _newBoat,
                              ),
                            ),
                          ],
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
              padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, 8, Bars.screenGutterDp, Bars.screenGutterDp),
              child: RaceTimeAction(
                id: 'rounding-undo-last',
                primary: true,
                child: SizedBox(
                  width: double.infinity,
                  height: Bars.minTargetDp,
                  child: ElevatedButton(
                    key: const ValueKey('rounding-undo-last'),
                    // At once, with no confirm dialog (criterion 5).
                    onPressed: last == null || _unreadable ? null : () => _append(RoundingEvents.undo(last.ulid)),
                    child: FitLabel(last == null ? 'Nothing to undo' : 'UNDO LAST (#$lastAt)'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _newBoat() => setState(() {
        _keypad = const _NewBoat();
        _digits = '';
      });

  String _namingTitle(List<RoundingEntry> list, String ulid) {
    final at = list.indexWhere((r) => r.ulid == ulid);
    return at < 0 ? 'Sail' : 'Sail for #${at + 1} · ${clockText(list[at].deviceTs)}';
  }
}

/// The log could not be read: say so, and offer to read it again.
class _Unreadable extends StatelessWidget {
  const _Unreadable({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(Bars.screenGutterDp),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('The log on this phone could not be read.',
                key: const ValueKey('rounding-unreadable'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: Bars.minTargetDp,
              child: OutlinedButton(
                key: const ValueKey('rounding-retry'),
                onPressed: onRetry,
                child: const FitLabel('RETRY'),
              ),
            ),
          ],
        ),
      );
}

/// One frozen section of the grid: a fleet's known boats (null for a
/// single-fleet day's, or boats known with no fleet), or, when [added], the
/// boats typed in for it after the grid was drawn.
class _GridSection {
  _GridSection(this.fleet, this.sails, {this.added = false});

  final String? fleet;
  final List<String> sails;
  final bool added;
}

/// One section as the grid draws it: its fleet, its heading (null on a
/// single-fleet day) and its boats.
typedef _Section = ({String? fleet, String? name, List<String> sails});

/// The boats to tap: UNKNOWN and NEW BOAT first, always in the same two cells,
/// then each fleet's known boats, under the fleet's name when the day has
/// several.
class _BoatGrid extends StatelessWidget {
  const _BoatGrid({required this.sections, required this.onRound, required this.onUnknown, required this.onNew});

  final List<_Section> sections;
  final void Function(String? fleet, String sail) onRound;
  final VoidCallback onUnknown;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    // Each says what a tap does: a number here logs a rounding, while the same
    // number in the list above changes one (the semantics tree, #54's audit).
    Widget cell(String id, Key key, String label, String spoken, VoidCallback onPressed, {bool outlined = false}) {
      final text = FitLabel(label, semanticsLabel: spoken);
      return RaceTimeAction(
        id: id,
        child: SizedBox(
          height: Bars.minTargetDp,
          child: outlined
              ? OutlinedButton(key: key, onPressed: onPressed, child: text)
              : FilledButton(key: key, onPressed: onPressed, child: text),
        ),
      );
    }

    SliverGrid grid(List<Widget> cells) => SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            mainAxisExtent: Bars.minTargetDp,
          ),
          delegate: SliverChildListDelegate(cells),
        );

    // UNKNOWN and NEW BOAT sit above the boats, out of their scroll: scrolled
    // down to a boat, they had gone with the boats (the emulator, #54).
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, Bars.screenGutterDp, Bars.screenGutterDp, 0),
          child: Row(
            children: [
              Expanded(
                child: cell('rounding-unknown', const ValueKey('rounding-unknown'), 'UNKNOWN',
                    'Unknown boat, log a rounding', onUnknown,
                    outlined: true),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: cell('rounding-type', const ValueKey('rounding-type'), 'NEW BOAT',
                    'New boat, type her sail number', onNew,
                    outlined: true),
              ),
            ],
          ),
        ),
        Expanded(child: _boats(context, cell, grid)),
      ],
    );
  }

  Widget _boats(
    BuildContext context,
    Widget Function(String id, Key key, String label, String spoken, VoidCallback onPressed, {bool outlined}) cell,
    SliverGrid Function(List<Widget> cells) grid,
  ) {
    return CustomScrollView(
      key: const ValueKey('rounding-grid'),
      slivers: [
        for (final s in sections) ...[
          if (s.name case final String name)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, 12, Bars.screenGutterDp, 0),
              sliver: SliverToBoxAdapter(
                child: Semantics(
                  header: true,
                  container: true,
                  child: Text(name, style: Theme.of(context).textTheme.titleMedium),
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, 8, Bars.screenGutterDp, 0),
            sliver: grid([
              for (final sail in s.sails)
                cell(
                  'rounding-boat',
                  ValueKey(s.fleet == null ? 'rounding-boat-$sail' : 'rounding-boat-${s.fleet}-$sail'),
                  sail,
                  [sail, ?s.name, 'log a rounding'].join(', '),
                  () => onRound(s.fleet, sail),
                ),
            ]),
          ),
        ],
        const SliverPadding(padding: EdgeInsets.only(bottom: Bars.screenGutterDp)),
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

class _RoundingRow extends StatelessWidget {
  const _RoundingRow({required this.place, required this.entry, required this.onSail});

  final int place;
  final RoundingEntry entry;
  final VoidCallback onSail;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme.bodyLarge;
    final time = clockText(entry.deviceTs);
    final lap = entry.lap == null ? null : 'lap ${entry.lap}';
    return Padding(
      key: ValueKey('rounding-${entry.ulid}'),
      padding: const EdgeInsets.symmetric(horizontal: Bars.screenGutterDp, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              label: [
                '$place',
                time,
                entry.sail == null ? 'boat not named' : 'sail ${entry.sail}',
                ?lap,
              ].join(', '),
              excludeSemantics: true,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: Bars.minTargetDp),
                child: Row(
                  children: [
                    SizedBox(width: 56, child: _OneLine('$place', style: text?.copyWith(fontWeight: FontWeight.w700))),
                    Expanded(child: _OneLine([time, ?lap].join(' · '), style: text)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          RaceTimeAction(
            id: 'rounding-sail',
            itemScoped: true,
            child: SizedBox(
              width: 132,
              height: Bars.minTargetDp,
              child: OutlinedButton(
                key: ValueKey('rounding-sail-${entry.ulid}'),
                onPressed: onSail,
                child: FitLabel(
                  entry.sail ?? 'Sail #',
                  semanticsLabel: entry.sail == null ? 'Name the boat for $place' : 'Change sail ${entry.sail} for $place',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
