import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #24 criterion 8 - the enforced answer to "front end or back end?" (ADR 001,
/// groom decision G1). UI code under lib/ reaches the core only through its
/// interface, never the network or the store; the core under packages/core
/// never imports Flutter or the network.
///
/// Reads import and export directives as text, so it cannot be fooled by code
/// that happens not to be called, and it runs without compiling anything.

/// A rule is a URI prefix that a set of files must not import or export.
class Rule {
  const Rule(this.prefix, this.why);
  final String prefix;
  final String why;
}

const uiForbidden = [
  Rule('dart:io', 'sockets and HTTP live in dart:io; the UI never calls the network'),
  Rule('package:http/', 'the UI never calls the network'),
  Rule('package:supabase', 'the UI never calls the server; sync is the core\'s'),
  Rule('package:sqlite3/', 'the UI never touches the store'),
  Rule('package:pro_companion_core/store.dart', 'the UI never touches the store'),
  Rule('package:pro_companion_core/src/', 'the UI sees only the core\'s public interface'),
];

const coreForbidden = [
  Rule('package:flutter/', 'the core is pure Dart, so it can run headless'),
  Rule('dart:ui', 'the core is pure Dart, so it can run headless'),
  Rule('dart:io', 'the core makes no network calls'),
  Rule('package:http/', 'the core makes no network calls until sync (#6)'),
  Rule('package:supabase', 'the core makes no network calls until sync (#6)'),
];

final _directive = RegExp(r'''^\s*(?:import|export)\b([^;]*);''', multiLine: true);
final _quoted = RegExp(r'''['"]([^'"]+)['"]''');

/// Every URI named by an import or export in [source], conditional ones too.
List<String> directiveUris(String source) => [
      for (final d in _directive.allMatches(source))
        for (final q in _quoted.allMatches(d.group(1)!)) q.group(1)!,
    ];

/// `file: uri - why` for each forbidden URI in [source].
List<String> violations(String file, String source, List<Rule> rules) => [
      for (final uri in directiveUris(source))
        for (final r in rules)
          if (uri == r.prefix || uri.startsWith(r.prefix) || _reachesIntoCore(uri, r))
            '$file: $uri - ${r.why}',
    ];

/// A relative import into packages/core would dodge the package: URI rules.
bool _reachesIntoCore(String uri, Rule r) =>
    r.prefix.startsWith('package:pro_companion_core/') && uri.contains('packages/core/');

List<File> dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  group('the checker itself', () {
    test('finds a planted forbidden import of each kind', () {
      expect(violations('x', "import 'dart:io';", uiForbidden), hasLength(1));
      expect(violations('x', 'import "package:http/http.dart" as http;', uiForbidden), hasLength(1));
      expect(violations('x', "import 'package:supabase_flutter/supabase_flutter.dart';", uiForbidden),
          hasLength(1));
      expect(violations('x', "import 'package:sqlite3/sqlite3.dart';", uiForbidden), hasLength(1));
      expect(violations('x', "import 'package:pro_companion_core/store.dart';", uiForbidden),
          hasLength(1));
      expect(violations('x', "import 'package:pro_companion_core/src/store.dart';", uiForbidden),
          hasLength(1));
      expect(violations('x', "import '../packages/core/lib/src/store.dart';", uiForbidden),
          isNotEmpty);
      expect(violations('x', "export 'dart:io' show File;", uiForbidden), hasLength(1));
      expect(violations('x', "import 'a.dart' if (dart.library.io) 'dart:io';", uiForbidden),
          hasLength(1));
      expect(violations('x', "import 'package:flutter/foundation.dart';", coreForbidden),
          hasLength(1));
      expect(violations('x', "import 'dart:ui';", coreForbidden), hasLength(1));
    });

    test('lets through what the UI and the core legitimately import', () {
      const uiOk = '''
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'core_bootstrap.dart';
''';
      expect(violations('x', uiOk, uiForbidden), isEmpty);
      const coreOk = '''
import 'dart:isolate';
import 'dart:math';
import 'package:sqlite3/sqlite3.dart' as sql;
export 'src/client.dart' show CoreClient;
''';
      expect(violations('x', coreOk, coreForbidden), isEmpty);
    });
  });

  test('UI code under lib/ imports no network, server or store', () {
    final files = dartFiles('lib');
    expect(files.map((f) => f.path.replaceAll(r'\', '/')), contains('lib/main.dart'),
        reason: 'the scan must actually reach the UI code');
    final found = [
      for (final f in files) ...violations(f.path, f.readAsStringSync(), uiForbidden),
    ];
    expect(found, isEmpty, reason: found.join('\n'));
  });

  test('the core under packages/core/lib imports no Flutter or network', () {
    final files = dartFiles('packages/core/lib');
    expect(files.map((f) => f.path.replaceAll(r'\', '/')),
        contains('packages/core/lib/core.dart'),
        reason: 'the scan must actually reach the core');
    final found = [
      for (final f in files) ...violations(f.path, f.readAsStringSync(), coreForbidden),
    ];
    expect(found, isEmpty, reason: found.join('\n'));
  });
}
