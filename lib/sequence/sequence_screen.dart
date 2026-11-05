import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../fleets/fleet_picker_screen.dart';
import '../fleets/fleet_row.dart';
import '../roles/race_area.dart';
import '../shore/shore_status.dart';
import '../ui/bars.dart';
import '../ui/clock.dart';
import '../ui/digit_keypad.dart';
import '../ui/fit_label.dart';
import '../ui/race_time.dart';
import '../ui/sunlight.dart';
import 'link_banner.dart';
import 'ocs_panel.dart';

/// How long a race-timer gun can reach the phone after it fired before the
/// card says when it arrived. Normally it is milliseconds.
const _lateAfterMs = 2000;

/// The sequence card (#25): the selected fleet's start, logged by hand when
/// race-timer is not running. That is ADR 001's fallback, marked
/// `source: manual` so a protest committee can tell a hand-tapped gun from
/// race-timer's.
///
/// With race-timer running, its signals land in the log by themselves (#33).
/// The core has no way to tell a screen, so the card re-reads the log every
/// few seconds, as the shore chip does. A banner says when nothing has come
/// from race-timer for ten minutes, and the manual controls stay where they
/// are. The fleet selected here is the fleet the next sequence arms to, and
/// UNDO, then a fleet, moves a sequence that landed on the wrong one.
///
/// Laid out like the finish screen (owner's choice, 2026-09-25): the fleet
/// row under the title, GUN anchored big at the bottom where it never moves,
/// and UNDO LAST above it. A gun, a postponement and a general recall are each
/// their own row in the log. A late or wrong gun is fixed by tapping it and
/// typing the time it really went (owner's choice, 2026-09-25): a correction
/// event, with the gun kept as it was tapped.
///
/// Boats over early at the gun (#29): INDIVIDUAL RECALL logs the recall
/// against the start, and OCS opens [OcsPanel] in the card's place, where each
/// boat over is logged by her sail number and cleared when she comes back.
class SequenceScreen extends StatefulWidget {
  const SequenceScreen({
    super.key,
    required this.core,
    required this.confirmation,
    this.clock = systemClock,
    this.every = const Duration(seconds: 5),
  });

  final CoreClient core;
  final ConfirmationService confirmation;

  /// The phone's clock: a gun's typed time may not be later than now, and the
  /// link's quiet time is counted on it.
  final int Function() clock;

  /// How often the log is read for what race-timer sent.
  final Duration every;

  @override
  State<SequenceScreen> createState() => _SequenceScreenState();
}

class _SequenceScreenState extends State<SequenceScreen> {
  final _events = <EventEnvelope>[];

  /// Every event held, since a read and an append can each bring the same one.
  final _held = <String>{};
  bool _loaded = false;
  bool _failed = false;
  String? _deviceId;

  /// Whether race-timer has reached this phone lately, as of the last read.
  bool _linkUp = false;
  Timer? _timer;
  bool _reading = false;
  bool _current = true;

  /// The gun whose time is being typed, or null while the keypad is shut.
  String? _fixing;
  String _digits = '';

  /// The gun the OCS panel is open for, or null while it is shut.
  String? _ocsFor;

  /// True while a sail number is typed on the OCS panel's keypad.
  bool _typingSail = false;
  String _sailDigits = '';

  /// The OCS boat selected to be cleared.
  String? _ocsSelected;

  /// The boats the OCS panel shows, in the order it opened with. It is held
  /// for as long as the panel is open, so a boat logged never moves another.
  List<String> _ocsOrder = const [];

  @override
  void initState() {
    super.initState();
    _firstRead().catchError((Object _) {
      if (mounted) setState(() => _failed = true);
    });
    _timer = Timer.periodic(widget.every, (_) {
      if (_current) _readLog();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    // Back on top: what arrived behind the screen it opened is read now.
    if (current && !_current) _readLog();
    _current = current;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Takes in what this screen reads, and returns whether any of it is new.
  /// Finishes too: their sail numbers are the boats the OCS panel knows.
  bool _hold(Iterable<EventEnvelope> events) {
    var fresh = false;
    for (final e in events) {
      final shown = StartKinds.all.contains(e.kind) || FleetKinds.all.contains(e.kind) || FinishKinds.all.contains(e.kind);
      if (shown && _held.add(e.ulid)) {
        _events.add(e);
        fresh = true;
      }
    }
    return fresh;
  }

  bool _linkIsUp() {
    final deviceId = _deviceId;
    return deviceId != null && linkActive(_events, deviceId: deviceId, now: widget.clock());
  }

  Future<void> _firstRead() async {
    final r = await Future.wait([widget.core.readOwn(), widget.core.deviceId()]);
    if (!mounted) return;
    setState(() {
      _hold(r[0] as List<EventEnvelope>);
      _deviceId = r[1] as String;
      _loaded = true;
      _linkUp = _linkIsUp();
    });
  }

  /// What race-timer sent since the last read. It was confirmed when the core
  /// stored it, with this screen shut or open, so nothing fires here. A failed
  /// read leaves the card as it was and says nothing: "Not logged" means a tap
  /// that did not land. The one exception is the screen's first read, which
  /// the timer retries until it lands, since the card has nothing to show
  /// until then, and that clears what the failure raised.
  Future<void> _readLog() async {
    if (_reading) return;
    _reading = true;
    try {
      if (!_loaded) {
        await _firstRead();
        if (mounted && _loaded) setState(() => _failed = false);
        return;
      }
      final own = await widget.core.readOwn();
      if (!mounted) return;
      final fresh = _hold(own);
      final linkUp = _linkIsUp();
      if (fresh || linkUp != _linkUp) {
        setState(() {
          _linkUp = linkUp;
        });
      }
    } catch (_) {
      // The next tick tries again.
    } finally {
      _reading = false;
    }
  }

  /// The fleet this phone is starting, or null on a single-fleet day.
  String? get _fleet => _deviceId == null ? null : selectedFleet(_events, _deviceId!);

  Future<void> _switchTo(String fleet) async {
    if (fleet == _fleet) return;
    await _append(FleetEvents.select(fleet));
  }

  Future<void> _pickFromAll(List<Fleet> all) async {
    final chosen = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => FleetPickerScreen(fleets: all, current: _fleet),
    ));
    if (chosen != null && mounted) await _switchTo(chosen);
  }

  /// Appends [event] and, once the core confirms it, shows it. A failed
  /// append shows "Not logged" and fires no confirmation, and leaves the
  /// keypad as it was for the retry. Anything logged shuts the time keypad:
  /// the gun it was fixing may no longer be the one that anchors. The OCS
  /// panel stays open for the next boat, and shows only while its gun
  /// anchors.
  Future<void> _append(NewEvent event) async {
    try {
      final stored = await widget.confirmation.confirm(() => widget.core.append(event));
      if (!mounted) return;
      _appended([stored]);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _appended(List<EventEnvelope> stored) => setState(() {
        _hold(stored);
        _failed = false;
        _fixing = null;
        _digits = '';
        _sailDigits = '';
        _ocsSelected = null;
      });

  /// UNDO, or the card, on a race-timer sequence: the first tap opens the
  /// fleets and writes nothing, so Back is a true cancel, and the pick does
  /// everything in one commit, with one confirmation (owner decisions on #33).
  /// The core works it out from the log at that moment, so signals that arrive
  /// behind the picker move too. Picking the fleet it is on logs nothing. From
  /// the card, [gun] is the race-timer gun it shows, and the picker offers its
  /// time fix too, since the card is where that lives.
  Future<void> _fixSequence(EventEnvelope event, List<Fleet> all, String? fleet, {EventEnvelope? gun}) async {
    final sequence = event.payload[linkSequenceKey] as String;
    final chosen = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => FleetPickerScreen(
        fleets: all,
        current: fleet,
        title: 'Right fleet',
        actionId: 'sequence-fleet',
        itemScoped: true,
        offerTimeFix: gun != null,
        offerTakeBack: true,
      ),
    ));
    if (chosen == FleetPickerScreen.fixTime) {
      if (mounted && gun != null) {
        setState(() {
          _fixing = gun.ulid;
          _digits = '';
        });
      }
      return;
    }
    if (chosen == null || chosen == fleet || !mounted) return;
    try {
      final stored = await widget.confirmation.confirm(() => chosen == FleetPickerScreen.takeBack
          ? widget.core.takeBackSequence(sequence)
          : widget.core.relogSequence(sequence, chosen));
      if (mounted) _appended(stored);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _openOcs(EventEnvelope gun) => setState(() {
        _ocsFor = gun.ulid;
        _ocsOrder = knownSails(_events, fleet: _fleet, day: gunTime(_events, gun));
        _typingSail = false;
        _sailDigits = '';
        _ocsSelected = null;
      });

  /// The OCS panel for [gun], or its keypad while a sail number is typed.
  Widget _ocs(EventEnvelope gun, String? fleet) {
    final over = ocsAt(_events, gun);
    final logged = {for (final o in over) o.sail};
    if (_typingSail) {
      final already = logged.contains(_sailDigits);
      return DigitKeypad(
        title: 'OCS sail · gun ${clockText(gunTime(_events, gun))}',
        display: _sailDigits.isEmpty
            ? '—'
            : already
                ? '$_sailDigits · already logged'
                : _sailDigits,
        onDigit: (d) => setState(() {
          if (_sailDigits.length < 7) _sailDigits += d;
        }),
        onDelete: () => setState(
            () => _sailDigits = _sailDigits.isEmpty ? '' : _sailDigits.substring(0, _sailDigits.length - 1)),
        // Back to the panel. Boats saved on the way stay saved.
        onClose: () => setState(() {
          _typingSail = false;
          _sailDigits = '';
        }),
        onSave: _sailDigits.isEmpty || already
            ? null
            : () => _append(StartEvents.ocs(gun.ulid, fleet: fleet, sail: _sailDigits)),
      );
    }
    final selected = over.where((o) => o.ulid == _ocsSelected && !o.cleared).firstOrNull;
    return OcsPanel(
      gunAt: gunTime(_events, gun),
      // A boat over that the panel did not open with - typed, or arrived
      // since - joins the end, where she moves no other boat.
      boats: {..._ocsOrder, ...logged}.toList(),
      over: over,
      selected: selected,
      onSail: (sail) => _append(StartEvents.ocs(gun.ulid, fleet: fleet, sail: sail)),
      onSelect: (o) => setState(() => _ocsSelected = o.ulid == _ocsSelected ? null : o.ulid),
      onClear: () {
        if (selected != null) _append(StartEvents.clearOcs(selected.ulid));
      },
      onType: () => setState(() {
        _typingSail = true;
        _sailDigits = '';
      }),
      onClose: () => setState(() => _ocsFor = null),
    );
  }

  /// The digits typed so far as HH:MM:SS, a blank for each still to come.
  String _typedClock() {
    final d = _digits.padRight(6, '_');
    return '${d.substring(0, 2)}:${d.substring(2, 4)}:${d.substring(4, 6)}';
  }

  /// The typed time on [gun]'s own day, or why it cannot be saved. Both null
  /// until all six digits are in.
  ({int? time, String? problem}) _typedTime(EventEnvelope gun) {
    if (_digits.length < 6) return (time: null, problem: null);
    final h = int.parse(_digits.substring(0, 2));
    final m = int.parse(_digits.substring(2, 4));
    final s = int.parse(_digits.substring(4, 6));
    if (h > 23 || m > 59 || s > 59) return (time: null, problem: 'not a time');
    final day = DateTime.fromMillisecondsSinceEpoch(firedAt(gun));
    final time = DateTime(day.year, day.month, day.day, h, m, s).millisecondsSinceEpoch;
    if (time > widget.clock()) return (time: null, problem: 'later than now');
    return (time: time, problem: null);
  }

  Widget _keypad(EventEnvelope gun) {
    final typed = _typedTime(gun);
    final now = gunTime(_events, gun);
    final fired = firedAt(gun);
    final origin = gun.source == raceTimerSource ? 'race-timer' : 'tapped';
    return DigitKeypad(
      title: now == fired
          ? 'Fix gun · $origin ${clockText(fired)}'
          : 'Fix gun ${clockText(now)} · $origin ${clockText(fired)}',
      display: typed.problem == null ? _typedClock() : '${_typedClock()} · ${typed.problem}',
      onDigit: (d) => setState(() {
        if (_digits.length < 6) _digits += d;
      }),
      onDelete: () => setState(() => _digits = _digits.isEmpty ? '' : _digits.substring(0, _digits.length - 1)),
      onClose: () => setState(() {
        _fixing = null;
        _digits = '';
      }),
      onSave: typed.time == null ? null : () => _append(StartEvents.correctTime(gun.ulid, time: typed.time!)),
    );
  }

  /// The name race-timer gave [event]'s sequence, or null.
  String? _sequenceName(EventEnvelope event) {
    for (final e in _events) {
      if (e.kind == StartKinds.sequenceStart && e.payload[linkSequenceKey] == event.payload[linkSequenceKey]) {
        final name = (e.payload[linkFieldsKey] as Map)['sequence_name'];
        if (name is String) return name;
      }
    }
    return null;
  }

  /// UNDO LAST's label for [target], the event it would take back.
  String _undoLabel(EventEnvelope? target) => switch (target?.kind) {
        null => 'Nothing to undo',
        StartKinds.start => 'UNDO GUN (${clockText(gunTime(_events, target!))})',
        StartKinds.postponement => 'UNDO POSTPONE',
        StartKinds.generalRecall => 'UNDO RECALL',
        StartKinds.timeCorrected => 'UNDO TIME FIX',
        StartKinds.individualRecall => 'UNDO INDIVIDUAL RECALL',
        StartKinds.ocs => 'UNDO OCS (${target!.payload['sail']})',
        StartKinds.ocsCleared =>
          'UNDO CLEARED (${_events.where((e) => e.ulid == target!.correctsUlid).firstOrNull?.payload['sail'] ?? '?'})',
        _ => 'UNDO LAST',
      };

  @override
  Widget build(BuildContext context) {
    final fleet = _fleet;
    final allFleets = fleets(_events);
    final fleetName = allFleets.where((f) => f.id == fleet).firstOrNull?.name;
    final anchor = elapsedAnchor(_events, fleet);
    final latest = sequenceOf(_events, fleet).lastOrNull;
    // The keypad shows only while the gun it opened for still anchors. That
    // is a spare: _append already shuts it on anything logged, and a test
    // deleting either one alone stays green; deleting both reddens (#25).
    final fixing = anchor != null && anchor.ulid == _fixing ? anchor : null;
    // The OCS panel likewise shows only while its gun anchors: a new gun, a
    // recall or a fleet switch puts the card back.
    final ocsFor = anchor != null && anchor.ulid == _ocsFor ? anchor : null;
    final stillOver = anchor == null ? 0 : ocsAt(_events, anchor).where((o) => !o.cleared).length;
    final height = MediaQuery.sizeOf(context).height;
    // Only once the log is read, or a phone mid-sequence flashes it on opening.
    final showBanner = _loaded && !_linkUp;

    // UNDO LAST takes back whichever came last: this fleet's last sequence
    // event, or the switch that made it this fleet - as on the finish screen.
    final lastStart = lastUndoableStart(_events, fleet: fleet);
    final lastSwitch = _deviceId == null ? null : lastFleetSwitch(_events, _deviceId!);
    final undoSwitch = lastSwitch != null && (lastStart == null || happened(lastSwitch, lastStart) > 0);
    final NewEvent? undo = undoSwitch
        ? FleetEvents.undo(lastSwitch.ulid)
        : lastStart == null
            ? null
            : StartEvents.undo(lastStart.ulid);
    final undoLabel = undoSwitch ? 'UNDO SWITCH (${fleetName ?? 'fleet'})' : _undoLabel(lastStart);

    // UNDO on a race-timer event takes in its whole sequence, because what is
    // wrong with it is its fleet (#33). With no fleets, nothing can be
    // misattributed, so UNDO goes on taking back one event at a time. The
    // PRO's own tap on this card is undone first, but the switch here is not:
    // a wrong fleet is often noticed after the phone has moved on, so a fleet
    // holding a sequence offers its fix, and a mis-tapped switch is undone
    // from the fleet row (owner decision on #33).
    // By when each fired, not when each arrived: a backlog race-timer resent
    // out of order must not put an earlier race back (#33's review).
    final lastLink = lastRaceTimerEvent(_events, fleet: fleet);
    final fixable =
        allFleets.isNotEmpty && lastLink != null && (lastStart == null || onTheWater(lastLink, lastStart) >= 0)
            ? lastLink
            : null;
    // A countdown under way. Its gun is still to come, so the anchor still
    // standing is the last race's, and it is not what the card should offer.
    // One race-timer stopped sending partway through is over once the link
    // goes quiet: nothing on a day with no fleets could otherwise end it.
    final running = _linkUp &&
            lastLink != null &&
            (lastLink.kind == StartKinds.sequenceStart || lastLink.kind == StartKinds.signal) &&
            (latest == null || onTheWater(lastLink, latest) > 0) &&
            (anchor == null || anchor.payload[linkSequenceKey] != lastLink.payload[linkSequenceKey])
        ? lastLink
        : null;
    // What the card shows came from race-timer: on a day with fleets, the card
    // opens the right-fleet picker, with the gun's time fix as one of its rows,
    // so a sequence on the wrong fleet is two taps from the card whatever was
    // tapped since. UNDO still takes back one tap at a time (owner decision at
    // #33's review).
    final shown = running ?? anchor ?? latest;
    final cardLink =
        allFleets.isNotEmpty && shown != null && shown.source == raceTimerSource && shown.payload[linkSequenceKey] is String
            ? shown
            : null;

    return Scaffold(
      // Nothing here is typed with the system keyboard, as on FINISHES: back
      // from FLEETS it is still up while this screen lays out, and on a
      // 320 x 640 phone the fixed rows overflowed what it left (PR #94).
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        toolbarHeight: 72,
        leadingWidth: 80,
        actions: [ShoreIndicator(core: widget.core, clock: widget.clock)],
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
            child: Text(
              fleetName == null ? 'Sequence' : 'Sequence · $fleetName',
              style: Theme.of(context).textTheme.titleLarge,
            ),
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
                recent: _deviceId == null ? const [] : recentFleets(_events, _deviceId!),
                onSwitch: _switchTo,
                onMore: () => _pickFromAll(allFleets),
              ),
            Expanded(
              child: fixing != null
                  ? _keypad(fixing)
                  : ocsFor != null
                      ? _ocs(ocsFor, fleet)
                      : !_loaded && !_failed
                      ? const Center(child: Text('Reading the log…'))
                      // Room to scroll, never to overflow: on a short phone at
                      // 200% text, with "Not logged" up, the card and the
                      // buttons do not fit. The inset keeps every target off
                      // the scrollable's edges, where the bar check's
                      // tap-target guideline would skip it.
                      : LayoutBuilder(
                          builder: (context, box) => SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, 12, Bars.screenGutterDp, 4),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(minHeight: math.max(0, box.maxHeight - 16)),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  // One child of one height whether the banner
                                  // shows or not: this Column spaces its children
                                  // out, so an extra one would move every row.
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (showBanner) const LinkBanner(),
                                      _StartCard(
                                        height: _StartCard.fullHeight - (showBanner ? LinkBanner.height : 0),
                                        anchor: anchor,
                                        anchorAt: anchor == null ? null : gunTime(_events, anchor),
                                        latest: latest,
                                        running: running,
                                        sequenceName: running == null ? null : _sequenceName(running),
                                        individualRecall:
                                            anchor != null && individualRecallsOf(_events, anchor).isNotEmpty,
                                        onFix: anchor == null || running != null || cardLink != null
                                            ? null
                                            : () => setState(() {
                                                  _fixing = anchor.ulid;
                                                  _digits = '';
                                                }),
                                        onFleet: cardLink == null
                                            ? null
                                            : () => _fixSequence(cardLink, allFleets, fleet,
                                                gun: cardLink == anchor ? anchor : null),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: RaceTimeAction(
                                          id: 'postpone',
                                          child: SizedBox(
                                            height: Bars.minTargetDp + 8,
                                            child: OutlinedButton(
                                              onPressed: () =>
                                                  _append(StartEvents.postponement(fleet: fleet, source: 'manual')),
                                              child: const FitLabel('POSTPONE'),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: RaceTimeAction(
                                          id: 'general-recall',
                                          child: SizedBox(
                                            height: Bars.minTargetDp + 8,
                                            child: OutlinedButton(
                                              onPressed: () =>
                                                  _append(StartEvents.generalRecall(fleet: fleet, source: 'manual')),
                                              child: const FitLabel('GENERAL RECALL'),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  // Both need a gun to name, so neither does
                                  // anything before the first or after a
                                  // general recall (#29), or during a
                                  // countdown, when the gun still anchoring
                                  // is the last race's (#33).
                                  Row(
                                    children: [
                                      Expanded(
                                        child: RaceTimeAction(
                                          id: 'individual-recall',
                                          child: SizedBox(
                                            height: Bars.minTargetDp + 8,
                                            child: OutlinedButton(
                                              onPressed: anchor == null || running != null
                                                  ? null
                                                  : () => _append(StartEvents.individualRecall(anchor.ulid,
                                                      fleet: fleet, source: 'manual')),
                                              child: const FitLabel('INDIVIDUAL RECALL'),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: RaceTimeAction(
                                          id: 'ocs',
                                          child: SizedBox(
                                            height: Bars.minTargetDp + 8,
                                            child: OutlinedButton(
                                              onPressed:
                                                  anchor == null || running != null ? null : () => _openOcs(anchor),
                                              child: FitLabel(stillOver == 0 ? 'OCS' : 'OCS · $stillOver'),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
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
                  // One line at any text size: wrapped at 200%, it took the
                  // room the card and its buttons need (#25).
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text('Not logged. Tap again.',
                        maxLines: 1,
                        style: TextStyle(color: SunlightTokens.onDanger, fontSize: 22, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, 8, Bars.screenGutterDp, 8),
              child: RaceTimeAction(
                id: 'sequence-undo',
                primary: true,
                child: SizedBox(
                  width: double.infinity,
                  height: Bars.minTargetDp,
                  child: ElevatedButton(
                    onPressed: fixable != null
                        ? () => _fixSequence(fixable, allFleets, fleet)
                        : undo == null
                            ? null
                            : () => _append(undo),
                    child: FitLabel(fixable == null
                        ? undoLabel
                        : fleetName == null
                            ? 'UNDO SEQUENCE'
                            : 'UNDO SEQUENCE ($fleetName)'),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, 0, Bars.screenGutterDp, Bars.screenGutterDp),
              child: RaceTimeAction(
                id: 'gun',
                primary: true,
                child: SizedBox(
                  width: double.infinity,
                  height: math.max(120, height * 0.3),
                  child: FilledButton(
                    onPressed: () => _append(StartEvents.start(fleet: fleet, source: 'manual')),
                    style: FilledButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 44, fontWeight: FontWeight.w900, letterSpacing: 2),
                    ),
                    child: const FitLabel('GUN'),
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

/// What the selected fleet's start stands at: the gun that anchors its
/// elapsed time, or why there is none. With a gun, the card is the way to fix
/// its time, so it is a button; without one there is nothing to fix. What
/// race-timer sent can also be on the wrong fleet, so on a day with fleets its
/// card opens the right-fleet picker, gun or not, and the time fix is a row
/// there (#33).
class _StartCard extends StatelessWidget {
  const _StartCard({
    required this.height,
    required this.anchor,
    required this.anchorAt,
    required this.latest,
    required this.running,
    required this.sequenceName,
    required this.individualRecall,
    required this.onFix,
    required this.onFleet,
  });

  static const fullHeight = Bars.minTargetDp + 32;

  /// [fullHeight], less what the link banner above it takes, so that the
  /// buttons below stay where they are when the banner comes and goes.
  final double height;
  final EventEnvelope? anchor;

  /// The anchor's gun time, corrected if it has been.
  final int? anchorAt;

  /// The fleet's latest sequence event, not undone.
  final EventEnvelope? latest;

  /// race-timer's latest signal of a sequence with no gun yet, the fleet it is
  /// counting down for (#33): the card's only sign, before the gun, that a
  /// sequence landed on the wrong fleet.
  final EventEnvelope? running;

  /// [running]'s sequence, as race-timer named it.
  final String? sequenceName;

  /// True once an individual recall of the anchor is logged (#29).
  final bool individualRecall;
  final VoidCallback? onFix;

  /// Opens the right-fleet picker, when what the card shows came from
  /// race-timer on a day with fleets. The picker holds the gun's time fix, so
  /// the card is then not the `fix-gun-time` action itself.
  final VoidCallback? onFleet;

  /// Where [gun]'s time came from, and how it reached the phone. A gun's time
  /// is its own: race-timer's or a tap's, unless typed over. Every race-timer
  /// gun reaches the phone a little after it fired, so that is said only when
  /// it was late, and the word `race-timer` is always there for a protest.
  List<String> _gunOrigin(EventEnvelope gun) {
    final fired = firedAt(gun);
    if (gun.source != raceTimerSource) return [if (anchorAt != fired) 'tapped ${clockText(fired)}'];
    final received = gun.payload[linkReceivedKey];
    return [
      anchorAt == fired ? 'race-timer' : 'race-timer ${clockText(fired)}',
      if (received is int && received - fired >= _lateAfterMs) 'received ${clockText(received)}',
    ];
  }

  @override
  Widget build(BuildContext context) {
    final last = latest;
    final signal = running;
    // The headline and this line shrink together to fit, so a longer line
    // makes the time a PRO reads in glare smaller. Only a gun's card says it
    // fixes the fleet, in fewer words than it had: before the gun, after a
    // recall and while postponed, UNDO names the fix too (#33's review).
    final (String headline, String detail) = switch (anchor) {
      _ when signal != null => (
          sequenceName == null ? 'SEQUENCE' : 'SEQUENCE $sequenceName',
          [
            'race-timer',
            if ((signal.payload[linkFieldsKey] as Map)['signal'] case final String name) name,
            clockText(firedAt(signal)),
          ].join(' · '),
        ),
      final EventEnvelope gun => (
          'GUN ${clockText(anchorAt!)}',
          [
            ..._gunOrigin(gun),
            if (last != null && last.kind == StartKinds.postponement) 'postponed ${clockText(firedAt(last))}',
            if (individualRecall) 'individual recall',
            onFleet != null ? 'fix fleet or time' : 'tap to fix the time',
          ].join(' · '),
        ),
      null when last == null => ('NO GUN', 'tap GUN at the start signal'),
      null when last.kind == StartKinds.postponement => ('POSTPONED', 'at ${clockText(firedAt(last))}'),
      // With no anchor, the latest event is a general recall.
      null => ('GENERAL RECALL', 'at ${clockText(firedAt(last))} · waiting for the next gun'),
    };
    final text = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(headline, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: SunlightTokens.text)),
          Text(detail, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
    // With the banner up the card has 64 dp, and its usual padding would shrink
    // what it says, which is what a PRO reads in glare, by a third.
    final vertical = height < fullHeight ? 2.0 : 8.0;
    final style = ButtonStyle(
      alignment: Alignment.centerLeft,
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16, vertical: vertical)),
    );
    // Not a race-time action: it opens the picker, whose rows are.
    if (onFleet != null) {
      return SizedBox(
        width: double.infinity,
        height: height,
        child: OutlinedButton(key: const ValueKey('start-card'), onPressed: onFleet, style: style, child: text),
      );
    }
    if (onFix == null) {
      return Container(
        key: const ValueKey('start-card'),
        width: double.infinity,
        height: height,
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: vertical),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          border: Border.all(color: SunlightTokens.mutedText, width: 2),
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        child: text,
      );
    }
    return RaceTimeAction(
      id: 'fix-gun-time',
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: OutlinedButton(key: const ValueKey('start-card'), onPressed: onFix, style: style, child: text),
      ),
    );
  }
}
