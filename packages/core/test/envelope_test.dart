import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/store.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #24 criterion 1: an appended event carries the whole ADR 001 envelope.
void main() {
  test('an appended event carries every ADR 001 envelope field', () {
    final store = openStore(tempDbPath(), clock: steppingClock([1000, 1727190000123]));
    final original = store.append(const NewEvent(kind: 'finish', source: 'tap'));

    final e = store.append(NewEvent(
      kind: 'finish.correction',
      source: 'tap',
      payload: const {'sail': '12345'},
      payloadVersion: 2,
      person: 'volunteer@example.org',
      role: 'recorder',
      gps: const GpsFix(lat: 33.4, lon: -86.8, accuracyM: 4.5),
      correctsUlid: original.ulid,
    ));
    final stored = store.readAll().singleWhere((x) => x.ulid == e.ulid);

    expect(isUlid(stored.ulid), isTrue, reason: 'ULID');
    expect(stored.deviceTs, 1727190000123, reason: 'device timestamp, from the device clock');
    expect(stored.deviceId, store.deviceId, reason: 'device id');
    expect(isUlid(stored.deviceId), isTrue);
    expect(stored.seq, 2, reason: 'per-device sequence number');
    expect(stored.person, 'volunteer@example.org');
    expect(stored.role, 'recorder');
    expect(stored.gps, const GpsFix(lat: 33.4, lon: -86.8, accuracyM: 4.5));
    expect(stored.source, 'tap');
    expect(stored.kind, 'finish.correction');
    expect(stored.payloadVersion, 2, reason: 'payload schema version');
    expect(stored.correctsUlid, original.ulid, reason: 'corrects-ULID');
    expect(stored.prevHash, chainHash(store.readCanonical().first),
        reason: 'the previous hash: seq 1 as stored (#28)');
    expect(stored.payload, {'sail': '12345'});
  });

  test('person, role, GPS and corrects-ULID may all be null; a first event chains from genesis', () {
    final store = openStore(tempDbPath());
    expect(store.readAll(), isEmpty);

    store.append(const NewEvent(kind: 'note', source: 'tap'));
    final e = store.readAll().single;
    expect([e.person, e.role, e.gps, e.correctsUlid], everyElement(isNull));
    expect(e.prevHash, genesisHash, reason: '#28');
    expect(e.seq, 1);
  });

  test('the wire form carries exactly the envelope fields, each present even when null', () {
    final store = openStore(tempDbPath());
    final wire = store.append(const NewEvent(kind: 'note', source: 'tap')).toWire();
    expect(wire.keys.toSet(), {
      'ulid',
      'device_ts',
      'device_id',
      'seq',
      'person',
      'role',
      'gps',
      'source',
      'kind',
      'payload_version',
      'corrects_ulid',
      'prev_hash',
      'payload',
    });
    expect(isWireSafe(wire), isTrue);
  });

  test('sequence numbers run 1, 2, 3 per device and survive a reopen', () {
    final path = tempDbPath();
    final first = EventStore.open(path);
    final id = first.deviceId;
    expect([for (var i = 0; i < 3; i++) first.append(const NewEvent(kind: 'k', source: 's')).seq],
        [1, 2, 3]);
    first.close();

    final again = openStore(path);
    expect(again.deviceId, id, reason: 'the device id is stable for the install');
    expect(again.append(const NewEvent(kind: 'k', source: 's')).seq, 4);
  });

  test('an event the core must not store is refused before anything is written', () {
    final store = openStore(tempDbPath());
    expect(() => store.append(const NewEvent(kind: '', source: 'tap')), throwsArgumentError);
    expect(() => store.append(const NewEvent(kind: 'k', source: '')), throwsArgumentError);
    expect(() => store.append(const NewEvent(kind: 'k', source: 's', payloadVersion: 0)),
        throwsArgumentError);
    expect(() => store.append(const NewEvent(kind: 'k', source: 's', correctsUlid: 'not-a-ulid')),
        throwsArgumentError);
    expect(() => store.append(NewEvent(kind: 'k', source: 's', payload: {'at': DateTime(2026)})),
        throwsArgumentError);
    expect(store.count(), 0);
    expect(store.append(const NewEvent(kind: 'k', source: 's')).seq, 1,
        reason: 'a refusal does not use up a sequence number');
  });
}
