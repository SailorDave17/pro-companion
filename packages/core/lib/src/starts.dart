import 'envelope.dart';
import 'finishes.dart';
import 'fleets.dart';
import 'order.dart';

/// Starts, keyed by fleet (#18). The events a start is made of, and each
/// fleet's race state derived from them. #25 logs them by hand
/// (`source: manual`) and #33 from race-timer (`source: race-timer`); both
/// build them here, so neither can log a start without a fleet.
///
/// Nothing here edits an event (ADR 001): a gun's corrected time, an OCS
/// boat's clearance, and an undo, are each a new event naming the one they
/// apply to.
abstract final class StartKinds {
  /// A fleet's start gun. Its time is [firedAt]'s: when race-timer fired it,
  /// or the device time it was tapped at.
  static const start = 'start';

  /// A general recall of a fleet's start: that start no longer anchors
  /// elapsed time, and nothing does until the fleet's next gun.
  static const generalRecall = 'start.general_recall';

  /// A postponement of a fleet's start (#25), logged as its own row. It moves
  /// no anchor: a start not yet made has none to move, and one already made
  /// is recalled, not postponed.
  static const postponement = 'start.postponement';

  /// The real time of a gun tapped late or wrong (#25). `payload.time` is the
  /// time, and `correctsUlid` names the start, which is kept as tapped.
  static const timeCorrected = 'start.time_corrected';

  /// An individual recall of a fleet's start (#29): boats were over early.
  /// `payload.start` is the start it recalls. It moves no anchor; the boats
  /// over are each an [ocs].
  static const individualRecall = 'start.individual_recall';

  /// One boat on the course side at a start (#29). `payload.start` is the
  /// start, and `payload.sail` her sail number.
  static const ocs = 'start.ocs';

  /// An OCS boat that came back and started (#29). Its `correctsUlid` names
  /// the [ocs], which is kept as logged.
  static const ocsCleared = 'start.ocs_cleared';

  /// Takes a start, postponement, recall, time correction, OCS or clearance
  /// back. Its `correctsUlid` is the event it undoes.
  static const undo = 'start.undo';

  /// race-timer began a start sequence (#33, ADR 004). It has no manual
  /// equivalent, and moves no anchor.
  static const sequenceStart = 'start.sequence_start';

  /// A signal race-timer fired on the way to the gun (#33, ADR 004). It too
  /// moves no anchor. A kind race-timer adds later is logged as one.
  static const signal = 'start.signal';

  /// The events that make up a fleet's sequence. Each carries its fleet; a
  /// time correction and an undo name the event they apply to, so they
  /// follow it. An individual recall and an OCS name their start, and change
  /// nothing about which start anchors.
  static const sequence = {start, postponement, generalRecall};

  static const all = {
    start,
    generalRecall,
    postponement,
    timeCorrected,
    individualRecall,
    ocs,
    ocsCleared,
    undo,
    sequenceStart,
    signal,
  };
}

/// Builds start events. [fleet] is required, and null only on a day run as a
/// single fleet.
abstract final class StartEvents {
  static NewEvent start({required String? fleet, required String source}) =>
      NewEvent(kind: StartKinds.start, source: source, payload: {fleetPayloadKey: fleet});

  static NewEvent generalRecall({required String? fleet, required String source}) =>
      NewEvent(kind: StartKinds.generalRecall, source: source, payload: {fleetPayloadKey: fleet});

  static NewEvent postponement({required String? fleet, required String source}) =>
      NewEvent(kind: StartKinds.postponement, source: source, payload: {fleetPayloadKey: fleet});

  /// The time [startUlid]'s gun really went, typed by hand, in milliseconds
  /// since the epoch.
  static NewEvent correctTime(String startUlid, {required int time}) => NewEvent(
        kind: StartKinds.timeCorrected,
        source: 'manual',
        correctsUlid: startUlid,
        payload: {'time': time},
      );

  /// An individual recall of [startUlid], [fleet]'s start.
  static NewEvent individualRecall(String startUlid, {required String? fleet, required String source}) => NewEvent(
        kind: StartKinds.individualRecall,
        source: source,
        payload: {fleetPayloadKey: fleet, 'start': startUlid},
      );

  /// [sail] over the line at [startUlid], [fleet]'s start, as the PRO saw it.
  static NewEvent ocs(String startUlid, {required String? fleet, required String sail}) => NewEvent(
        kind: StartKinds.ocs,
        source: 'manual',
        payload: {fleetPayloadKey: fleet, 'start': startUlid, 'sail': sail},
      );

  /// The OCS boat [ocsUlid] came back and started.
  static NewEvent clearOcs(String ocsUlid) =>
      NewEvent(kind: StartKinds.ocsCleared, source: 'manual', correctsUlid: ocsUlid);

  static NewEvent undo(String eventUlid) => NewEvent(kind: StartKinds.undo, source: 'tap', correctsUlid: eventUlid);
}

/// One fleet's race state: what its starts and recalls add up to.
class FleetRaceState {
  const FleetRaceState({required this.starts, required this.recalls, this.anchorUlid});

  /// Guns logged for the fleet, and not undone.
  final int starts;

  /// General recalls logged for the fleet, and not undone.
  final int recalls;

  /// The start elapsed time is measured from: the fleet's most recent start
  /// not recalled since. Null before the first gun and after a recall.
  final String? anchorUlid;

  @override
  bool operator ==(Object other) =>
      other is FleetRaceState && other.starts == starts && other.recalls == recalls && other.anchorUlid == anchorUlid;

  @override
  int get hashCode => Object.hash(starts, recalls, anchorUlid);

  @override
  String toString() => 'FleetRaceState(starts: $starts, recalls: $recalls, anchor: $anchorUlid)';
}

/// When [e] happened on the water, in milliseconds since the epoch: race-timer's
/// own `at_ms` for what it sent (#33), or the device time it was tapped at.
/// The two differ by the link's latency, and by far more for an event that
/// waited to be resent, or that a fix re-logged.
int firedAt(EventEnvelope e) {
  final at = e.payload['at_ms'];
  return at is int ? at : e.deviceTs;
}

/// Orders [a] before [b] when it happened first on the water ([firedAt]), and
/// two that fired in the same millisecond in the order they were logged. Not
/// [happened]: race-timer need not resend in order (ADR 004), so the event
/// logged last is not always the one that fired last.
int onTheWater(EventEnvelope a, EventEnvelope b) {
  final byFired = firedAt(a).compareTo(firedAt(b));
  return byFired != 0 ? byFired : happened(a, b);
}

/// [fleet]'s starts, postponements and recalls that have not been undone, in
/// the order they happened on the water, so a gun race-timer had to resend
/// still comes before the recall that cancels it. Another fleet's never enter
/// it.
List<EventEnvelope> sequenceOf(Iterable<EventEnvelope> events, String? fleet) {
  final undone = undoneBy(events, StartKinds.undo);
  return events
      .where((e) => StartKinds.sequence.contains(e.kind) && fleetOf(e) == fleet && !undone.contains(e.ulid))
      .toList()
    ..sort(onTheWater);
}

/// [fleet]'s race state. Another fleet's starts and recalls never enter it,
/// and neither does anything undone.
FleetRaceState raceState(Iterable<EventEnvelope> events, String? fleet) {
  var starts = 0;
  var recalls = 0;
  String? anchor;
  for (final e in sequenceOf(events, fleet)) {
    if (e.kind == StartKinds.start) {
      starts++;
      anchor = e.ulid;
    } else if (e.kind == StartKinds.generalRecall) {
      recalls++;
      anchor = null;
    }
  }
  return FleetRaceState(starts: starts, recalls: recalls, anchorUlid: anchor);
}

/// The start [fleet]'s elapsed time is measured from: its most recent start
/// not recalled since, or null.
EventEnvelope? elapsedAnchor(Iterable<EventEnvelope> events, String? fleet) {
  final anchor = raceState(events, fleet).anchorUlid;
  if (anchor == null) return null;
  return events.firstWhere((e) => e.ulid == anchor);
}

/// [start]'s time corrections that have not been undone, in the order they
/// were made.
List<EventEnvelope> _timeFixesOf(Iterable<EventEnvelope> events, EventEnvelope start) {
  final undone = undoneBy(events, StartKinds.undo);
  return events
      .where((e) => e.kind == StartKinds.timeCorrected && e.correctsUlid == start.ulid && !undone.contains(e.ulid))
      .toList()
    ..sort(happened);
}

/// When [start]'s gun went, in milliseconds since the epoch: its latest time
/// correction not undone, or else [firedAt]. A typed time beats race-timer's.
int gunTime(Iterable<EventEnvelope> events, EventEnvelope start) {
  final fixes = _timeFixesOf(events, start);
  return fixes.isEmpty ? firedAt(start) : fixes.last.payload['time'] as int;
}

/// The time [fleet]'s elapsed time is measured from - its anchor's
/// [gunTime] - or null when it has no anchor.
int? anchorTime(Iterable<EventEnvelope> events, String? fleet) {
  final anchor = elapsedAnchor(events, fleet);
  return anchor == null ? null : gunTime(events, anchor);
}

/// One boat logged over the line at a start (#29).
class OcsEntry {
  const OcsEntry({required this.ulid, required this.sail, this.clearedUlid});

  /// The OCS event.
  final String ulid;
  final String sail;

  /// The clearance in force, when she came back and started; null while she
  /// is still over.
  final String? clearedUlid;

  bool get cleared => clearedUlid != null;

  @override
  String toString() => 'OcsEntry($sail${cleared ? ' cleared' : ''} $ulid)';
}

/// [start]'s events of [kind] that name it in `payload.start` and have not
/// been undone, in the order they were logged. A race-timer recall that
/// arrived before its gun could name none (#33), so it names the sequence.
List<EventEnvelope> _namingStart(Iterable<EventEnvelope> events, EventEnvelope start, String kind) {
  final undone = undoneBy(events, StartKinds.undo);
  final sequence = start.payload['sequence'];
  bool names(EventEnvelope e) =>
      e.payload['start'] == start.ulid ||
      (e.payload['start'] == null && sequence != null && e.payload['sequence'] == sequence);
  return events.where((e) => e.kind == kind && names(e) && !undone.contains(e.ulid)).toList()..sort(happened);
}

/// [ocs]'s clearances that have not been undone, in the order they were made.
List<EventEnvelope> _clearancesOf(Iterable<EventEnvelope> events, EventEnvelope ocs) {
  final undone = undoneBy(events, StartKinds.undo);
  return events
      .where((e) => e.kind == StartKinds.ocsCleared && e.correctsUlid == ocs.ulid && !undone.contains(e.ulid))
      .toList()
    ..sort(happened);
}

/// The boats logged over the line at [start], in the order they were logged,
/// each with its latest clearance not undone. An undone OCS is left out.
List<OcsEntry> ocsAt(Iterable<EventEnvelope> events, EventEnvelope start) => [
      for (final e in _namingStart(events, start, StartKinds.ocs))
        OcsEntry(ulid: e.ulid, sail: e.payload['sail'] as String, clearedUlid: _clearancesOf(events, e).lastOrNull?.ulid),
    ];

/// The individual recalls of [start] that have not been undone, in the order
/// they were logged.
List<EventEnvelope> individualRecallsOf(Iterable<EventEnvelope> events, EventEnvelope start) =>
    _namingStart(events, start, StartKinds.individualRecall);

/// The sail numbers [fleet] has already logged on the phone's local day of
/// [day] (milliseconds since the epoch), newest first and each once: every
/// finish's latest sail number, and every OCS not undone. The log has no
/// entry list, so these are the boats the OCS panel can offer to pick (owner
/// decision on #29, 2026-10-06). A finish counts on the day it was logged.
List<String> knownSails(Iterable<EventEnvelope> events, {required String? fleet, required int day}) {
  final on = DateTime.fromMillisecondsSinceEpoch(day);
  bool sameDay(EventEnvelope e) {
    final t = DateTime.fromMillisecondsSinceEpoch(e.deviceTs);
    return t.year == on.year && t.month == on.month && t.day == on.day;
  }

  final byUlid = {for (final e in events) e.ulid: e};
  final places = {for (final p in finishOrder(events, fleet: fleet)) p.ulid};
  final latestSail = <String, EventEnvelope>{};
  for (final e in events.where((e) => e.kind == FinishKinds.sail).toList()..sort(happened)) {
    latestSail[e.payload['finish'] as String] = e;
  }
  final undone = undoneBy(events, StartKinds.undo);
  final named = [
    for (final MapEntry(key: place, value: sail) in latestSail.entries)
      if (places.contains(place) && sameDay(byUlid[place]!)) sail,
    for (final e in events)
      if (e.kind == StartKinds.ocs && fleetOf(e) == fleet && !undone.contains(e.ulid) && sameDay(e)) e,
  ]..sort(happened);
  final seen = <String>{};
  return [
    for (final e in named.reversed)
      if (e.payload['sail'] case final String sail when sail.isNotEmpty && seen.add(sail)) sail,
  ];
}

/// The sequence event of [fleet] that "Undo last" takes back: the most
/// recently logged of its starts, postponements, recalls, time corrections,
/// OCS boats and clearances not already undone. Null when there is none. A
/// start's corrections and OCS boats go when the start is undone.
EventEnvelope? lastUndoableStart(Iterable<EventEnvelope> events, {required String? fleet}) {
  final own = sequenceOf(events, fleet);
  final candidates = [
    ...own,
    for (final s in own)
      if (s.kind == StartKinds.start) ...[
        ..._timeFixesOf(events, s),
        ...individualRecallsOf(events, s),
        for (final o in _namingStart(events, s, StartKinds.ocs)) ...[o, ..._clearancesOf(events, o)],
      ],
  ]..sort(happened);
  return candidates.isEmpty ? null : candidates.last;
}
