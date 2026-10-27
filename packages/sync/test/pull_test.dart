import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_sync/sync.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #64: the sync engine pulls the other committee phones' events down, against the scripted
/// server, which applies the pull's filter the way PostgREST does (support.dart's parseLogic). The
/// store's half is packages/core/test/pulls_test.dart, and the real server's is test/sync_test.dart.
void main() {
  const alice = '00000000-0000-4000-8000-00000000a11c';
  const bob = '00000000-0000-4000-8000-0000000000b0';

  /// Another committee phone on [day], with [n] notes on shore: their texts by sequence number
  /// from 1. [onShore] picks which of them the server holds.
  (TestPhone, List<String>) shorePhone(FakeServer server, int n, {String? day, bool Function(int seq)? onShore}) {
    final phone = TestPhone(admission: server.admitDirectly(alice, day ?? dayOne));
    phone.log(n);
    final texts = phone.store.readCanonical();
    for (var i = 0; i < texts.length; i++) {
      if (onShore == null || onShore(i + 1)) server.seedLog(day ?? dayOne, texts[i]);
    }
    return (phone, texts);
  }

  Set<String> held(TestPhone phone) => {...phone.store.readCanonical()};

  test('criterion 1, in the fake: another phone uploads, this one pulls, each event attributed to '
      'its device and admission and kept byte for byte', () async {
    final server = FakeServer();
    final (other, otherEngine, otherAdmission) = await admittedPhone(server, alice, dayOne);
    other.log(4);
    expect((await otherEngine.syncOnce()).remaining, 0, reason: 'control: they reached shore');

    final (phone, engine, _) = await admittedPhone(server, bob, dayOne);
    final run = await engine.syncOnce();
    expect(run.pull?.state, PullRunState.done, reason: '$run');
    expect(run.pull?.stored, 4);
    final theirs = [for (final e in phone.store.readAll()) if (e.deviceId == other.store.deviceId) e];
    expect(theirs, hasLength(4));
    expect({for (final e in theirs) e.admissionId}, {otherAdmission});
    expect(held(phone), containsAll(other.store.readCanonical()));
  });

  group('criterion 2: the cursor is per device, contiguous, and never a receipt time', () {
    test("a device's 7 on shore before its 6: both delivered, and nothing is read twice that "
        'need not be', () async {
      final server = FakeServer();
      final (other, texts) = shorePhone(server, 7, onShore: (seq) => seq != 6);
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne);

      await engine.syncOnce();
      expect(held(phone), containsAll([...texts.take(5), texts[6]]));
      expect(held(phone), isNot(contains(texts[5])));
      expect(phone.store.pullCursors(dayOne)[other.store.deviceId],
          const PullCursor(floor: 1, contiguous: 5, highest: 7, missing: [(6, 6)]));

      server.seedLog(dayOne, texts[5]);
      server.reads.clear();
      final run = await engine.syncOnce();
      expect(held(phone), containsAll(texts), reason: '6 arrived late, and was delivered');
      expect(run.pull?.stored, 1);
      expect(server.rowsRead('/rest/v1/event_log'), [1], reason: 'only what it did not hold: 6, and not 7 again');

      server.reads.clear();
      await engine.syncOnce();
      expect(server.rowsRead('/rest/v1/event_log'), [0], reason: 'caught up: nothing is sent again');
    });

    test("a device whose first events never reached shore is not read again from its start", () async {
      // Its role pick, before it was admitted, never uploads (#6, D3): a cursor counting from 1
      // would stall at 0 and send the whole day on every pull.
      final server = FakeServer();
      final (other, texts) = shorePhone(server, 6, onShore: (seq) => seq > 2);
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne);
      await engine.syncOnce();
      expect(phone.store.pullCursors(dayOne)[other.store.deviceId], const PullCursor(floor: 3, contiguous: 6));
      server.reads.clear();
      await engine.syncOnce();
      expect(server.rowsRead('/rest/v1/event_log'), [0]);
      expect(held(phone), containsAll(texts.skip(2)));
    });

    test('a lower number reaching shore after a higher one, below the floor, is still delivered',
        () async {
      final server = FakeServer();
      final (other, texts) = shorePhone(server, 4, onShore: (seq) => seq > 2);
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne);
      await engine.syncOnce();
      server.seedLog(dayOne, texts[1]);
      await engine.syncOnce();
      expect(held(phone), containsAll(texts.skip(1)));
      expect(phone.store.pullCursors(dayOne)[other.store.deviceId], const PullCursor(floor: 2, contiguous: 4));
    });
  });

  group("a hole that never fills (the review of #64)", () {
    test("numbers a device logged on another race day are not a reason to send its later ones again",
        () async {
      // It logs 1-3 here, 4-5 on another race day this phone is not admitted to, then 6-8 here.
      final server = FakeServer();
      final (other, texts) = shorePhone(server, 8, onShore: (seq) => seq < 4 || seq > 5);
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne);
      await engine.syncOnce();
      expect(phone.store.pullCursors(dayOne)[other.store.deviceId],
          const PullCursor(floor: 1, contiguous: 3, highest: 8, missing: [(4, 5)]));
      server.reads.clear();
      await engine.syncOnce();
      expect(server.rowsRead('/rest/v1/event_log'), [0], reason: 'nothing above the hole is sent again');
      expect(held(phone), containsAll([...texts.take(3), ...texts.skip(5)]));
    });

    test('past ${SyncEngine.maxMissingRanges} holes the request stays bounded, and a number reaching '
        'shore in a later hole is still delivered', () async {
      final server = FakeServer();
      // Every other number on shore: 1, 3, 5, ... 25, so 12 holes.
      final (other, texts) = shorePhone(server, 26, onShore: (seq) => seq.isOdd);
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne);
      await engine.syncOnce();
      expect(phone.store.pullCursors(dayOne)[other.store.deviceId]!.missing, hasLength(12));
      server.seedLog(dayOne, texts[23]); // 24, in the twelfth hole
      final run = await engine.syncOnce();
      expect(held(phone), contains(texts[23]));
      expect(run.pull?.stored, 1);
      final scope = server.reads.last.query['or']!;
      // 12 holes, and this device's own cursor names none: uncapped, the request would name 12.
      expect(RegExp(r'and\(seq\.gt\.').allMatches(scope).length, SyncEngine.maxMissingRanges,
          reason: 'the request names at most that many ranges per device');
    });
  });

  group('pages: every row is read once, wherever a page ends (the review of #64)', () {
    test('a page that ends inside one device goes on to the next device in the same run', () async {
      final server = FakeServer();
      final (_, first) = shorePhone(server, 4);
      final carol = TestPhone(admission: server.admitDirectly('00000000-0000-4000-8000-0000000000c0', dayOne));
      carol.log(4);
      final second = carol.store.readCanonical();
      for (final t in second) {
        server.seedLog(dayOne, t);
      }
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne, pullPageSize: 3);
      final run = await engine.syncOnce();
      expect(run.pull?.stored, 8, reason: 'one run reads both devices');
      expect(held(phone), containsAll([...first, ...second]));
      expect(server.rowsRead('/rest/v1/event_log'), [3, 3, 2]);
    });

    test('two log rows at one number, across a page boundary, are both read', () async {
      // A forked chain: a second event at a device's number 2, under another ULID. The store takes
      // the first and refuses the second, so the refusal is the proof that it was read.
      final server = FakeServer();
      final (other, texts) = shorePhone(server, 3);
      final two = jsonDecode(texts[1]) as Map;
      final ulids = [two['ulid'] as String, '01J8${'Z'.padLeft(22, 'Z')}']..sort();
      final fork = canonicalJson({...two, 'ulid': ulids.last == two['ulid'] ? ulids.first : ulids.last, 'payload': {'text': 'fork'}});
      server.seedLog(dayOne, fork);
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne, pullPageSize: 2);
      final run = await engine.syncOnce();
      expect(run.pull?.rejected, 1, reason: 'both rows at number 2 were read, one page each side of the boundary');
      expect(held(phone), containsAll([texts[0], texts[2]]));
      expect(phone.store.pullCursors(dayOne)[other.store.deviceId], const PullCursor(floor: 1, contiguous: 3));
    });

    test('two refusals at one number, across a page boundary, are both stored', () async {
      final server = FakeServer();
      final (other, _) = shorePhone(server, 1);
      final d = other.store.deviceId;
      server.refusals
        ..add((event: dayOne, device: d, seq: 2, hash: 'aa11', reason: 'inconsistent_canonical'))
        ..add((event: dayOne, device: d, seq: 2, hash: 'bb22', reason: 'ulid_conflict'))
        ..add((event: dayOne, device: d, seq: 3, hash: 'cc33', reason: 'revoked'));
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne, pullPageSize: 1);
      await engine.syncOnce();
      expect([for (final s in phone.store.refusalStubs(dayOne)) s.eventHash], ['aa11', 'bb22', 'cc33']);
    });
  });

  group('values the server sends back are text, never filter syntax', () {
    test("a ULID holding PostgREST's reserved characters, ending a full page, does not stop the pull",
        () async {
      // A value the server sends back is the uploading phone's text. As the last row of a full
      // page it is carried into the next page's filter, so it must be read there as text.
      final server = FakeServer();
      final (other, texts) = shorePhone(server, 3);
      final crafted = jsonDecode(texts[1]) as Map;
      server.log.remove(crafted['ulid']);
      server.seedLog(dayOne, canonicalJson({...crafted, 'ulid': r'01J8,(X).Y:Z"Q\R'}));
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne, pullPageSize: 2);
      final run = await engine.syncOnce();
      expect(run.pull?.state, PullRunState.done, reason: '$run');
      expect(run.pull?.rejected, 1, reason: 'the crafted row is read, and refused by the store');
      expect(held(phone), containsAll([texts[0], texts[2]]), reason: 'the page after it was read');
      expect(phone.store.pullCursors(dayOne)[other.store.deviceId],
          const PullCursor(floor: 1, contiguous: 1, highest: 3, missing: [(2, 2)]));
    });

    test('a device id that is not a ULID is never asked for, so it is never sent', () async {
      final server = FakeServer();
      final (_, texts) = shorePhone(server, 1);
      final crafted = jsonDecode(texts.single) as Map;
      server.seedLog(dayOne, canonicalJson({...crafted, 'ulid': '01J8${'Q'.padLeft(22, 'Q')}', 'device_id': 'a,b(c)'}));
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne);
      final run = await engine.syncOnce();
      expect(run.pull?.rejected, 0);
      expect(run.pull?.stored, 1);
      expect(server.rowsRead('/rest/v1/event_log'), [1], reason: 'only the real phone\'s event');
    });
  });

  test('a new event goes up before the rest of a pull (the review of #64)', () async {
    final server = FakeServer();
    shorePhone(server, 6);
    final (phone, engine, _) = await admittedPhone(server, bob, dayOne, pullPageSize: 2);
    var tapped = false;
    server.hooks.add((r) {
      if (r.path == '/rest/v1/event_log' && !tapped) {
        tapped = true;
        phone.log(1);
        unawaited(engine.syncOnce()); // the core's nudge while a run is active
      }
      return null;
    });
    await engine.syncOnce();
    final paths = [for (final r in server.requests) if (r.isAppend || r.path == '/rest/v1/event_log') r.path];
    expect(paths.take(2), ['/rest/v1/event_log', '/rest/v1/rpc/append_event'],
        reason: 'the tap went up after the page in flight, before the next one');
    expect(phone.store.uploadStatus().accepted, 1);
    expect(phone.store.readCanonical(), hasLength(7), reason: 'and the pull still read every row');
  });

  group('criterion 4: no duplicate is stored', () {
    test("this phone's own events are not asked for, and an echo of them stores nothing", () async {
      final server = FakeServer();
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne);
      phone.log(3);
      final run = await engine.syncOnce();
      expect(run.remaining, 0, reason: 'control: its own events are on shore');
      expect(run.pull?.stored, 0);
      expect(server.rowsRead('/rest/v1/event_log'), [0], reason: 'its own cursor covers all it wrote');

      // A server that answers with everything, the phone's own events included.
      server.hooks.add((r) {
        if (r.path != '/rest/v1/event_log') return null;
        return http.Response(
            jsonEncode([
              for (final MapEntry(key: ulid, value: row) in server.log.entries)
                {'ulid': ulid, 'device_id': (jsonDecode(row.canonical) as Map)['device_id'], 'seq': 1, 'canonical': row.canonical},
            ]),
            200,
            headers: {'content-type': 'application/json'});
      });
      final echoed = await engine.syncOnce();
      expect(echoed.pull?.state, PullRunState.done);
      expect(echoed.pull?.stored, 0);
      expect(phone.store.count(), 3);
    });
  });

  group('criterion 5: a pull cut off mid-page resumes from the cursor', () {
    for (final (name, lostAfterCommit) in [('before the server answers', false), ('with its answer lost', true)]) {
      test('the second page lost $name: no gap and no duplicate', () async {
        final server = FakeServer();
        final (_, texts) = shorePhone(server, 10);
        final (phone, engine, _) = await admittedPhone(server, bob, dayOne, pullPageSize: 3);
        var pages = 0;
        server.firstHooks.add((r) {
          if (r.path != '/rest/v1/event_log' || ++pages != 2) return null;
          if (lostAfterCommit) server.answer(r);
          throw http.ClientException('the link dropped mid-pull (test)');
        });

        final cut = await engine.syncOnce();
        expect(cut.pull?.state, PullRunState.unreachable, reason: '$cut');
        expect(cut.pull?.stored, 3, reason: 'the first page was kept');
        expect(phone.store.count(), 3);
        expect(phone.store.pullStatus().lastPulledAt, isNull, reason: 'it did not read everything');

        server.reads.clear();
        final resumed = await engine.syncOnce();
        expect(resumed.pull?.state, PullRunState.done);
        expect(resumed.pull?.stored, 7);
        expect(server.rowsRead('/rest/v1/event_log'), [3, 3, 1], reason: 'from the cursor: rows 4 to 10, in pages');
        expect(phone.store.readCanonical(), texts, reason: 'every one, once');
      });
    }
  });

  group("criterion 6: pulled events never enter this phone's own chain", () {
    test('an event on shore naming this phone, which it never wrote, is refused, and its next tap '
        'still takes its own next number', () async {
      final server = FakeServer();
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne);
      phone.log(1);
      await engine.syncOnce();
      final mine = jsonDecode(phone.store.readCanonical().single) as Map;
      final forged = canonicalJson({
        ...mine,
        'ulid': '01J8${'7'.padLeft(22, '0')}',
        'seq': 2,
        'payload': {'text': 'not mine'},
      });
      server.seedLog(dayOne, forged);

      final run = await engine.syncOnce();
      expect(run.pull?.rejected, 1);
      expect(phone.store.count(), 1);
      final next = phone.store.append(const NewEvent(kind: 'note', source: 'tap'));
      expect(next.seq, 2);
      expect(verifyChains(phone.store.readCanonical())[phone.store.deviceId]?.state, ChainState.intact);
    });
  });

  group('criterion 7: refusal stubs ride the same pull', () {
    test('each stub is stored against its device and number, and lets the cursor past it', () async {
      final server = FakeServer();
      final (other, texts) = shorePhone(server, 5, onShore: (seq) => seq != 3);
      server.refusals.add((event: dayOne, device: other.store.deviceId, seq: 3, hash: 'ab12', reason: 'ulid_conflict'));
      // One refused as unreadable names no device or number: never asked for, never stored.
      server.refusals.add((event: dayOne, device: null, seq: null, hash: 'cd34', reason: 'inconsistent_canonical'));
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne);

      final run = await engine.syncOnce();
      expect(run.pull?.state, PullRunState.done);
      expect(phone.store.refusalStubs(dayOne), [
        RefusalStub(eventId: dayOne, deviceId: other.store.deviceId, seq: 3, eventHash: 'ab12', reason: 'ulid_conflict'),
      ]);
      expect(phone.store.pullCursors(dayOne)[other.store.deviceId], const PullCursor(floor: 1, contiguous: 5));
      expect(held(phone), containsAll([...texts.take(2), ...texts.skip(3)]));

      server.reads.clear();
      await engine.syncOnce();
      expect(server.rowsRead('/rest/v1/event_refusal'), [0]);
      expect(server.rowsRead('/rest/v1/event_log'), [0], reason: 'not stalled at the refused 3');
    });

    test("another phone's refusal through append_event reaches this one as a stub", () async {
      final server = FakeServer();
      final (other, otherEngine, otherAdmission) = await admittedPhone(server, alice, dayOne);
      other.log(1);
      await otherEngine.syncOnce();
      server.revoked.add(otherAdmission);
      other.log(1);
      await otherEngine.syncOnce();
      expect(other.store.uploadStatus().refused.single.reason, 'revoked', reason: 'control');

      final (phone, engine, _) = await admittedPhone(server, bob, dayOne);
      await engine.syncOnce();
      expect(phone.store.refusalStubs(dayOne).single.seq, 2);
      expect(phone.store.refusalStubs(dayOne).single.reason, 'revoked');
    });
  });

  group('criterion 8: with no signal the phone keeps working, and the last pull is kept', () {
    test('offline, its own log is unaffected and the last successful pull stays where it was', () async {
      final server = FakeServer();
      shorePhone(server, 2);
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne);
      final first = await engine.syncOnce();
      final pulledAt = phone.store.pullStatus().lastPulledAt;
      expect(pulledAt, first.pull?.at);

      server.offline = true;
      phone.log(2);
      final offline = await engine.syncOnce();
      expect(offline.state, UploadRunState.unreachable);
      expect(offline.pull, isNull, reason: 'no pull is tried where the upload found no signal');
      expect(phone.store.pullStatus().lastPulledAt, pulledAt);
      // The two are appended in one millisecond, and since #145 read back in the order logged.
      expect([for (final e in phone.store.readOwn()) e.seq], [1, 2], reason: 'its own log went on');

      server.offline = false;
      final back = await engine.syncOnce();
      expect(back.pull?.state, PullRunState.done);
      expect(phone.store.pullStatus().lastPulledAt, back.pull?.at);
    });

    test('a pull that fails on its own is recorded as such, and moves nothing', () async {
      final server = FakeServer();
      shorePhone(server, 2);
      final (phone, engine, _) = await admittedPhone(server, bob, dayOne);
      server.hooks.add((r) => r.path == '/rest/v1/event_log' ? postgrestError(503, '503', 'gateway') : null);
      final run = await engine.syncOnce();
      expect(run.pull?.state, PullRunState.unreachable);
      expect(phone.store.pullStatus(), PullStatus(lastRun: run.pull));
    });
  });

  group('criterion 10: a revoked phone is refused, and nothing stored is deleted', () {
    test('revoked after a pull: no read of the log, and every event it held is still there', () async {
      final server = FakeServer();
      shorePhone(server, 3);
      final (phone, engine, admission) = await admittedPhone(server, bob, dayOne);
      await engine.syncOnce();
      final before = phone.store.readCanonical();
      expect(before, hasLength(3));

      server.revoked.add(admission);
      server.reads.clear();
      final run = await engine.syncOnce();
      expect(run.pull?.state, PullRunState.revoked);
      expect(run.pull?.revoked, 1);
      expect(server.rowsRead('/rest/v1/event_log'), isEmpty, reason: 'not read at all');
      expect(phone.store.readCanonical(), before);
      expect(phone.store.pullStatus().lastRun?.state, PullRunState.revoked);
    });

    test('revoked on one race day and admitted on another: the other is read', () async {
      final server = FakeServer();
      final (_, dayTwoTexts) = shorePhone(server, 2, day: dayTwo);
      final (phone, engine, admission) = await admittedPhone(server, bob, dayOne);
      server.admitDirectly(bob, dayTwo);
      server.revoked.add(admission);
      final run = await engine.syncOnce();
      expect(run.pull?.state, PullRunState.done);
      expect(run.pull?.revoked, 1);
      expect(held(phone), containsAll(dayTwoTexts));
    });

    test('a phone admitted nowhere has nothing to read', () async {
      final server = FakeServer();
      final phone = TestPhone();
      phone.keepSession(server.session(bob));
      final engine = phone.engine(server);
      addTearDown(engine.close);
      final run = await engine.syncOnce();
      expect(run.pull?.state, PullRunState.notAdmitted);
    });
  });

  test('cadence: with nothing to upload, a started phone pulls every 15 s (owner decision on #64)', () {
    fakeAsync((async) {
      final server = FakeServer();
      final (_, texts) = shorePhone(server, 1);
      final phone = TestPhone(admission: server.admitDirectly(bob, dayOne));
      phone.keepSession(server.session(bob));
      final engine = phone.engine(server);
      engine.start();
      async.elapse(const Duration(seconds: 61));
      final pulls = [for (final r in server.requests) if (r.path == '/rest/v1/event_log') r.at];
      expect(pulls.length, inInclusiveRange(4, 5));
      for (var i = 1; i < pulls.length; i++) {
        expect(pulls[i].difference(pulls[i - 1]), const Duration(seconds: 15));
      }

      final other = jsonDecode(texts.single) as Map;
      final later = canonicalJson({...other, 'ulid': '01J8${'9'.padLeft(22, '0')}', 'seq': 2, 'prev_hash': chainHash(texts.single)});
      server.seedLog(dayOne, later);
      async.elapse(const Duration(seconds: 16));
      expect(phone.store.readCanonical(), contains(later), reason: 'within one interval of reaching shore');
      unawaited(engine.close());
      async.elapse(const Duration(seconds: 30));
    });
  });
}
