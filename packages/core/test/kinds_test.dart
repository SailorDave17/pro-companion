import 'dart:io';

import 'package:pro_companion_core/core.dart';
import 'package:test/test.dart';

/// #6 criterion 6 uploads one event of every kind, taken from [EventKinds.all].
/// That is only "every kind" while the set holds every kind a `*Kinds` class
/// declares, so this reads the classes' source and fails on a kind the set
/// lacks. It reads source because Dart has no reflection over constants in an
/// AOT build.

/// The kinds declared in each `*Kinds` class in [source]: every `static const`
/// holding a string, typed or not, in either quote style, whatever modifiers
/// the class carries. A `static const` that is neither a string nor a set
/// literal is reported in [unreadable], so a kind declared some other way
/// fails the check rather than slipping past it.
({Map<String, Set<String>> kinds, List<String> unreadable}) declaredKinds(String source) {
  final classes = RegExp(r'^(?:[a-z]+ )*class (\w+Kinds)\b[^{]*\{(.*?)^\}', multiLine: true, dotAll: true);
  final constant = RegExp(r'static const (?:\w+ )?(\w+) = (.*?);', dotAll: true);
  final string = RegExp(r'''^(['"])([^'"]+)\1$''');
  final kinds = <String, Set<String>>{};
  final unreadable = <String>[];
  for (final c in classes.allMatches(source)) {
    final found = kinds[c.group(1)!] = <String>{};
    for (final k in constant.allMatches(c.group(2)!)) {
      final value = k.group(2)!.trim();
      final s = string.firstMatch(value);
      if (s != null) {
        found.add(s.group(2)!);
      } else if (!value.startsWith('{')) {
        unreadable.add('${c.group(1)}.${k.group(1)} = $value');
      }
    }
  }
  return (kinds: kinds, unreadable: unreadable);
}

void main() {
  test('the scan finds a kind however it is declared, and nothing outside a *Kinds class', () {
    const source = '''
abstract final class WeatherKinds {
  static const gust = 'weather.gust';
  static const String lull = "weather.lull";
  static const all = {gust, lull};
}

final class TideKinds {
  static const turn = 'tide.turn';
}

class CurrentKinds {
  static const set = 'current.set';
  static const drift = CurrentKinds.set;
}

abstract final class Other {
  static const notAKind = 'not.a.kind';
}
''';
    final scan = declaredKinds(source);
    expect(scan.kinds, {
      'WeatherKinds': {'weather.gust', 'weather.lull'},
      'TideKinds': {'tide.turn'},
      'CurrentKinds': {'current.set'},
    });
    expect(scan.unreadable, ['CurrentKinds.drift = CurrentKinds.set']);
  });

  test('every kind a *Kinds class declares is in EventKinds.all', () {
    final declared = <String, Set<String>>{};
    final unreadable = <String>[];
    for (final f in Directory('lib/src').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final scan = declaredKinds(f.readAsStringSync());
      declared.addAll(scan.kinds);
      unreadable.addAll(scan.unreadable);
    }
    // The scan must reach every feature that declares kinds, or it proves nothing.
    expect(declared.keys, containsAll(['FinishKinds', 'FleetKinds', 'StartKinds', 'ResultsKinds']));
    expect(unreadable, isEmpty, reason: 'a *Kinds constant the scan cannot read');
    final all = declared.values.expand((k) => k).toSet();
    expect(all.length, greaterThanOrEqualTo(13));
    expect(EventKinds.all, containsAll(all), reason: 'missing: ${all.difference(EventKinds.all)}');
    expect(all, containsAll(EventKinds.all), reason: 'EventKinds.all holds a kind no class declares');
  });
}
