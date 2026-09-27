import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pro_companion_core/core.dart' show EventKinds;
import 'package:pro_companion_core/store.dart' hide newUlid;
import 'package:pro_companion_sync/sync.dart';
import 'package:supabase/supabase.dart' show PostgrestException;

import '../scripts/owner.dart' as owner;
import 'support/local_stack.dart';

/// #6: the sync engine against the local stack, as a phone meets the companion's server. Each
/// phone signs in and is admitted through the engine itself; the owner's reads (psql as the table
/// owner) are the instrument, since no phone can read the log before #50.
///
/// Spend per run of this file: 2 anonymous sign-ins (the device-handoff case) of the stack's 30 an
/// hour, and 12 magic-link verifications of its 30 per 5 minutes. A whole stack run spends 16
/// verifications (README), so two whole runs inside 5 minutes can fail on RATE LIMITED rather than
/// on what they test. Prove a mutation with --plain-name on one case.
///
/// Skips unless PRO_COMPANION_LOCAL_STACK=1, which the CI job `local-stack` sets.
void main() {
  group('sync against the local stack (#6)', () {
    late LocalStack stack;
    late owner.Provisioned day;
    late owner.Provisioned otherDay;
    late owner.Provisioned strangerDay;
    late StackPhone scorer;

    setUpAll(() async {
      stack = await LocalStack.connect();
      day = await stack.raceDay();
      otherDay = await stack.raceDay();
      strangerDay = await stack.raceDay();
      scorer = await StackPhone.open(stack);
      await scorer.signInNamed();
      await scorer.admitTo(day);
    });

    tearDownAll(() async => scorer.close());

    Future<Map<String, Map<String, Object?>>> shore(String eventId) async =>
        {for (final r in await stack.eventLogRows(eventId)) r['ulid'] as String: r};

    test('criterion 1: events logged offline land once each, as stored, and the phone keeps the '
        'acknowledgement', () async {
      final ulids = scorer.log(8);
      final run = await scorer.engine.syncOnce();
      expect(run.state, UploadRunState.done, reason: '$run');

      final rows = await shore(day.eventId);
      final stored = scorer.storedByUlid();
      for (final u in ulids) {
        expect(rows[u]?['canonical'], stored[u], reason: 'stored exactly as the phone wrote it: $u');
        expect(scorer.transport.appendsOf(u), 1, reason: 'counted: sent once: $u');
      }
      expect(scorer.store.pendingUploads(), isEmpty);

      final sent = scorer.transport.appends.length;
      final again = await scorer.engine.syncOnce();
      expect(again.remaining, 0);
      expect(scorer.transport.appends.length, sent, reason: 'a second run sends nothing');
    });

    test('criterion 2: drops before the send and after the commit, and a 503, retried, end with '
        'every event once', () async {
      // One carries a number a decode and re-encode would print differently, so a retry that
      // re-serialised would become a ulid_conflict here rather than a duplicate.
      final ulids = [
        ...scorer.log(2),
        scorer.store.append(const NewEvent(kind: 'finish', source: 'tap', payload: {'big': 1e20})).ulid,
        ...scorer.log(3),
      ];
      // Each fault on a different event's first send. A fault ends its run, so faults keyed by
      // call number would all land on one event.
      final faults = {ulids[1]: 'before', ulids[2]: 'after-commit', ulids[3]: '503', ulids[4]: 'after-commit'};
      final lostAfterCommit = <String>[];
      final faulted = <String>[];
      scorer.transport.hooks.add((r) async {
        if (!r.url.path.endsWith('/rpc/append_event')) return null;
        final u = (jsonDecode((jsonDecode(r.body) as Map)['p_canonical'] as String) as Map)['ulid'] as String;
        final fault = faults.remove(u);
        if (fault != null) faulted.add(u);
        switch (fault) {
          case 'before':
            throw http.ClientException('dropped before the send (test)');
          case 'after-commit':
            await scorer.transport.forward(r);
            lostAfterCommit.add((jsonDecode((jsonDecode(r.body) as Map)['p_canonical'] as String) as Map)['ulid'] as String);
            throw http.ClientException('the answer is lost (test)');
          case '503':
            return http.Response('<html>Service Unavailable</html>', 503);
        }
        return null;
      });
      addTearDown(scorer.transport.hooks.clear);

      await scorer.engine.syncOnce();
      await scorer.engine.syncOnce();
      // Control: the drop after the commit was after it. The server holds it; the phone has no
      // outcome for it yet.
      expect(lostAfterCommit, hasLength(1));
      expect(await stack.eventLogCanonical(lostAfterCommit.single), scorer.storedByUlid()[lostAfterCommit.single]);
      expect(scorer.store.pendingUploads().map((p) => p.ulid), contains(lostAfterCommit.single));

      for (var i = 0; i < 8 && scorer.store.pendingUploads().isNotEmpty; i++) {
        await scorer.engine.syncOnce();
      }
      expect(scorer.store.pendingUploads(), isEmpty);
      final rows = await shore(day.eventId);
      final stored = scorer.storedByUlid();
      for (final u in ulids) {
        expect(rows[u]?['canonical'], stored[u], reason: u);
      }
      expect(scorer.store.uploadStatus().refused, isEmpty, reason: 'no retry became a ulid_conflict');
      // The retries of the two lost answers were answered as duplicates.
      final duplicates = [
        for (final s in scorer.transport.appends)
          if (s.status == 200 && (jsonDecode(s.answer!) as Map)['duplicate'] == true) s,
      ];
      expect(duplicates, hasLength(2));
      expect(faulted, hasLength(4), reason: 'control: every fault was injected');
      for (final u in ulids) {
        expect(scorer.transport.appendsOf(u), 1 + faulted.where((f) => f == u).length,
            reason: 'counted: sent once more than it failed, and never again: $u');
      }
    });

    test('criteria 6 and 8: one event of every kind the core writes, and a new kind at a new payload '
        'version, upload as their stored bytes, admission included', () async {
      final kinds = [...EventKinds.all, 'test.synthetic'];
      final ulids = <String, String>{
        for (final k in kinds)
          k: scorer.store
              .append(NewEvent(kind: k, source: 'tap', payloadVersion: k == 'test.synthetic' ? 99 : 1, payload: {'probe': k}))
              .ulid,
      };
      expect(kinds.length, greaterThanOrEqualTo(14));
      await scorer.engine.syncOnce();

      final rows = await shore(day.eventId);
      final stored = scorer.storedByUlid();
      for (final MapEntry(key: kind, value: u) in ulids.entries) {
        expect(rows[u]?['canonical'], stored[u], reason: kind);
        expect(rows[u]?['hash'], chainHash(stored[u]!), reason: kind);
        expect((jsonDecode(rows[u]!['canonical'] as String) as Map)['admission_id'], scorer.admission, reason: kind);
      }
    });

    test('criterion 7: keys out of order and decimals arrive as the phone\'s bytes, and the hash '
        'recomputes on shore to the phone\'s value', () async {
      final u = scorer.store.append(const NewEvent(kind: 'finish', source: 'tap', payload: {
        'z': 1e20,
        'm': 12.0,
        'a': 0.1,
        'k': {'y': 1, 'b': 2.5},
      })).ulid;
      final text = scorer.storedByUlid()[u]!;
      // Written by hand from RFC 8785, not by the serialiser under test.
      expect(text, contains('"payload":{"a":0.1,"k":{"b":2.5,"y":1},"m":12,"z":100000000000000000000}'));

      await scorer.engine.syncOnce();
      final row = (await shore(day.eventId))[u]!;
      expect(row['canonical'], text);
      final phoneHash = chainHash(text);
      expect(sha256.convert(utf8.encode(row['canonical'] as String)).toString(), phoneHash);
      expect(row['hash'], phoneHash, reason: "the server's own SHA-256 of what it stored");
      final answer = scorer.transport.seen.lastWhere((s) => s.body.contains(u)).answer!;
      expect((jsonDecode(answer) as Map)['hash'], phoneHash, reason: "append_event's answer");
    });

    test('criteria 5 and 13: from the sync client, the log refuses UPDATE, DELETE and a direct INSERT, '
        'another club\'s race day refuses the event, and no request carries the secret key', () async {
      final u = scorer.log(1).single;
      await scorer.engine.syncOnce();
      final text = await stack.eventLogCanonical(u);
      expect(text, isNotNull);
      final client = scorer.engine.clientForTests;

      Future<void> refused(Future<Object?> Function() write, String what) async {
        await expectLater(
            write(),
            throwsA(isA<PostgrestException>()
                .having((e) => e.code, 'code', '42501')
                .having((e) => e.message, 'message', 'permission denied for table event_log')),
            reason: what);
      }

      await refused(() => client.from('event_log').update({'canonical': 'x'}).eq('ulid', u), 'update');
      await refused(() => client.from('event_log').delete().eq('ulid', u), 'delete');
      final planted = sampleEvent(newUlid());
      await refused(() => client.from('event_log').insert({'event_id': day.eventId, 'canonical': planted}), 'insert');
      expect(await stack.eventLogCanonical(u), text, reason: 'the row is unchanged');
      expect(await stack.eventLogCanonical((jsonDecode(planted) as Map)['ulid'] as String), isNull);

      // A race day of another club, which this phone holds no admission to.
      await expectLater(
          client.rpc<dynamic>('append_event', params: {'p_event': strangerDay.eventId, 'p_canonical': text}),
          throwsA(isA<PostgrestException>()
              .having((e) => e.code, 'code', 'append_event_refused')
              .having((e) => e.details, 'details', 'not_admitted')));
      expect(await stack.eventLogRows(strangerDay.eventId), isEmpty);

      for (final s in scorer.transport.seen) {
        expect(s.apikey, stack.publishableKey, reason: '${s.method} ${s.path}');
        expect(s.bearer, isNot(stack.secretKeyForRefusal));
      }
      final dir = Directory.systemTemp.createTempSync('pc_sync_key_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final quiet = StackTransport();
      expect(
          () => SyncEngine.open(
              url: stack.api.toString(),
              publishableKey: stack.secretKeyForRefusal,
              store: scorer.store,
              sessionDir: dir.path,
              transport: quiet),
          throwsArgumentError);
      expect(quiet.seen, isEmpty, reason: 'refused before any request');
    });

    test('criterion 3: two phones on one race day end with the union, each row its own phone\'s '
        'bytes', () async {
      final base = DateTime.now().millisecondsSinceEpoch;
      // The first value mints the device id; then each event's time. The store's clock is also
      // read by sync's own records, so a phone's third event takes the list's last value: two
      // times, base + 20 and base + 100, are shared by both phones, two ties to break.
      final first = await StackPhone.open(stack, clock: stepping([base - 1000, base, base + 20, base + 40, base + 100]));
      final second = await StackPhone.open(stack, clock: stepping([base - 1000, base + 10, base + 20, base + 40, base + 100]));
      addTearDown(first.close);
      addTearDown(second.close);
      for (final p in [first, second]) {
        await p.signInNamed();
        await p.admitTo(day);
      }
      // The two ties reach shore in opposite phone orders: the first phone's event lands first at
      // the first tie, the second's at the second. So whatever order rows with equal keys come
      // back in, one tie disagrees with the device-id order unless device_id decides it. Measured
      // on #6: today the read goes through the (event_id, device_id, seq) index, which hands the
      // rows over in device-id order anyway, so dropping device_id from the read's ORDER BY
      // changes nothing (0 of 4 runs red); with index scans also off, the second tie comes back in
      // arrival order and this test fails (2 of 2).
      final aUlids = first.log(2);
      final bUlids = second.log(2);
      await first.engine.syncOnce();
      final firstRows = await shore(day.eventId);
      await second.engine.syncOnce();
      bUlids.addAll(second.log(1));
      await second.engine.syncOnce();
      aUlids.addAll(first.log(1));
      await first.engine.syncOnce();
      final rows = await shore(day.eventId);

      final stored = {...first.storedByUlid(), ...second.storedByUlid()};
      for (final u in [...aUlids, ...bUlids]) {
        expect(rows[u]?['canonical'], stored[u], reason: 'the union, each as its phone wrote it: $u');
      }
      for (final u in aUlids.take(2)) {
        expect(rows[u]?['canonical'], firstRows[u]?['canonical'], reason: 'the second phone overwrote nothing');
      }
      // Held by the data rather than by sync: device_ts, device_id and seq are generated from the
      // text. A sanity check that the rule reads the same on shore as on the phones. The phones'
      // own order is pinned with fixed ids in packages/core/test/ordering_test.dart.
      final devices = {first.store.deviceId, second.store.deviceId};
      final shoreOrder = [
        for (final r in await stack.eventLogRows(day.eventId))
          if (devices.contains(r['device_id'])) r['ulid'],
      ];
      final local = [...first.pendingUploadsIncludingSent(), ...second.pendingUploadsIncludingSent()]
        ..sort((x, y) => x.compareTo(y));
      expect(shoreOrder, [for (final e in local) e.ulid]);
    });

    test('criterion 4: skewed phone clocks are kept verbatim, and the server keeps its own receipt '
        'time beside them', () async {
      const threeHours = 3 * 3600 * 1000;
      const sevenMinutes = 7 * 60 * 1000;
      final behind = await StackPhone.open(stack, clock: () => DateTime.now().millisecondsSinceEpoch - threeHours);
      final ahead = await StackPhone.open(stack, clock: () => DateTime.now().millisecondsSinceEpoch + sevenMinutes);
      addTearDown(behind.close);
      addTearDown(ahead.close);
      for (final p in [behind, ahead]) {
        await p.signInNamed();
        await p.admitTo(day);
      }
      final before = DateTime.now().millisecondsSinceEpoch;
      final slow = behind.log(2);
      final fast = ahead.log(2);
      await behind.engine.syncOnce();
      await ahead.engine.syncOnce();
      final after = DateTime.now().millisecondsSinceEpoch;

      final rows = await shore(day.eventId);
      for (final (phone, ulids, skew) in [(behind, slow, -threeHours), (ahead, fast, sevenMinutes)]) {
        final local = {for (final e in phone.store.readAll()) e.ulid: e};
        for (final u in ulids) {
          expect(rows[u]!['device_ts'], local[u]!.deviceTs, reason: 'verbatim: $u');
          final received = rows[u]!['received_at'] as int;
          expect(received, inInclusiveRange(before - 60000, after + 60000), reason: "the server's clock: $u");
          expect(local[u]!.deviceTs - received, closeTo(skew, 60000), reason: 'never rewritten toward it: $u');
        }
      }
    });

    test("each event goes to its own admission's race day, when one user is admitted to two", () async {
      final phone = await StackPhone.open(stack);
      addTearDown(phone.close);
      await phone.signInNamed();
      await phone.admitTo(day);
      final saturday = phone.log(1).single;
      await phone.admitTo(otherDay);
      final sunday = phone.log(1).single;
      await phone.engine.syncOnce();
      expect(await stack.eventOf(saturday), day.eventId);
      expect(await stack.eventOf(sunday), otherDay.eventId);
    });

    test('criterion 10: a refusal of any category stays on the phone, flagged, and is never sent '
        'again; one after a lost answer is flagged as maybe on shore', () async {
      final phone = await StackPhone.open(stack);
      addTearDown(phone.close);
      await phone.signInNamed();
      final admission = await phone.admitTo(day);

      final ok = phone.log(1).single;
      // A body the server cannot store as an event (its seq is not a number), planted in the
      // phone's log the way a corrupt write would leave it.
      final bad = newUlid();
      phone.store.debugDatabase.execute('INSERT INTO events (ulid, device_id, seq, device_ts, body) VALUES (?, ?, ?, ?, ?)', [
        bad,
        phone.store.deviceId,
        1000000,
        DateTime.now().millisecondsSinceEpoch,
        '{"admission_id":"$admission","device_id":"${phone.store.deviceId}","seq":"three","ulid":"$bad"}',
      ]);
      // An event whose ULID the log already holds with other bytes.
      final clash = phone.log(1).single;
      await stack.seedCanonical(day.eventId, phone.storedByUlid()[clash]!.replaceFirst('Mark 2 hold', 'Mark 3 hold'));

      for (var i = 0; i < 3; i++) {
        await phone.engine.syncOnce();
      }
      expect(await stack.eventLogCanonical(ok), phone.storedByUlid()[ok]);
      expect(phone.transport.appendsOf(bad), 1, reason: 'counted: never sent again');
      expect(phone.transport.appendsOf(clash), 1, reason: 'counted: never sent again');

      // A lost answer, then the phone is revoked before it retries.
      final lost = phone.log(1).single;
      var dropped = false;
      phone.transport.hooks.add((r) async {
        if (dropped || !r.body.contains(lost)) return null;
        dropped = true;
        await phone.transport.forward(r);
        throw http.ClientException('the answer is lost (test)');
      });
      await phone.engine.syncOnce();
      expect(await stack.eventLogCanonical(lost), isNotNull, reason: 'control: it landed');
      await stack.revoke(admission);
      final after = phone.log(1).single;
      await phone.engine.syncOnce();
      await phone.engine.syncOnce();

      expect(phone.store.uploadStatus().refused, unorderedEquals([
        RefusedUpload(ulid: clash, reason: 'ulid_conflict', mayBeOnShore: false),
        RefusedUpload(ulid: bad, reason: 'inconsistent_canonical', mayBeOnShore: false),
        RefusedUpload(ulid: lost, reason: 'revoked', mayBeOnShore: true),
        RefusedUpload(ulid: after, reason: 'revoked', mayBeOnShore: false),
      ]));
      expect(phone.transport.appendsOf(after), 1);
      final kept = await stack.refusals(day.eventId);
      expect(kept.where((r) => r.startsWith('revoked ')), isNotEmpty, reason: 'the server kept them too (#48)');
    });

    test('criterion 12: with signal cut and restored, the upload starts on its own within 30 s',
        () async {
      final phone = await StackPhone.open(stack);
      addTearDown(phone.close);
      await phone.signInNamed();
      await phone.admitTo(day);
      phone.transport.offline = true;
      phone.engine.start();
      phone.log(1);
      phone.engine.nudge();
      await Future<void>.delayed(const Duration(seconds: 20));
      expect(phone.transport.appends, isEmpty, reason: 'control: the cut held');
      expect(phone.store.uploadStatus().lastRun?.state, UploadRunState.unreachable);

      final back = DateTime.now();
      phone.transport.offline = false;
      await phone.until(() => phone.store.uploadStatus().accepted == 1, const Duration(seconds: 40));
      final first = phone.transport.seen.firstWhere((s) => s.path.endsWith('/rpc/append_event') && s.status != null);
      expect(first.at.difference(back), lessThanOrEqualTo(const Duration(seconds: 30)));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('criterion 14 (a): a session that expired while the phone was off and offline recovers as the '
        'same user once signal returns, with nothing lost or duplicated', () async {
      var phone = await StackPhone.open(stack);
      final user = await phone.signInNamed();
      await phone.admitTo(day);
      final ulids = phone.log(3);
      final dir = phone.dir;
      await phone.engine.close();
      phone.transport.close();
      phone.expireKeptSession();

      // The core restarts with no signal.
      phone = await StackPhone.reopen(stack, dir, store: phone.store, offline: true);
      addTearDown(phone.close);
      phone.engine.start();
      await Future<void>.delayed(const Duration(seconds: 16)); // past gotrue's own retry window
      expect(phone.store.uploadStatus().lastRun?.state, UploadRunState.unreachable, reason: 'control');
      expect(phone.transport.seen.where((s) => s.path == '/auth/v1/signup'), isEmpty, reason: 'no new user');
      expect(File('$dir${Platform.pathSeparator}sync_session.json').existsSync(), isTrue);

      final back = DateTime.now();
      phone.transport.offline = false;
      await phone.until(() => phone.store.pendingUploads().isEmpty, const Duration(seconds: 40));
      final first = phone.transport.seen.firstWhere((s) => s.path.endsWith('/rpc/append_event') && s.status != null);
      expect(first.at.difference(back), lessThanOrEqualTo(const Duration(seconds: 30)));
      expect(phone.engine.userId, user);
      final rows = await shore(day.eventId);
      for (final u in ulids) {
        expect(rows[u]?['canonical'], phone.storedByUlid()[u], reason: u);
        expect(phone.transport.appendsOf(u), 1, reason: u);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('criterion 14 (a), the refresh: its answer lost twice after the server rotated the token '
        '(ADR 006 left this to #6), the phone stays signed in as the same user', () async {
      var phone = await StackPhone.open(stack);
      final user = await phone.signInNamed();
      await phone.admitTo(day);
      final u = phone.log(1).single;
      final dir = phone.dir;
      await phone.engine.close();
      phone.transport.close();
      final kept = phone.expireKeptSession();

      phone = await StackPhone.reopen(stack, dir, store: phone.store);
      addTearDown(phone.close);
      final answers = <String>[];
      phone.transport.hooks.add((r) async {
        if (!r.url.path.endsWith('/auth/v1/token') || answers.length >= 2) return null;
        final answer = await phone.transport.forward(r);
        final rotated = (jsonDecode(answer.body) as Map)['refresh_token'];
        answers.add('${answer.statusCode} rotated=${rotated != null && rotated != kept}');
        throw http.ClientException('the refresh answer is lost (test)');
      });
      final run = await phone.engine.syncOnce();
      // The measurement ADR 006 left to #6, printed on every run for the record.
      debugPrint('#6 lost refresh answers, as the server gave them: $answers; then: ${run.state}');
      expect(answers.first, '200 rotated=true', reason: 'control: the server rotated before the loss');
      expect(run.state, UploadRunState.done, reason: '$run');
      expect(phone.engine.userId, user);
      expect(await stack.eventLogCanonical(u), phone.storedByUlid()[u]);

      await phone.engine.clientForTests.auth.refreshSession();
      final v = phone.log(1).single;
      expect((await phone.engine.syncOnce()).accepted, 1, reason: 'and the next refresh and upload work');
      expect(await stack.eventLogCanonical(v), isNotNull);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('criterion 14 (b): a named volunteer who lost the session signs in again as the same '
        'account, and the waiting events upload', () async {
      final phone = await StackPhone.open(stack);
      addTearDown(phone.close);
      final user = await phone.signInNamed();
      await phone.admitTo(day);
      phone.log(1);
      await phone.engine.syncOnce();
      final waiting = phone.log(2);
      await phone.engine.clientForTests.auth.signOut(); // the session is gone, on the server too

      final paused = await phone.engine.syncOnce();
      expect(paused.state, UploadRunState.noSession);
      expect(phone.store.uploadStatus().refused, isEmpty, reason: 'nothing refused while signed out');

      expect(await phone.signInNamed(phone.email), user, reason: 'the same account');
      final run = await phone.engine.syncOnce();
      expect(run.accepted, 2);
      for (final u in waiting) {
        expect(await stack.eventLogCanonical(u), phone.storedByUlid()[u]);
      }
      expect((await stack.admissions(day.eventId)).where((a) => a['auth_uid'] == user), hasLength(1),
          reason: 'the account kept its admission');
    });

    test('criterion 14 (c): a device-handoff phone that lost its session signs in as a new user; '
        'nothing is sent until it is admitted again, and then everything waiting lands', () async {
      final phone = await StackPhone.open(stack);
      addTearDown(phone.close);
      final first = await phone.engine.signInAnonymously();
      final oldAdmission = await phone.admitTo(day, role: 'overall_pro');
      final waiting = phone.log(3);
      await phone.engine.clientForTests.auth.signOut();

      final second = await phone.engine.signInAnonymously();
      expect(second, isNot(first));
      final beforeAdmission = await phone.engine.syncOnce();
      expect(beforeAdmission.state, UploadRunState.notAdmitted);
      expect(phone.transport.appends, isEmpty, reason: 'counted: nothing goes out before the admission');
      expect(phone.store.uploadStatus().refused, isEmpty);

      // Admitted again with the day's code. The events keep the admission they were written under.
      await phone.engine.admit(day.eventId, day.codes['overall_pro']!);
      final run = await phone.engine.syncOnce();
      expect(run.accepted, 3, reason: '$run');
      for (final u in waiting) {
        final text = await stack.eventLogCanonical(u);
        expect(text, phone.storedByUlid()[u]);
        expect((jsonDecode(text!) as Map)['admission_id'], oldAdmission);
      }
      // Accepted today: append_event judges the caller, not the admission in the text. #73 will
      // judge the text, and would refuse these; that conflict is raised on #73.
    });
  }, skip: localStackRequested ? false : localStackSkip);
}

/// A transport over the real network that a test can cut, fault and read back.
class StackTransport extends http.BaseClient {
  final _inner = http.Client();
  bool offline = false;
  final hooks = <Future<http.Response?> Function(http.Request request)>[];
  final seen = <SeenRequest>[];

  Iterable<SeenRequest> get appends => seen.where((s) => s.path.endsWith('/rpc/append_event'));
  int appendsOf(String ulid) => appends.where((s) => s.body.contains('\\"ulid\\":\\"$ulid\\"')).length;

  /// Sends [request] on to the server and returns its answer, read in full.
  Future<http.Response> forward(http.Request request) async =>
      http.Response.fromStream(await _inner.send(_copy(request)));

  static http.Request _copy(http.Request r) => http.Request(r.method, r.url)
    ..headers.addAll(r.headers)
    ..bodyBytes = r.bodyBytes;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final copy = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = bytes;
    final auth = request.headers['Authorization'] ?? request.headers['authorization'];
    final record = SeenRequest(request.method, request.url.path, request.headers['apikey'],
        auth?.startsWith('Bearer ') == true ? auth!.substring(7) : null, utf8.decode(bytes), DateTime.now());
    seen.add(record);
    if (offline) throw http.ClientException('offline (cut by the test)', request.url);
    http.Response? response;
    for (final hook in [...hooks]) {
      response = await hook(copy);
      if (response != null) break;
    }
    response ??= await forward(copy);
    record
      ..status = response.statusCode
      ..answer = response.body;
    return http.StreamedResponse(Stream.value(response.bodyBytes), response.statusCode,
        request: request, headers: response.headers, contentLength: response.bodyBytes.length);
  }

  @override
  void close() => _inner.close();
}

class SeenRequest {
  SeenRequest(this.method, this.path, this.apikey, this.bearer, this.body, this.at);
  final String method;
  final String path;
  final String? apikey;
  final String? bearer;
  final String body;
  final DateTime at;
  int? status;
  String? answer;
}

/// A phone for the stack tests: its own log and session directory, and a sync engine over a
/// [StackTransport], signing in and admitting itself through the engine.
class StackPhone {
  StackPhone._(this._stack, this.dir, this.store, this.transport, this.engine);

  static Future<StackPhone> open(LocalStack stack, {int Function()? clock}) async {
    final dir = Directory.systemTemp.createTempSync('pc_sync_stack_').path;
    final store = EventStore.open('$dir${Platform.pathSeparator}core.db', clock: clock);
    return reopen(stack, dir, store: store);
  }

  /// A new engine on an existing phone's log and session, as the core restarting would make.
  static Future<StackPhone> reopen(LocalStack stack, String dir, {required EventStore store, bool offline = false}) async {
    final transport = StackTransport()..offline = offline;
    final engine = SyncEngine.open(
      url: stack.api.toString(),
      publishableKey: stack.publishableKey,
      store: store,
      sessionDir: dir,
      transport: transport,
      log: printOnFailure,
    );
    return StackPhone._(stack, dir, store, transport, engine);
  }

  final LocalStack _stack;
  final String dir;
  final EventStore store;
  final StackTransport transport;
  final SyncEngine engine;
  String? email;
  String? admission;

  /// Signs in by magic link as [asEmail], or as a new named volunteer.
  Future<String> signInNamed([String? asEmail]) async {
    email = asEmail ?? 'sync.${newUlid().toLowerCase()}@pro-companion.test';
    return engine.signInWithMagicLink(await _stack.magicLink(email!));
  }

  /// Admits the phone to [day] with [role]'s code, and stamps the admission on what it logs next.
  Future<String> admitTo(owner.Provisioned day, {String role = 'scorer'}) async {
    admission = await engine.admit(day.eventId, day.codes[role]!);
    store.setAdmissionId(admission!);
    return admission!;
  }

  List<String> log(int n) => [
        for (var i = 0; i < n; i++)
          store.append(NewEvent(kind: 'note', source: 'tap', payload: {'text': 'Mark 2 hold $i'})).ulid,
      ];

  /// Every event this phone wrote, as stored, by ULID.
  Map<String, String> storedByUlid() => {
        for (final t in store.readCanonical())
          if ((jsonDecode(t) as Map)['device_id'] == store.deviceId) (jsonDecode(t) as Map)['ulid'] as String: t,
      };

  /// This phone's events in the ADR 001 order: device time, device, sequence number.
  List<({int deviceTs, String deviceId, int seq, String ulid})> pendingUploadsIncludingSent() => [
        for (final e in store.readAll())
          if (e.deviceId == store.deviceId) (deviceTs: e.deviceTs, deviceId: e.deviceId, seq: e.seq, ulid: e.ulid),
      ];

  /// Rewrites the kept session so its access token expired ten minutes ago, keeping the real
  /// refresh token and user: a phone that slept through the token's hour. Built at run time, so
  /// no tracked file holds a token. Returns the refresh token kept.
  String expireKeptSession() {
    final file = File('$dir${Platform.pathSeparator}sync_session.json');
    final session = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final token = session['access_token'] as String;
    final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1])))) as Map;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    claims['iat'] = now - 4200;
    claims['exp'] = now - 600;
    final payload = base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');
    final parts = token.split('.');
    session['access_token'] = '${parts[0]}.$payload.${parts[2]}';
    session['expires_at'] = now - 600;
    file.writeAsStringSync(jsonEncode(session));
    return session['refresh_token'] as String;
  }

  Future<void> until(bool Function() done, Duration limit) async {
    final end = DateTime.now().add(limit);
    while (!done() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(done(), isTrue, reason: 'not within $limit');
  }

  Future<void> close() async {
    await engine.close();
    transport.close();
    try {
      store.close();
    } catch (_) {
      // Already closed.
    }
  }
}

extension on ({int deviceTs, String deviceId, int seq, String ulid}) {
  int compareTo(({int deviceTs, String deviceId, int seq, String ulid}) o) {
    final t = deviceTs.compareTo(o.deviceTs);
    if (t != 0) return t;
    final d = deviceId.compareTo(o.deviceId);
    return d != 0 ? d : seq.compareTo(o.seq);
  }
}

/// A clock that returns [times] in turn, then keeps returning the last one.
int Function() stepping(List<int> times) {
  var i = 0;
  return () => times[i < times.length ? i++ : times.length - 1];
}
