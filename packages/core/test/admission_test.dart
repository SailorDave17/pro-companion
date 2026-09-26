import 'dart:convert';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #49: every event carries the admission its phone held when it wrote it,
/// stamped by the core inside the canonical text (groom decision G44).
void main() {
  const admission = '3f6c1a52-8d0e-4b7a-9c21-5e4f0a9b7d13';
  const readmission = '9b0d7e21-44c6-4e1f-8a35-c7f2d6190e48';

  // What #28's core stored for [pre49Event] as a device's first event, captured from develop at
  // 9936b44 before #49 changed the envelope, so it is an answer from outside the code under test.
  // Its device id and ULID came from a seeded Random, whose sequence the SDK may change, so the
  // tests put the store's own in their place.
  const pre49Text = '{"corrects_ulid":"01J8Z0E0000000000000000002","device_id":"01J8J8QRC05WWNWNVRK0MK8A65",'
      '"device_ts":1727190001000,"gps":{"accuracy_m":5,"lat":33.4012,"lon":-86.8123},"kind":"finish",'
      '"payload":{"dist_nm":1.5,"fleet":"01J8Z0E0000000000000000001","sail":"12345"},"payload_version":2,'
      '"person":"Dana (fixture)","prev_hash":"0000000000000000000000000000000000000000000000000000000000000000",'
      '"role":"recorder","seq":1,"source":"tap","ulid":"01J8J8QSB81SHAZ7H9RVRYGT1Z"}';
  const pre49DeviceId = '01J8J8QRC05WWNWNVRK0MK8A65';
  const pre49Ulid = '01J8J8QSB81SHAZ7H9RVRYGT1Z';
  const pre49Event = NewEvent(
    kind: 'finish',
    source: 'tap',
    payload: {'fleet': '01J8Z0E0000000000000000001', 'sail': '12345', 'dist_nm': 1.5},
    payloadVersion: 2,
    person: 'Dana (fixture)',
    role: 'recorder',
    gps: GpsFix(lat: 33.4012, lon: -86.8123, accuracyM: 5.0),
    correctsUlid: '01J8Z0E0000000000000000002',
  );

  String pre49For(String deviceId, String ulid) {
    expect(pre49Text, allOf(contains(pre49DeviceId), contains(pre49Ulid)), reason: 'the ids to replace are there');
    return pre49Text.replaceFirst(pre49DeviceId, deviceId).replaceFirst(pre49Ulid, ulid);
  }

  Future<CoreClient> spawnedCore() async {
    final core = await spawnCore(tempDbPath());
    addTearDown(() async {
      try {
        await core.close();
      } on Object {
        // Closed by the test.
      }
    });
    return core;
  }

  List<Object?> admissionsIn(List<String> texts) => [for (final t in texts) (jsonDecode(t) as Map)['admission_id']];

  group('criterion 1: an admitted phone stamps every event it appends', () {
    test('with its admission, in the envelope and in the canonical text as stored', () {
      final store = openStore(tempDbPath());
      store.setAdmissionId(admission);
      final fleet = store.append(const NewEvent(kind: 'fleet.defined', source: 'tap', payload: {'name': 'Lasers'}));
      final appended = [
        fleet,
        store.append(NewEvent(kind: 'start', source: 'race-timer', payload: {'fleet': fleet.ulid}, role: 'overall_pro')),
        store.append(const NewEvent(kind: 'finish', source: 'tap', gps: GpsFix(lat: 33.4, lon: -86.8))),
        store.append(NewEvent(kind: 'start.undo', source: 'manual', correctsUlid: fleet.ulid)),
      ];

      expect([for (final e in appended) e.admissionId], everyElement(admission));
      expect([for (final e in store.readAll()) e.admissionId], everyElement(admission));
      expect(admissionsIn(store.readCanonical()), everyElement(admission));
    });

    test('and the hash covers it: an admission changed after the fact breaks the chain at the next event', () {
      final store = openStore(tempDbPath());
      store.setAdmissionId(admission);
      for (var i = 0; i < 3; i++) {
        store.append(NewEvent(kind: 'note', source: 'tap', payload: {'n': i}));
      }
      final texts = store.readCanonical();
      expect(verifyChain(texts), const ChainVerdict.intact());

      final altered = texts[1].replaceFirst('"admission_id":"$admission"', '"admission_id":"$readmission"');
      expect(altered, isNot(texts[1]), reason: 'the admission to alter is there');
      final verdict = verifyChain([texts[0], altered, texts[2]]);
      expect([verdict.state, verdict.atSeq, verdict.afterSeq], [ChainState.broken, 3, 2]);
    });

    test('a restart keeps the admission', () {
      final path = tempDbPath();
      final first = EventStore.open(path);
      first.setAdmissionId(admission);
      first.close();

      final again = openStore(path);
      expect(again.admissionId, admission);
      expect(again.append(const NewEvent(kind: 'note', source: 'tap')).admissionId, admission);
    });

    test("an event from another phone keeps that phone's admission: only this phone's appends are stamped", () {
      final other = openStore(tempDbPath(), seed: 2);
      other.setAdmissionId(readmission);
      final theirs = other.append(const NewEvent(kind: 'finish', source: 'tap'));
      final unadmitted = openStore(tempDbPath(), seed: 3);
      final neverAdmitted = unadmitted.append(const NewEvent(kind: 'finish', source: 'tap'));

      final store = openStore(tempDbPath());
      store.setAdmissionId(admission);
      store.insert(theirs);
      store.insert(neverAdmitted);
      final byDevice = {for (final e in store.readAll()) e.deviceId: e.admissionId};
      expect(byDevice, {other.deviceId: readmission, unadmitted.deviceId: null});
    });

    test('over the core interface, as the UI reaches it', () async {
      final core = await spawnedCore();
      expect(await core.admissionId(), isNull);
      await core.setAdmissionId(admission);
      expect(await core.admissionId(), admission);

      final e = await core.append(const NewEvent(kind: 'note', source: 'tap'));
      expect(e.admissionId, admission);
      expect((await core.readAll()).single.toWire()['admission_id'], admission);
    });

    test('and the fake core stamps the same way, so widget tests see what the real core writes', () async {
      final fake = FakeCore();
      expect(await fake.admissionId(), isNull);
      await fake.setAdmissionId(admission);
      expect(await fake.admissionId(), admission);
      expect((await fake.append(const NewEvent(kind: 'note', source: 'tap'))).admissionId, admission);
    });
  });

  group('criterion 2: a phone never admitted', () {
    test('appends events whose admission id is null, and says so in the text rather than leaving it out', () async {
      final store = openStore(tempDbPath());
      final e = store.append(const NewEvent(kind: 'note', source: 'tap'));
      expect(store.admissionId, isNull);
      expect(e.admissionId, isNull);
      expect(e.toWire(), containsPair('admission_id', isNull));
      expect(store.readCanonical().single, contains('"admission_id":null'));

      final core = await spawnedCore();
      expect((await core.append(const NewEvent(kind: 'note', source: 'tap'))).admissionId, isNull);
      expect(await core.admissionId(), isNull);
      final fake = FakeCore();
      expect((await fake.append(const NewEvent(kind: 'note', source: 'tap'))).admissionId, isNull);
    });

    test("and nothing else in the envelope changes: the text is #28's, with the null admission added", () {
      final store = openStore(tempDbPath(), clock: steppingClock([1727190000000, 1727190001000]));
      final e = store.append(pre49Event);
      expect(store.readCanonical().single, '{"admission_id":null,${pre49For(store.deviceId, e.ulid).substring(1)}');
    });
  });

  group('criterion 3: a re-admission', () {
    test('later events carry the new admission, and the earlier events are unchanged', () {
      final path = tempDbPath();
      final store = EventStore.open(path);
      store.setAdmissionId(admission);
      store.append(const NewEvent(kind: 'note', source: 'tap', payload: {'n': 1}));
      store.append(const NewEvent(kind: 'note', source: 'tap', payload: {'n': 2}));
      final before = store.readCanonical();

      store.setAdmissionId(readmission);
      store.append(const NewEvent(kind: 'note', source: 'tap', payload: {'n': 3}));
      store.append(const NewEvent(kind: 'note', source: 'tap', payload: {'n': 4}));
      final after = store.readCanonical();
      store.close();

      expect(after.sublist(0, 2), before, reason: 'the earlier events, byte for byte as stored');
      expect(admissionsIn(after), [admission, admission, readmission, readmission]);
      expect(verifyChain(after), const ChainVerdict.intact(),
          reason: 'one chain across both admissions: the chain is per device, not per admission');
      expect(openStore(path).admissionId, readmission, reason: 'a restart keeps the re-admission');
    });

    test('over the core interface', () async {
      final core = await spawnedCore();
      await core.setAdmissionId(admission);
      final first = await core.append(const NewEvent(kind: 'note', source: 'tap'));
      await core.setAdmissionId(readmission);
      final second = await core.append(const NewEvent(kind: 'note', source: 'tap'));

      expect([first.admissionId, second.admissionId], [admission, readmission]);
      final all = await core.readAll();
      expect([for (final e in all) e.toWire()], [first.toWire(), second.toWire()]);
    });
  });

  group('an admission id the core must not stamp is refused', () {
    final refused = [
      '',
      'not-an-admission',
      admission.toUpperCase(),
      '{$admission}',
      '$admission ',
      '$admission\n',
      admission.replaceAll('-', ''),
      '01J8Z0D0000000000000000001',
    ];

    test('by the store, which keeps the admission it held, through a restart', () {
      final path = tempDbPath();
      final store = EventStore.open(path);
      store.setAdmissionId(admission);
      for (final id in refused) {
        expect(() => store.setAdmissionId(id),
            throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'admissionId')), reason: '"$id"');
      }
      expect(store.admissionId, admission);
      store.close();

      final again = openStore(path);
      expect(again.admissionId, admission);
      expect(again.append(const NewEvent(kind: 'note', source: 'tap')).admissionId, admission);
    });

    test('across the interface as an invalid call, and by the fake core', () async {
      final core = await spawnedCore();
      await expectLater(core.setAdmissionId('not-an-admission'),
          throwsA(isA<CoreException>().having((e) => e.code, 'code', 'invalid')));
      expect(await core.admissionId(), isNull);

      final fake = FakeCore();
      await expectLater(fake.setAdmissionId('not-an-admission'),
          throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'admissionId')));
      expect(await fake.admissionId(), isNull);
    });
  });

  test('an event written before #49 keeps its text and its hash on a phone upgraded mid-log, and the chain '
      'continues from it', () {
    final path = tempDbPath();
    final old = EventStore.open(path);
    final text = pre49For(old.deviceId, pre49Ulid);
    old.debugDatabase.execute('INSERT INTO events (ulid, device_id, seq, device_ts, body) VALUES (?, ?, ?, ?, ?)',
        [pre49Ulid, old.deviceId, 1, 1727190001000, text]);
    old.close();

    final upgraded = openStore(path);
    expect(upgraded.readAll().single.admissionId, isNull, reason: 'it reads back as never admitted');
    upgraded.setAdmissionId(admission);
    final next = upgraded.append(const NewEvent(kind: 'note', source: 'tap'));

    expect(next.prevHash, chainHash(text), reason: 'linked to the text as stored, not to a re-serialisation of it');
    expect(upgraded.readCanonical().first, text, reason: 'never rewritten');
    expect(verifyChain(upgraded.readCanonical()), const ChainVerdict.intact());
  });
}
