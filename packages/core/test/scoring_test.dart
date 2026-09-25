import 'dart:convert';
import 'dart:io';

import 'package:pro_companion_core/core.dart';
import 'package:test/test.dart';

/// #2: the Dart scorer against the golden vectors in fixtures/scoring/ (#83),
/// which are canonical and hand-computed (groom decision G32). Every vector
/// is scored and compared field by field: rank, boat, each race's points,
/// code and excluded flag, gross and net.
///
/// The vectors are read from this repository's checkout, synchronously, and
/// the scorer is synchronous and pure, so nothing here can reach a network or
/// need a credential.

/// fixtures/scoring/ at the repo root, from packages/core where `dart test`
/// runs.
const vectorDir = '../../fixtures/scoring';

List<File> vectorFiles() => Directory(vectorDir)
    .listSync()
    .whereType<File>()
    .where((f) => f.path.endsWith('.json'))
    .toList()
  ..sort((a, b) => a.path.compareTo(b.path));

String baseName(File f) => f.uri.pathSegments.last;

/// The vector files SHA256SUMS lists, so a loader that finds nothing - a
/// moved directory, a wrong path - cannot pass by scoring nothing.
Set<String> manifestVectors() => {
      for (final line in File('$vectorDir/SHA256SUMS').readAsLinesSync())
        if (line.trim().endsWith('.json')) line.trim().split(RegExp(r'\s+')).last,
    };

ScoreCode codeOf(Object? value) {
  final v = value as Map<String, dynamic>;
  final code = ScoreCode.tryParse(v['code'] as String);
  if (code == null) throw FormatException('unknown code ${v['code']}');
  if (code == ScoreCode.rdg && v['redress'] != 'A9(a)') {
    throw FormatException('the scorer gives redress by A9(a) only, not ${v['redress']}');
  }
  return code;
}

/// The vector's input, and nothing from its expected standings.
Series seriesOf(Map<String, dynamic> vector) {
  if (vector['format'] != 'pro-companion-scoring-vector/1') {
    throw FormatException('unknown vector format ${vector['format']}');
  }
  final s = vector['series'] as Map<String, dynamic>;
  final d = s['discards'] as Map<String, dynamic>;
  return Series(
    entries: (s['entries'] as List).cast<String>(),
    discards: d.containsKey('count')
        ? Discards.count(d['count'] as int)
        : Discards.schedule([
            for (final step in d['schedule'] as List)
              DiscardStep(races: step['races'] as int, count: step['count'] as int),
          ]),
    a53: s['a5_3'] as bool,
    races: [
      for (final race in vector['races'] as List)
        Race(
          finishes: (race['finishes'] as List).cast<String>(),
          codes: {
            for (final e in (race['codes'] as Map).entries) e.key as String: codeOf(e.value),
          },
        ),
    ],
  );
}

/// Points in a vector as whole tenths; the README says to compare in tenths.
int tenths(Object? points) {
  final scaled = (points as num) * 10;
  final rounded = scaled.round();
  if ((scaled - rounded).abs() > 1e-9) throw FormatException('$points is not in tenths');
  return rounded;
}

String line(int rank, String boat, List<String> races, int gross, int net) =>
    '$rank $boat | ${races.join(', ')} | $gross $net';

String raceText(int tenths, String? code, bool excluded) =>
    '${code ?? '-'} $tenths${excluded ? ' excl' : ''}';

List<String> expectedLines(Map<String, dynamic> vector) => [
      for (final row in (vector['expected'] as List).cast<Map<String, dynamic>>())
        line(
          row['rank'] as int,
          row['boat'] as String,
          [
            for (final s in (row['races'] as List).cast<Map<String, dynamic>>())
              raceText(tenths(s['points']), s['code'] as String?, s['excluded'] as bool),
          ],
          tenths(row['gross']),
          tenths(row['net']),
        ),
    ];

List<String> actualLines(List<Standing> standings) => [
      for (final s in standings)
        line(
          s.rank,
          s.boat,
          [for (final r in s.races) raceText(r.tenths, r.code?.label, r.excluded)],
          s.grossTenths,
          s.netTenths,
        ),
    ];

List<String> ranksAndBoats(Series series) =>
    [for (final s in scoreSeries(series)) '${s.rank} ${s.boat} ${s.netTenths}'];

void main() {
  final files = vectorFiles();

  test('the vector set read is the whole set SHA256SUMS lists', () {
    expect(files.map(baseName).toSet(), manifestVectors());
    expect(files, isNotEmpty);
  });

  group('the golden vectors (#83)', () {
    for (final f in files) {
      test(baseName(f), () {
        final vector = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        expect(actualLines(scoreSeries(seriesOf(vector))), expectedLines(vector));
      });
    }
  });

  group('a tie A8 cannot break', () {
    // Hand-computed. A5.3 in force; 5 entered. R1: C 1, D 2; A and B DNF;
    // E nothing recorded, so DNC. 4 came, so DNF scores 5 and DNC 6. R2: D 1,
    // C 2; A and B DNF 5; E DNC 6. C 1+2 = 3 and D 2+1 = 3: A8.1 gives
    // [1, 2] each, and A8.2's last race puts D ahead. A and B score 5, 5 = 10
    // in both races alike, so nothing separates them. E 12.
    Series tie(List<String> entries) => Series(
          entries: entries,
          discards: const Discards.count(0),
          a53: true,
          races: const [
            Race(finishes: ['C', 'D'], codes: {'A': ScoreCode.dnf, 'B': ScoreCode.dnf}),
            Race(finishes: ['D', 'C'], codes: {'A': ScoreCode.dnf, 'B': ScoreCode.dnf, 'E': ScoreCode.dnc}),
          ],
        );

    test('shares the rank, and the next boat takes the rank after both', () {
      expect(ranksAndBoats(tie(['A', 'B', 'C', 'D', 'E'])),
          ['1 D 30', '2 C 30', '3 A 100', '3 B 100', '5 E 120']);
    });

    test('lists the tied boats in entry order, not by name', () {
      expect(ranksAndBoats(tie(['B', 'A', 'C', 'D', 'E'])),
          ['1 D 30', '2 C 30', '3 B 100', '3 A 100', '5 E 120']);
    });

    test('shares one rank among three boats', () {
      // 5 entered, no A5.3: DNF scores 6. D 1+2 = 3 and E 2+1 = 3; A8.1
      // gives [1, 2] each and A8.2's last race puts E ahead. A, B and C
      // score DNF 6 in both races, 12 each: one rank for all three.
      expect(
          ranksAndBoats(const Series(
            entries: ['A', 'B', 'C', 'D', 'E'],
            discards: Discards.count(0),
            races: [
              Race(finishes: ['D', 'E'], codes: {'A': ScoreCode.dnf, 'B': ScoreCode.dnf, 'C': ScoreCode.dnf}),
              Race(finishes: ['E', 'D'], codes: {'A': ScoreCode.dnf, 'B': ScoreCode.dnf, 'C': ScoreCode.dnf}),
            ],
          )),
          ['1 E 30', '2 D 30', '3 A 120', '3 B 120', '3 C 120']);
    });

    test('keeps entry order in a fleet too large for the sort to keep it by chance', () {
      // Dart's List.sort is stable only up to 32 elements (insertion sort),
      // so a smaller fleet keeps entry order whether or not the scorer asks
      // for it. 40 entered, listed S40 down to S01; S01 finishes alone and
      // the other 39 score DNC 41 alike: rank 2 for all 39, in entry order.
      final entries = [for (var i = 40; i >= 1; i--) 'S${i.toString().padLeft(2, '0')}'];
      expect(
          ranksAndBoats(Series(
            entries: entries,
            discards: const Discards.count(0),
            races: const [
              Race(finishes: ['S01']),
            ],
          )),
          ['1 S01 10', for (final boat in entries.take(39)) '2 $boat 410']);
    });
  });

  group('hand-computed cases the vectors leave open', () {
    test('a tenth of a point in net decides the order', () {
      // 7 entered: DNF 8, so an SCP adds 1.6. R1 X (SCP) 1st: 2.6, P 2, Q 3,
      // R 4, S 5, Y 6, T 7. R2 P 1, Y (SCP) 2nd: 3.6, X 3, Q 4, R 5, S 6,
      // T 7. R3 Y 1, P 2, Q 3, R 4, X 5, S 6, T 7. P 5, Q 10, X 10.6,
      // Y 10.6, R 13, S 17, T 21: Q's 10 beats 10.6, and A8.1 puts Y [1,
      // 3.6, 6] ahead of X [2.6, 3, 5].
      expect(
          ranksAndBoats(const Series(
            entries: ['P', 'Q', 'R', 'S', 'T', 'X', 'Y'],
            discards: Discards.count(0),
            races: [
              Race(finishes: ['X', 'P', 'Q', 'R', 'S', 'Y', 'T'], codes: {'X': ScoreCode.scp}),
              Race(finishes: ['P', 'Y', 'X', 'Q', 'R', 'S', 'T'], codes: {'Y': ScoreCode.scp}),
              Race(finishes: ['Y', 'P', 'Q', 'R', 'X', 'S', 'T']),
            ],
          )),
          ['1 P 50', '2 Q 100', '3 Y 106', '4 X 106', '5 R 130', '6 S 170', '7 T 210']);
    });

    test('under A5.3 an SCP takes 20% of the A5.3 DNF score, and is capped there', () {
      // 6 entered, F nothing recorded (DNC): 5 came, so DNF scores 6 and DNC
      // 7. 20% of 6 is 1.2. C 3rd + 1.2 = 4.2; E 5th + 1.2 = 6.2, capped at
      // DNF 6.
      expect(
          actualLines(scoreSeries(const Series(
            entries: ['A', 'B', 'C', 'D', 'E', 'F'],
            discards: Discards.count(0),
            a53: true,
            races: [
              Race(finishes: ['A', 'B', 'C', 'D', 'E'], codes: {'C': ScoreCode.scp, 'E': ScoreCode.scp}),
            ],
          ))),
          [
            '1 A | - 10 | 10 10',
            '2 B | - 20 | 20 20',
            '3 D | - 40 | 40 40',
            '4 C | SCP 42 | 42 42',
            '5 E | SCP 60 | 60 60',
            '6 F | DNC 70 | 70 70',
          ]);
    });

    test('under A5.3 OCS and every disqualification score one more than the boats that came', () {
      // 9 entered, F nothing recorded (DNC): 8 came, so each code scores 9
      // and DNC 10. U (UFD) and X (DSQ) crossed the line and vacate their
      // places: A 1, B 2, C 3. O (OCS), Y (DNE) and Z (BFD) are not in the
      // finishing order.
      expect(
          actualLines(scoreSeries(const Series(
            entries: ['A', 'B', 'C', 'O', 'U', 'X', 'Y', 'Z', 'F'],
            discards: Discards.count(0),
            a53: true,
            races: [
              Race(finishes: [
                'A', 'U', 'B', 'X', 'C', //
              ], codes: {
                'O': ScoreCode.ocs,
                'U': ScoreCode.ufd,
                'X': ScoreCode.dsq,
                'Y': ScoreCode.dne,
                'Z': ScoreCode.bfd,
              }),
            ],
          ))),
          [
            '1 A | - 10 | 10 10',
            '2 B | - 20 | 20 20',
            '3 C | - 30 | 30 30',
            '4 O | OCS 90 | 90 90',
            '4 U | UFD 90 | 90 90',
            '4 X | DSQ 90 | 90 90',
            '4 Y | DNE 90 | 90 90',
            '4 Z | BFD 90 | 90 90',
            '9 F | DNC 100 | 100 100',
          ]);
    });

    test('an RDG can be an excluded score', () {
      // Two discards. R1 C 1, A 2, B 3. R2 A 1, B 2, C given redress in 3rd
      // (her place kept). R3 A 1, B 2, C 3. C's RDG averages R1 and R3:
      // (1 + 3) / 2 = 2. A 2,1,1 drops R1 and the earlier 1 (R2): net 1. B
      // 3,2,2 drops R1 and R2: net 2. C 1,2,3 drops R3 and the RDG: net 1.
      // A and C tie: A8.1 [1] and [1], A8.2's R3 A 1 against C 3.
      expect(
          actualLines(scoreSeries(const Series(
            entries: ['A', 'B', 'C'],
            discards: Discards.count(2),
            races: [
              Race(finishes: ['C', 'A', 'B']),
              Race(finishes: ['A', 'B', 'C'], codes: {'C': ScoreCode.rdg}),
              Race(finishes: ['A', 'B', 'C']),
            ],
          ))),
          [
            '1 A | - 20 excl, - 10 excl, - 10 | 40 10',
            '2 C | - 10, RDG 20 excl, - 30 excl | 60 10',
            '3 B | - 30 excl, - 20 excl, - 20 | 70 20',
          ]);
    });

    test("an A9(a) average takes in the boat's code scores", () {
      // 4 entered: DNF 5. R1 A 1, B 2, C 3, D DNF 5. R2 A 1, B 2, C 3, D
      // given redress in 4th. R3 D 1, A 2, B 3, C 4. D's RDG averages R1 and
      // R3: (5 + 1) / 2 = 3. A 4, B 7, D 9, C 10.
      expect(
          actualLines(scoreSeries(const Series(
            entries: ['A', 'B', 'C', 'D'],
            discards: Discards.count(0),
            races: [
              Race(finishes: ['A', 'B', 'C'], codes: {'D': ScoreCode.dnf}),
              Race(finishes: ['A', 'B', 'C', 'D'], codes: {'D': ScoreCode.rdg}),
              Race(finishes: ['D', 'A', 'B', 'C']),
            ],
          ))),
          [
            '1 A | - 10, - 10, - 20 | 40 40',
            '2 B | - 20, - 20, - 30 | 70 70',
            '3 D | DNF 50, RDG 30, - 10 | 90 90',
            '4 C | - 30, - 30, - 40 | 100 100',
          ]);
    });

    test('a race with nobody in the finishing order is scored when a boat may have finished', () {
      // R2's finishing order is empty, but A retired and B was disqualified,
      // and either may have crossed the line first (README, recording
      // conventions), so R2 is a race one boat may have sailed. 3 entered:
      // every code and C's DNC score 4. A 1+4 = 5, B 2+4 = 6, C 3+4 = 7.
      expect(
          ranksAndBoats(const Series(
            entries: ['A', 'B', 'C'],
            discards: Discards.count(0),
            races: [
              Race(finishes: ['A', 'B', 'C']),
              Race(finishes: [], codes: {'A': ScoreCode.ret, 'B': ScoreCode.dsq}),
            ],
          )),
          ['1 A 50', '2 B 60', '3 C 70']);
    });
  });

  group('refuses what it cannot score as given', () {
    Series one(Race race, {List<String> entries = const ['A', 'B', 'C']}) =>
        Series(entries: entries, discards: const Discards.count(0), races: [race]);

    void refuses(Series series, String wording) => expect(
          () => scoreSeries(series),
          throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains(wording))),
        );

    test('a boat entered twice', () {
      refuses(one(const Race(finishes: ['A']), entries: const ['A', 'B', 'A']), 'entered twice');
    });

    test('a finish by a boat not entered', () {
      refuses(one(const Race(finishes: ['A', 'Z'])), 'finishes Z, who is not entered');
    });

    test('a boat finishing twice', () {
      refuses(one(const Race(finishes: ['A', 'B', 'A'])), 'finishes A twice');
    });

    test('a code for a boat not entered', () {
      refuses(one(const Race(finishes: ['A'], codes: {'Z': ScoreCode.dns})), 'scores Z, who is not entered');
    });

    for (final code in [ScoreCode.dnc, ScoreCode.dns, ScoreCode.ocs, ScoreCode.dnf]) {
      test('a boat scored ${code.label} in the finishing order', () {
        refuses(one(Race(finishes: const ['A', 'B'], codes: {'B': code})),
            'B is ${code.label}, so she cannot be in the finishing order');
      });
    }

    test('an SCP boat with no place to score from', () {
      refuses(one(const Race(finishes: ['A'], codes: {'B': ScoreCode.scp})), 'B is SCP');
    });

    test('a negative discard count', () {
      refuses(
          const Series(entries: ['A'], discards: Discards.count(-1), races: []), 'cannot be negative');
    });

    test('a discard schedule whose race counts do not rise', () {
      refuses(
          const Series(
            entries: ['A'],
            discards: Discards.schedule([DiscardStep(races: 4, count: 1), DiscardStep(races: 4, count: 2)]),
            races: [],
          ),
          'rising race counts');
    });

    test('a negative count in a discard schedule', () {
      refuses(
          const Series(
            entries: ['A'],
            discards: Discards.schedule([DiscardStep(races: 1, count: -1)]),
            races: [
              Race(finishes: ['A']),
            ],
          ),
          'cannot be negative: -1');
    });

    test('a race nobody sailed, which rule 35 abandons', () {
      // DNS, OCS and nothing recorded: no boat can have finished.
      refuses(
          one(const Race(finishes: [], codes: {'A': ScoreCode.dns, 'B': ScoreCode.ocs})),
          'race 1: nobody finished, so no boat sailed the course');
      // A race with no results entered yet.
      refuses(one(const Race(finishes: [])), 'race 1: nobody finished, so no boat sailed the course');
    });
  });

  group('refuses the RDG cases the vectors do not cover', () {
    void unsupported(Series series, String wording) => expect(
          () => scoreSeries(series),
          throwsA(isA<UnsupportedError>().having((e) => e.message, 'message', contains(wording))),
        );

    test('more than one RDG for one boat', () {
      unsupported(
          const Series(
            entries: ['A', 'B'],
            discards: Discards.count(0),
            races: [
              Race(finishes: ['A', 'B'], codes: {'A': ScoreCode.rdg}),
              Race(finishes: ['B', 'A'], codes: {'A': ScoreCode.rdg}),
              Race(finishes: ['A', 'B']),
            ],
          ),
          'A has more than one RDG');
    });

    test('an RDG with no other race to average', () {
      unsupported(
          const Series(
            entries: ['A', 'B'],
            discards: Discards.count(0),
            races: [
              Race(finishes: ['A', 'B'], codes: {'A': ScoreCode.rdg}),
            ],
          ),
          'no other race to average');
    });
  });
}
