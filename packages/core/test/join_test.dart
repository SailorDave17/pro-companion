import 'dart:async';
import 'dart:isolate';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #71: the core's `join`, as the UI reaches it. The core makes no network
/// call; a host wires `join` to whatever admits the phone (sync, #113) and the
/// server relays the answer, or the coded refusal, over the port. A core
/// nothing is wired to refuses a join as `no_server`.
void main() {
  const admission = '3f6c1a52-8d0e-4b7a-9c21-5e4f0a9b7d13';
  const readmission = '9b0d7e21-44c6-4e1f-8a35-c7f2d6190e48';
  const day = 'b3c7e9a1-2d4f-4b6a-8c0e-1f2a3b4c5d6e';
  const granted = Admission(
      admissionId: admission, eventId: day, role: Roles.recorder, courseId: '00000000-0000-4000-8000-0000000000ca', raceArea: 'Alpha');

  /// [store] served in this isolate over [handler], reached through the same client the UI uses.
  CoreClient served(EventStore store, JoinHandler? handler) {
    final server = CoreServer(store, join: handler);
    final requests = ReceivePort();
    addTearDown(requests.close);
    requests.listen(server.handle);
    return PortCoreClient(requests.sendPort, closesCore: false);
  }

  test('the answer crosses the port as plain data, and the handler stamps the admission on the store', () async {
    String? asked;
    final store = openStore(tempDbPath());
    final core = served(store, (code) async {
      asked = code;
      store.setAdmissionId(granted.admissionId);
      return granted;
    });
    final answer = await core.join('RECO-ALFA');
    expect(asked, 'RECO-ALFA');
    expect(answer, granted);
    expect(isWireSafe(answer.toWire()), isTrue);
    expect(store.admissionId, admission);
    expect((await core.append(const NewEvent(kind: 'note', source: 'tap'))).admissionId, admission);
  });

  test('a join while the handler is still answering does not block the core: a read answers first', () async {
    final gate = Completer<void>();
    final core = served(openStore(tempDbPath()), (code) async {
      await gate.future;
      return granted;
    });
    final joining = core.join('RECO-ALFA');
    expect(await core.count(), 0, reason: 'answered while the join waits on the server');
    gate.complete();
    expect(await joining, granted);
  });

  group('what comes back when the handler cannot admit', () {
    test('a coded refusal keeps its code and message', () async {
      final core = served(openStore(tempDbPath()), (code) async => throw joinException(JoinCodes.refused, 'That code was not recognised.'));
      await expectLater(
          core.join('XXXX-0000'),
          throwsA(isA<CoreException>()
              .having((e) => e.code, 'code', JoinCodes.refused)
              .having((e) => e.message, 'message', 'That code was not recognised.')));
    });

    test('no signal keeps its code', () async {
      final core = served(openStore(tempDbPath()), (code) async => throw joinException(JoinCodes.noSignal, 'no answer from the server'));
      await expectLater(core.join('RECO-ALFA'), throwsA(isA<CoreException>().having((e) => e.code, 'code', JoinCodes.noSignal)));
    });

    test('anything else the handler throws is a failure, never a crash of the core', () async {
      final core = served(openStore(tempDbPath()), (code) async => throw StateError('the engine is closed'));
      await expectLater(core.join('RECO-ALFA'),
          throwsA(isA<CoreException>().having((e) => e.code, 'code', 'failed').having((e) => e.message, 'message', contains('closed'))));
      expect(await core.count(), 0, reason: 'the core is still serving');
    });

    test('a core nothing is wired to refuses as no_server, before it asks anything', () async {
      final core = served(openStore(tempDbPath()), null);
      await expectLater(core.join('RECO-ALFA'), throwsA(isA<CoreException>().having((e) => e.code, 'code', JoinCodes.noServer)));
      final spawned = await spawnCore(tempDbPath());
      addTearDown(spawned.close);
      await expectLater(spawned.join('RECO-ALFA'), throwsA(isA<CoreException>().having((e) => e.code, 'code', JoinCodes.noServer)));
    });

    test('an empty code is invalid, and the handler is never asked', () async {
      var asked = 0;
      final core = served(openStore(tempDbPath()), (code) async {
        asked++;
        return granted;
      });
      await expectLater(core.join(''), throwsA(isA<CoreException>().having((e) => e.code, 'code', 'invalid')));
      expect(asked, 0);
    });

    test('only a join code may be minted as one', () {
      expect(() => joinException('refused', 'x'), throwsArgumentError);
      for (final code in JoinCodes.all) {
        expect(joinException(code, 'x').code, code);
      }
    });
  });

  test('the fake core: the answer is stamped like the real one, a change appends the marker, and a code is recorded', () async {
    final fake = FakeCore();
    await expectLater(fake.join('RECO-ALFA'), throwsA(isA<CoreException>().having((e) => e.code, 'code', JoinCodes.noServer)),
        reason: 'nothing wired, as the real core');
    fake.onJoin = (code) async => code == 'RECO-ALFA'
        ? granted
        : throw joinException(JoinCodes.refused, 'That code was not recognised.');
    expect(await fake.join('RECO-ALFA'), granted);
    expect(await fake.admissionId(), admission);
    await expectLater(fake.join('XXXX-0000'), throwsA(isA<CoreException>().having((e) => e.code, 'code', JoinCodes.refused)));
    expect(await fake.admissionId(), admission, reason: 'a refusal changes nothing');
    fake.onJoin = (code) async => const Admission(admissionId: readmission, eventId: day, role: Roles.scorer, courseId: null, raceArea: null);
    await fake.join('SCOR-0001');
    expect([for (final e in await fake.readOwn()) (e.kind, e.admissionId)], [(AdmissionKinds.superseded, admission)]);
    expect(fake.joins, ['RECO-ALFA', 'RECO-ALFA', 'XXXX-0000', 'SCOR-0001']);
    expect(fake.calls['join'], 4);
  });
}
