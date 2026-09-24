import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// #39: "no key value appears anywhere in git". Every tracked file is scanned for the shapes of a
// Supabase credential. Runs under `flutter test`, so it is part of the CI gate on every PR.
//
// The shapes, not the values: a personal access token (sbp_ + 40 hex), the new secret and
// publishable keys, and a three-part JWT (the legacy anon and service_role keys). The publishable
// key is not a secret by design and is still refused here, because the rule this test enforces is
// "names in git, values in secrets" — one rule for every credential is one nobody has to think about.
final Map<String, RegExp> credentialShapes = {
  'Supabase personal access token': RegExp(r'sbp_[0-9a-f]{40}'),
  'Supabase secret key': RegExp(r'sb_secret_[A-Za-z0-9_-]{16,}'),
  'Supabase publishable key': RegExp(r'sb_publishable_[A-Za-z0-9_-]{16,}'),
  'JWT': RegExp(r'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'),
};

const int maxScannedBytes = 2 * 1024 * 1024;

Future<List<String>> trackedFiles() async {
  final result = await Process.run('git', ['ls-files', '-z']);
  if (result.exitCode != 0) {
    throw StateError('git ls-files failed: ${result.stderr}');
  }
  return (result.stdout as String)
      .split('\u0000')
      .where((path) => path.isNotEmpty)
      .toList();
}

void main() {
  test('no Supabase credential value is tracked in git', () async {
    final files = await trackedFiles();
    expect(files, isNotEmpty, reason: 'the scan must see the tracked tree');

    final hits = <String>[];
    for (final path in files) {
      final file = File(path);
      if (!file.existsSync()) continue; // deleted in the working tree, still tracked
      final bytes = file.readAsBytesSync();
      if (bytes.length > maxScannedBytes) continue;
      final text = String.fromCharCodes(bytes);
      credentialShapes.forEach((label, shape) {
        if (shape.hasMatch(text)) hits.add('$path: $label');
      });
    }

    expect(hits, isEmpty,
        reason: 'credential-shaped strings in tracked files — rotate them, then remove them:\n'
            '${hits.join('\n')}');
  });

  test('.env.example names variables and carries no values', () {
    final lines = File('.env.example').readAsLinesSync();
    final assignments = lines
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList();
    expect(assignments, isNotEmpty, reason: '.env.example must name at least one variable');
    for (final line in assignments) {
      expect(line, matches(RegExp(r'^[A-Z][A-Z0-9_]*=$')),
          reason: '.env.example line must be NAME= with no value: "$line"');
    }
  });
}
