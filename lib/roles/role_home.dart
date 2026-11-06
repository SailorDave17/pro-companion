import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../finish/finish_screen.dart';
import '../finish/mark_finish_screen.dart';
import '../finish/volume_key.dart';
import '../fleets/fleets_screen.dart';
import '../log/log_screen.dart';
import '../results/results_screen.dart';
import '../rounding/rounding_screen.dart';
import '../running_order/running_order_screen.dart';
import '../sequence/sequence_screen.dart';
import '../shore/shore_status.dart';
import '../stations/mark_list_screen.dart';
import '../stations/station_screen.dart';
import '../ui/bars.dart';
import '../ui/clock.dart';
import '../ui/fill_or_scroll.dart';
import '../ui/fit_label.dart';
import '../ui/race_time.dart';
import '../ui/sunlight.dart';
import 'race_area.dart';
import 'roles.dart';

/// A role's home (#20): the role's name, UNDO ROLE, and the screens that
/// role's job needs, each one tap away ([homeActions]).
class RoleHome extends StatefulWidget {
  const RoleHome({
    super.key,
    required this.role,
    required this.core,
    required this.confirmation,
    required this.onUndo,
    this.notLogged = false,
    this.clock = systemClock,
    this.volumeKeys = const NoVolumeKeyCapture(),
  });

  final String role;
  final CoreClient core;
  final ConfirmationService confirmation;

  /// Takes the role pick back, which returns the phone to the picker.
  final VoidCallback onUndo;

  /// True when the last UNDO ROLE did not log.
  final bool notLogged;
  final int Function() clock;
  final VolumeKeyCapture volumeKeys;

  @override
  State<RoleHome> createState() => _RoleHomeState();
}

class _RoleHomeState extends State<RoleHome> {
  late Future<int> _count = _ownCount();

  /// How many events this phone logged: its own only, so another phone's
  /// events pulled down by sync (#64) never change the count.
  Future<int> _ownCount() => widget.core.readOwn().then((events) => events.length);

  // This phone's role, station (#26) and race-area (#74) picks, and their
  // undos: the station and the race area in force are each the latest pick
  // under the role pick this home is for. One read serves both.
  final _stationEvents = <EventEnvelope>[];
  String? _deviceId;
  bool _stationUnreadable = false;
  bool _stationNotLogged = false;
  bool _busy = false;

  // The race area (#74): what the phone's admission granted and the race
  // day's race areas, as sync kept them.
  RaceAreas _raceAreas = RaceAreas.none;
  ValueNotifier<RaceArea?>? _frame;

  String? get _course => _deviceId == null ? null : currentCourse(_raceAreas, _stationEvents, _deviceId!);

  // Every phone's mark lists (#78), read on a home with a station only: a
  // custom station is named by the list that sent it, which arrives by pull.
  final _markLists = <EventEnvelope>[];

  /// What [mark] is called, a custom one by the latest list naming it.
  String _markName(String mark) => markName(mark, customMarksEver(_markLists));

  Future<void> _readMarkLists() async {
    if (!homeActions(widget.role).contains(HomeAction.station)) return;
    try {
      final events = await widget.core.readAll();
      if (!mounted) return;
      setState(() => _markLists
        ..clear()
        ..addAll(events.where((e) => MarkListKinds.all.contains(e.kind))));
    } catch (_) {
      // A custom station then reads "Custom mark"; nothing else needs them.
    }
  }

  /// The race area in force, named, or null: never admitted, grant not known
  /// yet, nothing picked, or a race area sync has not named on this phone.
  RaceArea? get _area => _raceAreas.byId(_course);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _frame = RaceAreaFrame.notifierOf(context);
  }

  /// Tells the frame which race area every header shows. Every home sets it
  /// once it has read its own, null included, so a role's home never shows
  /// the last one's. Never cleared in dispose: a notifier fired while the tree
  /// is locked is an error (measured on #74's first run).
  void _publish() => _frame?.value = _area;

  @override
  void initState() {
    super.initState();
    widget.core.raceAreas().then((info) {
      if (!mounted) return;
      setState(() => _raceAreas = info);
      _publish();
    }, onError: (Object _) {
      // The home still works without it: the phone shows no race area, as a
      // phone never admitted does.
    });
    Future.wait([widget.core.readOwn(), widget.core.deviceId()]).then((r) {
      if (!mounted) return;
      setState(() {
        _stationEvents.addAll((r[0] as List<EventEnvelope>).where((e) =>
            RoleKinds.all.contains(e.kind) || StationKinds.all.contains(e.kind) || RaceAreaKinds.all.contains(e.kind)));
        _deviceId = r[1] as String;
      });
      _publish();
    }, onError: (Object _) {
      if (mounted) setState(() => _stationUnreadable = true);
    });
    _readMarkLists();
  }

  EventEnvelope? get _stationPick => _deviceId == null ? null : currentStationPick(_stationEvents, _deviceId!);

  Future<void> _open(Widget Function() screen) async {
    final result = await Navigator.of(context).push(MaterialPageRoute<Object?>(builder: (_) => screen()));
    if (mounted) {
      setState(() {
        _count = _ownCount();
        // The station screen pops with the pick it logged.
        if (result is EventEnvelope) {
          _stationEvents.add(result);
          _stationNotLogged = false;
        }
      });
      _readMarkLists();
    }
  }

  /// UNDO STATION: takes the station pick in force back at once, with no
  /// confirm dialog (#26 criterion 5). A failed undo says so here.
  Future<void> _undoStation(EventEnvelope pick) async {
    if (_busy) return;
    _busy = true;
    try {
      final stored = await widget.confirmation.confirm(() => widget.core.append(StationEvents.undo(pick.ulid)));
      if (!mounted) return;
      setState(() {
        _stationEvents.add(stored);
        _stationNotLogged = false;
        // The undo is an event too. The render showed the count one short.
        _count = _ownCount();
      });
    } catch (_) {
      if (mounted) setState(() => _stationNotLogged = true);
    } finally {
      _busy = false;
    }
  }

  /// RACE AREA (#74 criterion 2): the picker, for a phone admitted with an
  /// event-wide role. It pops with the pick it logged.
  Future<void> _pickRaceArea() async {
    final result = await Navigator.of(context).push(MaterialPageRoute<Object?>(
      builder: (_) => RaceAreaScreen(
        core: widget.core,
        confirmation: widget.confirmation,
        areas: _raceAreas.areas,
        current: _course,
      ),
    ));
    if (!mounted) return;
    setState(() {
      _count = _ownCount();
      if (result is EventEnvelope) _stationEvents.add(result);
    });
    _publish();
  }

  /// Where this phone works (#74): its race area, and RACE AREA where the
  /// phone picks one. Nothing on a phone never admitted, which has one
  /// implicit race area (criterion 4), and nothing while its grant is not
  /// known, since a bound phone must never be offered the picker.
  List<Widget> _raceArea() {
    if (!_raceAreas.granted) return const [];
    final area = _area;
    final course = _course;
    final status = area != null
        ? raceAreaLine(area)
        : course != null
            ? 'Race area · not named on this phone yet'
            : 'Race area · none picked';
    return [
      const SizedBox(height: 8),
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(status, key: const ValueKey('race-area-status'), style: Theme.of(context).textTheme.titleLarge),
      ),
      if (_raceAreas.picks) ...[
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: Bars.minTargetDp + 8,
          child: OutlinedButton(
            key: const ValueKey('race-area'),
            onPressed: _pickRaceArea,
            child: const FitLabel('RACE AREA'),
          ),
        ),
      ],
    ];
  }

  /// The mark boat's station: where the phone is, STATION to pick it, and
  /// UNDO STATION, which is there whether or not there is a pick to undo, so
  /// nothing moves when one is made.
  Widget _station() {
    final pick = _stationPick;
    final mark = pick == null ? null : markOf(pick);
    final status = _stationUnreadable
        ? 'The log on this phone could not be read'
        : _deviceId == null
            ? 'Reading the log…'
            : mark == null
                ? 'No station yet'
                : 'Station: ${_markName(mark)}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(status, key: const ValueKey('station-status'), style: Theme.of(context).textTheme.titleLarge),
        ),
        const SizedBox(height: 12),
        _big('STATION',
            () => StationScreen(core: widget.core, confirmation: widget.confirmation, current: mark, course: _course)),
        const SizedBox(height: 16),
        RaceTimeAction(
          id: 'station-undo',
          child: SizedBox(
            width: double.infinity,
            height: Bars.minTargetDp + 8,
            child: OutlinedButton(
              key: const ValueKey('undo-station'),
              onPressed: pick == null ? null : () => _undoStation(pick),
              child: const FitLabel('UNDO STATION'),
            ),
          ),
        ),
        if (_stationNotLogged)
          Semantics(
            liveRegion: true,
            child: Container(
              width: double.infinity,
              color: SunlightTokens.danger,
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(top: 12),
              child: const Text('Not logged. Tap again.',
                  style: TextStyle(color: SunlightTokens.onDanger, fontSize: 22, fontWeight: FontWeight.w700)),
            ),
          ),
      ],
    );
  }

  /// ROUNDINGS (#54): the rounding screen for the station in force. Off until
  /// the phone has one, since that station is the mark the boats round.
  Widget _roundings() {
    final pick = _stationPick;
    final mark = pick == null ? null : markOf(pick);
    return SizedBox(
      width: double.infinity,
      height: 96,
      child: ElevatedButton(
        key: const ValueKey('roundings'),
        onPressed: mark == null
            ? null
            : () => _open(() => RoundingScreen(
                  core: widget.core,
                  confirmation: widget.confirmation,
                  mark: mark,
                  markLabel: _markName(mark),
                  clock: widget.clock,
                )),
        child: const FitLabel('ROUNDINGS'),
      ),
    );
  }

  /// FINISH AT MARK (#30): the finish-at-mark screen for the station in
  /// force. Off until the phone has one, since that station is the mark the
  /// finishes are taken at.
  Widget _finishAtMark() {
    final pick = _stationPick;
    final mark = pick == null ? null : markOf(pick);
    return SizedBox(
      width: double.infinity,
      height: 96,
      child: ElevatedButton(
        key: const ValueKey('finish-at-mark'),
        onPressed: mark == null
            ? null
            : () => _open(() => MarkFinishScreen(
                core: widget.core, confirmation: widget.confirmation, mark: mark, markLabel: _markName(mark))),
        child: const FitLabel('FINISH AT MARK'),
      ),
    );
  }

  Widget _button(HomeAction action) => switch (action) {
        // Naming the day's fleets is set-up, done before racing (#18).
        HomeAction.fleets => _outlined(
            'FLEETS',
            () => FleetsScreen(
                core: widget.core, confirmation: widget.confirmation, course: _course, areas: _raceAreas.areas)),
        // The race area's custom marks (#78): set-up too, and off until the
        // phone works on a race area, since a list is sent to one.
        HomeAction.marks => SizedBox(
            width: double.infinity,
            height: Bars.minTargetDp + 8,
            child: OutlinedButton(
              key: const ValueKey('marks'),
              onPressed: _course == null
                  ? null
                  : () {
                      final course = _course!;
                      _open(() => MarkListScreen(core: widget.core, confirmation: widget.confirmation, course: course));
                    },
              child: const FitLabel('MARKS'),
            ),
          ),
        // The start, then the finishes: the order a race runs in (#25).
        HomeAction.sequence => _big('SEQUENCE', () => SequenceScreen(
              core: widget.core,
              confirmation: widget.confirmation,
              clock: widget.clock,
            )),
        HomeAction.finishes => _big('FINISHES', () => FinishScreen(
              core: widget.core,
              confirmation: widget.confirmation,
              volumeKeys: widget.volumeKeys,
            )),
        // Provisional results come after the finishes (#7).
        HomeAction.results =>
          _outlined('RESULTS', () => ResultsScreen(core: widget.core, confirmation: widget.confirmation)),
        // The other phones' logs, checked after racing or at a protest (#67).
        HomeAction.log => _outlined('LOG', () => LogScreen(core: widget.core)),
        HomeAction.station => _station(),
        HomeAction.roundings => _roundings(),
        HomeAction.finishAtMark => _finishAtMark(),
        // Every phone's roundings, followed live (#68).
        HomeAction.runningOrder =>
          _outlined('RUNNING ORDER',
              () => RunningOrderScreen(core: widget.core, clock: widget.clock, areas: _raceAreas.areas)),
      };

  Widget _big(String label, Widget Function() screen) => SizedBox(
        width: double.infinity,
        height: 96,
        child: ElevatedButton(onPressed: () => _open(screen), child: Text(label)),
      );

  Widget _outlined(String label, Widget Function() screen) => SizedBox(
        width: double.infinity,
        height: Bars.minTargetDp + 8,
        // Shrunk to fit, never wrapped: RUNNING ORDER at 200% on a 320 dp phone.
        child: OutlinedButton(onPressed: () => _open(screen), child: FitLabel(label)),
      );

  @override
  Widget build(BuildContext context) {
    // MARKS only on an admitted phone (#78): a phone never admitted has one
    // implicit race area, and no mark boat elsewhere to send a list to.
    final actions = [
      for (final a in homeActions(widget.role))
        if (a != HomeAction.marks || _raceAreas.granted) a,
    ];
    // What this phone has sent, and what waits (#66): below the role's own
    // buttons, so none of them moves. Above them it pushed LOG below the fold
    // at 100% text on the 320 x 640 phone, and RESULTS at 200% (owner's
    // choice at #66's build).
    final shore = ShoreIndicator(core: widget.core, clock: widget.clock, wide: true);
    return Scaffold(
      // A home has nothing to type into. Back from FLEETS the keyboard is
      // still up while it lays out, and on a 320 x 640 phone the buttons did
      // not fit in what it left (#25, PR #94's emulator job).
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: FillOrScroll(
          children: [
            const SizedBox.shrink(),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // One line each, shrunk to fit: wrapped at 200% text, these
                // took the room the buttons need on a short phone (#25).
                Semantics(
                  header: true,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(roleName(widget.role), style: Theme.of(context).textTheme.headlineMedium),
                  ),
                ),
                const SizedBox(height: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: FutureBuilder<int>(
                    future: _count,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) return const Text('The log on this phone could not be read');
                      final n = snapshot.data;
                      if (n == null) return const Text('Reading the log…');
                      return Text('$n ${n == 1 ? 'event' : 'events'} on this phone');
                    },
                  ),
                ),
                ..._raceArea(),
                const SizedBox(height: 16),
                // Away from the thumb's path to the role's own buttons below,
                // and undone at once, with no confirm dialog (#20 criterion 6).
                SizedBox(
                  width: double.infinity,
                  height: Bars.minTargetDp + 8,
                  child: OutlinedButton(
                    key: const ValueKey('undo-role'),
                    onPressed: widget.onUndo,
                    child: const FitLabel('UNDO ROLE'),
                  ),
                ),
                if (widget.notLogged)
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      width: double.infinity,
                      color: SunlightTokens.danger,
                      padding: const EdgeInsets.all(16),
                      margin: const EdgeInsets.only(top: 12),
                      child: const Text('Not logged. Tap again.',
                          style: TextStyle(color: SunlightTokens.onDanger, fontSize: 22, fontWeight: FontWeight.w700)),
                    ),
                  ),
              ],
            ),
            if (actions.isEmpty) ...[
              Text('No actions for this role yet.',
                  textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
              shore,
            ] else
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(height: 16),
                    _button(actions[i]),
                  ],
                  const SizedBox(height: 16),
                  shore,
                ],
              ),
          ],
        ),
      ),
    );
  }
}
