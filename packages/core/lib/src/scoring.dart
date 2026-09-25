import 'dart:math';

/// The scoring codes the engine scores: burgee's scoring vocabulary (owner
/// decision on #83). A10's ZFP, NSC and DPI are outside it.
enum ScoreCode {
  dnc,
  dns,
  ocs,
  dnf,
  ret,
  dsq,
  dne,
  ufd,
  bfd,
  scp,
  rdg;

  /// The code as results print it and the vectors spell it: `DNC`.
  String get label => name.toUpperCase();

  /// The code spelled [label], or null for one outside the vocabulary.
  static ScoreCode? tryParse(String label) {
    for (final c in values) {
      if (c.label == label) return c;
    }
    return null;
  }

  /// Scored as not having started or not having finished, so the record
  /// holds no place for her (fixtures/scoring/README.md, recording
  /// conventions).
  bool get neverFinishes => switch (this) { dnc || dns || ocs || dnf => true, _ => false };

  /// Disqualified, or retired: if she crossed the line anyway, her place is
  /// vacated and every boat behind her moves up one (A6.1).
  bool get vacatesPlace => switch (this) { ret || dsq || dne || ufd || bfd => true, _ => false };
}

/// One step of a notice of race's discard schedule: [count] scores are
/// excluded once at least [races] races are scored.
class DiscardStep {
  const DiscardStep({required this.races, required this.count});

  final int races;
  final int count;
}

/// How many of each boat's scores are excluded (A2.1).
class Discards {
  /// [fixedCount] scores excluded however many races are scored; 0 for none.
  const Discards.count(int this.fixedCount) : schedule = const [];

  /// A schedule: the last step whose `races` is reached applies, and nothing
  /// is excluded below the first.
  const Discards.schedule(this.schedule) : fixedCount = null;

  final int? fixedCount;
  final List<DiscardStep> schedule;

  /// The number of scores excluded once [racesScored] races are scored.
  int countFor(int racesScored) {
    final fixed = fixedCount;
    if (fixed != null) return fixed;
    var count = 0;
    for (final step in schedule) {
      if (racesScored >= step.races) count = step.count;
    }
    return count;
  }
}

/// One race as the committee recorded it. Only a race someone finished is
/// scored: a race with nobody in the finishing order is refused (see
/// [scoreSeries]), so a race still being sailed, or with no results yet, is
/// left out of the series rather than passed in empty.
class Race {
  const Race({required this.finishes, this.codes = const {}});

  /// Boats in the order they crossed the finishing line, first to last. A
  /// boat later disqualified, or retiring after finishing, may be here; one
  /// scored DNC, DNS, OCS or DNF may not.
  final List<String> finishes;

  /// The boats scored under a code. An entered boat with neither a finish nor
  /// a code is still scored (A2.2): she did not come to the starting area, so
  /// she scores DNC, one more than the boats entered (A5.2, and the recording
  /// convention in fixtures/scoring/README.md).
  final Map<String, ScoreCode> codes;
}

/// A series to score: who entered, what each race recorded, and the notice
/// of race's choices.
class Series {
  const Series({
    required this.entries,
    required this.races,
    required this.discards,
    this.a53 = false,
  });

  /// The boats entered in the series. A5.2's "number of boats entered in the
  /// series" is its length, and each is scored for every race (A2.2).
  final List<String> entries;

  final List<Race> races;
  final Discards discards;

  /// The notice of race puts A5.3 in force.
  final bool a53;
}

/// One boat's score in one race.
class RaceScore {
  const RaceScore({required this.tenths, required this.code, required this.excluded});

  /// Her points in whole tenths: 46 is 4.6 points.
  final int tenths;

  /// The code she was scored under, or null for a place.
  final ScoreCode? code;

  /// Left out of her series score (A2.1).
  final bool excluded;

  @override
  String toString() => '${code == null ? '' : '${code!.label} '}${_points(tenths)}${excluded ? ' excl' : ''}';
}

/// One boat's line in the series standings.
class Standing {
  const Standing({
    required this.rank,
    required this.boat,
    required this.races,
    required this.grossTenths,
    required this.netTenths,
  });

  /// 1 leads. Boats A8 cannot separate share a rank - 1, 2, 2, 4 - and are
  /// listed in entry order (owner decision on #2, 2026-09-25; the vectors
  /// hold no such tie).
  final int rank;
  final String boat;

  /// One score per race, in race order.
  final List<RaceScore> races;

  /// Every race's points, in tenths.
  final int grossTenths;

  /// The series score: gross less the excluded scores, in tenths.
  final int netTenths;

  @override
  String toString() => 'Standing($rank $boat ${races.join(', ')} | ${_points(grossTenths)} ${_points(netTenths)})';
}

/// Low-point series standings for [series], best first, under Appendix A of
/// the Racing Rules of Sailing 2025-2028 (#2).
///
/// Held to the golden vectors in fixtures/scoring/ (#83), which are canonical
/// (groom decision G32) and hand-computed. Rule numbers are the 2025-2028
/// edition's: the points table is A4, and "one more than the number of boats
/// entered" is A5.2 (fixtures/scoring/README.md, Edition).
///
/// Points are carried in whole tenths, never as floating point: A9(a) and
/// 44.3(c) round to a tenth, and the vectors compare in tenths.
///
/// Pure and synchronous, like the rest of the core's domain rules. Throws an
/// [ArgumentError] for a record that cannot be scored as given - among them a
/// race nobody finished, which rule 35 abandons and 90.3(a) leaves unscored -
/// and an [UnsupportedError] for a case the vectors do not cover and the
/// engine will not guess at: more than one RDG for one boat, or an A9(a)
/// average with no other race to take it from.
///
/// Known limit, under A5.3 only: a boat scored RDG, DSQ, DNE, UFD or BFD is
/// counted as having come to the starting area, because the golden set's
/// recording convention counts every boat but a DNC, and one code cannot say
/// whether she came. For one that did not, the race's other A5.3 scores come
/// out too high, which A6.2 forbids for redress, and a disqualified boat is
/// scored as one that came. #92 adds a way to record it.
List<Standing> scoreSeries(Series series) {
  _validate(series);
  final entries = series.entries;
  final raceCount = series.races.length;
  final entered = entries.length;
  final codes = {for (final b in entries) b: List<ScoreCode?>.filled(raceCount, null)};
  // Null for an RDG until her other races are scored.
  final tenths = {for (final b in entries) b: List<int?>.filled(raceCount, null)};

  for (var r = 0; r < raceCount; r++) {
    final race = series.races[r];
    final finished = race.finishes.toSet();
    ScoreCode? codeOf(String boat) =>
        race.codes[boat] ?? (finished.contains(boat) ? null : ScoreCode.dnc);

    // A5.2: one more than the boats entered in the series. Under A5.3, a boat
    // that came to the starting area - every boat but a DNC, by the golden
    // set's recording convention, which is the known limit #92 addresses -
    // scores one more than the boats that came, and a DNC keeps A5.2's score.
    final dnc = entered + 1;
    final came = entered - entries.where((b) => codeOf(b) == ScoreCode.dnc).length;
    final dnf = series.a53 ? came + 1 : dnc;

    // A4 scores each place after A6.1 has vacated the places of boats
    // disqualified or retiring after finishing. An SCP or RDG boat keeps her
    // place, so nobody behind her moves (44.3(c), A6.2).
    final place = <String, int>{};
    for (final boat in race.finishes) {
      if (race.codes[boat]?.vacatesPlace ?? false) continue;
      place[boat] = place.length + 1;
    }

    for (final boat in entries) {
      final code = codeOf(boat);
      codes[boat]![r] = code;
      tenths[boat]![r] = switch (code) {
        null => place[boat]! * 10,
        ScoreCode.dnc => dnc * 10,
        ScoreCode.dns ||
        ScoreCode.ocs ||
        ScoreCode.dnf ||
        ScoreCode.ret ||
        ScoreCode.dsq ||
        ScoreCode.dne ||
        ScoreCode.ufd ||
        ScoreCode.bfd =>
          dnf * 10,
        ScoreCode.scp => _scoringPenalty(place[boat]!, dnf),
        ScoreCode.rdg => null,
      };
    }
  }

  // A9(a): an RDG scores the average of her points in every other race of
  // the series, to the nearest tenth with 0.05 rounded upward.
  for (final boat in entries) {
    final scores = tenths[boat]!;
    for (var r = 0; r < raceCount; r++) {
      if (codes[boat]![r] != ScoreCode.rdg) continue;
      final others = [for (var o = 0; o < raceCount; o++) if (o != r) scores[o]];
      if (others.contains(null)) {
        throw UnsupportedError('$boat has more than one RDG; A9(a) averages her other races, '
            'and more than one RDG for one boat is outside the golden vectors');
      }
      if (others.isEmpty) {
        throw UnsupportedError('$boat has an RDG with no other race to average (A9(a)); '
            'A9(b) and A9(c) are outside the golden vectors');
      }
      scores[r] = _roundHalfUp(others.fold<int>(0, (sum, t) => sum + t!), others.length);
    }
  }

  final discards = series.discards.countFor(raceCount);
  final rows = [
    for (var i = 0; i < entered; i++)
      _row(i, entries[i], [for (final t in tenths[entries[i]]!) t!], codes[entries[i]]!, discards),
  ];

  rows.sort((a, b) {
    final byRules = _compare(a, b);
    return byRules != 0 ? byRules : a.entryIndex.compareTo(b.entryIndex);
  });

  final standings = <Standing>[];
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    final tied = i > 0 && _compare(rows[i - 1], row) == 0;
    standings.add(Standing(
      rank: tied ? standings.last.rank : i + 1,
      boat: row.boat,
      races: [
        for (var r = 0; r < raceCount; r++)
          RaceScore(tenths: row.scores[r], code: row.codes[r], excluded: row.excluded.contains(r)),
      ],
      grossTenths: row.gross,
      netTenths: row.net,
    ));
  }
  return standings;
}

/// 44.3(c) with no number of points stated: the place's score made worse by
/// 20% of the DNF score, and never worse than DNF. In tenths. The rule rounds
/// the 20% to the nearest tenth, but a DNF score is always whole points (A5.2,
/// A5.3), so 20% of it is always a whole number of tenths - two per point -
/// and the rounding never changes it.
int _scoringPenalty(int place, int dnf) => min(place * 10 + dnf * 2, dnf * 10);

/// [numerator] / [denominator] to the nearest whole number, halves upward.
/// Both are non-negative.
int _roundHalfUp(int numerator, int denominator) =>
    (2 * numerator + denominator) ~/ (2 * denominator);

_Row _row(int entryIndex, String boat, List<int> scores, List<ScoreCode?> codes, int discards) {
  // A2.1 excludes her worst scores; for equal worst scores, the races sailed
  // earliest. 90.3(b): a DNE is never excluded.
  final excludable = [
    for (var r = 0; r < scores.length; r++)
      if (codes[r] != ScoreCode.dne) r,
  ]..sort((a, b) {
      final worseFirst = scores[b].compareTo(scores[a]);
      return worseFirst != 0 ? worseFirst : a.compareTo(b);
    });
  final excluded = excludable.take(discards).toSet();
  final gross = scores.fold<int>(0, (sum, t) => sum + t);
  final net = gross - excluded.fold<int>(0, (sum, r) => sum + scores[r]);
  return _Row(entryIndex, boat, scores, codes, excluded, gross, net);
}

/// The rules' order between two boats: net score, then A8.1, then A8.2.
/// Zero means the rules cannot separate them.
int _compare(_Row a, _Row b) {
  final byNet = a.net.compareTo(b.net);
  if (byNet != 0) return byNet;

  // A8.1: each boat's scores listed best to worst, and at the first
  // difference the better score wins. No excluded scores are used.
  final countedA = a.counted;
  final countedB = b.counted;
  for (var i = 0; i < min(countedA.length, countedB.length); i++) {
    final c = countedA[i].compareTo(countedB[i]);
    if (c != 0) return c;
  }

  // A8.2: the last race, then the next-to-last and so on, excluded scores
  // included.
  for (var r = a.scores.length - 1; r >= 0; r--) {
    final c = a.scores[r].compareTo(b.scores[r]);
    if (c != 0) return c;
  }
  return 0;
}

class _Row {
  _Row(this.entryIndex, this.boat, this.scores, this.codes, this.excluded, this.gross, this.net);

  final int entryIndex;
  final String boat;
  final List<int> scores;
  final List<ScoreCode?> codes;
  final Set<int> excluded;
  final int gross;
  final int net;

  /// Her counted scores, best first.
  late final List<int> counted = [
    for (var r = 0; r < scores.length; r++)
      if (!excluded.contains(r)) scores[r],
  ]..sort();
}

void _validate(Series series) {
  final entries = series.entries;
  if (entries.toSet().length != entries.length) {
    throw ArgumentError('a boat is entered twice: $entries');
  }
  final entered = entries.toSet();

  final discards = series.discards;
  final fixed = discards.fixedCount;
  if (fixed != null && fixed < 0) throw ArgumentError('a discard count cannot be negative: $fixed');
  var lastRaces = -1;
  for (final step in discards.schedule) {
    if (step.races <= lastRaces) throw ArgumentError('a discard schedule needs rising race counts');
    if (step.count < 0) throw ArgumentError('a discard count cannot be negative: ${step.count}');
    lastRaces = step.races;
  }

  for (var r = 0; r < series.races.length; r++) {
    final race = series.races[r];
    final label = 'race ${r + 1}';
    final seen = <String>{};
    for (final boat in race.finishes) {
      if (!entered.contains(boat)) throw ArgumentError('$label finishes $boat, who is not entered');
      if (!seen.add(boat)) throw ArgumentError('$label finishes $boat twice');
    }
    race.codes.forEach((boat, code) {
      if (!entered.contains(boat)) throw ArgumentError('$label scores $boat, who is not entered');
      if (code.neverFinishes && seen.contains(boat)) {
        throw ArgumentError('$label: $boat is ${code.label}, so she cannot be in the finishing order');
      }
      if (code == ScoreCode.scp && !seen.contains(boat)) {
        throw ArgumentError('$label: $boat is SCP, which scores from her place, '
            'so she must be in the finishing order (44.3(c))');
      }
    });
    // Rule 35: a race no boat sailed is abandoned, and 90.3(a) scores only a
    // race one boat sailed. With nobody in the finishing order, a boat can
    // still have finished only if she is scored as retiring or disqualified
    // after it, so only a race with neither is refused.
    if (race.finishes.isEmpty && !race.codes.values.any((c) => c.vacatesPlace)) {
      throw ArgumentError('$label: nobody finished, so no boat sailed the course and the race '
          'is abandoned, not scored (rule 35, 90.3(a)); leave it out of the series');
    }
  }
}

String _points(int tenths) =>
    tenths % 10 == 0 ? '${tenths ~/ 10}' : '${tenths ~/ 10}.${tenths % 10}';
