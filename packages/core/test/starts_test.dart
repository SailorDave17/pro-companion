import 'dart:convert';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #25 at the domain level, through the real store: a gun, a postponement and
/// a general recall logged by hand as `source: manual`, a late gun's
/// corrected time, and undo. Each is a new event; none edits another
/// (ADR 001). The screen's half is the app's test/sequence_screen_test.dart.
void main() {
  late EventStore store;
  late int now;

  setUp(() {
    now = DateTime(2026, 9, 26, 14, 30).millisecondsSinceEpoch;
    store = openStore(tempDbPath(), clock: () => now);
  });

  List<EventEnvelope> log() => store.readAll();

  /// Appends [e] at [now], then moves the clock on a second.
  EventEnvelope at(NewEvent e) {
    final stored = store.append(e);
    now += 1000;
    return stored;
  }

  /// The stored bytes of an event, to prove a later event did not touch it.
  String body(String ulid) =>
      store.debugDatabase.select('SELECT body FROM events WHERE ulid = ?', [ulid]).single['body'] as String;

  String fleet(String name) => at(FleetEvents.define(name)).ulid;

  group('criterion 1: a manual gun is a start with the device time and the fleet, and anchors it', () {
    test('kind start, source manual, the time it was tapped, the fleet - and it becomes the anchor', () {
      final lasers = fleet('Lasers');
      final tappedAt = now;
      final gun = at(StartEvents.start(fleet: lasers, source: 'manual'));
      expect(gun.kind, StartKinds.start);
      expect(gun.source, 'manual');
      expect(gun.deviceTs, tappedAt);
      expect(fleetOf(gun), lasers);
      expect(elapsedAnchor(log(), lasers)?.ulid, gun.ulid);
      expect(anchorTime(log(), lasers), tappedAt);
    });

    test('on a single-fleet day the gun carries no fleet and anchors the day', () {
      final gun = at(StartEvents.start(fleet: null, source: 'manual'));
      expect(gun.payload, {'fleet': null});
      expect(elapsedAnchor(log(), null)?.ulid, gun.ulid);
    });
  });

  group('criterion 2: a postponement and a general recall are each their own row', () {
    test('a postponement is appended as its own row, source manual, and moves no anchor', () {
      final lasers = fleet('Lasers');
      final before = raceState(log(), lasers);
      final ap = at(StartEvents.postponement(fleet: lasers, source: 'manual'));
      expect(ap.kind, StartKinds.postponement);
      expect(ap.source, 'manual');
      expect(fleetOf(ap), lasers);
      expect(sequenceOf(log(), lasers).map((e) => e.ulid), [ap.ulid]);
      expect(raceState(log(), lasers), before);
      expect(elapsedAnchor(log(), lasers), isNull);
    });

    test('a postponement after a gun leaves that gun anchoring, and edits nothing', () {
      final lasers = fleet('Lasers');
      final gun = at(StartEvents.start(fleet: lasers, source: 'manual'));
      final gunBody = body(gun.ulid);
      at(StartEvents.postponement(fleet: lasers, source: 'manual'));
      expect(elapsedAnchor(log(), lasers)?.ulid, gun.ulid);
      expect(body(gun.ulid), gunBody);
    });

    test('a general recall is its own row and clears the anchor until a new gun is logged', () {
      final lasers = fleet('Lasers');
      final first = at(StartEvents.start(fleet: lasers, source: 'manual'));
      final firstBody = body(first.ulid);
      final recall = at(StartEvents.generalRecall(fleet: lasers, source: 'manual'));
      expect(recall.kind, StartKinds.generalRecall);
      expect(recall.source, 'manual');
      expect(fleetOf(recall), lasers);
      expect(elapsedAnchor(log(), lasers), isNull);
      expect(anchorTime(log(), lasers), isNull);
      expect(body(first.ulid), firstBody, reason: 'the recalled gun is kept');

      final second = at(StartEvents.start(fleet: lasers, source: 'manual'));
      expect(elapsedAnchor(log(), lasers)?.ulid, second.ulid);
      expect(sequenceOf(log(), lasers).map((e) => e.kind),
          [StartKinds.start, StartKinds.generalRecall, StartKinds.start]);
    });
  });

  group('criterion 3: a corrected time is a new event naming the gun, which is kept', () {
    test('the correction references the gun, carries the time, and the gun is untouched', () {
      final lasers = fleet('Lasers');
      final gun = at(StartEvents.start(fleet: lasers, source: 'manual'));
      final tapped = body(gun.ulid);
      final real = gun.deviceTs - 4000; // tapped 4 s after the gun went

      final fix = at(StartEvents.correctTime(gun.ulid, time: real));
      expect(fix.kind, StartKinds.timeCorrected);
      expect(fix.correctsUlid, gun.ulid);
      expect(fix.payload, {'time': real});
      expect(fix.source, 'manual', reason: 'a hand-typed time');
      expect(body(gun.ulid), tapped, reason: 'the original is kept as tapped');
      expect(elapsedAnchor(log(), lasers)?.ulid, gun.ulid, reason: 'still the anchor');
      expect(anchorTime(log(), lasers), real, reason: 'measured from the corrected time');
      expect(gunTime(log(), gun), real);
    });

    test('a later correction wins over an earlier one, and both are kept', () {
      final lasers = fleet('Lasers');
      final gun = at(StartEvents.start(fleet: lasers, source: 'manual'));
      final first = at(StartEvents.correctTime(gun.ulid, time: gun.deviceTs - 4000));
      final second = at(StartEvents.correctTime(gun.ulid, time: gun.deviceTs - 3000));
      expect(anchorTime(log(), lasers), gun.deviceTs - 3000);
      expect(log().map((e) => e.ulid), containsAll([gun.ulid, first.ulid, second.ulid]));
    });

    test("a correction moves only its own gun's time", () {
      final lasers = fleet('Lasers');
      final fourTwenties = fleet('420s');
      final a = at(StartEvents.start(fleet: lasers, source: 'manual'));
      final b = at(StartEvents.start(fleet: fourTwenties, source: 'manual'));
      at(StartEvents.correctTime(a.ulid, time: a.deviceTs - 2000));
      expect(anchorTime(log(), lasers), a.deviceTs - 2000);
      expect(anchorTime(log(), fourTwenties), b.deviceTs);
    });
  });

  group('criterion 4: source=manual survives every way out of the core', () {
    /// One of each manual kind, as a PRO without race-timer logs them.
    List<EventEnvelope> manualDay() {
      final lasers = fleet('Lasers');
      final ap = at(StartEvents.postponement(fleet: lasers, source: 'manual'));
      final gun = at(StartEvents.start(fleet: lasers, source: 'manual'));
      final recall = at(StartEvents.generalRecall(fleet: lasers, source: 'manual'));
      final again = at(StartEvents.start(fleet: lasers, source: 'manual'));
      final fix = at(StartEvents.correctTime(again.ulid, time: again.deviceTs - 1000));
      return [ap, gun, recall, again, fix];
    }

    test('read back from the store', () {
      final written = manualDay();
      final read = {for (final e in log()) e.ulid: e};
      for (final e in written) {
        expect(read[e.ulid]!.source, 'manual', reason: e.kind);
      }
    });

    test('serialised as the ADR 001 envelope - the form an export or sync carries - and parsed back', () {
      for (final e in manualDay()) {
        final text = jsonEncode(e.toWire());
        final wire = jsonDecode(text) as Map;
        expect(wire['source'], 'manual', reason: e.kind);
        expect(EventEnvelope.fromWire(wire).source, 'manual', reason: e.kind);
        expect(EventEnvelope.fromWire(wire).toWire(), e.toWire(), reason: 'nothing lost or rewritten');
      }
    });

    test('across the isolate boundary the UI reads through', () async {
      final core = await spawnCore(tempDbPath());
      addTearDown(() async {
        try {
          await core.close();
        } on Object {
          // Already closed.
        }
      });
      final gun = await core.append(StartEvents.start(fleet: null, source: 'manual'));
      await core.append(StartEvents.postponement(fleet: null, source: 'manual'));
      await core.append(StartEvents.generalRecall(fleet: null, source: 'manual'));
      await core.append(StartEvents.correctTime(gun.ulid, time: gun.deviceTs - 1000));
      final all = await core.readAll();
      expect(all, hasLength(4));
      expect(all.map((e) => e.source), everyElement('manual'));
    });
  });

  group('criterion 7: undo is a correction event, and the anchor reverts to its prior value', () {
    test('undoing a gun: a start.undo names it, the gun is kept, the anchor is back to what it was', () {
      final lasers = fleet('Lasers');
      final first = at(StartEvents.start(fleet: lasers, source: 'manual'));
      final second = at(StartEvents.start(fleet: lasers, source: 'manual'));
      final secondBody = body(second.ulid);
      expect(lastUndoableStart(log(), fleet: lasers)?.ulid, second.ulid);

      final undo = at(StartEvents.undo(second.ulid));
      expect(undo.kind, StartKinds.undo);
      expect(undo.correctsUlid, second.ulid);
      expect(body(second.ulid), secondBody, reason: 'the undone gun is kept');
      expect(elapsedAnchor(log(), lasers)?.ulid, first.ulid);
      expect(raceState(log(), lasers), FleetRaceState(starts: 1, recalls: 0, anchorUlid: first.ulid));
    });

    test('undoing the only gun leaves no anchor', () {
      final lasers = fleet('Lasers');
      final gun = at(StartEvents.start(fleet: lasers, source: 'manual'));
      at(StartEvents.undo(gun.ulid));
      expect(elapsedAnchor(log(), lasers), isNull);
      expect(raceState(log(), lasers), const FleetRaceState(starts: 0, recalls: 0));
      expect(lastUndoableStart(log(), fleet: lasers), isNull, reason: 'an undo is not itself undoable');
    });

    test('undoing a general recall: the recalled gun anchors again', () {
      final lasers = fleet('Lasers');
      final gun = at(StartEvents.start(fleet: lasers, source: 'manual'));
      final recall = at(StartEvents.generalRecall(fleet: lasers, source: 'manual'));
      expect(elapsedAnchor(log(), lasers), isNull);
      at(StartEvents.undo(recall.ulid));
      expect(elapsedAnchor(log(), lasers)?.ulid, gun.ulid);
      expect(raceState(log(), lasers).recalls, 0);
    });

    test('undoing a time correction: the gun time goes back to the one before', () {
      final lasers = fleet('Lasers');
      final gun = at(StartEvents.start(fleet: lasers, source: 'manual'));
      final first = at(StartEvents.correctTime(gun.ulid, time: gun.deviceTs - 4000));
      final second = at(StartEvents.correctTime(gun.ulid, time: gun.deviceTs - 3000));
      expect(lastUndoableStart(log(), fleet: lasers)?.ulid, second.ulid);
      at(StartEvents.undo(second.ulid));
      expect(anchorTime(log(), lasers), gun.deviceTs - 4000);
      expect(lastUndoableStart(log(), fleet: lasers)?.ulid, first.ulid);
      at(StartEvents.undo(first.ulid));
      expect(anchorTime(log(), lasers), gun.deviceTs, reason: 'back to the time it was tapped');
    });

    test('undoing a postponement takes it out of the sequence', () {
      final lasers = fleet('Lasers');
      final ap = at(StartEvents.postponement(fleet: lasers, source: 'manual'));
      at(StartEvents.undo(ap.ulid));
      expect(sequenceOf(log(), lasers), isEmpty);
      expect(log().where((e) => e.ulid == ap.ulid), hasLength(1), reason: 'kept in the log');
    });

    test('repeated undo walks the sequence back, newest first', () {
      final lasers = fleet('Lasers');
      final ap = at(StartEvents.postponement(fleet: lasers, source: 'manual'));
      final gun = at(StartEvents.start(fleet: lasers, source: 'manual'));
      final fix = at(StartEvents.correctTime(gun.ulid, time: gun.deviceTs - 2000));
      final recall = at(StartEvents.generalRecall(fleet: lasers, source: 'manual'));
      final undone = <String>[];
      for (var target = lastUndoableStart(log(), fleet: lasers);
          target != null;
          target = lastUndoableStart(log(), fleet: lasers)) {
        undone.add(target.ulid);
        at(StartEvents.undo(target.ulid));
      }
      expect(undone, [recall.ulid, fix.ulid, gun.ulid, ap.ulid]);
    });

    test("a gun's time correction goes when its gun is undone", () {
      final lasers = fleet('Lasers');
      final gun = at(StartEvents.start(fleet: lasers, source: 'manual'));
      at(StartEvents.correctTime(gun.ulid, time: gun.deviceTs - 2000));
      at(StartEvents.undo(gun.ulid));
      expect(lastUndoableStart(log(), fleet: lasers), isNull);
      expect(anchorTime(log(), lasers), isNull);
    });

    test("undo on one fleet never takes back another fleet's event", () {
      final lasers = fleet('Lasers');
      final fourTwenties = fleet('420s');
      final a = at(StartEvents.start(fleet: lasers, source: 'manual'));
      final b = at(StartEvents.start(fleet: fourTwenties, source: 'manual'));
      expect(lastUndoableStart(log(), fleet: lasers)?.ulid, a.ulid);
      expect(lastUndoableStart(log(), fleet: fourTwenties)?.ulid, b.ulid);
      at(StartEvents.undo(a.ulid));
      expect(elapsedAnchor(log(), fourTwenties)?.ulid, b.ulid);
    });
  });

  group('#18 criterion 2, the start half: after a switch, start and sequence events carry that fleet', () {
    test('three fleets, switched between: each gun, postponement and recall carries the fleet selected then', () {
      final ids = [for (final n in ['Lasers', '420s', 'Optis']) fleet(n)];
      final builders = <NewEvent Function(String?)>[
        (f) => StartEvents.postponement(fleet: f, source: 'manual'),
        (f) => StartEvents.start(fleet: f, source: 'manual'),
        (f) => StartEvents.generalRecall(fleet: f, source: 'manual'),
      ];
      final carried = <String?>[];
      for (final (i, id) in [ids[1], ids[0], ids[2]].indexed) {
        at(FleetEvents.select(id));
        carried.add(fleetOf(at(builders[i](selectedFleet(log(), store.deviceId)))));
      }
      expect(carried, [ids[1], ids[0], ids[2]]);
    });
  });
}
