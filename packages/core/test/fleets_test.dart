import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/store.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #18 at the domain level, through the real store: fleets are defined and
/// switched by events, every race-time event carries its fleet, and each
/// fleet's finishes and starts are its own.
void main() {
  late EventStore store;

  setUp(() {
    var t = 1727190000000;
    store = openStore(tempDbPath(), clock: () => t += 1000);
  });

  List<EventEnvelope> log() => store.readAll();

  /// An event from another phone, as sync would store it.
  EventEnvelope fromOtherPhone(NewEvent e, {required int ts, required int seq}) {
    final other = EventEnvelope(
      ulid: newUlidFor(ts),
      deviceTs: ts,
      deviceId: '01J9OTHERPHONE000000000000Z',
      seq: seq,
      source: e.source,
      kind: e.kind,
      payloadVersion: e.payloadVersion,
      payload: e.payload,
      correctsUlid: e.correctsUlid,
    );
    store.insert(other);
    return other;
  }

  group('criterion 1: a fleet is defined by an event and is then selectable', () {
    test('the name and class are the payload, and the fleet id is the defining event', () {
      final lasers = store.append(FleetEvents.define('  Lasers ', klass: ' ILCA 7 '));
      expect(lasers.kind, FleetKinds.defined);
      expect(lasers.payload, {'name': 'Lasers', 'class': 'ILCA 7'});
      final all = fleets(log());
      expect(all.single.id, lasers.ulid);
      expect(all.single.name, 'Lasers');
      expect(all.single.klass, 'ILCA 7');
    });

    test('the class is optional, and a blank one is none', () {
      store.append(FleetEvents.define('420s'));
      store.append(FleetEvents.define('Optis', klass: '   '));
      expect(fleets(log()).map((f) => f.klass), [null, null]);
    });

    test('fleets list in the order they were defined', () {
      for (final name in ['Lasers', '420s', 'Optis']) {
        store.append(FleetEvents.define(name));
      }
      expect(fleets(log()).map((f) => f.name), ['Lasers', '420s', 'Optis']);
    });

    test('a defined fleet can be selected', () {
      final lasers = store.append(FleetEvents.define('Lasers'));
      expect(selectedFleet(log(), store.deviceId), isNull, reason: 'defining is not selecting');
      store.append(FleetEvents.select(lasers.ulid));
      expect(selectedFleet(log(), store.deviceId), lasers.ulid);
    });
  });

  group('criterion 2: after a switch, finish events carry that fleet', () {
    test('three fleets, switched between: each finish carries the fleet selected when it was tapped', () {
      final ids = [for (final n in ['Lasers', '420s', 'Optis']) store.append(FleetEvents.define(n)).ulid];
      final carried = <String?>[];
      for (final id in [ids[1], ids[0], ids[2]]) {
        store.append(FleetEvents.select(id));
        final fleet = selectedFleet(log(), store.deviceId);
        carried.add(fleetOf(store.append(FinishEvents.finish(fleet: fleet))));
      }
      expect(carried, [ids[1], ids[0], ids[2]]);
    });

    test('each fleet has its own places, even with finishes interleaved on one line', () {
      final a = store.append(FleetEvents.define('Lasers')).ulid;
      final b = store.append(FleetEvents.define('420s')).ulid;
      final a1 = store.append(FinishEvents.finish(fleet: a));
      final b1 = store.append(FinishEvents.finish(fleet: b));
      final a2 = store.append(FinishEvents.finish(fleet: a));
      final b2 = store.append(FinishEvents.finish(fleet: b));
      final a3 = store.append(FinishEvents.finish(fleet: a));
      expect(finishOrder(log(), fleet: a).map((e) => (e.place, e.ulid)), [(1, a1.ulid), (2, a2.ulid), (3, a3.ulid)]);
      expect(finishOrder(log(), fleet: b).map((e) => (e.place, e.ulid)), [(1, b1.ulid), (2, b2.ulid)]);
      expect(finishOrder(log(), fleet: null), isEmpty, reason: 'no fleetless finish was logged');
    });

    test('a missed finish takes a place in its own fleet only', () {
      final a = store.append(FleetEvents.define('Lasers')).ulid;
      final b = store.append(FleetEvents.define('420s')).ulid;
      final a1 = store.append(FinishEvents.finish(fleet: a));
      store.append(FinishEvents.finish(fleet: b));
      final a2 = store.append(FinishEvents.finish(fleet: a));
      final m = store.append(FinishEvents.missed(fleet: a, afterUlid: a1.ulid, beforeUlid: a2.ulid));
      expect(finishOrder(log(), fleet: a).map((e) => e.ulid), [a1.ulid, m.ulid, a2.ulid]);
      expect(finishOrder(log(), fleet: b), hasLength(1));
    });

    test('Undo last takes back the current fleet\'s last finish, not another fleet\'s later one', () {
      final a = store.append(FleetEvents.define('Lasers')).ulid;
      final b = store.append(FleetEvents.define('420s')).ulid;
      final a1 = store.append(FinishEvents.finish(fleet: a));
      final b1 = store.append(FinishEvents.finish(fleet: b));
      expect(lastUndoable(log(), fleet: a), a1.ulid);
      expect(lastUndoable(log(), fleet: b), b1.ulid);
    });

    test('start and recall builders stamp the fleet, and keep the source verbatim', () {
      final a = store.append(FleetEvents.define('Lasers')).ulid;
      final gun = store.append(StartEvents.start(fleet: a, source: 'manual'));
      final recall = store.append(StartEvents.generalRecall(fleet: a, source: 'race-timer'));
      expect([fleetOf(gun), fleetOf(recall)], [a, a]);
      expect([gun.source, recall.source], ['manual', 'race-timer']);
    });
  });

  group('criterion 3: a recall is one fleet\'s business', () {
    test('a general recall against Lasers leaves the 420s race state exactly as it was', () {
      final a = store.append(FleetEvents.define('Lasers')).ulid;
      final b = store.append(FleetEvents.define('420s')).ulid;
      store.append(StartEvents.start(fleet: a, source: 'manual'));
      store.append(StartEvents.start(fleet: b, source: 'manual'));
      final before = raceState(log(), b);
      final aBefore = raceState(log(), a);

      store.append(StartEvents.generalRecall(fleet: a, source: 'manual'));

      expect(raceState(log(), b), before, reason: 'the other fleet is untouched');
      expect(before.anchorUlid, isNotNull);
      expect(raceState(log(), a), isNot(aBefore), reason: 'the recalled fleet did change');
      expect(raceState(log(), a).anchorUlid, isNull);
    });
  });

  group('criterion 4: the elapsed-time anchor is the fleet\'s most recent start not recalled', () {
    test('gun, recall, gun: the second gun anchors; the other fleet keeps its own gun', () {
      final a = store.append(FleetEvents.define('Lasers')).ulid;
      final b = store.append(FleetEvents.define('420s')).ulid;
      final a1 = store.append(StartEvents.start(fleet: a, source: 'manual'));
      expect(elapsedAnchor(log(), a)?.ulid, a1.ulid);
      final b1 = store.append(StartEvents.start(fleet: b, source: 'manual'));
      store.append(StartEvents.generalRecall(fleet: a, source: 'manual'));
      expect(elapsedAnchor(log(), a), isNull, reason: 'a recall clears the anchor until the next gun');
      final a2 = store.append(StartEvents.start(fleet: a, source: 'manual'));
      expect(elapsedAnchor(log(), a)?.ulid, a2.ulid);
      expect(elapsedAnchor(log(), b)?.ulid, b1.ulid);
      expect(raceState(log(), a), FleetRaceState(starts: 2, recalls: 1, anchorUlid: a2.ulid));
    });

    test('a fleet with no gun has no anchor', () {
      final a = store.append(FleetEvents.define('Lasers')).ulid;
      expect(elapsedAnchor(log(), a), isNull);
      expect(raceState(log(), a), const FleetRaceState(starts: 0, recalls: 0));
    });
  });

  group('criterion 7: an undone switch is a correction, and the phone returns to its fleet', () {
    test('undo appends a correction naming the switch; the switch itself is unchanged', () {
      final a = store.append(FleetEvents.define('Lasers')).ulid;
      final b = store.append(FleetEvents.define('420s')).ulid;
      store.append(FleetEvents.select(a));
      final wrong = store.append(FleetEvents.select(b));
      final bodyBefore = store.debugDatabase.select('SELECT body FROM events WHERE ulid = ?', [wrong.ulid]).single['body'];

      expect(lastFleetSwitch(log(), store.deviceId)?.ulid, wrong.ulid);
      final undo = store.append(FleetEvents.undo(wrong.ulid));

      expect(undo.kind, FleetKinds.undo);
      expect(undo.correctsUlid, wrong.ulid);
      expect(selectedFleet(log(), store.deviceId), a, reason: 'back to the fleet before the wrong switch');
      expect(store.debugDatabase.select('SELECT body FROM events WHERE ulid = ?', [wrong.ulid]).single['body'],
          bodyBefore);
    });

    test('undoing the only switch leaves no fleet selected', () {
      final a = store.append(FleetEvents.define('Lasers')).ulid;
      final only = store.append(FleetEvents.select(a));
      store.append(FleetEvents.undo(only.ulid));
      expect(selectedFleet(log(), store.deviceId), isNull);
      expect(lastFleetSwitch(log(), store.deviceId), isNull);
    });
  });

  group('selection belongs to one phone', () {
    test("another phone's switch, arriving by sync, does not move this one", () {
      final a = store.append(FleetEvents.define('Lasers')).ulid;
      final b = store.append(FleetEvents.define('420s')).ulid;
      store.append(FleetEvents.select(a));
      fromOtherPhone(FleetEvents.select(b), ts: 1727199999000, seq: 1);
      expect(selectedFleet(log(), store.deviceId), a);
      expect(selectedFleet(log(), '01J9OTHERPHONE000000000000Z'), b);
    });

    test('a switch to a fleet nobody defined is ignored', () {
      final a = store.append(FleetEvents.define('Lasers')).ulid;
      store.append(FleetEvents.select(a));
      store.append(FleetEvents.select('01J9NOSUCHFLEET00000000000'));
      expect(selectedFleet(log(), store.deviceId), a);
    });
  });
}

/// A ULID for [ts] with a fixed tail, for events built by hand.
String newUlidFor(int ts) {
  const crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  final chars = List.filled(26, 'Z');
  var t = ts;
  for (var i = 9; i >= 0; i--) {
    chars[i] = crockford[t % 32];
    t ~/= 32;
  }
  return chars.join();
}
