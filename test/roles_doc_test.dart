import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../scripts/owner.dart' as owner;

/// #57 criterion 4: docs/roles.md lists groom decision G28's six roles, marks
/// the three that G38 binds to one race area, and says the signal boat is the
/// PRO. supabase/tests/roles_test.sql holds the server's check to the same six.
/// Since #65 the owner script issues its codes from the same split.
void main() {
  final doc = File('docs/roles.md').readAsStringSync();

  /// Each table row's stored value, mapped to its "Where it works" cell.
  Map<String, String> scopes() {
    final rows = <String, String>{};
    for (final line in doc.split('\n')) {
      final cells = line.split('|').map((cell) => cell.trim()).toList();
      if (cells.length < 5) continue;
      final stored = RegExp(r'^`([a-z_]+)`$').firstMatch(cells[2]);
      if (stored == null) continue;
      rows[stored.group(1)!] = cells[3];
    }
    return rows;
  }

  test('the table lists exactly the six roles of G28', () {
    expect(scopes().keys.toSet(),
        {'overall_pro', 'course_pro', 'recorder', 'mark_boat', 'safety', 'scorer'});
  });

  test('course_pro, recorder and mark_boat work on one race area, the rest event-wide (G38)', () {
    final scope = scopes();
    for (final role in ['course_pro', 'recorder', 'mark_boat']) {
      expect(scope[role], '**One race area**', reason: role);
    }
    for (final role in ['overall_pro', 'scorer', 'safety']) {
      expect(scope[role], '**Event-wide**', reason: role);
    }
  });

  test('#65: the owner script issues per-race-area codes for exactly the roles the table binds', () {
    final scope = scopes();
    expect(owner.raceAreaRoles.toSet(),
        {for (final e in scope.entries) if (e.value == '**One race area**') e.key});
    expect(owner.eventWideRoles.toSet(),
        {for (final e in scope.entries) if (e.value == '**Event-wide**') e.key});
  });

  test('the doc says the signal boat is the PRO, and lists no role for it (G28)', () {
    expect(doc, contains('**The signal boat is the PRO (G28).**'));
    expect(scopes().keys, isNot(contains('signal_boat')));
  });
}
