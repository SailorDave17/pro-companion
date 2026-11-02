import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #33: ADR 004 says a release build trusts race-timer's package and its two field keys and nothing
/// else, and android/app/build.gradle.kts compiles that list in. This holds the two together: a key
/// added to one and not the other fails here rather than on the water, where the companion would
/// refuse race-timer and only its refusal log would say so. scripts/check_release_signing.sh holds
/// a release APK to the ADR the same way.
void main() {
  final adr = File('docs/adr/004-race-timer-link.md').readAsStringSync();
  final gradle = File('android/app/build.gradle.kts').readAsStringSync();
  final sha256 = RegExp(r'^[0-9a-f]{64}$');

  // Longer than a digest and it is still read, so one with a character added differs here rather
  // than disappearing from the set.
  final hexRun = RegExp(r'[0-9a-fA-F]{32,}');

  // Play Console's previous app-signing key for race-timer. ADR 004 records it and leaves it
  // unpinned: whether a Play install matches it was not measured, and #167 records whether it matters.
  const previousPlayKey = '577e91f860496f5c2411d843020f4774d8ddb9859d7edc71a33bf188e577a2b3';

  /// ADR 004's table "The companion trusts race-timer", and nothing from the table after it.
  String trustsRaceTimer() => adr.substring(
      adr.indexOf('**The companion trusts race-timer**'), adr.indexOf('**race-timer trusts the companion**'));

  /// The SHA-256 cell of each row of that table whose first cell is [row], without its backticks.
  List<String> pinned(String row) => [
        for (final line in trustsRaceTimer().split('\n'))
          if (line.split('|').map((c) => c.trim()).toList() case [_, final name, _, final digest, _, _]
              when name == row)
            digest.replaceAll('`', ''),
      ];

  Set<String> compiledIn() => {for (final m in hexRun.allMatches(gradle)) m.group(0)!};

  test("ADR 004 records one digest for each of race-timer's field keys", () {
    for (final row in ['from Play', 'sideloaded release']) {
      expect(pinned(row), hasLength(1), reason: 'ADR 004 has one "$row" row');
      expect(pinned(row).single, matches(sha256));
    }
  });

  test("build.gradle.kts pins exactly ADR 004's two field keys", () {
    expect(compiledIn(), {...pinned('from Play'), ...pinned('sideloaded release')},
        reason: 'a release build trusts these and nothing else, so a third digest here is a key '
            'the ADR never agreed to');
  });

  test("Play's previous key stays unpinned", () {
    expect(adr, contains(previousPlayKey), reason: 'the key this holds out is the one the ADR records');
    expect(gradle, isNot(contains(previousPlayKey)));
  });

  test("build.gradle.kts pins race-timer's package as ADR 004 names it", () {
    final named = RegExp(r'\*\*The companion trusts race-timer\*\*, package `([^`]+)`').firstMatch(adr);
    final compiled = RegExp(r'val linkTrustedPackage = "([^"]+)"').firstMatch(gradle);
    expect(named, isNotNull, reason: 'ADR 004 names the package at its table');
    expect(compiled, isNotNull, reason: 'build.gradle.kts declares linkTrustedPackage');
    expect(compiled!.group(1), named!.group(1));
  });
}
