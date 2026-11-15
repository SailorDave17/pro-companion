import 'dart:convert';
import 'dart:isolate';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/src/wire.dart';
import 'package:pro_companion_core/store.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #113 criterion 1's core half: the core host nudges sync after every append
/// the core's server takes, so the server tells its host once a request has
/// committed one of this phone's own events, and only then. Each route that
/// appends is driven over the port the UI uses; reads, refusals, a link event
/// already held and a pull's stored events must stay quiet, or a phone would
/// run sync on every screen refresh.
void main() {
  late EventStore store;
  late int nudges;
  late SendPort port;

  setUp(() {
    store = openStore(tempDbPath());
    nudges = 0;
  });

  CoreClient served({void Function()? onAppended}) {
    final server = CoreServer(store, closable: false, onAppended: onAppended ?? () => nudges++);
    final requests = ReceivePort();
    addTearDown(requests.close);
    requests.listen(server.handle);
    port = requests.sendPort;
    return PortCoreClient(port, closesCore: false);
  }

  /// One raw request to the last [served] core, for a shape the client would refuse to send.
  Future<List<Object?>> raw(String command, Map<String, Object?> args) async {
    final reply = ReceivePort();
    port.send([reply.sendPort, command, args]);
    final answer = await reply.first as List<Object?>;
    reply.close();
    return answer;
  }

  String link(String id, int at) =>
      jsonEncode({'v': 1, 'id': id, 'kind': LinkContract.signal, 'at_ms': at, 'sequence': 'seq-1'});

  test('an append nudges once, after it is committed', () async {
    var seenWhenNudged = -1;
    final core = served(onAppended: () {
      nudges++;
      seenWhenNudged = store.count();
    });
    await core.append(FleetEvents.define('Lasers'));
    expect(nudges, 1);
    expect(seenWhenNudged, 1, reason: 'the event is in the log when sync is told');
    await core.append(FleetEvents.define('420s'));
    expect(nudges, 2);
  });

  test('reads, statuses and a location fix nudge nothing', () async {
    final core = served();
    await core.append(FleetEvents.define('Lasers'));
    nudges = 0;
    await core.readAll();
    await core.readOwn();
    await core.count();
    await core.deviceId();
    await core.uploadStatus();
    await core.pullStatus();
    await core.chainStatus();
    await core.raceTimes();
    await core.reportNoFix(GpsReasons.all.first);
    expect(nudges, 0);
  });

  test('a refused append nudges nothing', () async {
    served();
    final answer = await raw(Wire.append, {
      'event': {'kind': 7},
    });
    expect(answer.first, Wire.err, reason: 'the control: the request really was refused');
    expect(store.count(), 0);
    expect(nudges, 0);
  });

  test('a race-timer event nudges once when stored, and not when it was already held', () async {
    final core = served();
    final now = DateTime(2026, 11, 10, 14).millisecondsSinceEpoch;
    expect((await core.receiveLink(link('evt-1', now), receivedMs: now)).stored, isTrue);
    expect(nudges, 1);
    expect((await core.receiveLink(link('evt-1', now), receivedMs: now)).stored, isFalse,
        reason: 'the control: the resend stored nothing');
    expect(nudges, 1);
  });

  test('the clock being set nudges once, for the clock.changed it logs', () async {
    final core = served();
    await core.reportClockChanged();
    expect(store.readOwn().single.kind, ClockKinds.changed);
    expect(nudges, 1);
  });

  test('a first admission stamps without a nudge; a change nudges once, for its marker', () async {
    final core = served();
    const first = '11111111-1111-4111-8111-111111111111';
    const second = '22222222-2222-4222-8222-222222222222';
    await core.setAdmissionId(first);
    expect(store.count(), 0, reason: 'the control: a first admission appends nothing');
    expect(nudges, 0);
    await core.setAdmissionId(second);
    expect(store.readOwn().single.kind, AdmissionKinds.superseded);
    expect(nudges, 1);
    await core.setAdmissionId(second);
    expect(nudges, 1, reason: 'the same admission again appends nothing');
  });

  test('a nudge that throws costs the request nothing, and the core keeps serving', () async {
    final core = served(onAppended: () => throw StateError('sync is gone'));
    final stored = await core.append(FleetEvents.define('Lasers'));
    expect(stored.seq, 1);
    expect(await core.count(), 1);
  });

  test("another phone's event stored by a pull leaves this phone's sequence where it was", () {
    // The other phone's event is its third, so a sequence read across every device would say 3
    // (#113's review: with one event each, max(1, 1) hid it).
    final other = openStore(tempDbPath(), seed: 2);
    for (final name in ['Lasers', 'Optis', 'ILCA 6']) {
      other.append(FleetEvents.define(name));
    }
    final body = other.debugDatabase.select('SELECT body FROM events WHERE seq = 3').single['body'] as String;
    store.append(FleetEvents.define('420s'));
    expect(store.lastOwnSeq, 1);
    expect(store.insertPulled('33333333-3333-4333-8333-333333333333', body), isTrue,
        reason: 'the control: the pulled event really was stored');
    expect(store.count(), 2);
    expect(store.lastOwnSeq, 1);
  });

  test('serveStore hands its nudge to the server', () async {
    final port = serveStore(store, onAppended: () => nudges++);
    final core = PortCoreClient(port, closesCore: false);
    await core.append(FleetEvents.define('Lasers'));
    expect(nudges, 1);
  });
}
