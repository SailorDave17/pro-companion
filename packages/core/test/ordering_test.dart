import 'dart:math';

import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #24 criterion 5: the log reads in device-timestamp order, then device id,
/// the same order on every read and every phone (ADR 001). Since #145 one
/// phone's own events in one millisecond read in its sequence order: the
/// ULID broke that tie until then, and its random tail inverted two events
/// one run in a few.
void main() {
  EventEnvelope event(String ulid, String device, int seq, int ts) => EventEnvelope(
        ulid: ulid,
        deviceTs: ts,
        deviceId: device,
        seq: seq,
        source: 'tap',
        kind: 'finish',
        payloadVersion: 1,
        payload: const {},
      );

  // Inserted deliberately out of order. Same timestamp for the first four;
  // ULIDs chosen so that ULID order disagrees with insertion order, with
  // device order, and with each device's sequence order.
  final inserted = [
    event('01J00000000000000000000009', 'DEVICE-B', 1, 5000),
    event('01J00000000000000000000003', 'DEVICE-A', 2, 5000),
    event('01J00000000000000000000001', 'DEVICE-B', 2, 5000),
    event('01J00000000000000000000007', 'DEVICE-A', 1, 5000),
    event('01J00000000000000000000005', 'DEVICE-C', 1, 4999),
    event('01J00000000000000000000002', 'DEVICE-A', 3, 5001),
  ];
  const expected = [
    '01J00000000000000000000005', // ts 4999
    '01J00000000000000000000007', // ts 5000, DEVICE-A, seq 1, the higher ULID
    '01J00000000000000000000003', // ts 5000, DEVICE-A, seq 2
    '01J00000000000000000000009', // ts 5000, DEVICE-B, seq 1, the higher ULID
    '01J00000000000000000000001', // ts 5000, DEVICE-B, seq 2
    '01J00000000000000000000002', // ts 5001
  ];

  test('same device timestamp orders by device id, then the device\'s sequence number', () {
    final store = openStore(tempDbPath());
    inserted.forEach(store.insert);
    expect([for (final e in store.readAll()) e.ulid], expected);
  });

  test('the order is identical across reads and across a reopen', () {
    final path = tempDbPath();
    final store = EventStore.open(path);
    inserted.forEach(store.insert);
    final first = [for (final e in store.readAll()) e.ulid];
    final second = [for (final e in store.readAll()) e.ulid];
    store.close();
    final reopened = [for (final e in openStore(path).readAll()) e.ulid];
    expect(second, first);
    expect(reopened, first);
    expect(first, expected);
  });

  test('#145 criterion 2: phones tied on device time still order by device id, whatever their sequence numbers', () {
    final store = openStore(tempDbPath());
    // DEVICE-A's seq 2 against DEVICE-B's seq 1: the device decides, not the number.
    store.insert(event('01J00000000000000000000001', 'DEVICE-B', 1, 5000));
    store.insert(event('01J00000000000000000000009', 'DEVICE-A', 2, 5000));
    expect([for (final e in store.readAll()) e.deviceId], ['DEVICE-A', 'DEVICE-B']);
  });

  group('#145 criterion 1: one phone\'s events in one millisecond read back in the order it logged them', () {
    const n = 20;
    const note = NewEvent(kind: 'note', source: 'tap');

    // The forced case: every event in one millisecond, so only the tie-break orders them. The
    // control proves the ULIDs alone would order them otherwise, so a ULID tie-break fails here.
    void expectLoggedOrder(List<EventEnvelope> appended, List<EventEnvelope> read) {
      final seqs = [for (final e in appended) e.seq];
      expect(appended.map((e) => e.deviceTs).toSet(), hasLength(1), reason: 'control: one millisecond');
      expect([for (final e in [...appended]..sort((a, b) => a.ulid.compareTo(b.ulid))) e.seq], isNot(seqs),
          reason: 'control: ULID order disagrees with the order they were logged');
      expect([for (final e in read) e.seq], seqs);
    }

    test('readAll and readOwn, in the store', () {
      final store = openStore(tempDbPath(), clock: () => 5000);
      final appended = [for (var i = 0; i < n; i++) store.append(note)];
      expectLoggedOrder(appended, store.readAll());
      expectLoggedOrder(appended, store.readOwn());
    });

    test('across a reopen of a log written before the index changed', () {
      final path = tempDbPath();
      final store = EventStore.open(path, clock: () => 5000, random: Random(145));
      final appended = [for (var i = 0; i < n; i++) store.append(note)];
      // As a pre-#145 log holds it: the ULID-keyed index, and not the new one.
      store.debugDatabase.execute('DROP INDEX events_read_order');
      store.debugDatabase.execute('CREATE INDEX events_order ON events (device_ts, device_id, ulid)');
      store.close();
      final reopened = openStore(path);
      expectLoggedOrder(appended, reopened.readAll());
      final indexes = [
        for (final r in reopened.debugDatabase.select("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'events'"))
          r['name'] as String,
      ];
      expect(indexes, contains('events_read_order'));
      expect(indexes, isNot(contains('events_order')), reason: 'the old index is dropped on open');
    });

    test('and the fake core the widget tests use reads them the same way', () async {
      final fake = FakeCore(clock: () => 5000);
      final appended = [for (var i = 0; i < n; i++) await fake.append(note)];
      expectLoggedOrder(appended, await fake.readAll());
      expectLoggedOrder(appended, await fake.readOwn());
    });

    test('over the core interface, as the UI reaches it', () async {
      final path = tempDbPath();
      final store = EventStore.open(path, clock: () => 5000, random: Random(145));
      final appended = [for (var i = 0; i < n; i++) store.append(note)];
      store.close();
      final core = await spawnCore(path);
      addTearDown(core.close);
      expectLoggedOrder(appended, await core.readAll());
      expectLoggedOrder(appended, await core.readOwn());
    });
  });
}
