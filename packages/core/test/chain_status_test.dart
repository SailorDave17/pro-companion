import 'dart:convert';

import 'package:pro_companion_core/core.dart' show RoleEvents, Roles, StandardMarks, StationEvents, isWireSafe;
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #67, the core's half: refusal stubs standing in as links (criterion 3), and the status of each
/// other phone's log the view shows (criteria 1 to 5), worked out from what the store holds. The
/// screen's half is test/log_screen_test.dart.
const dayOne = 'b3c7e9a1-2d4f-4b6a-8c0e-1f2a3b4c5d6e';
const dayTwo = 'c4d8f0b2-3e5a-4c7b-9d1f-2a3b4c5d6e7f';

/// Another committee phone: a log of its own with [n] notes, its id, and the texts as it stored
/// them, by sequence number from 1 (index i is seq i + 1).
(String, List<String>) otherPhone(int n, {int seed = 2}) {
  var t = 1000000;
  final phone = openStore(tempDbPath(), seed: seed, clock: () => t += 1000);
  for (var i = 0; i < n; i++) {
    phone.append(NewEvent(kind: 'note', source: 'tap', payload: {'text': 'Mark 2 hold $i'}));
  }
  return (phone.deviceId, phone.readCanonical());
}

Map wireOf(String text) => jsonDecode(text) as Map;
int tsOf(String text) => wireOf(text)['device_ts'] as int;
String ulidOf(String text) => wireOf(text)['ulid'] as String;

/// [text] with one payload byte changed and nothing else: its hash moves, and so the link from the
/// event after it stops holding.
String altered(String text) {
  final w = Map<String, Object?>.from(wireOf(text));
  w['payload'] = {'text': 'Mark 3 hold'};
  return canonicalJson(w);
}

ChainRefusal stub(String device, int seq, String hash, {String reason = 'revoked'}) =>
    ChainRefusal(deviceId: device, seq: seq, hash: hash, reason: reason);

void main() {
  group('criterion 3: a refusal stands in for the event it refused, by its hash', () {
    test('with the stub, the event after it is checked against its hash and the chain holds', () {
      final (device, texts) = otherPhone(8);
      final held = [...texts]..removeAt(4); // seq 5 was refused, so it never reached the log
      expect(verifyChain(held).state, ChainState.gapped, reason: 'without the stub, 5 is a hole');
      expect(verifyChain(held, refusals: [stub(device, 5, chainHash(texts[4]))]), const ChainVerdict.intact());
    });

    test("a stub whose hash is not the refused event's breaks the chain at the event after it", () {
      final (device, texts) = otherPhone(8);
      final held = [...texts]..removeAt(4);
      expect(
        verifyChain(held, refusals: [stub(device, 5, chainHash(altered(texts[4])))]),
        ChainVerdict.broken(atSeq: 6, atUlid: ulidOf(texts[5]), afterSeq: 5, reason: ''),
        reason: 'only its number, not its hash, would let 6 through',
      );
    });

    test('a stub restating an event held at its number is that event, read once', () {
      // This phone's own refused events: it holds the text, and the pull brings the stub back.
      final (device, texts) = otherPhone(4);
      expect(verifyChain(texts, refusals: [stub(device, 3, chainHash(texts[2]))]), const ChainVerdict.intact());
    });

    test('a stub holding another text at a held number is a fork, named by the held event', () {
      final (device, texts) = otherPhone(4);
      expect(
        verifyChain(texts, refusals: [stub(device, 3, chainHash(altered(texts[2])))]),
        ChainVerdict.broken(atSeq: 3, atUlid: ulidOf(texts[2]), reason: ''),
      );
    });

    test('two stubs holding two texts at one number are a fork, with no text to name it by', () {
      final (device, texts) = otherPhone(5);
      final held = [...texts]..removeAt(2);
      final verdict = verifyChain(held, refusals: [
        stub(device, 3, chainHash(texts[2])),
        stub(device, 3, chainHash(altered(texts[2]))),
      ]);
      expect(verdict.state, ChainState.broken);
      expect([verdict.atSeq, verdict.atUlid], [3, null]);
    });

    test('one refusal pulled from two race days is read once', () {
      final (device, texts) = otherPhone(5);
      final held = [...texts]..removeAt(2);
      final hash = chainHash(texts[2]);
      expect(verifyChain(held, refusals: [stub(device, 3, hash), stub(device, 3, hash)]), const ChainVerdict.intact());
    });

    test("an event linking straight to a stub across missing numbers was re-linked: broken", () {
      final (device, texts) = otherPhone(5);
      final w = Map<String, Object?>.from(wireOf(texts[4]))..['prev_hash'] = chainHash(texts[2]);
      final relinked = canonicalJson(w);
      expect(
        verifyChain([texts[0], texts[1], relinked], refusals: [stub(device, 3, chainHash(texts[2]))]),
        ChainVerdict.broken(atSeq: 5, atUlid: ulidOf(texts[4]), afterSeq: 3, reason: ''),
      );
    });

    test('verifyChains reads each device with its own stubs, and a device held only as stubs', () {
      final (a, aTexts) = otherPhone(3, seed: 2);
      final (b, _) = otherPhone(2, seed: 3);
      final verdicts = verifyChains([aTexts[0], aTexts[2]], refusals: [
        stub(a, 2, chainHash(aTexts[1])),
        stub(b, 2, 'f' * 64),
      ]);
      expect(verdicts[a], const ChainVerdict.intact());
      expect(verdicts[b], const ChainVerdict.gapped(), reason: 'seq 1 is missing, and a stub has no link to check');
    });

    test('a stub after missing numbers fills its own number only: the chain is still gapped', () {
      // 1 and 2 held, 3 missing, 4 refused, 5 held: 5's link to the stub holds, and 3 is still a hole.
      // The mutation round found nothing asserting this (C5, predicted 0, got 0).
      final (device, texts) = otherPhone(5);
      expect(
        verifyChain([texts[0], texts[1], texts[4]], refusals: [stub(device, 4, chainHash(texts[3]))]),
        const ChainVerdict.gapped(),
      );
    });
  });

  group("the status of another phone's log, from what the store holds", () {
    late EventStore store;

    setUp(() => store = openStore(tempDbPath()));

    void pull(String day, Iterable<String> texts) {
      for (final t in texts) {
        expect(store.insertPulled(day, t), isTrue);
      }
    }

    DeviceChain only() => store.chainStatus().devices.single;

    test('criterion 1: an interior gap reads as catching up, with the count missing and the last verified event',
        () {
      final (device, texts) = otherPhone(9);
      pull(dayOne, [texts[1], texts[2], texts[3], texts[6], texts[7], texts[8]]); // 2-4 and 7-9
      final d = only();
      expect(d.deviceId, device);
      expect(d.state, DeviceChainStates.catchingUp);
      expect([d.first, d.last, d.missing], [2, 9, 2]);
      expect(d.lastVerified, ChainPoint(seq: 4, ulid: ulidOf(texts[3]), deviceTs: tsOf(texts[3])));
    });

    test('criterion 4: once a pull fills the gap, it reads as verified', () {
      final (_, texts) = otherPhone(9);
      pull(dayOne, [texts[1], texts[2], texts[3], texts[6], texts[7], texts[8]]);
      expect(only().state, DeviceChainStates.catchingUp);
      pull(dayOne, [texts[4], texts[5]]);
      final d = only();
      expect(d.state, DeviceChainStates.verified);
      expect([d.first, d.last, d.missing], [2, 9, 0]);
      expect(d.lastVerified?.seq, 9);
    });

    test("the numbers below the lowest held are not missing: a phone's first events never reach shore", () {
      final (_, texts) = otherPhone(6);
      pull(dayOne, texts.sublist(2)); // 3-6, as though 1 and 2 were logged before admission
      final d = only();
      expect(d.state, DeviceChainStates.verified);
      expect([d.first, d.missing], [3, 0]);
    });

    test('criterion 2: a broken chain reads as altered, naming the first bad event and its time', () {
      final (_, texts) = otherPhone(6);
      pull(dayOne, [texts[0], texts[1], altered(texts[2]), texts[3], texts[4], texts[5]]);
      final d = only();
      expect(d.state, DeviceChainStates.altered);
      expect(d.breakAt?.at, ChainPoint(seq: 4, ulid: ulidOf(texts[3]), deviceTs: tsOf(texts[3])));
      expect(d.breakAt?.afterSeq, 3, reason: 'the event before the break may be the one changed');
      expect(d.lastVerified, isNull);
    });

    test('altered comes first, whatever else applies', () {
      final (device, texts) = otherPhone(9);
      pull(dayOne, [texts[0], altered(texts[1]), texts[2], texts[6], texts[7]]); // a gap too
      store.insertRefusalStub(RefusalStub(
          eventId: dayOne, deviceId: device, seq: 9, eventHash: chainHash(texts[8]), reason: 'revoked'));
      expect(only().state, DeviceChainStates.altered);
    });

    test("criterion 3: a refusal stub reads as refused at N with its reason, and verification continues past N",
        () {
      final (device, texts) = otherPhone(8);
      pull(dayOne, [...texts]..removeAt(4));
      store.insertRefusalStub(RefusalStub(
          eventId: dayOne, deviceId: device, seq: 5, eventHash: chainHash(texts[4]), reason: 'revoked'));
      final d = only();
      expect(d.state, DeviceChainStates.refused);
      expect(d.refusals, [stub(device, 5, chainHash(texts[4]))]);
      expect([d.missing, d.lastVerified?.seq], [0, 8], reason: 'past N, to the end');
    });

    test("criterion 3: a stub that is not the refused event's own hash reads as altered, not refused", () {
      final (device, texts) = otherPhone(8);
      pull(dayOne, [...texts]..removeAt(4));
      store.insertRefusalStub(RefusalStub(
          eventId: dayOne, deviceId: device, seq: 5, eventHash: chainHash(altered(texts[4])), reason: 'revoked'));
      final d = only();
      expect(d.state, DeviceChainStates.altered);
      expect(d.breakAt?.at.seq, 6);
    });

    test('refused and catching up at once reads as catching up, the refusal still listed', () {
      final (device, texts) = otherPhone(9);
      pull(dayOne, [texts[0], texts[1], texts[2], texts[3], texts[5], texts[7], texts[8]]); // 5 refused, 7 missing
      store.insertRefusalStub(RefusalStub(
          eventId: dayOne, deviceId: device, seq: 5, eventHash: chainHash(texts[4]), reason: 'not_admitted'));
      final d = only();
      expect(d.state, DeviceChainStates.catchingUp);
      expect([d.missing, d.lastVerified?.seq], [1, 6]);
      expect([for (final r in d.refusals) (r.seq, r.reason)], [(5, 'not_admitted')]);
    });

    test('a refused event at the end of the run is the last verified, by its number alone', () {
      final (device, texts) = otherPhone(8);
      pull(dayOne, [texts[0], texts[1], texts[2], texts[6], texts[7]]);
      store.insertRefusalStub(RefusalStub(
          eventId: dayOne, deviceId: device, seq: 4, eventHash: chainHash(texts[3]), reason: 'revoked'));
      expect(only().lastVerified, const ChainPoint(seq: 4));
    });

    test('each race day is its own row, so a stint on a race day not pulled is no hole', () {
      final (device, texts) = otherPhone(9);
      pull(dayOne, texts.sublist(0, 4)); // 1-4
      pull(dayTwo, texts.sublist(6)); // 7-9; 5 and 6 were logged on a race day this phone cannot read
      store.recordRaceDayName(dayOne, 'Saturday series');
      final rows = store.chainStatus().devices;
      expect([for (final d in rows) (d.eventId, d.deviceId, d.state, d.first, d.last)], [
        (dayTwo, device, DeviceChainStates.verified, 7, 9),
        (dayOne, device, DeviceChainStates.verified, 1, 4),
      ], reason: 'the race day with the newest event first');
      expect([for (final d in rows) d.raceDayName], [null, 'Saturday series']);
    });

    test('a device known only from a stub has a row', () {
      store.insertRefusalStub(RefusalStub(
          eventId: dayOne, deviceId: '01J9${'1'.padLeft(22, '0')}', seq: 3, eventHash: 'a' * 64, reason: 'revoked'));
      final d = only();
      expect([d.state, d.first, d.last, d.role, d.lastVerified], [DeviceChainStates.refused, 3, 3, null, const ChainPoint(seq: 3)]);
    });

    test('a row names its phone by the role and station its latest event carries', () {
      var t = 1000000;
      final mark = openStore(tempDbPath(), seed: 5, clock: () => t += 1000);
      mark.append(RoleEvents.assign(Roles.markBoat));
      mark.append(StationEvents.select(StandardMarks.windward));
      mark.append(const NewEvent(kind: 'note', source: 'tap'));
      pull(dayOne, mark.readCanonical());
      final d = only();
      expect([d.role, d.mark], [Roles.markBoat, StandardMarks.windward]);
    });

    test("this phone's own events are never a row, and its own chain stands", () {
      store.append(const NewEvent(kind: 'note', source: 'tap'));
      store.append(const NewEvent(kind: 'note', source: 'tap'));
      expect(store.chainStatus(), ChainStatus.empty);
    });
  });

  group("criterion 5: this phone's own chain", () {
    test('altered in the file, it reads as broken at the first bad event, with its time', () {
      final store = openStore(tempDbPath());
      for (var i = 0; i < 4; i++) {
        store.append(NewEvent(kind: 'note', source: 'tap', payload: {'n': i}));
      }
      final texts = store.readCanonical();
      // What the core never does: the triggers that refuse it are dropped first.
      store.debugDatabase
        ..execute('DROP TRIGGER events_no_update')
        ..execute('UPDATE events SET body = ? WHERE seq = 2', [altered(texts[1])]);
      expect(
        store.chainStatus().ownBreak,
        ChainBreak(at: ChainPoint(seq: 3, ulid: ulidOf(texts[2]), deviceTs: tsOf(texts[2])), afterSeq: 2, reason:
            "its previous hash is not seq 2's: one of the two was altered"),
      );
    });

    test("a stub of another text at one of its numbers is a fork in its own chain", () {
      final store = openStore(tempDbPath());
      for (var i = 0; i < 3; i++) {
        store.append(NewEvent(kind: 'note', source: 'tap', payload: {'n': i}));
      }
      final texts = store.readCanonical();
      store.insertRefusalStub(RefusalStub(
          eventId: dayOne, deviceId: store.deviceId, seq: 2, eventHash: chainHash(altered(texts[1])), reason: 'ulid_conflict'));
      expect(store.chainStatus().ownBreak?.at, ChainPoint(seq: 2, ulid: ulidOf(texts[1]), deviceTs: tsOf(texts[1])));
    });

    test('its own refused events, stubbed back by the pull, leave it standing', () {
      final store = openStore(tempDbPath());
      for (var i = 0; i < 3; i++) {
        store.append(NewEvent(kind: 'note', source: 'tap', payload: {'n': i}));
      }
      store.insertRefusalStub(RefusalStub(
          eventId: dayOne, deviceId: store.deviceId, seq: 2, eventHash: chainHash(store.readCanonical()[1]), reason: 'revoked'));
      expect(store.chainStatus().ownBreak, isNull);
      // Nor is this phone a row of its own, from its stubs (C12, predicted 0, got 0).
      expect(store.chainStatus().devices, isEmpty);
    });
  });

  group('through the core interface', () {
    test('chainStatus crosses the isolate boundary as plain data', () async {
      final core = await spawnCore(tempDbPath());
      addTearDown(core.close);
      await core.append(const NewEvent(kind: 'note', source: 'tap'));
      expect(await core.chainStatus(), ChainStatus.empty);
    });

    test('every field survives the wire form', () {
      final status = ChainStatus(
        ownBreak: const ChainBreak(at: ChainPoint(seq: 3, ulid: 'U', deviceTs: 9), afterSeq: 2, reason: 'r'),
        devices: [
          DeviceChain(
            eventId: dayOne,
            raceDayName: 'Saturday',
            deviceId: 'D',
            role: Roles.markBoat,
            mark: StandardMarks.leeward,
            state: DeviceChainStates.catchingUp,
            first: 2,
            last: 9,
            missing: 3,
            lastVerified: const ChainPoint(seq: 4, ulid: 'V', deviceTs: 7),
            refusals: [stub('D', 5, 'h', reason: 'not_admitted')],
          ),
          const DeviceChain(
            eventId: dayTwo,
            deviceId: 'E',
            state: DeviceChainStates.altered,
            first: 1,
            last: 3,
            breakAt: ChainBreak(at: ChainPoint(seq: 3), reason: 'fork'),
          ),
        ],
      );
      final wire = status.toWire();
      expect(isWireSafe(wire), isTrue);
      expect(ChainStatus.fromWire(wire), status);
    });

    test('the fake core answers what a test sets, through the wire form', () async {
      const status = ChainStatus(ownBreak: ChainBreak(at: ChainPoint(seq: 1), reason: 'r'));
      final fake = FakeCore()..chainStatusValue = status;
      expect(await fake.chainStatus(), status);
      expect(fake.calls['chainStatus'], 1);
    });
  });
}
