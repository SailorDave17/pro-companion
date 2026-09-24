import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// #83: fixtures/scoring/ holds the canonical low-point vectors that the Dart
/// port (#2) and burgee's engine are both held to (groom decision G32). This
/// test scores nothing. It refuses a vector that is malformed, uncited,
/// arithmetically inconsistent or out of step with its own race input, a set
/// that stops covering the rules and codes it promises, and a SHA256SUMS that
/// no longer matches the bytes burgee vendors.

const vectorDir = 'fixtures/scoring';
const manifestName = 'SHA256SUMS';
const vectorFormat = 'pro-companion-scoring-vector/1';
const edition = 'RRS 2025-2028';

/// burgee's scoring vocabulary: the codes its engine scores today plus
/// burgee#15's additions (owner decision on #83, 2026-09-24).
const scoringCodes = {
  'DNC', 'DNS', 'DNF', 'OCS', 'RET', 'DSQ', //
  'RDG', 'DNE', 'UFD', 'BFD', 'SCP',
};

/// #2's case list in RRS 2025-2028 numbers, plus A5.3 (owner decision on #83).
const requiredRules = {
  'A4', 'A5.2', 'A2.2', 'A2.1', 'A6.1', 'A6.2', 'A8.1', 'A8.2', //
  'A9(a)', '44.3(c)', '90.3(b)', '30.3', '30.4', 'A5.3',
};

/// A boat scored under one of these did not start or did not finish, so she
/// has no place in the crossing order.
const neverInFinishes = {'DNC', 'DNS', 'OCS', 'DNF'};

final ruleId = RegExp(r'^(A\d{1,2}(\.\d)?|\d{2}\.\d)(\([a-z]\))?$');
final sumLine = RegExp(r'^([0-9a-f]{64})  (\S+)$');

String baseName(FileSystemEntity f) => f.uri.pathSegments.last;

List<File> vectorFiles() => Directory(vectorDir)
    .listSync()
    .whereType<File>()
    .where((f) => f.path.endsWith('.json'))
    .toList()
  ..sort((a, b) => a.path.compareTo(b.path));

/// Points as whole tenths, or null if [v] is not a non-negative number with at
/// most one decimal place.
int? tenths(Object? v) {
  if (v is! num || v < 0) return null;
  final scaled = v * 10;
  final rounded = scaled.round();
  return (scaled - rounded).abs() < 1e-9 ? rounded : null;
}

bool isNonEmptyString(Object? v) => v is String && v.trim().isNotEmpty;

/// Every way [json] fails the vector format, empty when it passes.
List<String> vectorProblems(String name, Object? json) {
  final p = <String>[];
  if (json is! Map<String, dynamic>) return ['top level is not an object'];

  if (json['format'] != vectorFormat) p.add('format is not "$vectorFormat"');
  if (json['id'] != name.replaceAll('.json', '')) {
    p.add('id does not match the file name');
  }
  if (!isNonEmptyString(json['description'])) p.add('description missing');

  final rules = json['rules'];
  final citation = json['citation'];
  if (rules is! List || rules.isEmpty) {
    p.add('rules missing or empty - the vector cites nothing');
  } else {
    for (final r in rules) {
      if (r is! String || !ruleId.hasMatch(r)) p.add('rules: "$r" is not a rule number');
    }
  }
  if (!isNonEmptyString(citation)) {
    p.add('citation missing');
  } else {
    if (!(citation as String).contains(edition)) p.add('citation does not name $edition');
    if (rules is List) {
      for (final r in rules.whereType<String>()) {
        if (!citation.contains(r)) p.add('citation does not mention $r');
      }
    }
  }
  if (json['expected_source'] != 'hand') p.add('expected_source is not "hand"');
  final working = json['working'];
  if (working is! List || working.isEmpty || !working.every(isNonEmptyString)) {
    p.add('working missing: the hand computation is the evidence');
  }

  final series = json['series'];
  if (series is! Map<String, dynamic>) return p..add('series missing');
  final entries = series['entries'];
  if (entries is! List || entries.isEmpty || !entries.every(isNonEmptyString)) {
    return p..add('series.entries must list the boats entered');
  }
  final boats = entries.cast<String>();
  if (boats.toSet().length != boats.length) p.add('series.entries repeats a boat');
  final discards = series['discards'];
  if (discards is! Map<String, dynamic> || discards.length != 1) {
    p.add('series.discards must hold exactly one of count or schedule');
  } else if (discards.containsKey('count')) {
    final c = discards['count'];
    if (c is! int || c < 0) p.add('series.discards.count must be a whole number');
  } else if (discards['schedule'] is List && (discards['schedule'] as List).isNotEmpty) {
    var lastRaces = 0;
    for (final step in discards['schedule'] as List) {
      if (step is! Map || step['races'] is! int || step['count'] is! int ||
          (step['races'] as int) <= lastRaces) {
        p.add('series.discards.schedule steps need rising races and a count');
        break;
      }
      lastRaces = step['races'] as int;
    }
  } else {
    p.add('series.discards must hold count or a non-empty schedule');
  }
  if (series['a5_3'] is! bool) p.add('series.a5_3 must be true or false');

  final races = json['races'];
  if (races is! List || races.isEmpty) return p..add('races missing');
  // The code each boat was recorded under in each race; null for a finisher.
  final recorded = <String, List<String?>>{for (final b in boats) b: []};
  for (var i = 0; i < races.length; i++) {
    final race = races[i];
    final label = 'race ${i + 1}';
    if (race is! Map<String, dynamic> || race['finishes'] is! List || race['codes'] is! Map) {
      return p..add('$label needs finishes and codes');
    }
    final finishes = race['finishes'] as List;
    final codes = race['codes'] as Map;
    if (!finishes.every((b) => boats.contains(b))) p.add('$label finishes a boat not entered');
    if (finishes.toSet().length != finishes.length) p.add('$label finishes a boat twice');
    for (final entry in codes.entries) {
      final boat = entry.key;
      final value = entry.value;
      if (!boats.contains(boat)) p.add('$label codes a boat not entered: $boat');
      if (value is! Map || !scoringCodes.contains(value['code'])) {
        p.add('$label: $boat has no known scoring code');
        continue;
      }
      final code = value['code'] as String;
      if (neverInFinishes.contains(code) && finishes.contains(boat)) {
        p.add('$label: $boat is $code but appears in finishes');
      }
      if ((code == 'RDG') != value.containsKey('redress')) {
        p.add('$label: $boat - redress belongs on RDG and only there');
      }
      if (code == 'RDG' && value['redress'] != 'A9(a)') {
        p.add('$label: $boat - the only redress method in the set is A9(a)');
      }
    }
    for (final b in boats) {
      if (codes.containsKey(b)) {
        final value = codes[b];
        recorded[b]!.add(value is Map ? value['code'] as String? : null);
      } else {
        // Nothing recorded is DNC (README, recording conventions).
        recorded[b]!.add(finishes.contains(b) ? null : 'DNC');
      }
    }
  }

  final expected = json['expected'];
  if (expected is! List || expected.isEmpty) return p..add('expected missing');
  final seen = <String>[];
  num? lastNet;
  for (var i = 0; i < expected.length; i++) {
    final row = expected[i];
    if (row is! Map<String, dynamic>) return p..add('expected row ${i + 1} is not an object');
    final boat = row['boat'];
    final label = 'expected $boat';
    if (!boats.contains(boat)) {
      p.add('expected row ${i + 1} names a boat not entered');
      continue;
    }
    seen.add(boat as String);
    if (row['rank'] != i + 1) p.add('$label: rank must be ${i + 1} at row ${i + 1}');
    final scores = row['races'];
    if (scores is! List || scores.length != races.length) {
      p.add('$label: needs one score per race');
      continue;
    }
    var sum = 0;
    var excludedSum = 0;
    for (var r = 0; r < scores.length; r++) {
      final s = scores[r];
      if (s is! Map || s['excluded'] is! bool) {
        p.add('$label race ${r + 1}: needs points and excluded');
        continue;
      }
      final t = tenths(s['points']);
      if (t == null) {
        p.add('$label race ${r + 1}: points must be whole or tenths');
        continue;
      }
      sum += t;
      if (s['excluded'] == true) excludedSum += t;
      if (s['code'] != recorded[boat]![r]) {
        p.add('$label race ${r + 1}: code ${s['code']} but the race records ${recorded[boat]![r]}');
      }
    }
    final gross = tenths(row['gross']);
    final net = tenths(row['net']);
    if (gross != sum) p.add('$label: gross is not the sum of the race points');
    if (net != sum - excludedSum) p.add('$label: net is not gross less the excluded points');
    if (net != null && lastNet != null && net < lastNet) {
      p.add('$label: ranked below a boat with a higher net score');
    }
    lastNet = net ?? lastNet;
  }
  if (seen.toSet().length != seen.length || seen.toSet().length != boats.length) {
    p.add('expected must rank every entered boat exactly once');
  }
  return p;
}

Map<String, dynamic> readVector(File f) =>
    jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;

void main() {
  final files = vectorFiles();

  group('every vector is well-formed, cited and adds up', () {
    for (final f in files) {
      test(baseName(f), () {
        final problems = vectorProblems(baseName(f), jsonDecode(f.readAsStringSync()));
        expect(problems, isEmpty, reason: problems.join('\n'));
      });
    }
  });

  test("the set covers #2's rules and burgee's scoring vocabulary", () {
    expect(files, isNotEmpty, reason: 'an empty set would pass every other test');
    final vectors = files.map(readVector).toList();
    final rules = {for (final v in vectors) ...(v['rules'] as List).cast<String>()};
    final codes = {
      for (final v in vectors)
        for (final row in v['expected'] as List)
          for (final s in (row as Map)['races'] as List)
            if ((s as Map)['code'] != null) s['code'] as String,
    };
    final discardForms = {
      for (final v in vectors) ((v['series'] as Map)['discards'] as Map).keys.single,
    };
    expect(requiredRules.difference(rules), isEmpty, reason: 'rules with no vector');
    expect(scoringCodes.difference(codes), isEmpty, reason: 'codes with no vector');
    expect(discardForms, containsAll(['count', 'schedule']), reason: 'a discard schedule');
    expect(vectors.any((v) => (v['series'] as Map)['a5_3'] == true), isTrue, reason: 'A5.3');
  });

  test('SHA256SUMS lists every file in the set with its current hash', () {
    final listed = <String, String>{};
    for (final line in File('$vectorDir/$manifestName').readAsLinesSync()) {
      if (line.isEmpty) continue;
      final m = sumLine.firstMatch(line);
      expect(m, isNotNull, reason: 'not a sha256sum line: "$line"');
      listed[m!.group(2)!] = m.group(1)!;
    }
    final present = Directory(vectorDir)
        .listSync()
        .whereType<File>()
        .map(baseName)
        .where((n) => n != manifestName)
        .toSet();
    expect(listed.keys.toSet(), present, reason: 'SHA256SUMS must list exactly the files here');
    listed.forEach((name, hash) {
      final actual = sha256.convert(File('$vectorDir/$name').readAsBytesSync()).toString();
      expect(actual, hash, reason: '$name changed without SHA256SUMS');
    });
  });

  test('the README states the direction and that results are hand-computed', () {
    final readme = File('$vectorDir/README.md').readAsStringSync();
    expect(readme, contains('pro-companion is canonical'));
    expect(readme, contains('burgee vendors'));
    expect(readme, contains('G32'));
    expect(readme, contains('never generated by the Dart port'));
  });
}
