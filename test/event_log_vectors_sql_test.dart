import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../scripts/write_event_log_vector_test.dart' as vectors;

/// #40 criterion 8: supabase/tests/event_log_vectors_test.sql embeds every
/// chain vector in fixtures/chain/ verbatim, because pgTAP cannot read the
/// repo. These fail when the committed file is not what the script writes
/// from the fixtures today, so a changed vector cannot leave the database test
/// checking an old copy.
void main() {
  final committed = File(vectors.outputPath).readAsStringSync().replaceAll('\r\n', '\n');

  test('the pgTAP vector test is exactly what the script writes from fixtures/chain/', () {
    expect(committed, vectors.render(vectors.readVectors()),
        reason: 'run: dart run scripts/write_event_log_vector_test.dart');
  });

  test('it checks every vector in fixtures/chain/, each once', () {
    final files = Directory(vectors.vectorDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .map((f) => f.uri.pathSegments.last)
        .toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      final checks = RegExp('^-- ${RegExp.escape('${vectors.vectorDir}/$file')}\n'
              r'select is\(pg_temp\.check_vector\(', multiLine: true)
          .allMatches(committed);
      expect(checks, hasLength(1), reason: file);
    }
  });
}
