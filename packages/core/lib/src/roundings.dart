import 'clock_offsets.dart';
import 'envelope.dart';
import 'finishes.dart';
import 'fleets.dart';
import 'order.dart';
import 'roles.dart';
import 'starts.dart';
import 'stations.dart';

/// Roundings (#54): a mark-boat phone taps each boat as she rounds its
/// station, so the roundings exist as protest evidence and feed the running
/// order (#68). Nothing here edits an event (ADR 001): a sail number named
/// later, a corrected one, and an undo are each a new event naming the
/// rounding in its `correctsUlid`.
abstract final class RoundingKinds {
  /// A boat rounded `payload.mark`, the phone's station, which the core
  /// stamps (#26). `payload.sail` is her sail number, or null for a boat the
  /// operator could not identify. The core also stamps `payload.race`, the
  /// gun the race began with, and `payload.lap`, her rounding count at the
  /// mark in that race ([stampRounding]).
  static const rounding = 'rounding';

  /// A sail number for a rounding, named later or corrected. Its
  /// `correctsUlid` is the rounding, `payload.sail` the number, and the
  /// latest wins.
  static const sail = 'rounding.sail';

  /// Takes a rounding back. Its `correctsUlid` is the rounding.
  static const undo = 'rounding.undo';

  static const all = {rounding, sail, undo};
}

/// The payload keys the core stamps into a rounding.
const racePayloadKey = 'race';
const lapPayloadKey = 'lap';

/// Builds the events a rounding screen appends.
abstract final class RoundingEvents {
  /// [sail] rounded this phone's station, for [fleet] (null on a single-fleet
  /// day). A null [sail] is a boat the operator could not identify.
  static NewEvent rounding({required String? fleet, required String? sail}) => NewEvent(
        kind: RoundingKinds.rounding,
        source: 'tap',
        payload: {fleetPayloadKey: fleet, 'sail': sail},
      );

  /// Names [roundingUlid]'s boat [sail], or corrects the number it had.
  static NewEvent assignSail(String roundingUlid, String sail) => NewEvent(
        kind: RoundingKinds.sail,
        source: 'tap',
        correctsUlid: roundingUlid,
        payload: {'sail': sail},
      );

  static NewEvent undo(String roundingUlid) =>
      NewEvent(kind: RoundingKinds.undo, source: 'tap', correctsUlid: roundingUlid);
}

/// A sail number as stored: an empty one is none.
String? _sailOf(Object? sail) => sail is String && sail.isNotEmpty ? sail : null;

/// The order events were logged in: by phone, then that phone's sequence
/// number. On one phone that is the order they were tapped, whatever its
/// clock did meanwhile; [happened] reads the clock, so a clock set back
/// mid-race would reorder it (#54's review).
int _logged(EventEnvelope a, EventEnvelope b) {
  final byDevice = a.deviceId.compareTo(b.deviceId);
  return byDevice != 0 ? byDevice : a.seq.compareTo(b.seq);
}

/// Each rounding's latest sail number named by a `rounding.sail`, by the
/// rounding's ULID. Latest as its phone logged them.
Map<String, String> _namedSails(Iterable<EventEnvelope> events) => {
      for (final e in events.where((e) => e.kind == RoundingKinds.sail).toList()..sort(_logged))
        if (e.correctsUlid case final String rounding)
          if (_sailOf(e.payload['sail']) case final String sail) rounding: sail,
    };

/// [rounding]'s boat: the latest sail number named for it, else the one it
/// was tapped with. Null for a boat nobody has named.
String? _boat(EventEnvelope rounding, Map<String, String> named) =>
    named[rounding.ulid] ?? _sailOf(rounding.payload['sail']);

/// True when [rounding] belongs to the race that began with [gun] (or to the
/// race of the day, when [gun] is null), as a phone reads it at [now]. A
/// rounding stamped with a gun is in that gun's race only. One stamped with
/// none was tapped on a phone that knew no gun: it is in the race of the day
/// it was tapped on, and, once a gun is known, in that gun's race when it came
/// after it. That last comparison reads two phones' raw clocks, which differ
/// by seconds against the minutes between a gun and the first mark.
bool _inRace(EventEnvelope rounding, {required String? gun, required int? gunAt, required int now}) {
  final stamped = rounding.payload[racePayloadKey];
  if (stamped is String) return stamped == gun;
  if (!sameLocalDay(rounding.deviceTs, now)) return false;
  return gunAt == null || rounding.deviceTs >= gunAt;
}

/// The roundings in [events] that have not been undone.
List<EventEnvelope> _kept(Iterable<EventEnvelope> events) {
  final undone = undoneBy(events, RoundingKinds.undo);
  return [
    for (final e in events)
      if (e.kind == RoundingKinds.rounding && !undone.contains(e.ulid)) e,
  ]..sort(happened);
}

/// [event] as the core stores it, given what the phone holds ([events]: every
/// phone's guns, and this phone's own roundings, their sail numbers and their
/// undos), at [now], on [deviceId] stationed at [station] (#54 criterion 1).
/// Anything but a rounding comes back as it is.
///
/// A rounding gains the race it was tapped in, [racePayloadKey]: the gun
/// [raceGun] names, or null when the phone knows none. And its boat's lap
/// there, [lapPayloadKey]: one more than her roundings this phone has kept at
/// the mark, for the fleet, in that race. That is her count since the gun,
/// else since the day began (owner decision at #54's pickup, 2026-10-27). So
/// until a mark-boat phone learns the guns (#113), a second race on one day
/// counts on from the first. An unidentified boat's lap is null; a sail number
/// named later leaves it so, and her next rounding counts that one.
///
/// A rounding that names a race or a lap of its own keeps it, as an event
/// naming a mark keeps its own.
NewEvent stampRounding(Iterable<EventEnvelope> events, NewEvent event,
    {required String deviceId, required String? station, required int now}) {
  if (event.kind != RoundingKinds.rounding) return event;
  final payload = event.payload;
  final fleet = payload[fleetPayloadKey] as String?;
  final race = payload.containsKey(racePayloadKey) ? payload[racePayloadKey] : raceGun(events, fleet, now: now);
  final mark = payload.containsKey(markPayloadKey) ? payload[markPayloadKey] : station;
  final sail = _sailOf(payload['sail']);

  Object? lap;
  if (payload.containsKey(lapPayloadKey)) {
    lap = payload[lapPayloadKey];
  } else if (sail != null) {
    final gun = race is String ? race : null;
    final gunAt = gun == null ? null : _gunAt(events, gun);
    final named = _namedSails(events);
    lap = 1 +
        _kept(events.where((e) => e.deviceId == deviceId))
            .where((r) =>
                fleetOf(r) == fleet &&
                markOf(r) == mark &&
                _boat(r, named) == sail &&
                _inRace(r, gun: gun, gunAt: gunAt, now: now))
            .length;
  }
  return NewEvent(
    kind: event.kind,
    source: event.source,
    payload: {...payload, racePayloadKey: race, lapPayloadKey: lap},
    payloadVersion: event.payloadVersion,
    person: event.person,
    role: event.role,
    correctsUlid: event.correctsUlid,
  );
}

/// When [gun] went, or null when [events] do not hold it.
int? _gunAt(Iterable<EventEnvelope> events, String gun) {
  for (final e in events) {
    if (e.ulid == gun) return gunTime(events, e);
  }
  return null;
}

/// One rounding on the rounding screen.
class RoundingEntry {
  const RoundingEntry({required this.ulid, required this.deviceTs, this.sail, this.lap});

  final String ulid;

  /// When the boat was tapped, on this phone's clock.
  final int deviceTs;

  /// Her latest sail number; null while nobody has named her.
  final String? sail;

  /// Her lap as stamped when she was tapped; null for a boat tapped
  /// unidentified.
  final int? lap;

  @override
  String toString() => 'RoundingEntry(${sail ?? '-'} lap ${lap ?? '-'} $deviceTs $ulid)';
}

/// True for a rounding at [mark] for [fleet] on the local date of [day].
bool _roundingAt(EventEnvelope e, String? fleet, String mark, int day) =>
    e.kind == RoundingKinds.rounding && fleetOf(e) == fleet && markOf(e) == mark && sameLocalDay(e.deviceTs, day);

/// [fleet]'s roundings at [mark] on the local date of [day], in the order
/// they were logged, undone ones removed, each with its latest sail number.
/// For one phone's own events, as the rounding screen reads them.
List<RoundingEntry> roundingsAt(Iterable<EventEnvelope> events,
    {required String? fleet, required String mark, required int day}) {
  final named = _namedSails(events);
  return [
    for (final r in _kept(events)..sort(_logged))
      if (_roundingAt(r, fleet, mark, day))
        RoundingEntry(
          ulid: r.ulid,
          deviceTs: r.deviceTs,
          sail: _boat(r, named),
          lap: r.payload[lapPayloadKey] is int ? r.payload[lapPayloadKey] as int : null,
        ),
  ];
}

/// The rounding at [mark] for [fleet] that UNDO LAST takes back: the last
/// one logged on the local date of [day] not already undone. Null when there
/// is none.
EventEnvelope? lastUndoableRounding(Iterable<EventEnvelope> events,
    {required String? fleet, required String mark, required int day}) =>
    (_kept(events)..sort(_logged)).where((r) => _roundingAt(r, fleet, mark, day)).lastOrNull;

/// The boats the rounding screen offers to tap (owner decision at #54's
/// pickup, 2026-10-27): every sail number [fleet] has logged in these events
/// on the local date of [day], in roundings and in finishes at a mark, each
/// once, in the order each was last logged, oldest first. So a lap's boats
/// are offered in the order they rounded on the one before. The log has no
/// entry list, as for the OCS panel (#29).
List<String> knownRoundingSails(Iterable<EventEnvelope> events, {required String? fleet, required int day}) {
  final named = _namedSails(events);
  final undoneFinishes = undoneBy(events, FinishKinds.undo);
  final finishSails = <String, String>{
    for (final e in events.where((e) => e.kind == FinishKinds.sail).toList()..sort(happened))
      if (_sailOf(e.payload['sail']) case final String sail) e.payload['finish'] as String: sail,
  };
  final logged = <(EventEnvelope, String)>[
    for (final r in _kept(events))
      if (fleetOf(r) == fleet && sameLocalDay(r.deviceTs, day))
        if (_boat(r, named) case final String sail) (r, sail),
    for (final f in events)
      if (f.kind == FinishKinds.atMark &&
          fleetOf(f) == fleet &&
          !undoneFinishes.contains(f.ulid) &&
          sameLocalDay(f.deviceTs, day))
        if (finishSails[f.ulid] case final String sail) (f, sail),
  ]..sort((a, b) => _logged(a.$1, b.$1));
  final last = <String, int>{};
  for (var i = 0; i < logged.length; i++) {
    last[logged[i].$2] = i;
  }
  return [
    for (var i = 0; i < logged.length; i++)
      if (last[logged[i].$2] == i) logged[i].$2,
  ];
}

// The running order (#68) ----------------------------------------------------

/// One boat in a fleet's running order.
class RunningEntry {
  const RunningEntry({required this.sail, required this.roundings, required this.last});

  final String sail;

  /// Her roundings in the race, at every mark: how far round she is, since
  /// the log has no course to say which mark comes next.
  final int roundings;

  /// Her latest rounding: the furthest mark she has rounded, and when.
  final EventEnvelope last;

  /// The mark of [last].
  String? get mark => markOf(last);

  @override
  String toString() => 'RunningEntry($sail x$roundings at $mark)';
}

/// One fleet's running order in its current race, as a phone reads it (#68).
class FleetRunningOrder {
  const FleetRunningOrder({
    required this.fleet,
    required this.race,
    required this.entries,
    required this.unnamed,
    required this.waiting,
    required this.clocksUnmatched,
  });

  /// The fleet, or null on a single-fleet day.
  final String? fleet;

  /// The gun the race began with, or null for the race of the day.
  final String? race;

  /// Furthest round first.
  final List<RunningEntry> entries;

  /// Roundings in the race whose boat nobody has named yet. They count for
  /// no boat until one is.
  final int unnamed;

  /// The marks a committee phone is stationed at with no rounding of this
  /// fleet in the race yet: each one's roundings have not arrived, so the
  /// order shown does not include it (criterion 4). In the standard set's
  /// order.
  final List<String> waiting;

  /// True when boats level on roundings were put in order across phones
  /// whose clocks are not matched to satellite time (#55): those places rest
  /// on two phones' own clocks.
  final bool clocksUnmatched;

  @override
  String toString() => 'FleetRunningOrder($fleet race $race $entries, $unnamed unnamed, waiting $waiting'
      '${clocksUnmatched ? ', clocks unmatched' : ''})';
}

/// The marks committee phones are stationed at on the local date of [now],
/// by what [events] hold of each phone's station picks. A phone whose role
/// picks are held keeps its station only under the role pick in force
/// ([currentStationPick]). Another phone's role pick is logged before it is
/// admitted, so it never reaches shore, and for such a phone its latest pick
/// not undone stands. Either way the pick counts only if made that day:
/// yesterday's station is no mark today (#68's review).
Set<String> stationedMarks(Iterable<EventEnvelope> events, {required int now}) {
  final devices = {for (final e in events) if (StationKinds.all.contains(e.kind)) e.deviceId};
  final marks = <String>{};
  for (final device in devices) {
    final EventEnvelope? pick;
    if (events.any((e) => e.deviceId == device && RoleKinds.all.contains(e.kind))) {
      pick = currentStationPick(events, device);
    } else {
      final own = events.where((e) => e.deviceId == device && StationKinds.all.contains(e.kind)).toList();
      final undone = undoneBy(own, StationKinds.undo);
      final picks = own.where((e) => e.kind == StationKinds.selected && !undone.contains(e.ulid)).toList()
        ..sort(_logged);
      pick = picks.lastOrNull;
    }
    if (pick != null && sameLocalDay(pick.deviceTs, now)) {
      if (markOf(pick) case final String mark) marks.add(mark);
    }
  }
  return marks;
}

/// [marks] in the standard set's order, any other after them by name.
List<String> _inMarkOrder(Iterable<String> marks) {
  int rank(String m) {
    final i = StandardMarks.all.indexOf(m);
    return i < 0 ? StandardMarks.all.length : i;
  }

  return marks.toList()
    ..sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : a.compareTo(b);
    });
}

/// [fleet]'s running order at [now], from every phone's events (#68, owner
/// decisions at pickup, 2026-10-27).
///
/// - The race is the one [raceGun] names, as this phone knows the guns.
/// - A boat is ahead when she has rounded more marks in it (criterion 2: the
///   furthest mark she has rounded). The log has no course, so how many is
///   how far. Boats level on that are in the order they rounded their latest
///   mark (criterion 1).
/// - Boats level on one phone are in the order that phone logged them, which
///   is the order they were tapped, whatever its clock did (a clock set back
///   mid-race, #54's review). Across phones (a gate's two boats) each rounding
///   is moved to satellite time by its phone's clock offset (#55). Where either
///   phone has none measured, they are ordered on the phones' own clocks, and
///   [FleetRunningOrder.clocksUnmatched] says so.
/// - A rounding counts for the boat its latest sail number names (criterion
///   3), and not at all once undone.
FleetRunningOrder runningOrder(Iterable<EventEnvelope> events, {required String? fleet, required int now}) {
  final gun = raceGun(events, fleet, now: now);
  final gunAt = gun == null ? null : _gunAt(events, gun);
  final named = _namedSails(events);
  final inRace = [
    for (final r in _kept(events))
      if (fleetOf(r) == fleet && _inRace(r, gun: gun, gunAt: gunAt, now: now)) r,
  ];

  final byBoat = <String, List<EventEnvelope>>{};
  var unnamed = 0;
  for (final r in inRace) {
    final sail = _boat(r, named);
    if (sail == null) {
      unnamed++;
    } else {
      (byBoat[sail] ??= []).add(r);
    }
  }

  final entries = [
    for (final MapEntry(key: sail, value: rs) in byBoat.entries)
      RunningEntry(sail: sail, roundings: rs.length, last: _latest(rs)),
  ];
  final groups = <int, List<RunningEntry>>{};
  for (final e in entries) {
    (groups[e.roundings] ??= []).add(e);
  }

  var clocksUnmatched = false;
  final ordered = <RunningEntry>[];
  for (final count in groups.keys.toList()..sort((a, b) => b.compareTo(a))) {
    final group = groups[count]!;
    final phones = {for (final e in group) e.last.deviceId};
    final satellite = {for (final e in group) e.sail: _satelliteTime(events, e.last)};
    if (phones.length > 1 && satellite.values.every((t) => t != null)) {
      group.sort((a, b) {
        final byTime = satellite[a.sail]!.compareTo(satellite[b.sail]!);
        return byTime != 0 ? byTime : happened(a.last, b.last);
      });
    } else if (phones.length > 1) {
      clocksUnmatched = true;
      group.sort((a, b) => happened(a.last, b.last));
      _keepEachPhonesOrder(group);
    } else {
      group.sort((a, b) => _logged(a.last, b.last));
    }
    ordered.addAll(group);
  }

  final rounded = {for (final r in inRace) ?markOf(r)};
  return FleetRunningOrder(
    fleet: fleet,
    race: gun,
    entries: ordered,
    unnamed: unnamed,
    waiting: _inMarkOrder(stationedMarks(events, now: now).difference(rounded)),
    clocksUnmatched: clocksUnmatched,
  );
}

/// A boat's latest rounding of [rs]: each phone's last logged, then the
/// latest of those by the phones' clocks. One rule for any set of phones;
/// mixing the two orders pairwise could cycle (#68's second review).
EventEnvelope _latest(List<EventEnvelope> rs) {
  final lastByPhone = <String, EventEnvelope>{};
  for (final r in rs) {
    final held = lastByPhone[r.deviceId];
    if (held == null || r.seq > held.seq) lastByPhone[r.deviceId] = r;
  }
  return lastByPhone.values.reduce((a, b) => happened(a, b) >= 0 ? a : b);
}

/// [group], already in clock order, with each phone's own entries put back
/// in the order that phone logged them, in the places they hold. The
/// phones' clocks decide between phones; a phone's own sequence decides
/// within it, so a clock set on one phone cannot reverse two of its taps
/// (#68's second review).
void _keepEachPhonesOrder(List<RunningEntry> group) {
  final byPhone = <String, List<int>>{};
  for (var i = 0; i < group.length; i++) {
    (byPhone[group[i].last.deviceId] ??= []).add(i);
  }
  for (final places in byPhone.values) {
    final entries = [for (final i in places) group[i]]..sort((a, b) => _logged(a.last, b.last));
    for (var k = 0; k < places.length; k++) {
      group[places[k]] = entries[k];
    }
  }
}

/// [rounding]'s time moved to satellite time by its phone's clock offset in
/// force ([offsetFor]), or null when that phone has none measured.
int? _satelliteTime(Iterable<EventEnvelope> events, EventEnvelope rounding) {
  final offset = offsetFor(events, rounding)?.payload['offset_ms'];
  return offset is int ? rounding.deviceTs + offset : null;
}

/// Every fleet's running order at [now]: each fleet the day defines, in the
/// order defined, or the single fleet when it defines none. Roundings that
/// name no fleet on a day that defines fleets, as a mark-boat phone that has
/// none of the day's fleets logs, are their own order, last, and only while
/// that order holds a rounding in its race: an undone one or yesterday's
/// leaves no empty section behind (#68's review).
List<FleetRunningOrder> runningOrders(Iterable<EventEnvelope> events, {required int now}) {
  final defined = fleets(events);
  final none = runningOrder(events, fleet: null, now: now);
  return [
    for (final f in defined) runningOrder(events, fleet: f.id, now: now),
    if (defined.isEmpty || none.entries.isNotEmpty || none.unnamed > 0) none,
  ];
}
