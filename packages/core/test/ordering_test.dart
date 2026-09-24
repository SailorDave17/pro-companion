import 'package:pro_companion_core/store.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #24 criterion 5: the log reads in device-timestamp order, then device id,
/// then ULID - the same order on every read and every phone (ADR 001).
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
  // ULIDs chosen so that ULID order disagrees with insertion order.
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
    '01J00000000000000000000003', // ts 5000, DEVICE-A, lower ULID
    '01J00000000000000000000007', // ts 5000, DEVICE-A
    '01J00000000000000000000001', // ts 5000, DEVICE-B, lower ULID
    '01J00000000000000000000009', // ts 5000, DEVICE-B
    '01J00000000000000000000002', // ts 5001
  ];

  test('same device timestamp orders by device id, then ULID', () {
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
}
