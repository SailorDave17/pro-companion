import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_sync/sync.dart';
import 'package:supabase/supabase.dart' show SignOutScope;
import 'package:test/test.dart';

import 'support.dart';

/// #6: the engine's rules, against the real Supabase client over a scripted server. Only the
/// transport is fake, so every answer is read the way the real client reads it. The local-stack
/// tests (test/sync_test.dart at the repo root) meet the real server.
void main() {
  const alice = '00000000-0000-4000-8000-00000000a11c';
  const volunteer = '00000000-0000-4000-8000-00000000701d';

  group('criterion 1: every event lands once, and the phone keeps what was acknowledged', () {
    test('events logged offline all land on the first run, and a second run sends nothing', () async {
      final server = FakeServer();
      final (phone, engine, _) = await admittedPhone(server, alice, dayOne);
      final ulids = phone.log(12);

      final first = await engine.syncOnce();
      expect(first.state, UploadRunState.done);
      expect(first.accepted, 12);
      expect(server.log.keys, unorderedEquals(ulids));
      for (final u in ulids) {
        expect(server.appendsOf(u), 1, reason: u);
      }
      expect(phone.store.uploadStatus().accepted, 12);

      final sent = server.appends.length;
      final second = await engine.syncOnce();
      expect(second.state, UploadRunState.done);
      expect(second.remaining, 0);
      expect(server.appends.length, sent, reason: 'nothing is sent twice');
    });

    test('each event goes as its stored text, byte for byte, to its own admission\'s race day', () async {
      final server = FakeServer();
      final (phone, engine, _) = await admittedPhone(server, alice, dayOne);
      // A whole-number double past 2^63: stored as RFC 8785 prints it, which a decode and
      // re-encode would not reproduce ("100000000000000000000.0").
      phone.store.append(const NewEvent(kind: 'finish', source: 'tap', payload: {'z': 1e20, 'a': 0.1, 'm': 12.0}));
      final stored = phone.store.readCanonical().single;
      expect(stored, contains('"payload":{"a":0.1,"m":12,"z":100000000000000000000}'));

      await engine.syncOnce();
      final sent = server.appends.single.json;
      expect(sent['p_canonical'], stored);
      expect(sent['p_event'], dayOne);
    });
  });

  group('criterion 2: an interrupted sync, retried, loses nothing and duplicates nothing', () {
    test('drops before the send, drops after the server stored it, and a 503 all converge', () async {
      final server = FakeServer();
      final (phone, engine, _) = await admittedPhone(server, alice, dayOne);
      final ulids = phone.log(6);
      var appendCalls = 0;
      final faults = <int, String>{2: 'before', 3: 'after-commit', 5: '503', 6: 'after-commit'};
      server.hooks.add((r) {
        if (!r.isAppend) return null;
        appendCalls++;
        switch (faults[appendCalls]) {
          case 'before':
            throw http.ClientException('dropped before the send');
          case 'after-commit':
            server.answer(r); // the server stores it...
            throw http.ClientException('...and the answer is lost');
          case '503':
            return http.Response('<html>Service Unavailable</html>', 503);
        }
        return null;
      });

      final first = await engine.syncOnce();
      expect(first.state, UploadRunState.unreachable, reason: 'a network drop ends the run');
      final second = await engine.syncOnce();
      expect(second.state, UploadRunState.unreachable);
      expect(appendCalls, 3, reason: 'the second run ended on the lost answer');
      // Control: the drop after the commit really was after it. The server holds the event, and
      // the phone has no outcome for it.
      final lostAnswer = server.appends.elementAt(2).json['p_canonical'] as String;
      final lostUlid = (jsonDecode(lostAnswer) as Map)['ulid'] as String;
      expect(server.log[lostUlid]?.canonical, lostAnswer);
      expect(phone.store.pendingUploads().map((p) => p.ulid), contains(lostUlid));

      for (var i = 0; i < 6 && phone.store.pendingUploads().isNotEmpty; i++) {
        await engine.syncOnce();
      }
      expect(phone.store.pendingUploads(), isEmpty);
      expect(phone.store.uploadStatus().accepted, 6);
      // Converged: the server holds exactly the phone's events, each as stored.
      final stored = {for (final t in phone.store.readCanonical()) (jsonDecode(t) as Map)['ulid']: t};
      expect({for (final e in server.log.entries) e.key: e.value.canonical}, stored);
      expect(server.log.keys, unorderedEquals(ulids));
      // Each event was sent once more than it failed, and never again.
      final failed = {for (final i in faults.keys) i: server.appends.elementAt(i - 1).json['p_canonical']};
      for (final u in ulids) {
        final failures = failed.values.where((t) => t.toString().contains('"ulid":"$u"')).length;
        expect(server.appendsOf(u), failures + 1, reason: u);
      }
      final sent = server.appends.length;
      await engine.syncOnce();
      expect(server.appends.length, sent);
    });

    test('the retry after a lost answer is answered as a duplicate, and acknowledged', () async {
      final server = FakeServer();
      final (phone, engine, _) = await admittedPhone(server, alice, dayOne);
      phone.log(1);
      final answers = <Object?>[];
      var dropped = false;
      server.hooks.add((r) {
        if (!r.isAppend) return null;
        final answer = server.answer(r);
        answers.add(jsonDecode(answer.body));
        if (!dropped) {
          dropped = true;
          throw http.ClientException('lost');
        }
        return answer;
      });
      await engine.syncOnce();
      await engine.syncOnce();
      expect([for (final a in answers) (a as Map)['duplicate']], [false, true]);
      expect(phone.store.uploadStatus().accepted, 1);
    });
  });

  group('criteria 10 and 11: a refusal is final and flagged; anything else is retried', () {
    for (final reason in ['revoked', 'inconsistent_canonical', 'ulid_conflict', 'admission_mismatch']) {
      test('a refusal ($reason) is kept with its reason, and never sent again', () async {
        final server = FakeServer();
        final (phone, engine, _) = await admittedPhone(server, alice, dayOne);
        final ulids = phone.log(2);
        server.hooks.add((r) => r.isAppend && r.body.contains(ulids.first)
            ? FakeServer.refusal(reason, r.json['p_canonical'] as String)
            : null);

        final run = await engine.syncOnce();
        expect(run.refused, 1);
        expect(run.accepted, 1, reason: 'the next event still went');
        await engine.syncOnce();
        await engine.syncOnce();
        expect(server.appendsOf(ulids.first), 1, reason: 'counted: sent once, never again');
        final status = phone.store.uploadStatus();
        expect(status.refused, [RefusedUpload(ulid: ulids.first, reason: reason, mayBeOnShore: false)]);
        expect(status.pending, 0);
      });
    }

    // Each answer, the run state it leaves, and whether the send may have stored the event: only
    // an answer from the database itself proves nothing was stored (the send is voided); a drop,
    // a page from something in between, or a 2xx sync cannot read leaves it unknown.
    final transient = <String, (FutureOr<http.Response> Function(), String, bool)>{
      'a network drop': (
        () => throw http.ClientException('connection reset'),
        UploadRunState.unreachable,
        true,
      ),
      'a 500 with a SQLSTATE (append_event raised)': (
        () => postgrestError(500, '40001', 'could not serialize'),
        UploadRunState.retrying,
        false,
      ),
      "a gateway's 503 page": (
        () => http.Response('<html>Service Unavailable</html>', 503),
        UploadRunState.unreachable,
        true,
      ),
      'a raised 400, standing in for #75\'s unknown-fleet error': (
        () => postgrestError(400, 'P0001', 'unknown fleet'),
        UploadRunState.retrying,
        false,
      ),
      'a missing function (PGRST202)': (
        () => postgrestError(404, 'PGRST202', 'function not found'),
        UploadRunState.retrying,
        false,
      ),
      "a captive portal's 200 page": (
        () => http.Response('<html>Sign in to Club Wi-Fi</html>', 200),
        UploadRunState.unreachable,
        true,
      ),
      'an accepted answer with the wrong hash': (
        () => http.Response(jsonEncode({'outcome': 'accepted', 'duplicate': false, 'hash': '0' * 64}), 200,
            headers: {'content-type': 'application/json'}),
        UploadRunState.retrying,
        true,
      ),
    };
    for (final MapEntry(key: what, value: (answer, state, _)) in transient.entries) {
      test('$what is retried and never flagged', () async {
        final server = FakeServer();
        final (phone, engine, _) = await admittedPhone(server, alice, dayOne);
        final u = phone.log(1).single;
        var failures = 3;
        server.hooks.add((r) async => r.isAppend && failures-- > 0 ? await answer() : null);

        for (var i = 0; i < 3; i++) {
          final run = await engine.syncOnce();
          expect(run.state, state);
          expect(run.refused, 0);
          expect(run.remaining, 1);
          expect(phone.store.uploadStatus().refused, isEmpty);
        }
        final last = await engine.syncOnce();
        expect(last.state, UploadRunState.done);
        expect(server.appendsOf(u), 4);
        expect(phone.store.uploadStatus().accepted, 1);
      });
    }
    for (final MapEntry(key: what, value: (answer, _, unknown)) in transient.entries) {
      test('after $what, a later refusal is ${unknown ? '' : 'not '}flagged as maybe on shore', () async {
        final server = FakeServer();
        final (phone, engine, admission) = await admittedPhone(server, alice, dayOne);
        final u = phone.log(1).single;
        var failures = 1;
        server.hooks.add((r) async => r.isAppend && failures-- > 0 ? await answer() : null);
        expect((await engine.syncOnce()).remaining, 1);

        server.revoked.add(admission);
        await engine.syncOnce();
        expect(phone.store.uploadStatus().refused, [RefusedUpload(ulid: u, reason: 'revoked', mayBeOnShore: unknown)]);
      });
    }

    test('a refusal answered after an unknown outcome is flagged as maybe on shore; after a proved '
        'rollback it is not', () async {
      final server = FakeServer();
      final (phone, engine, admission) = await admittedPhone(server, alice, dayOne);
      final ulids = phone.log(2);
      final first = <String>{};
      server.hooks.add((r) {
        if (!r.isAppend) return null;
        final u = ulids.firstWhere((u) => r.body.contains(u));
        if (!first.add(u)) return null;
        if (u == ulids[0]) {
          server.answer(r); // stored, answer lost
          throw http.ClientException('lost');
        }
        return postgrestError(400, 'P0001', 'rolled back'); // nothing stored
      });
      await engine.syncOnce();
      server.revoked.add(admission);
      await engine.syncOnce();
      await engine.syncOnce();
      expect(phone.store.uploadStatus().refused, [
        RefusedUpload(ulid: ulids[0], reason: 'revoked', mayBeOnShore: true),
        RefusedUpload(ulid: ulids[1], reason: 'revoked', mayBeOnShore: false),
      ]);
      expect(server.log.keys, [ulids[0]], reason: 'the flag is right: the first one is on shore');
    });

    test('the flag survives the core engine being killed with the send in flight', () async {
      final server = FakeServer();
      final (phone, engine, admission) = await admittedPhone(server, alice, dayOne);
      final u = phone.log(1).single;
      final never = Completer<http.Response?>();
      server.hooks.add((r) {
        if (!r.isAppend) return null;
        server.answer(r);
        return never.future; // the process dies before an answer arrives
      });
      final killed = engine.syncOnce();
      for (var i = 0; i < 100 && server.log.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(server.log.keys, [u], reason: 'control: the send reached the server before the kill');

      // The system restarts the core: a new connection to the same log, a new engine.
      server.hooks.clear();
      server.revoked.add(admission);
      final restarted = EventStore.open(phone.dbPath);
      addTearDown(restarted.close);
      final again = SyncEngine.open(
          url: projectUrl, publishableKey: publishableKey, store: restarted, sessionDir: phone.dir, transport: server);
      addTearDown(again.close);
      await again.syncOnce();
      expect(restarted.uploadStatus().refused, [RefusedUpload(ulid: u, reason: 'revoked', mayBeOnShore: true)]);
      // The killed engine stands in for a dead process, so end its run here, inside the test:
      // left to finish during teardown, it wrote to a store being closed under it. That was the
      // likeliest cause of the suite exiting non-zero after all its tests passed (2 of 88 runs).
      never.completeError(http.ClientException('the killed process never hears back'));
      await killed;
      await engine.close();
    });
  });

  group('a run is bound to one user (owner decision on #6: a lost session pauses, never refuses)', () {
    test('nothing is sent to a race day the signed-in user holds no admission to', () async {
      final server = FakeServer();
      final phone = TestPhone(admission: uuid(0xa99));
      phone.store.recordAdmissionEvent(uuid(0xa99), dayOne);
      phone.keepSession(server.session(alice));
      final engine = phone.engine(server);
      addTearDown(engine.close);
      phone.log(3);

      final run = await engine.syncOnce();
      expect(run.state, UploadRunState.notAdmitted);
      expect(run.paused, 3);
      expect(server.appends, isEmpty, reason: 'counted: nothing sent');
      expect(phone.store.uploadStatus().refused, isEmpty);
      expect(phone.store.uploadStatus().pending, 3);
      expect(phone.store.uploadStatus().lastRun?.state, UploadRunState.notAdmitted);

      (server.admissions[alice] ??= {})[uuid(0xa99)] = dayOne; // admitted after all
      final after = await engine.syncOnce();
      expect(after.accepted, 3);
    });

    test("each event goes to its own admission's race day, not the phone's current one", () async {
      final server = FakeServer();
      final (phone, engine, dayOneAdmission) = await admittedPhone(server, alice, dayOne);
      final saturday = phone.log(2);
      final dayTwoAdmission = server.admitDirectly(alice, dayTwo);
      phone.store.setAdmissionId(dayTwoAdmission);
      final sunday = phone.log(2);
      expect(dayOneAdmission, isNot(dayTwoAdmission));

      await engine.syncOnce();
      for (final u in saturday) {
        expect(server.log[u]?.event, dayOne, reason: u);
      }
      for (final u in sunday) {
        expect(server.log[u]?.event, dayTwo, reason: u);
      }
    });

    test('a magic-link sign-in during a run waits for it to stop: nothing goes out as the new user', () async {
      final server = FakeServer();
      final (phone, engine, _) = await admittedPhone(server, alice, dayOne);
      phone.log(5);
      final link = server.magicLinkFor(volunteer);
      Future<String>? signIn;
      server.hooks.add((r) async {
        if (r.isAppend && signIn == null) {
          signIn = engine.signInWithMagicLink(link);
          // The answer is slow, so a sign-in that did not wait would go out while it is in flight.
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        return null;
      });

      await engine.syncOnce();
      expect(await signIn, volunteer);
      // The sign-in went out only once the run had stopped: after the last send the run made, and
      // with nothing in flight. The run's own stop at the next event would also keep the volunteer's
      // token off every send, so only this shows the sign-in itself waited.
      final verify = server.requests.firstWhere((r) => r.path == '/auth/v1/verify');
      expect(verify.appendsInFlight, 0);
      expect(server.requests.indexOf(verify),
          greaterThan(server.requests.lastIndexWhere((r) => r.isAppend && r.caller == alice)));
      await engine.syncOnce();
      expect(server.appends.where((r) => r.caller == volunteer), isEmpty,
          reason: 'counted: the volunteer holds no admission to that race day');
      expect(phone.store.uploadStatus().refused, isEmpty);
      expect(phone.store.uploadStatus().pending, 4, reason: 'the first went as alice; the rest wait');
    });

    test('a session lost mid-run ends it: nothing goes out as nobody, or as the next user', () async {
      final server = FakeServer();
      final (phone, engine, _) = await admittedPhone(server, alice, dayOne);
      phone.log(5);
      var lost = false;
      server.hooks.add((r) async {
        if (r.isAppend && !lost) {
          lost = true;
          // What gotrue does when its ticker's refresh is refused: signs the phone out locally.
          await engine.clientForTests.auth.signOut(scope: SignOutScope.local);
        }
        return null;
      });

      final run = await engine.syncOnce();
      expect(run.state, UploadRunState.noSession);
      expect(server.appends.where((r) => r.caller == null), isEmpty, reason: 'counted: no send without a session');
      expect(phone.sessionFile.existsSync(), isFalse);

      final next = await engine.signInAnonymously();
      final paused = await engine.syncOnce();
      expect(paused.state, UploadRunState.notAdmitted);
      expect(server.appends.where((r) => r.caller == next), isEmpty);
      expect(phone.store.uploadStatus().refused, isEmpty);
    });

    test('a not_admitted answer for a race day this user holds is never kept', () async {
      final server = FakeServer();
      final (phone, engine, _) = await admittedPhone(server, alice, dayOne);
      final u = phone.log(1).single;
      var once = true;
      server.hooks.add((r) {
        if (!r.isAppend || !once) return null;
        once = false;
        return FakeServer.refusal('not_admitted', r.json['p_canonical'] as String);
      });

      final run = await engine.syncOnce();
      expect(run.state, UploadRunState.notAdmitted);
      expect(phone.store.uploadStatus().refused, isEmpty);
      final again = await engine.syncOnce();
      expect(again.accepted, 1);
      expect(phone.store.uploadStatus().refused, isEmpty);
      expect(server.log.keys, [u]);
    });
  });

  group('the run itself', () {
    test('two runs asked for at once are one run: each event is sent once', () async {
      final server = FakeServer();
      final (phone, engine, _) = await admittedPhone(server, alice, dayOne);
      final ulids = phone.log(4);
      final runs = await Future.wait([engine.syncOnce(), engine.syncOnce(), engine.syncOnce()]);
      expect(runs.map((r) => r.state).toSet(), {UploadRunState.done});
      for (final u in ulids) {
        expect(server.appendsOf(u), 1, reason: u);
      }
    });

    test('an error nothing classifies fails the run, is recorded, and does not stop sync', () async {
      final server = FakeServer();
      final (phone, engine, _) = await admittedPhone(server, alice, dayOne);
      phone.log(1);
      var broken = true;
      server.hooks.add((r) => r.path == '/rest/v1/committee_device' && broken
          ? http.Response(jsonEncode([
              {'id': null, 'event_id': dayOne},
            ]), 200, headers: {'content-type': 'application/json'})
          : null);

      final run = await engine.syncOnce();
      expect(run.state, UploadRunState.retrying);
      expect(run.error, isNotNull);
      expect(phone.store.uploadStatus().lastRun?.state, UploadRunState.retrying);
      broken = false;
      final next = await engine.syncOnce();
      expect(next.accepted, 1);
    });

    test('a store that fails its reads fails the run, and sync is not stopped by the failure', () async {
      final server = FakeServer();
      final (phone, engine, _) = await admittedPhone(server, alice, dayOne);
      phone.log(1);
      phone.store.close();

      // Reading the store again to count what waits must not throw from the catch: the run would
      // escape unrecorded, and no retry would be set.
      final run = await engine.syncOnce();
      expect(run.state, UploadRunState.retrying);
      expect(run.remaining, greaterThan(0), reason: 'counted as waiting, so it is retried');
      expect(run.error, isNotNull);
    });

    test('criterion 8: a new event kind at a new payload version syncs with no change to sync', () async {
      final server = FakeServer();
      final (phone, engine, _) = await admittedPhone(server, alice, dayOne);
      phone.store.append(const NewEvent(
          kind: 'weather.gust', source: 'anemometer', payloadVersion: 99, payload: {'knots': 23.5, 'from': 270}));
      final stored = phone.store.readCanonical().single;

      final run = await engine.syncOnce();
      expect(run.accepted, 1);
      expect(server.log.values.single.canonical, stored);
      expect(stored, allOf(contains('"kind":"weather.gust"'), contains('"payload_version":99')));
    });

    test('events written before the phone was ever admitted stay on the phone', () async {
      final server = FakeServer();
      final phone = TestPhone();
      final early = phone.log(2);
      final admission = server.admitDirectly(alice, dayOne);
      phone.store.setAdmissionId(admission);
      phone.keepSession(server.session(alice));
      final engine = phone.engine(server);
      addTearDown(engine.close);
      final later = phone.log(1);

      final run = await engine.syncOnce();
      expect(run.neverAdmitted, 2);
      expect(run.accepted, 1);
      expect(server.log.keys, later);
      for (final u in early) {
        expect(server.appendsOf(u), 0);
      }
      final status = phone.store.uploadStatus();
      expect((status.neverAdmitted, status.pending, status.accepted), (2, 0, 1));
      expect(run.state, UploadRunState.done);
    });
  });
}
