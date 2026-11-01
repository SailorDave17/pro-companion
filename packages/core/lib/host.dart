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
export 'src/server.dart' show CoreServer, JoinHandler;

/// The name a core host publishes its port under, VM-wide, and the UI engine
/// looks it up by (ADR 003 decision 3). The app publishes it with
/// IsolateNameServer, which is Flutter's, so this package only names it.
const corePortName = 'pro_companion.core';

/// Opens the log at [dbPath] in a new isolate and returns a client for it,
/// so SQLite's synchronous calls never block a frame (ADR 002, ADR 003).
/// The app's core runs in the foreground service instead (#32, [serveCore]);
/// this is for tests and benchmarks that want a log of their own.
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

/// Opens the log at [dbPath] and serves it in the calling isolate, until that
/// isolate ends: the foreground service's engine is the core's isolate (ADR
/// 003, #32). Returns the port requests go to, for the host to publish under
/// [corePortName]. A close request is refused, because the host and not a
/// client owns the core's lifetime. Throws when the log cannot be opened.
///
/// [join] is what a `join` request runs (#71). With none, a join is refused
/// as `no_server`. A host that builds sync on the store first (#113) opens the
/// store itself and calls [serveStore].
SendPort serveCore(String dbPath, {JoinHandler? join}) => serveStore(EventStore.open(dbPath), join: join);

/// [serveCore] over a store the host already opened, so the host can build
/// sync on the same store and hand its join in as [join] (#71, #113).
SendPort serveStore(EventStore store, {JoinHandler? join}) {
  final server = CoreServer(store, closable: false, join: join);
  final requests = ReceivePort();
  requests.listen(server.handle);
  return requests.sendPort;
}

/// Waits for the core a host publishes and connects to it (#32). [lookup]
/// reads where the host published its port, IsolateNameServer in the app.
///
/// A published port is used only once it answers a ping within [ping]. A
/// host that was destroyed leaves its port published, and that port never
/// answers: the service's engine goes when the service does, while the name
/// stays in the VM. Then the lookup is repeated until the next host publishes
/// over it. Throws a [CoreException] when no core answers within [timeout].
///
/// The client does not own the core: closing it leaves the core serving.
Future<CoreClient> connectCore(
  SendPort? Function() lookup, {
  Duration timeout = const Duration(seconds: 30),
  Duration ping = const Duration(seconds: 2),
  Duration poll = const Duration(milliseconds: 20),
}) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < timeout) {
    final port = lookup();
    if (port == null) {
      await Future<void>.delayed(poll);
    } else if (await _answers(port, ping)) {
      return PortCoreClient(port, closesCore: false);
    }
  }
  throw CoreException('failed', 'no core answered within ${timeout.inSeconds} s: the core host did not start');
}

/// Whether a core serves behind [core]: any reply to a device-id request
/// within [within] says so. A port whose isolate has gone drops the request.
Future<bool> _answers(SendPort core, Duration within) {
  final answered = Completer<bool>();
  final reply = RawReceivePort();
  reply.handler = (Object? _) {
    if (!answered.isCompleted) answered.complete(true);
  };
  final timer = Timer(within, () {
    if (!answered.isCompleted) answered.complete(false);
  });
  core.send([reply.sendPort, Wire.deviceId, const <String, Object?>{}]);
  return answered.future.whenComplete(() {
    timer.cancel();
    reply.close();
  });
}
