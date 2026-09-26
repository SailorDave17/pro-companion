import 'dart:convert';
import 'dart:io';

import 'package:pro_companion_core/store.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #5 criterion 4, its capture half: capture never depends on connectivity or auth state, so a
/// phone whose session expires mid-race while offline goes on logging. The core takes no session
/// and reaches no network, and these hold both: one by logging a race day with every connection
/// refused, the other by reading what the core is built from. "Sync resumes after re-auth" is #6's,
/// where sync is built, outside the core (#47).
void main() {
  test('the core logs a race day, chained, with every network connection refused', () {
    HttpOverrides.runZoned(() {
      final store = openStore(tempDbPath());
      for (var n = 1; n <= 60; n++) {
        store.append(NewEvent(kind: 'finish', source: 'tap', payload: {'sail': '$n'}));
      }
      expect(store.count(), 60);
      expect(verifyChains(store.readCanonical()).values.single.state, ChainState.intact);
    }, createHttpClient: (_) => throw StateError('capture reached for the network'));
  });

  test('nothing the core is built from is a network or auth client, or another workspace package',
      () {
    // Written by `pub get` at the workspace root, which is where the core resolves from.
    final graphFile = File('../../.dart_tool/package_graph.json');
    expect(graphFile.existsSync(), isTrue,
        reason: 'run `flutter pub get` at the repo root first: the check reads what it wrote');
    final graph = jsonDecode(graphFile.readAsStringSync()) as Map;
    final dependencies = {
      for (final p in graph['packages'] as List)
        (p as Map)['name'] as String: [...(p['dependencies'] as List).cast<String>()],
    };

    final closure = <String>{};
    final pending = ['pro_companion_core'];
    while (pending.isNotEmpty) {
      final name = pending.removeLast();
      if (closure.add(name)) pending.addAll(dependencies[name]!);
    }
    expect(closure, containsAll(['crypto', 'sqlite3']), reason: 'the walk must reach the core\'s own dependencies');

    // The clients a Dart app reaches a server or an auth provider with, and the connectivity plugin
    // a capture path could be made to wait on. A package outside this list that makes network
    // calls would pass here; the test above is what refuses it at run time.
    const networkOrAuth = {
      'http', 'http2', 'dio', 'web_socket_channel', 'web_socket', 'grpc', 'socket_io_client',
      'cronet_http', 'cupertino_http', 'ok_http', 'connectivity_plus',
      'supabase', 'supabase_flutter', 'gotrue', 'postgrest', 'realtime_client', 'storage_client',
      'functions_client',
    };
    expect(closure.intersection(networkOrAuth), isEmpty);

    // Sync will be its own workspace package (#47, #6). The core depending on it would put the
    // network under capture, so no other workspace root may be in its closure.
    final roots = (graph['roots'] as List).cast<String>().toSet();
    expect(roots, contains('pro_companion_core'), reason: 'the graph must be the workspace\'s');
    expect(closure.intersection(roots.difference({'pro_companion_core'})), isEmpty);
  });
}
