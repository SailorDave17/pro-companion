import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #27 criterion 3: the field key's certificate digest is recorded in
/// docs/field-builds.md, and pro-companion ADR 004 pins it in its table
/// "race-timer trusts the companion". race-timer compiles that pin in, so this
/// holds the two docs together: a new key recorded in one and not the other
/// fails here rather than on the club phone, where race-timer would refuse to
/// bind without a word.
void main() {
  final guide = File('docs/field-builds.md').readAsStringSync();
  final adr = File('docs/adr/004-race-timer-link.md').readAsStringSync();
  final sha256 = RegExp(r'^[0-9a-f]{64}$');

  /// The digests on the guide's `- SHA-256: `…`` lines.
  List<String> recorded() => [
        for (final m in RegExp(r'^- SHA-256: `([^`]*)`$', multiLine: true).allMatches(guide))
          m.group(1)!,
      ];

  /// The SHA-256 cell of each ADR 004 table row whose first cell is the field build.
  List<String> pinned() => [
        for (final line in adr.split('\n'))
          if (line.split('|').map((c) => c.trim()).toList()
              case [_, 'field build (G20)', _, final digest, _, _])
            digest,
      ];

  test('the guide records one SHA-256 for the field key', () {
    expect(recorded(), hasLength(1));
    expect(recorded().single, matches(sha256));
  });

  test("ADR 004's field-build row pins the digest the guide records", () {
    expect(pinned(), hasLength(1), reason: 'ADR 004 has one "field build (G20)" row');
    expect(pinned().single, '`${recorded().single}`');
  });
}
