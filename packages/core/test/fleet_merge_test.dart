import 'package:pro_companion_core/core.dart';
import 'package:test/test.dart';

/// #76: fleets several phones named the same, on one race area, are read as one fleet, the first
/// defined; never across race areas, where the name is flagged instead. Built from envelopes by
/// hand, so each case states exactly which phone defined what, when, and on which race area.
void main() {
  const alpha = '00000000-0000-0000-0000-00000000ca01';
  const bravo = '00000000-0000-0000-0000-00000000ca02';
  const pro = '01J8000000000000000000PR01';
  const recorder = '01J8000000000000000000RC01';
  const mark = '01J8000000000000000000MK01';

  var n = 0;
  EventEnvelope event(String device, String kind, Map<String, Object?> payload, {required int at}) {
    n++;
    return EventEnvelope(
      ulid: '01J8Z0000000000000000${n.toString().padLeft(5, '0')}',
      deviceTs: at,
      deviceId: device,
      seq: n,
      source: 'tap',
      kind: kind,
      payloadVersion: 1,
      payload: payload,
    );
  }

  EventEnvelope define(String device, String name, {String? course, required int at}) => event(
      device, FleetKinds.defined, {'name': name, 'class': null, 'course': ?course},
      at: at);

  EventEnvelope finish(String device, String fleet, {required int at}) =>
      event(device, FinishKinds.finish, {'fleet': fleet}, at: at);

  group('criterion 1: two phones\' "Lasers" on one race area are one fleet', () {
    test('read as the first defined, whichever phone defined it', () {
      final first = define(recorder, 'Lasers', course: alpha, at: 1000);
      final second = define(pro, 'Lasers', course: alpha, at: 2000);
      final merge = FleetMerge.of([second, first]);
      expect(merge.resolve(second.ulid), first.ulid);
      expect(merge.resolve(first.ulid), first.ulid);
      expect([merge.mergedAway(second.ulid), merge.mergedAway(first.ulid)], [true, false]);
      expect(merge.conflicted(first.ulid) || merge.conflicted(second.ulid), isFalse,
          reason: 'a merge is not a conflict');
    });

    test('the same answer on every phone, whatever order its events arrived in', () {
      final a = define(pro, 'Lasers', course: alpha, at: 5000);
      final b = define(recorder, 'Lasers', course: alpha, at: 5000); // tied on time: the device id decides
      final c = define(mark, 'Lasers', course: alpha, at: 4000);
      final orders = [
        [a, b, c],
        [c, b, a],
        [b, a, c],
      ];
      final answers = {
        for (final o in orders) [for (final e in [a, b, c]) FleetMerge.of(o).resolve(e.ulid)].join(),
      };
      expect(answers, hasLength(1), reason: 'no phone reads the merge differently');
      expect(FleetMerge.of([a, b, c]).resolve(a.ulid), c.ulid, reason: 'the earliest device time wins');
    });

    test('names are compared trimmed and ignoring case, as FLEETS compares them on one phone', () {
      final first = define(pro, 'Lasers', at: 1000);
      final second = define(recorder, '  lasers ', at: 2000);
      expect(FleetMerge.of([first, second]).resolve(second.ulid), first.ulid);
    });

    test('a fleet naming no race area joins the one race area its name is defined on', () {
      final named = define(recorder, 'Lasers', course: alpha, at: 1000);
      final none = define(pro, 'Lasers', at: 2000); // an event-wide PRO that picked no race area
      final merge = FleetMerge.of([named, none]);
      expect(merge.resolve(none.ulid), named.ulid);
      expect(merge.conflicted(none.ulid), isFalse);
    });
  });

  group('criterion 2: a view reads each event through the merge', () {
    test("the merged-away fleet's events read as the surviving fleet's, and its definition drops out", () {
      final first = define(pro, 'Lasers', course: alpha, at: 1000);
      final second = define(recorder, 'Lasers', course: alpha, at: 2000);
      final f = finish(recorder, second.ulid, at: 3000);
      final view = FleetMerge.of([first, second, f]).apply([first, second, f]);
      expect([for (final e in fleets(view)) e.id], [first.ulid], reason: 'one fleet listed');
      expect(fleetOf(view.singleWhere((e) => e.ulid == f.ulid)), first.ulid);
    });
  });

  group('criterion 3: the original id is kept verbatim', () {
    test('apply changes no event it was handed, and writes nothing back', () {
      final first = define(pro, 'Lasers', course: alpha, at: 1000);
      final second = define(recorder, 'Lasers', course: alpha, at: 2000);
      final f = finish(recorder, second.ulid, at: 3000);
      final events = [first, second, f];
      final before = [for (final e in events) e.toWire().toString()];
      final view = FleetMerge.of(events).apply(events);
      expect([for (final e in events) e.toWire().toString()], before);
      expect(fleetOf(f), second.ulid, reason: 'the stored event names its own fleet');
      final read = view.singleWhere((e) => e.ulid == f.ulid);
      expect({...read.toWire()}..remove('payload'), {...f.toWire()}..remove('payload'),
          reason: 'only the fleet it is read under differs');
    });

    test('with nothing merged, apply hands back the very list it was given', () {
      final events = [define(pro, 'Lasers', at: 1000), define(recorder, 'Optimists', at: 2000)];
      expect(identical(FleetMerge.of(events).apply(events), events), isTrue);
      expect(FleetMerge.of(events).merges, isFalse);
    });
  });

  group('criterion 4: one name on two race areas is two fleets, flagged', () {
    test('never merged across race areas, and every fleet of the name names the others', () {
      final onAlpha = define(pro, 'Lasers', course: alpha, at: 1000);
      final onBravo = define(recorder, 'Lasers', course: bravo, at: 2000);
      final merge = FleetMerge.of([onAlpha, onBravo]);
      expect([merge.resolve(onAlpha.ulid), merge.resolve(onBravo.ulid)], [onAlpha.ulid, onBravo.ulid]);
      expect([merge.conflicted(onAlpha.ulid), merge.conflicted(onBravo.ulid)], [true, true]);
      expect([merge.conflictingCourses(onAlpha.ulid), merge.conflictingCourses(onBravo.ulid)], [
        {bravo},
        {alpha},
      ]);
    });

    test('a fleet naming no race area joins neither, and is flagged with both', () {
      final onAlpha = define(pro, 'Lasers', course: alpha, at: 1000);
      final onBravo = define(recorder, 'Lasers', course: bravo, at: 2000);
      final none = define(mark, 'Lasers', at: 3000);
      final merge = FleetMerge.of([onAlpha, onBravo, none]);
      expect(merge.resolve(none.ulid), none.ulid);
      expect(merge.conflictingCourses(none.ulid), {alpha, bravo});
    });

    test('each race area still merges its own', () {
      final a1 = define(pro, 'Lasers', course: alpha, at: 1000);
      final a2 = define(mark, 'Lasers', course: alpha, at: 1500);
      final b = define(recorder, 'Lasers', course: bravo, at: 2000);
      final merge = FleetMerge.of([a1, a2, b]);
      expect([merge.resolve(a2.ulid), merge.resolve(b.ulid)], [a1.ulid, b.ulid]);
      expect(merge.conflictingCourses(a2.ulid), {bravo});
    });
  });

  group('criterion 5: two fleets with different names stay separate', () {
    test('Lasers and Lasers 2 are two fleets', () {
      final lasers = define(pro, 'Lasers', course: alpha, at: 1000);
      final lasers2 = define(recorder, 'Lasers 2', course: alpha, at: 2000);
      final merge = FleetMerge.of([lasers, lasers2]);
      expect([merge.resolve(lasers.ulid), merge.resolve(lasers2.ulid)], [lasers.ulid, lasers2.ulid]);
      expect(merge.merges, isFalse);
    });
  });
}
