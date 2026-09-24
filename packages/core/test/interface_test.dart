import 'dart:isolate';
import 'dart:typed_data';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #24 criterion 7, the core's half: every call is async, and everything that
/// crosses the ADR 003 boundary is plain data. The UI's half - a widget test
/// against the fake core - is in the app's test/.
void main() {
  group('the plain-data rule', () {
    test('accepts what may cross an isolate-group boundary', () {
      final port = ReceivePort();
      addTearDown(port.close);
      for (final ok in <Object?>[
        null,
        true,
        3,
        2.5,
        'text',
        [1, 'a', null],
        {'k': {'nested': [1.5]}},
        port.sendPort,
        Uint8List(4),
      ]) {
        expect(isWireSafe(ok), isTrue, reason: '$ok');
      }
    });

    test('refuses what the VM would refuse between isolate groups', () {
      for (final bad in <Object?>[
        (1, 2), // a record: measured refused at send in #14
        DateTime(2026),
        const Duration(seconds: 1),
        Object(),
        [1, (2, 3)],
        {'k': DateTime(2026)},
        {DateTime(2026): 1},
      ]) {
        expect(isWireSafe(bad), isFalse, reason: '$bad');
      }
    });
  });

  group('over a real isolate', () {
    late CoreClient core;

    setUp(() async {
      core = await spawnCore(tempDbPath());
    });

    tearDown(() async {
      try {
        await core.close();
      } on Object {
        // Closed by the test.
      }
    });

    test('append, read, count and device id round-trip as plain data', () async {
      final id = await core.deviceId();
      expect(isUlid(id), isTrue);
      final a = await core.append(const NewEvent(
        kind: 'finish',
        source: 'tap',
        payload: {'sail': '42'},
        gps: GpsFix(lat: 1, lon: 2),
      ));
      final b = await core.append(NewEvent(kind: 'finish.undo', source: 'tap', correctsUlid: a.ulid));
      expect([a.seq, b.seq], [1, 2]);
      expect(a.deviceId, id);
      expect(await core.count(), 2);
      final all = await core.readAll();
      expect([for (final e in all) e.ulid], [a.ulid, b.ulid]);
      expect(all.first.toWire(), a.toWire());
      for (final e in all) {
        expect(isWireSafe(e.toWire()), isTrue);
      }
    });

    test('a refusal comes back as a CoreException, not a crash', () async {
      await expectLater(core.append(const NewEvent(kind: '', source: 'tap')),
          throwsA(isA<CoreException>().having((e) => e.code, 'code', 'invalid')));
      expect(await core.count(), 0, reason: 'the core is still serving');
    });

    test('an argument that is not plain data is refused before it is sent', () async {
      await expectLater(
        core.append(NewEvent(kind: 'k', source: 's', payload: {'at': DateTime(2026)})),
        throwsArgumentError,
      );
      expect(await core.count(), 0);
    });

    test('every interface call returns a Future', () {
      // Each would be a compile error if a method stopped being async; this
      // makes the claim visible in the test report as well.
      expect(core.count(), isA<Future<int>>());
      expect(core.deviceId(), isA<Future<String>>());
      expect(core.readAll(), isA<Future<List<EventEnvelope>>>());
      expect(core.append(const NewEvent(kind: 'k', source: 's')), isA<Future<EventEnvelope>>());
    });
  });

  group('the fake core', () {
    test('holds the UI to the same plain-data rule as the real one', () async {
      final fake = FakeCore();
      await expectLater(
        fake.append(NewEvent(kind: 'k', source: 's', payload: {'at': DateTime(2026)})),
        throwsArgumentError,
      );
      final e = await fake.append(const NewEvent(kind: 'k', source: 's'));
      expect(e.seq, 1);
      expect(await fake.count(), 1);
    });
  });
}
