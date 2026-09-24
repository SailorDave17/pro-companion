import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/store.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #4 criteria 6-8 at the domain level, through the real store: an undo, a
/// missed finish and a sail number are each a new event, and the stored
/// events they refer to are byte-for-byte unchanged.
void main() {
  late EventStore store;
  final stored = <String, String>{};

  Map<String, String> bodies() => {
        for (final r in store.debugDatabase.select('SELECT ulid, body FROM events'))
          r['ulid'] as String: r['body'] as String,
      };

  List<FinishEntry> order() => finishOrder(store.readAll());

  setUp(() {
    var t = 1727190000000;
    store = openStore(tempDbPath(), clock: () => t += 1000);
    stored.clear();
  });

  test('finishes are placed in the order they were tapped', () {
    final a = store.append(FinishEvents.finish());
    final b = store.append(FinishEvents.finish());
    expect([for (final e in order()) (e.place, e.ulid, e.missed)], [
      (1, a.ulid, false),
      (2, b.ulid, false),
    ]);
    expect(order().first.deviceTs, a.deviceTs);
  });

  test('undo appends a correction naming the original, which is left unchanged', () {
    final a = store.append(FinishEvents.finish());
    final b = store.append(FinishEvents.finish());
    stored.addAll(bodies());

    final undo = store.append(FinishEvents.undo(a.ulid));

    expect(undo.kind, FinishKinds.undo);
    expect(undo.correctsUlid, a.ulid);
    expect(store.count(), 3, reason: 'appended, nothing removed');
    expect(bodies()[a.ulid], stored[a.ulid], reason: 'the original is unchanged');
    expect([for (final e in order()) (e.place, e.ulid)], [(1, b.ulid)],
        reason: 'the undone finish leaves the order and places renumber');
  });

  test('a missed finish is placed between A and B with a gap marker, and neither moves', () {
    final a = store.append(FinishEvents.finish());
    final b = store.append(FinishEvents.finish());
    stored.addAll(bodies());

    final m = store.append(FinishEvents.missed(afterUlid: a.ulid, beforeUlid: b.ulid));

    expect(m.kind, FinishKinds.missed);
    expect(m.payload['gap'], isTrue, reason: 'the gap marker');
    expect(m.deviceTs, greaterThan(b.deviceTs), reason: 'appended after both');
    expect([for (final e in order()) (e.place, e.ulid, e.missed)], [
      (1, a.ulid, false),
      (2, m.ulid, true),
      (3, b.ulid, false),
    ]);
    expect(order()[1].deviceTs, isNull, reason: 'a missed finish has no time');
    expect(bodies()[a.ulid], stored[a.ulid]);
    expect(bodies()[b.ulid], stored[b.ulid]);
  });

  test('two misses placed in one gap keep the order they were logged in', () {
    final a = store.append(FinishEvents.finish());
    final b = store.append(FinishEvents.finish());
    final m1 = store.append(FinishEvents.missed(afterUlid: a.ulid, beforeUlid: b.ulid));
    final m2 = store.append(FinishEvents.missed(afterUlid: m1.ulid, beforeUlid: b.ulid));
    expect([for (final e in order()) e.ulid], [a.ulid, m1.ulid, m2.ulid, b.ulid]);
  });

  test('a miss before the first finish goes first', () {
    final a = store.append(FinishEvents.finish());
    final m = store.append(FinishEvents.missed(afterUlid: null, beforeUlid: a.ulid));
    expect([for (final e in order()) e.ulid], [m.ulid, a.ulid]);
  });

  test('a sail number is a new event, then or later, and the latest one counts', () {
    final a = store.append(FinishEvents.finish());
    final s1 = store.append(FinishEvents.assignSail(a.ulid, '12345'));
    final b = store.append(FinishEvents.finish());
    stored.addAll(bodies());

    final s2 = store.append(FinishEvents.assignSail(a.ulid, '12346'));

    expect([s1.kind, s2.kind], [FinishKinds.sail, FinishKinds.sail]);
    expect(store.count(), 4);
    for (final ulid in [a.ulid, s1.ulid, b.ulid]) {
      expect(bodies()[ulid], stored[ulid], reason: 'no earlier event is rewritten');
    }
    expect(order().first.sail, '12346', reason: 'the later assignment wins');
    expect(order().last.sail, isNull);
  });

  test('a missed finish can take a sail number and be undone like any other', () {
    final a = store.append(FinishEvents.finish());
    final m = store.append(FinishEvents.missed(afterUlid: null, beforeUlid: a.ulid));
    store.append(FinishEvents.assignSail(m.ulid, '777'));
    expect(order().first.sail, '777');
    store.append(FinishEvents.undo(m.ulid));
    expect([for (final e in order()) e.ulid], [a.ulid]);
  });

  test('two taps in one millisecond keep the order they were tapped, whatever their ULIDs', () {
    EventEnvelope finish(String ulid, int seq) => EventEnvelope(
          ulid: ulid,
          deviceTs: 5000,
          deviceId: 'PHONE-A',
          seq: seq,
          source: 'tap',
          kind: FinishKinds.finish,
          payloadVersion: 1,
          payload: const {},
        );
    // Tapped first (seq 1) but with the larger ULID: ADR 001's log order,
    // which breaks a tie by ULID, would put it second.
    final first = finish('01J0000000000000000000000Z', 1);
    final second = finish('01J00000000000000000000001', 2);
    store.insert(first);
    store.insert(second);
    expect([for (final e in store.readAll()) e.ulid], [second.ulid, first.ulid],
        reason: 'the log itself orders the tie by ULID');
    expect([for (final e in order()) e.ulid], [first.ulid, second.ulid],
        reason: 'the finish order follows the tap order');
    expect(lastUndoable(store.readAll()), second.ulid);
  });

  test('Undo last takes back the most recent finish or miss not already undone', () {
    expect(lastUndoable(store.readAll()), isNull);
    final a = store.append(FinishEvents.finish());
    final b = store.append(FinishEvents.finish());
    expect(lastUndoable(store.readAll()), b.ulid);
    final m = store.append(FinishEvents.missed(afterUlid: a.ulid, beforeUlid: b.ulid));
    expect(lastUndoable(store.readAll()), m.ulid, reason: 'the miss was logged last');
    store.append(FinishEvents.assignSail(a.ulid, '9'));
    expect(lastUndoable(store.readAll()), m.ulid, reason: 'a sail number is not undone by Undo last');
    store.append(FinishEvents.undo(m.ulid));
    expect(lastUndoable(store.readAll()), b.ulid);
    store.append(FinishEvents.undo(b.ulid));
    store.append(FinishEvents.undo(a.ulid));
    expect(lastUndoable(store.readAll()), isNull);
  });

  test('events that are not finish events are ignored', () {
    store.append(const NewEvent(kind: 'note', source: 'tap'));
    final a = store.append(FinishEvents.finish());
    expect([for (final e in order()) e.ulid], [a.ulid]);
  });
}
