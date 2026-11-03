import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion_core/core.dart';

import 'support/local_stack.dart';

/// #75 criterion 1: the critical-kind map in docs/roles.md ("The critical kinds, kind by kind") is
/// the server's, public.critical_kind and public.critical_correction, which append_event reads.
/// The first group needs only the doc and the core; the second reads the server's map from the
/// local stack.
void main() {
  final doc = File('docs/roles.md').readAsStringSync();
  final lines = doc.split('\n');

  List<String> cellsOf(String line) => line.split('|').map((cell) => cell.trim()).toList();

  /// The rows of the table whose header's first cell is [first], each as its cells.
  List<List<String>> table(String first) {
    final start = lines.indexWhere((l) => l.startsWith('|') && cellsOf(l)[1] == first);
    expect(start, isNot(-1), reason: 'docs/roles.md has a table headed $first');
    return [
      cellsOf(lines[start]),
      for (final l in lines.skip(start + 2).takeWhile((l) => l.startsWith('|'))) cellsOf(l),
    ];
  }

  String unquote(String cell) {
    final m = RegExp(r'^`([a-z_.]+)`$').firstMatch(cell);
    expect(m, isNotNull, reason: '"$cell" is one backticked name');
    return m!.group(1)!;
  }

  /// The roles table's display names, mapped to the stored role.
  Map<String, String> storedRoles() => {
        for (final line in lines)
          if (cellsOf(line) case [_, final name, final stored, _, ...]
              when RegExp(r'^`[a-z_]+`$').hasMatch(stored))
            name: unquote(stored),
      };

  const reaches = {
    'its race area': 'race_area',
    'any race area': 'any',
    'any race area, or event-wide': 'event',
  };

  /// Every (kind, role, reach) the doc's kind-by-kind table allows.
  Set<String> docKinds() {
    final rows = table('Kind');
    final roles = storedRoles();
    final header = rows.first;
    final columns = [for (final name in header.sublist(2, header.length - 1)) roles[name]];
    expect(columns, isNot(contains(null)), reason: 'every column is a role of the roles table: $header');
    return {
      for (final row in rows.skip(1))
        for (final (i, cell) in row.sublist(2, row.length - 1).indexed)
          if (cell != '—') '${unquote(row[1])} ${columns[i]} ${reaches[cell] ?? 'unknown cell "$cell"'}',
    };
  }

  /// Every (correction, target) the doc's corrections table names.
  Set<String> docCorrections() => {for (final row in table('Correction').skip(1)) '${unquote(row[1])} ${unquote(row[3])}'};

  group('the doc and the core', () {
    test('every column is one of the six roles, once', () {
      final header = table('Kind').first;
      final roles = storedRoles();
      expect({for (final name in header.sublist(2, header.length - 1)) roles[name]},
          {'overall_pro', 'course_pro', 'recorder', 'mark_boat', 'safety', 'scorer'});
    });

    test('the map names only kinds the core writes, and the two named ahead of it', () {
      final kinds = {for (final k in docKinds()) k.split(' ').first};
      expect(kinds.difference(EventKinds.all), {'race.abandoned', 'results.released'},
          reason: 'a kind the core does not write is a typo, unless it is one of the two named for '
              'the stories that add them; once the core writes one, drop it from this set');
    });

    test("every start kind the core writes is in the map or judged as one, #33's two included", () {
      final kinds = {
        for (final k in docKinds()) k.split(' ').first,
        for (final c in docCorrections()) c.split(' ').first,
      };
      expect(kinds, containsAll(EventKinds.all.where((k) => k == 'start' || k.startsWith('start.'))));
      expect(kinds, containsAll({'start.sequence_start', 'start.signal'}));
    });

    test('the kinds the core writes with no fleet, only the event they correct, are corrections (the review of #75)', () {
      final corrections = {for (final c in docCorrections()) c.split(' ').first};
      expect(corrections,
          containsAll({'finish.sail', 'finish.undo', 'start.undo', 'start.time_corrected', 'start.ocs_cleared', 'course.undo'}));
    });

    test('the corrections are kinds the core writes, and none is a critical kind of its own', () {
      final corrections = {for (final c in docCorrections()) c.split(' ').first};
      expect(EventKinds.all, containsAll(corrections));
      expect({for (final k in docKinds()) k.split(' ').first}.intersection(corrections), isEmpty);
    });

    test('safety writes no critical kind, and every cell is one of the three reaches or —', () {
      expect(docKinds().where((k) => k.contains(' safety ')), isEmpty);
      expect(docKinds().where((k) => k.contains('unknown cell')), isEmpty);
    });
  });

  group('the server (#75 criterion 1)', () {
    late LocalStack stack;
    setUpAll(() async => stack = await LocalStack.connect());

    test("append_event's map is the doc's table, row for row", () async {
      final map = await stack.criticalKindMap();
      expect({for (final r in map.kinds) '${r['kind']} ${r['role']} ${r['reach']}'}, docKinds());
    });

    test("and its corrections are the doc's", () async {
      final map = await stack.criticalKindMap();
      expect({for (final r in map.corrections) '${r['kind']} ${r['target']}'}, docCorrections());
    });
  }, skip: localStackRequested ? false : localStackSkip);
}
