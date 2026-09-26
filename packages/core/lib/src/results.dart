import 'envelope.dart';
import 'finishes.dart';
import 'fleets.dart';
import 'order.dart';
import 'scoring.dart';
import 'starts.dart';

/// Provisional results (#7): a fleet's finishes scored on the phone by
/// [scoreSeries], with no network and nothing from shore. The log carries no
/// race number, so races are read off the fleet's starts, and a boat is her
/// sail number, or a placeholder for a finish that has none yet (owner
/// decisions on #7, 2026-09-26).
abstract final class ResultsKinds {
  /// The number of scores excluded from each boat's series (A2.1), set by the
  /// PRO for one fleet. `payload.count`, and the fleet in `payload.fleet`.
  /// The latest one wins; the phone does not know the notice of race.
  static const discards = 'results.discards';

  static const all = {discards};
}

/// Builds the events the results screen appends.
abstract final class ResultsEvents {
  /// [fleet]'s discard count (null on a single-fleet day).
  static NewEvent discards({required String? fleet, required int count}) =>
      NewEvent(kind: ResultsKinds.discards, source: 'tap', payload: {fleetPayloadKey: fleet, 'count': count});
}

/// The discard count set for [fleet]: its latest, or 0 before one is set.
int discardsSet(Iterable<EventEnvelope> events, {required String? fleet}) {
  final set = events.where((e) => e.kind == ResultsKinds.discards && fleetOf(e) == fleet).toList()..sort(happened);
  return set.isEmpty ? 0 : set.last.payload['count'] as int;
}

/// The guns that began one of [fleet]'s races, oldest first: each start not
/// recalled before the fleet's next gun. A recalled start began no race.
List<EventEnvelope> raceStarts(Iterable<EventEnvelope> events, {required String? fleet}) {
  final starts = <EventEnvelope>[];
  EventEnvelope? pending;
  for (final e in sequenceOf(events, fleet)) {
    if (e.kind == StartKinds.start) {
      if (pending != null) starts.add(pending);
      pending = e;
    } else if (e.kind == StartKinds.generalRecall) {
      pending = null;
    }
  }
  if (pending != null) starts.add(pending);
  return starts;
}

/// [fleet]'s races, each its finish order with places counted from 1 within
/// the race. A finish belongs to the latest of [raceStarts] whose gun went
/// before it - the gun's [gunTime], so a late or forgotten gun whose time the
/// PRO corrected (#25) splits the races where it really went. Finishes before
/// any gun make a race of their own, so a day with no starts logged is one
/// race. A missed finish, whose time is unknown, belongs with the finish it
/// was placed above, or failing that the one it was placed below, even if
/// that finish was later undone. A race nobody has finished is left out:
/// [scoreSeries] refuses one, and it has no result yet.
List<List<FinishEntry>> racesOf(Iterable<EventEnvelope> events, {required String? fleet}) =>
    _races(events, fleet: fleet).races;

/// [racesOf], and the missed finishes placed between two races: placed above
/// one race's first finish and below the previous race's last, so the log
/// cannot say which race she sailed.
({List<List<FinishEntry>> races, Set<String> betweenRaces}) _races(Iterable<EventEnvelope> events,
    {required String? fleet}) {
  // Which gun a recall cancels is read in the order they were tapped; where
  // a race starts is the gun's own time, corrected if it was.
  final guns = [for (final s in raceStarts(events, fleet: fleet)) (start: s, time: gunTime(events, s))];
  // 0 before the first race's gun, then 1 after it, and so on.
  int raceAfter(EventEnvelope e) =>
      guns.where((g) => g.time < e.deviceTs || (g.time == e.deviceTs && happened(g.start, e) < 0)).length;

  final byUlid = {for (final e in events) e.ulid: e};
  final raceOf = <String, int>{};
  final betweenRaces = <String>{};
  int resolve(EventEnvelope e, Set<String> seen) {
    final known = raceOf[e.ulid];
    if (known != null) return known;
    if (e.kind != FinishKinds.missed || !seen.add(e.ulid)) return raceAfter(e);
    int? anchor(Object? ulid) {
      final a = byUlid[ulid];
      return a == null ? null : resolve(a, seen);
    }

    final above = anchor(e.payload['before']);
    final below = anchor(e.payload['after']);
    if (above != null && below != null && above != below) betweenRaces.add(e.ulid);
    return raceOf[e.ulid] = above ?? below ?? raceAfter(e);
  }

  final day = finishOrder(events, fleet: fleet);
  final grouped = <int, List<FinishEntry>>{};
  for (final entry in day) {
    (grouped[resolve(byUlid[entry.ulid]!, <String>{})] ??= []).add(entry);
  }
  return (
    races: [
      for (final r in grouped.keys.toList()..sort())
        [
          for (var p = 0; p < grouped[r]!.length; p++)
            FinishEntry(
              ulid: grouped[r]![p].ulid,
              place: p + 1,
              missed: grouped[r]![p].missed,
              deviceTs: grouped[r]![p].deviceTs,
              sail: grouped[r]![p].sail,
            ),
        ],
    ],
    betweenRaces: betweenRaces,
  );
}

/// Where a finish with no sail number is: its race (from 1) and its place.
typedef UnnamedFinish = ({int race, int place});

/// A sail number given to more than one finish in one race.
typedef DuplicateSail = ({int race, String sail});

/// A missed finish placed between two races, scored in the later one (owner
/// decision on #7): the boat, her race (from 1) and her place in it.
typedef BetweenRaces = ({String boat, int race, int place});

/// One fleet's provisional results.
class ProvisionalResults {
  const ProvisionalResults({
    required this.fleet,
    required this.races,
    required this.discards,
    required this.standings,
    required this.unnamed,
    required this.duplicates,
    required this.betweenRaces,
  });

  /// The fleet scored, or null for a single-fleet day.
  final String? fleet;

  /// The races scored.
  final int races;

  /// The discard count applied.
  final int discards;

  /// The series standings, best first. Empty when there is nothing to score,
  /// or when [duplicates] stops the scoring.
  final List<Standing> standings;

  /// The placeholder boats, by the id [Standing.boat] carries, for finishes
  /// with no sail number. Each keeps its place, so the boats behind it score
  /// right, and each counts as a boat entered, so a DNC scores one more per
  /// placeholder until it is named (owner decision on #7).
  final Map<String, UnnamedFinish> unnamed;

  /// Sail numbers given twice in one race. Nothing is scored until they are
  /// fixed: the rules cannot place one boat twice.
  final List<DuplicateSail> duplicates;

  /// Missed finishes placed between two races. Each is scored in the later
  /// race, and the standings are incomplete until she is checked: "Missed
  /// above" on a race's first finish is also the only way to place a boat
  /// missed last in the race before (#106).
  final List<BetweenRaces> betweenRaces;
}

/// [fleet]'s provisional results, scored on the phone by [scoreSeries] from
/// the log alone: its [racesOf], each boat by sail number, the discard count
/// the PRO set, and A5.3 not in force. Every boat is scored in every race
/// (A2.2), so a boat missing from a race scores DNC.
///
/// A discard count of the races scored or more would exclude every score, so
/// it is held to one fewer. That is this phone's choice, not a rule: A2.1 read
/// literally would exclude a one-race series' only score.
ProvisionalResults provisionalResults(Iterable<EventEnvelope> events, {required String? fleet}) {
  final split = _races(events, fleet: fleet);
  final races = split.races;
  final unnamed = <String, UnnamedFinish>{};
  final duplicates = <DuplicateSail>[];
  final betweenRaces = <BetweenRaces>[];
  final entries = <String>[];
  final seen = <String>{};
  final scored = <Race>[];

  for (var r = 0; r < races.length; r++) {
    final boats = <String>[];
    final inRace = <String>{};
    for (final e in races[r]) {
      final sail = e.sail;
      final boat = sail ?? placeholderId(r + 1, e.place);
      if (sail == null) {
        unnamed[boat] = (race: r + 1, place: e.place);
      } else if (!inRace.add(sail)) {
        if (!duplicates.any((d) => d.race == r + 1 && d.sail == sail)) duplicates.add((race: r + 1, sail: sail));
        continue;
      }
      boats.add(boat);
      if (seen.add(boat)) entries.add(boat);
      if (split.betweenRaces.contains(e.ulid)) betweenRaces.add((boat: boat, race: r + 1, place: e.place));
    }
    scored.add(Race(finishes: boats));
  }

  final discards = discardsSet(events, fleet: fleet).clamp(0, races.isEmpty ? 0 : races.length - 1);
  return ProvisionalResults(
    fleet: fleet,
    races: races.length,
    discards: discards,
    standings: races.isEmpty || duplicates.isNotEmpty
        ? const []
        : scoreSeries(Series(entries: entries, races: scored, discards: Discards.count(discards))),
    unnamed: unnamed,
    duplicates: duplicates,
    betweenRaces: betweenRaces,
  );
}

/// The id a finish with no sail number is scored under. A sail number is
/// typed on a digit keypad, so this can never be one.
String placeholderId(int race, int place) => '?R$race-$place';
