/// Starting the core. For the app's composition root and for tests - not for
/// UI code, which takes a [CoreClient] and never learns where the core runs.
library;

import 'dart:async';
import 'dart:isolate';

import 'src/client.dart';
import 'src/server.dart';
import 'src/store.dart';
import 'src/wire.dart';

export 'src/client.dart' show CoreClient, PortCoreClient;
export 'src/server.dart' show CoreServer;

/// Opens the log at [dbPath] in a new isolate and returns a client for it,
/// so SQLite's synchronous calls never block a frame (ADR 002, ADR 003).
/// #32 moves the host into the foreground service; the client is unchanged.
Future<CoreClient> spawnCore(String dbPath) async {
  final ready = ReceivePort();
  final isolate = await Isolate.spawn(
    _coreMain,
    [ready.sendPort, dbPath],
    debugName: 'core',
    errorsAreFatal: false,
  );
  final first = await ready.first;
  if (first is SendPort) return PortCoreClient(first);
  isolate.kill();
  final failure = first as List;
  throw CoreException('failed', 'the core did not start: ${failure[1]}');
}

void _coreMain(List<Object?> args) {
  final ready = args[0] as SendPort;
  final EventStore store;
  try {
    store = EventStore.open(args[1] as String);
  } catch (e) {
    ready.send([Wire.err, e.toString()]);
    return;
  }
  final server = CoreServer(store);
  final requests = ReceivePort();
  requests.listen((message) {
    if (!server.handle(message)) {
      requests.close();
      Isolate.exit();
    }
  });
  ready.send(requests.sendPort);
}
