import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_companion/core_bootstrap.dart';
import 'package:pro_companion_core/core.dart';

/// #24 criterion 4, one phase of it. Not named *_test.dart, so a plain
/// `flutter test integration_test` never runs it: the write phase kills its
/// own process. integration_test/force_kill.sh drives both phases.
///
///   PHASE=write  append [probes] events to the app's real log, wait for each
///                to return, then SIGKILL this process - no close, no flush.
///   PHASE=read   in a fresh process (the device in airplane mode), read the
///                log and require every acknowledged probe, in sequence.
const phase = String.fromEnvironment('PHASE');
const runId = String.fromEnvironment('RUN_ID');
const probes = 5;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (phase == 'write') {
    testWidgets('write phase: append, then die without closing', (tester) async {
      expect(runId, isNotEmpty, reason: 'pass --dart-define=RUN_ID=...');
      final core = await startCore();
      for (var i = 0; i < probes; i++) {
        await core.append(NewEvent(
          kind: 'probe.force_kill',
          source: 'test',
          payload: {'run': runId, 'i': i},
        ));
      }
      // ignore: avoid_print
      print('FORCE_KILL_ACKED run=$runId n=$probes');
      await Future<void>.delayed(const Duration(milliseconds: 500)); // let the line reach the host
      Process.killPid(pid, ProcessSignal.sigkill);
      await Future<void>.delayed(const Duration(seconds: 30)); // never reached
    });
  } else if (phase == 'read') {
    testWidgets('read phase: every acknowledged event is back', (tester) async {
      expect(runId, isNotEmpty, reason: 'pass --dart-define=RUN_ID=...');
      final core = await startCore();
      final mine = [
        for (final e in await core.readAll())
          if (e.kind == 'probe.force_kill' && e.payload['run'] == runId) e,
      ];
      // ignore: avoid_print
      print('FORCE_KILL_FOUND run=$runId n=${mine.length}');
      expect(mine, hasLength(probes), reason: 'acknowledged before the kill, so it must survive it');
      expect([for (final e in mine) e.payload['i']], [for (var i = 0; i < probes; i++) i]);
      final seqs = [for (final e in mine) e.seq];
      expect(seqs, [for (var i = 0; i < probes; i++) seqs.first + i], reason: 'contiguous');
      await core.close();
    });
  } else {
    test('PHASE must be write or read', () => fail('PHASE="$phase"'));
  }
}
