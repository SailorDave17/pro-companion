import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/core_host.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:pro_companion_sync/sync.dart';

import 'support/fake_confirmation.dart';

/// #32: what the core host does with an append CoreService hands it from an intent. The device half,
/// an intent sent once the activity is destroyed, is CoreHostTest (android/app/src/androidTest), run
/// by integration_test/core_host.sh. #33 adds the race-timer link's call.
void main() {
  MethodCall append(Object? argument) => MethodCall('append', argument);
  String event(Map<String, Object?> payload) =>
      jsonEncode(NewEvent(kind: 'probe.intent', source: 'test', payload: payload).toWire());

  test("an intent's event is appended, and the stored event comes back as JSON", () async {
    final core = FakeCore();
    final reply = await handleHostCall(core, append(event({'n': 1})));
    final stored = jsonDecode(reply as String) as Map<String, Object?>;
    expect(stored['kind'], 'probe.intent');
    expect(stored['payload'], {'n': 1});
    expect(stored['seq'], 1);
    expect(stored['ulid'], (await core.readAll()).single.ulid, reason: 'the reply is the event as stored');
  });

  test('an argument that is not an event is refused as malformed, and nothing is appended', () async {
    final core = FakeCore();
    for (final bad in <Object?>[null, 'not json', '[1, 2]', jsonEncode({'kind': 'probe.intent'})]) {
      await expectLater(handleHostCall(core, append(bad)),
          throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'malformed')),
          reason: '$bad');
    }
    expect(await core.count(), 0);
  });

  test("a refusal by the core comes back with the core's own code", () async {
    final core = FakeCore()..failWith = const CoreException('refused', 'the store said no');
    await expectLater(handleHostCall(core, append(event({}))),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'refused')));
  });

  test('the host answers no method but append and link', () async {
    await expectLater(handleHostCall(FakeCore(), const MethodCall('delete', null)),
        throwsA(isA<MissingPluginException>()));
  });

  group('#33: one event from race-timer, as LinkService hands it over', () {
    const received = 1793000000500;
    late FakeConfirmationDevice device;
    late ConfirmationService confirmation;

    setUp(() {
      device = FakeConfirmationDevice();
      confirmation = ConfirmationService(device);
    });

    MethodCall link(String event) => MethodCall('link', {'event': event, 'received_ms': received});
    String contract(String id) =>
        jsonEncode({'v': 1, 'id': id, 'kind': 'start', 'at_ms': 1793000000000, 'sequence': 'seq-1'});

    /// The confirmation's calls run unawaited, so they land a turn after it fires.
    Future<void> fired() => Future<void>.delayed(Duration.zero);

    test('it is stored with source race-timer and both times, and answers accepted', () async {
      final core = FakeCore();
      expect(await handleHostCall(core, link(contract('evt-1')), confirmation: confirmation), LinkContract.accepted);
      final stored = (await core.readAll()).singleWhere((e) => e.kind == StartKinds.start);
      expect(stored.source, raceTimerSource);
      expect([stored.payload[linkAtKey], stored.payload[linkReceivedKey]], [1793000000000, received]);
    });

    test('criterion 8: a stored event fires one vibration and one tone, once it is committed', () async {
      final core = FakeCore();
      await handleHostCall(core, link(contract('evt-1')), confirmation: confirmation);
      await fired();
      expect(device.vibrations, 1);
      expect(device.tones, [BeepStream.notification]);
    });

    test('a duplicate answers accepted and fires no second confirmation', () async {
      final core = FakeCore();
      await handleHostCall(core, link(contract('evt-1')), confirmation: confirmation);
      final second = await handleHostCall(core, link(contract('evt-1')), confirmation: confirmation);
      await fired();
      expect(second, LinkContract.accepted);
      expect(device.vibrations, 1);
      expect(device.tones, hasLength(1));
    });

    test('malformed answers malformed, as data, and fires nothing', () async {
      final core = FakeCore();
      expect(await handleHostCall(core, link('{not json'), confirmation: confirmation), LinkContract.malformed);
      await fired();
      expect(device.vibrations, 0);
      expect(device.tones, isEmpty);
      expect(await core.count(), 0);
    });

    test('a core failure throws and fires nothing: no refusal by the core is ever answered as a status', () async {
      // `refused` tells race-timer a retry cannot help, and only LinkTrust may
      // say it (ADR 004). A store that failed is a store to retry, so this
      // must reach CoreService as a failure, which answers no_core.
      for (final code in ['refused', 'invalid', 'failed']) {
        final core = FakeCore()..failWith = CoreException(code, 'the store said no');
        await expectLater(handleHostCall(core, link(contract('evt-1')), confirmation: confirmation),
            throwsA(isA<CoreException>().having((e) => e.code, 'code', code)));
      }
      await fired();
      expect(device.vibrations, 0);
      expect(device.tones, isEmpty);
    });

    test('with no confirmation handed in, the event is still stored', () async {
      final core = FakeCore();
      expect(await handleHostCall(core, link(contract('evt-1'))), LinkContract.accepted);
      expect((await core.readAll()).where((e) => e.source == raceTimerSource), hasLength(1));
    });
  });

  // #113: where sync's project comes from, and what the host does without one. The host with sync
  // running against a real server is test/sync_test.dart's #113 case; on a phone, sync_flow.sh.
  const url = 'http://127.0.0.1:54421';
  const key = 'sb_publishable_test';

  group('the project sync sends to (#113 criterion 2)', () {
    test('a build with neither define syncs nothing', () {
      expect(SyncConfig.of('', ''), isNull);
      expect(SyncConfig.compiled, isNull, reason: 'this test build was given no defines file');
    });

    test('a build with both syncs to that project', () {
      final config = SyncConfig.of(url, key)!;
      expect([config.url, config.publishableKey], [url, key]);
    });

    test('a defines file with one of the two is refused, naming the one it lacks', () {
      // Both names are in either message, so each is held to the one it says is missing (#113's review).
      expect(() => SyncConfig.of(url, ''),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains('without ${SyncConfig.keyName}'))));
      expect(() => SyncConfig.of('', key),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains('without ${SyncConfig.urlName}'))));
    });
  });

  group('the host with sync off, or unable to open (#113 criterion 2)', () {
    late EventStore store;
    late String dir;
    late List<String> logged;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('pc_host_').path;
      store = EventStore.open(p.join(dir, 'core.db'));
      logged = [];
      addTearDown(() {
        store.close();
        try {
          Directory(dir).deleteSync(recursive: true);
        } on FileSystemException {
          // Windows can hold the WAL briefly.
        }
      });
    });

    SyncEngine? open(SyncConfig? Function() config, {String? sessionDir}) =>
        openSync(store, config: config, sessionDir: sessionDir, log: logged.add);

    test('no project: sync is off, and says why', () {
      expect(open(() => null, sessionDir: dir), isNull);
      expect(logged, ['SYNC OFF this build names no project']);
    });

    test('no session directory: sync is off rather than keeping a session somewhere backed up', () {
      expect(open(() => const SyncConfig(url, 'sb_publishable_test')), isNull);
      expect(logged.single, startsWith('SYNC OFF'));
    });

    test('a broken defines file or a secret key: sync is off, the log names neither key', () {
      const secret = 'sb_secret_DO_NOT_SHIP';
      expect(open(() => SyncConfig.of(url, ''), sessionDir: dir), isNull);
      expect(open(() => const SyncConfig(url, secret), sessionDir: dir), isNull, reason: 'the control: refused');
      expect(logged, hasLength(2));
      expect(logged.every((l) => l.startsWith('SYNC OFF')), isTrue, reason: '$logged');
      expect(logged.join('\n'), isNot(contains(secret)));
    });

    test('with sync off the core works as before: appends land, join and sign-in answer no_server', () async {
      final core = PortCoreClient(serveHost(store, null), closesCore: false);
      expect((await core.append(FleetEvents.define('Lasers'))).seq, 1);
      await expectLater(core.join('ABCD-2345'),
          throwsA(isA<CoreException>().having((e) => e.code, 'code', JoinCodes.noServer)));
      await expectLater(core.requestSignInLink('volunteer@example.com'),
          throwsA(isA<CoreException>().having((e) => e.code, 'code', SignInCodes.noServer)));
    });

    test("with sync, join and both sign-in calls reach sync's engine (criterion 5's wiring)", () async {
      final paths = <String>[];
      final engine = SyncEngine.open(
        url: url,
        publishableKey: key,
        store: store,
        sessionDir: dir,
        // No server: every request is recorded and refused, which is all the wiring needs.
        transport: MockClient((request) async {
          paths.add(request.url.path);
          return http.Response('{"code":"test_refusal","msg":"no server here"}', 400);
        }),
        log: logged.add,
      );
      addTearDown(engine.close);
      final core = PortCoreClient(serveHost(store, engine), closesCore: false);
      // Each refusal is the engine's, never the core's no_server (#113's review: any CoreException
      // passed, so a call left unwired looked wired).
      final reachedSync = isA<CoreException>()
          .having((e) => e.code, 'code', isNot(anyOf(SignInCodes.noServer, JoinCodes.noServer)));
      await expectLater(core.requestSignInLink('volunteer@example.com'), throwsA(reachedSync));
      await expectLater(core.completeSignInLink('one-time-code'), throwsA(reachedSync));
      await expectLater(core.join('ABCD-2345'), throwsA(reachedSync));
      expect(paths, containsAllInOrder(['/auth/v1/otp', '/auth/v1/signup']),
          reason: 'the request mailed through gotrue, then the join signing in by device handoff');
    });
  });
}
