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
import 'ocs_panel.dart';

/// The sequence card (#25): the selected fleet's start, logged by hand when
/// race-timer is not running. That is ADR 001's fallback, marked
/// `source: manual` so a protest committee can tell a hand-tapped gun from
/// race-timer's.
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
  const SequenceScreen({super.key, required this.core, required this.confirmation, this.clock = systemClock});

  final CoreClient core;
  final ConfirmationService confirmation;

  /// The phone's clock: a gun's typed time may not be later than now.
  final int Function() clock;

  @override
  State<SequenceScreen> createState() => _SequenceScreenState();
}

class _SequenceScreenState extends State<SequenceScreen> {
  final _events = <EventEnvelope>[];
  bool _loaded = false;
  bool _failed = false;
  String? _deviceId;

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
    Future.wait([widget.core.readAll(), widget.core.deviceId()]).then((r) {
      if (!mounted) return;
      setState(() {
        // Finishes too: their sail numbers are the boats the OCS panel knows.
        _events.addAll((r[0] as List<EventEnvelope>).where((e) =>
            StartKinds.all.contains(e.kind) || FleetKinds.all.contains(e.kind) || FinishKinds.all.contains(e.kind)));
        _deviceId = r[1] as String;
        _loaded = true;
      });
    }, onError: (Object _) {
      if (mounted) setState(() => _failed = true);
    });
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
      setState(() {
        _events.add(stored);
        _failed = false;
        _fixing = null;
        _digits = '';
        _sailDigits = '';
        _ocsSelected = null;
      });
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
    final day = DateTime.fromMillisecondsSinceEpoch(gun.deviceTs);
    final time = DateTime(day.year, day.month, day.day, h, m, s).millisecondsSinceEpoch;
    if (time > widget.clock()) return (time: null, problem: 'later than now');
    return (time: time, problem: null);
  }

  Widget _keypad(EventEnvelope gun) {
    final typed = _typedTime(gun);
    final now = gunTime(_events, gun);
    return DigitKeypad(
      title: now == gun.deviceTs
          ? 'Fix gun · tapped ${clockText(gun.deviceTs)}'
          : 'Fix gun ${clockText(now)} · tapped ${clockText(gun.deviceTs)}',
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

    return Scaffold(
      // Nothing here is typed with the system keyboard, as on FINISHES: back
      // from FLEETS it is still up while this screen lays out, and on a
      // 320 x 640 phone the fixed rows overflowed what it left (PR #94).
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
            fleetName == null ? 'Sequence' : 'Sequence · $fleetName',
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
                                  _StartCard(
                                    anchor: anchor,
                                    anchorAt: anchor == null ? null : gunTime(_events, anchor),
                                    latest: latest,
                                    individualRecall:
                                        anchor != null && individualRecallsOf(_events, anchor).isNotEmpty,
                                    onFix: anchor == null
                                        ? null
                                        : () => setState(() {
                                              _fixing = anchor.ulid;
                                              _digits = '';
                                            }),
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
                                  // general recall (#29).
                                  Row(
                                    children: [
                                      Expanded(
                                        child: RaceTimeAction(
                                          id: 'individual-recall',
                                          child: SizedBox(
                                            height: Bars.minTargetDp + 8,
                                            child: OutlinedButton(
                                              onPressed: anchor == null
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
                                              onPressed: anchor == null ? null : () => _openOcs(anchor),
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
                    onPressed: undo == null ? null : () => _append(undo),
                    child: FitLabel(undoLabel),
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
/// its time, so it is a button; without one there is nothing to fix.
class _StartCard extends StatelessWidget {
  const _StartCard({
    required this.anchor,
    required this.anchorAt,
    required this.latest,
    required this.individualRecall,
    required this.onFix,
  });

  final EventEnvelope? anchor;

  /// The anchor's gun time, corrected if it has been.
  final int? anchorAt;

  /// The fleet's latest sequence event, not undone.
  final EventEnvelope? latest;

  /// True once an individual recall of the anchor is logged (#29).
  final bool individualRecall;
  final VoidCallback? onFix;

  @override
  Widget build(BuildContext context) {
    final last = latest;
    final (String headline, String detail) = switch (anchor) {
      final EventEnvelope gun => (
          'GUN ${clockText(anchorAt!)}',
          [
            if (anchorAt != gun.deviceTs) 'tapped ${clockText(gun.deviceTs)}',
            if (last != null && last.kind == StartKinds.postponement) 'postponed ${clockText(last.deviceTs)}',
            if (individualRecall) 'individual recall',
            'tap to fix the time',
          ].join(' · '),
        ),
      null when last == null => ('NO GUN', 'tap GUN at the start signal'),
      null when last.kind == StartKinds.postponement => ('POSTPONED', 'at ${clockText(last.deviceTs)}'),
      // With no anchor, the latest event is a general recall.
      null => ('GENERAL RECALL', 'at ${clockText(last.deviceTs)} · waiting for the next gun'),
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
    const height = Bars.minTargetDp + 32;
    if (onFix == null) {
      return Container(
        key: const ValueKey('start-card'),
        width: double.infinity,
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
        child: OutlinedButton(
          key: const ValueKey('start-card'),
          onPressed: onFix,
          style: const ButtonStyle(
            alignment: Alignment.centerLeft,
            padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16, vertical: 8)),
          ),
          child: text,
        ),
      ),
    );
  }
}
