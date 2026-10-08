import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/stations/station_screen.dart';
import 'package:pro_companion_core/core.dart';

/// #26 criterion 2: the standard set's ids are documented in docs/marks.md.
/// packages/core/test/stations_test.dart pins each id; this holds the doc's
/// table to the code, in the picker's order, and the label beside each id to
/// the one the picker shows.
void main() {
  final doc = File('docs/marks.md').readAsStringSync();

  /// Each table row's stored id and its "Shown as" cell, in table order.
  List<(String, String)> rows() => [
        for (final line in doc.split('\n'))
          if (line.split('|').map((c) => c.trim()).toList() case [_, _, final stored, final shown, _]
              when RegExp(r'^`[a-z0-9_]+`$').hasMatch(stored))
            (stored.substring(1, stored.length - 1), shown),
      ];

  test("the table lists exactly the core's standard set, in the picker's order", () {
    expect([for (final (id, _) in rows()) id], StandardMarks.all);
  });

  test('each row shows the label the picker shows', () {
    for (final (id, shown) in rows()) {
      expect(shown, markName(id).toUpperCase(), reason: id);
    }
  });
}
