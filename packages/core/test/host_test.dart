import 'dart:async';
import 'dart:isolate';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #32: the core as the foreground service hosts it. The service's engine
/// serves the log and publishes its port; the UI engine finds the port,
/// connects, and never owns the core. These run a host in an isolate of its
/// own, as the service's engine is one, which a test can end to leave its
/// published port behind with nothing serving it.
void main() {
  test('a client connects to a published core, and closing it leaves the core serving', () async {
    final host = await _Host.start(tempDbPath());
    final first = await connectCore(() => host.port);
    await first.append(const NewEvent(kind: 'finish', source: 'tap'));
    await first.close();

    final second = await connectCore(() => host.port);
    expect(await second.count(), 1, reason: 'the first client closing must not close the log');
  });

  test('the host refuses a close request from any client, so one cannot close the log under the others',
      () async {
    final host = await _Host.start(tempDbPath());
    final owning = PortCoreClient(host.port); // a client that does send close
    await expectLater(
        owning.close(), throwsA(isA<CoreException>().having((e) => e.code, 'code', 'refused')));
    expect(await owning.count(), 0, reason: 'still serving after the refused close');
  });

  test('a port its destroyed host left published is skipped, until the next host publishes', () async {
    final dead = await _Host.start(tempDbPath());
    await dead.kill();
    final live = await _Host.start(tempDbPath());

    var published = dead.port;
    var deadLookups = 0;
    Timer(const Duration(milliseconds: 300), () => published = live.port);
    final core = await connectCore(() {
      if (published == dead.port) deadLookups++;
      return published;
    }, ping: const Duration(milliseconds: 100));

    expect(deadLookups, greaterThan(0), reason: 'the lookup must have met the dead port first');
    await core.append(const NewEvent(kind: 'finish', source: 'tap'));
    expect(await PortCoreClient(live.port).count(), 1, reason: 'the client must be the live core\'s');
  });

  test('with nothing published, or only a dead port, it gives up after its timeout', () async {
    await expectLater(
        connectCore(() => null, timeout: const Duration(milliseconds: 200)),
        throwsA(isA<CoreException>().having((e) => e.code, 'code', 'failed')));

    final dead = await _Host.start(tempDbPath());
    await dead.kill();
    await expectLater(
        connectCore(() => dead.port,
            timeout: const Duration(milliseconds: 400), ping: const Duration(milliseconds: 100)),
        throwsA(isA<CoreException>()));
  });
}

/// A core served by [serveCore] in an isolate of its own, as the service's
/// engine serves it.
class _Host {
  _Host._(this.port, this._isolate);

  final SendPort port;
  final Isolate _isolate;

  static Future<_Host> start(String dbPath) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_serve, [ready.sendPort, dbPath]);
    final port = await ready.first as SendPort;
    final host = _Host._(port, isolate);
    addTearDown(() => host._isolate.kill(priority: Isolate.immediate));
    return host;
  }

  /// Ends the host's isolate and waits until it has gone, leaving [port]
  /// pointing at nothing, as a destroyed service's engine leaves it.
  Future<void> kill() async {
    final exited = ReceivePort();
    _isolate.addOnExitListener(exited.sendPort);
    _isolate.kill(priority: Isolate.immediate);
    await exited.first;
  }
}

void _serve(List<Object?> args) => (args[0] as SendPort).send(serveCore(args[1] as String));
