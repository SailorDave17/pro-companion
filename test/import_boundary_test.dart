import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #24 criterion 8 - the enforced answer to "front end or back end?" (ADR 001,
/// groom decision G1). UI code under lib/ reaches the core only through its
/// interface, never the network or the store; the core under packages/core
/// never imports Flutter or the network. Since #6 (ADR 006 decision 4), sync
/// under packages/sync never imports Flutter, the core never imports sync, and
/// the UI reaches sync only through the core host.
///
/// Reads import and export directives as text, so it cannot be fooled by code
/// that happens not to be called, and it runs without compiling anything.

/// A rule is a URI prefix that a set of files must not import or export. A file
/// named in [exempt] (its path from the repo root, with `/`) may.
class Rule {
  const Rule(this.prefix, this.why, {this.exempt = const {}});
  final String prefix;
  final String why;
  final Set<String> exempt;
}

const uiForbidden = [
  Rule('dart:io', 'sockets and HTTP live in dart:io; the UI never calls the network'),
  Rule('package:http/', 'the UI never calls the network'),
  Rule('package:supabase', 'the UI never calls the server; sync is the core\'s'),
  Rule('package:sqlite3/', 'the UI never touches the store'),
  Rule('package:pro_companion_core/store.dart', 'the UI never touches the store'),
  Rule('package:pro_companion_core/src/', 'the UI sees only the core\'s public interface'),
  // ADR 006 decision 4: the package:supabase rule above does not catch sync, which reaches the
  // network one package removed. Only the composition root (#32's core host) wires it.
  Rule('package:pro_companion_sync', 'the UI never reaches sync; only the core host wires it (ADR 006)',
      exempt: {'lib/core_host.dart'}),
];

const coreForbidden = [
  Rule('package:flutter/', 'the core is pure Dart, so it can run headless'),
  Rule('dart:ui', 'the core is pure Dart, so it can run headless'),
  Rule('dart:io', 'the core makes no network calls'),
  Rule('package:http/', 'the core makes no network calls; sync does, in its own package (ADR 006)'),
  Rule('package:supabase', 'the core makes no network calls; sync does, in its own package (ADR 006)'),
  Rule('package:pro_companion_sync', 'sync depends on the core, never the reverse (ADR 006)'),
];

/// ADR 006 decision 4: sync may import the network and the core, and never Flutter, so it runs in
/// the headless core engine and is tested with `dart test`.
const syncForbidden = [
  Rule('package:flutter/', 'sync is pure Dart, so it runs in the headless core engine'),
  Rule('dart:ui', 'sync is pure Dart, so it runs in the headless core engine'),
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
          if (!r.exempt.contains(file.replaceAll(r'\', '/')) &&
              (uri == r.prefix || uri.startsWith(r.prefix) || _reachesIntoCore(uri, r)))
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
      // ADR 006 decision 4 (#6): sync is reached by the core host alone, and never reaches Flutter.
      const importsSync = "import 'package:pro_companion_sync/sync.dart';";
      expect(violations('lib/main.dart', importsSync, uiForbidden), hasLength(1));
      expect(violations('packages/core/lib/core.dart', importsSync, coreForbidden), hasLength(1));
      expect(violations('packages/sync/lib/sync.dart', "import 'package:flutter/foundation.dart';",
          syncForbidden), hasLength(1));
      expect(violations('packages/sync/lib/sync.dart', "import 'dart:ui';", syncForbidden), hasLength(1));
    });

    test('the core host alone may import sync, and only sync', () {
      const importsSync = "import 'package:pro_companion_sync/sync.dart';";
      expect(violations('lib/core_host.dart', importsSync, uiForbidden), isEmpty);
      expect(violations(r'lib\core_host.dart', importsSync, uiForbidden), isEmpty,
          reason: 'a Windows path names the same file');
      expect(violations('lib/core_host.dart', "import 'package:supabase/supabase.dart';", uiForbidden),
          hasLength(1), reason: 'the exemption is for sync, not for the network');
      expect(violations('lib/screens/core_host.dart', importsSync, uiForbidden), hasLength(1),
          reason: 'the exemption names one file, not a file name');
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
      const syncOk = '''
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';
import 'package:pro_companion_core/store.dart';
''';
      expect(violations('x', syncOk, syncForbidden), isEmpty);
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

  test('the core under packages/core/lib imports no Flutter, network or sync', () {
    final files = dartFiles('packages/core/lib');
    expect(files.map((f) => f.path.replaceAll(r'\', '/')),
        contains('packages/core/lib/core.dart'),
        reason: 'the scan must actually reach the core');
    final found = [
      for (final f in files) ...violations(f.path, f.readAsStringSync(), coreForbidden),
    ];
    expect(found, isEmpty, reason: found.join('\n'));
  });

  test('sync under packages/sync/lib imports no Flutter (ADR 006, #6)', () {
    final files = dartFiles('packages/sync/lib');
    expect(files.map((f) => f.path.replaceAll(r'\', '/')),
        contains('packages/sync/lib/sync.dart'),
        reason: 'the scan must actually reach sync');
    final found = [
      for (final f in files) ...violations(f.path, f.readAsStringSync(), syncForbidden),
    ];
    expect(found, isEmpty, reason: found.join('\n'));
  });
}
