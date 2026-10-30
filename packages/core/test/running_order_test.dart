import 'package:pro_companion_core/core.dart';
import 'package:test/test.dart';

/// #68 in the core: the edges of the running-order rule that the committed
/// vectors (running_order_vectors_test.dart) do not carry. The vectors are
/// the rule's statement; these are its corners.
void main() {
  /// 2026-10-24 12:00 UTC: inside one local date in every time zone.
  const noon = 1792843200000;
  const now = noon + 30 * 60 * 1000;
  const minute = 60 * 1000;
  const pro = '01K0PR0PH0NE00000000000000';
  const mark1 = '01K0MARK1PH0NE000000000001';
  const mark2 = '01K0MARK2PH0NE000000000002';

  var n = 0;
  final seqs = <String, int>{};
  EventEnvelope ev(String device, int at, String kind, {Map<String, Object?> payload = const {}, String? corrects}) =>
      EventEnvelope(
        ulid: '01K8${(++n).toString().padLeft(22, '0')}',
        deviceId: device,
        seq: seqs[device] = (seqs[device] ?? 0) + 1,
        deviceTs: at,
        kind: kind,
        correctsUlid: corrects,
        payload: payload,
        source: 'tap',
        payloadVersion: 1,
      );

  EventEnvelope station(String device, String mark, int at) =>
      ev(device, at, StationKinds.selected, payload: {'mark': mark});
  EventEnvelope round(String device, String sail, int at, {String mark = 'mark_1', String? fleet, String? race}) =>
      ev(device, at, RoundingKinds.rounding, payload: {'fleet': fleet, 'sail': sail, 'mark': mark, 'race': race, 'lap': 1});

  List<String> order(Iterable<EventEnvelope> events, {String? fleet}) =>
      [for (final e in runningOrder(events, fleet: fleet, now: now).entries) e.sail];

  setUp(() {
    n = 0;
    seqs.clear();
  });

  test('a general recall ends the race: the next race is the race of the day until the next gun', () {
    final gun = ev(pro, noon, StartKinds.start, payload: {'fleet': null});
    final events = [
      gun,
      round(mark1, '887', noon + 10 * minute, race: gun.ulid),
      ev(pro, noon + 11 * minute, StartKinds.generalRecall, payload: {'fleet': null}),
      round(mark1, '412', noon + 12 * minute),
    ];
    final o = runningOrder(events, fleet: null, now: now);
    expect([o.race, order(events)], [null, ['412']],
        reason: "887 named the recalled gun's race; 412 is the race of the day");
  });

  test("a gun the PRO corrected by hand: the corrected time is the race's start", () {
    final gun = ev(pro, noon, StartKinds.start, payload: {'fleet': null});
    final events = [
      gun,
      ev(pro, noon + minute, StartKinds.timeCorrected, corrects: gun.ulid, payload: {'time': noon + 5 * minute}),
      round(mark1, '887', noon + 3 * minute), // before the corrected gun
      round(mark1, '412', noon + 8 * minute),
    ];
    expect(order(events), ['412']);
  });

  test("another fleet's rounding at a mark leaves that mark waiting for this fleet", () {
    final events = [
      station(mark1, 'mark_1', noon - 5 * minute),
      round(mark1, '887', noon + 10 * minute, fleet: 'f2'),
    ];
    expect(runningOrder(events, fleet: 'f1', now: now).waiting, ['mark_1']);
    expect(runningOrder(events, fleet: 'f2', now: now).waiting, isEmpty);
  });

  test("a phone's latest station counts, and waiting marks come in the standard set's order", () {
    // Leeward and the gate sort differently by name than in the set, so an
    // alphabetical sort fails here (#68's review: the first fixture's marks
    // agreed in both orders).
    final events = [
      station(mark1, 'offset', noon - 9 * minute),
      station(mark1, 'mark_1', noon - 8 * minute),
      station(mark2, 'windward', noon - 7 * minute),
      station('01K0MARK3PH0NE000000000003', 'mark_2', noon - 6 * minute),
      station('01K0MARK4PH0NE000000000004', 'leeward', noon - 5 * minute),
      station('01K0GATEAPH0NE000000000005', 'gate_left', noon - 4 * minute),
    ];
    expect(stationedMarks(events, now: now), {'mark_1', 'windward', 'mark_2', 'leeward', 'gate_left'});
    expect(runningOrder(events, fleet: null, now: now).waiting, ['mark_1', 'mark_2', 'windward', 'leeward', 'gate_left']);
  });

  test("yesterday's station is no mark today, held role picks or not (#68's review)", () {
    final yesterday = noon - 24 * 60 * minute;
    final events = [
      station(mark1, 'mark_2', yesterday),
      ev(mark2, yesterday, RoleKinds.assigned, payload: {'role': 'mark_boat'}),
      station(mark2, 'mark_3', yesterday + minute),
      station('01K0MARK3PH0NE000000000003', 'mark_4', noon - minute),
    ];
    expect(stationedMarks(events, now: now), {'mark_4'});
  });

  test('on one phone, boats level are in the order it tapped them, across its clock set back', () {
    final a = round(mark1, '412', noon + 10 * minute);
    final events = [
      a,
      ev(mark1, noon + 8 * minute, ClockKinds.changed),
      round(mark1, '887', noon + 8 * minute + 10000),
    ];
    final o = runningOrder(events, fleet: null, now: now);
    expect([order(events), o.clocksUnmatched], [['412', '887'], false]);
  });

  test("a boat's latest rounding on one phone is the one it logged last, across a clock set back", () {
    final first = round(mark1, '887', noon + 10 * minute);
    final second = round(mark1, '887', noon + 8 * minute);
    final events = [first, ev(mark1, noon + 7 * minute, ClockKinds.changed), second];
    final entry = runningOrder(events, fleet: null, now: now).entries.single;
    expect([entry.roundings, entry.last.ulid], [2, second.ulid]);
  });

  test("on unmatched clocks across phones, each phone's own boats keep its tap order (#68's second review)", () {
    final events = [
      round(mark1, '412', noon + 10 * minute, mark: 'gate_left'),
      ev(mark1, noon + 4 * minute, ClockKinds.changed), // phone A's clock set back
      round(mark1, '887', noon + 5 * minute + 10000, mark: 'gate_left'),
      round(mark2, '5', noon + 7 * minute, mark: 'gate_right'),
    ];
    final o = runningOrder(events, fleet: null, now: now);
    expect([order(events), o.clocksUnmatched], [['412', '5', '887'], true],
        reason: "by the clocks 887, 5, 412; phone A's own two back in its tap order, in the places they hold");
  });

  test("a boat's latest rounding: each phone's last logged, then the latest of those by clock (#68's second review)",
      () {
    // On phone A the second rounding is stamped before the first; phone B's
    // falls between them by the clocks.
    final a1 = round(mark1, '887', noon + 20 * minute);
    final a2 = round(mark1, '887', noon + 10 * minute);
    final b1 = round(mark2, '887', noon + 15 * minute, mark: 'mark_2');
    final entry = runningOrder([a1, a2, b1], fleet: null, now: now).entries.single;
    expect([entry.roundings, entry.last.ulid], [3, b1.ulid],
        reason: "A's latest is a2 (logged last); of a2 and b1, b1 is later by the clocks");
    expect(a2.ulid, isNot(a1.ulid));
  });

  test("a phone with no role picks held keeps the station it picked last, by its own order (#68's second review)",
      () {
    final events = [
      station(mark1, 'mark_1', noon - 2 * minute),
      station(mark1, 'mark_2', noon - 5 * minute), // picked later, after its clock was set back
    ];
    expect(stationedMarks(events, now: now), {'mark_2'});
  });

  test('on a day of fleets, roundings with no fleet that only an unnamed boat holds still show (#68\'s second review)',
      () {
    final lasers = ev(pro, noon - 30 * minute, FleetKinds.defined, payload: {'name': 'Lasers', 'class': null});
    final events = [lasers, ev(mark1, noon + 10 * minute, RoundingKinds.rounding,
        payload: {'fleet': null, 'sail': null, 'mark': 'mark_1', 'race': null, 'lap': null})];
    final all = runningOrders(events, now: now);
    expect([for (final o in all) o.fleet], [lasers.ulid, null]);
    expect([all.last.entries, all.last.unnamed], [isEmpty, 1]);
  });

  test("an undone or yesterday's rounding with no fleet leaves no empty no-fleet order (#68's review)", () {
    final lasers = ev(pro, noon - 30 * minute, FleetKinds.defined, payload: {'name': 'Lasers', 'class': null});
    final undone = round(mark1, '887', noon + 10 * minute);
    final events = [
      lasers,
      round(mark1, '412', noon - 24 * 60 * minute),
      undone,
      ev(mark1, noon + 11 * minute, RoundingKinds.undo, corrects: undone.ulid),
    ];
    expect([for (final o in runningOrders(events, now: now)) o.fleet], [lasers.ulid]);
  });

  test('boats on different counts are never flagged, however many phones: only a level place rests on two clocks', () {
    final events = [
      round(mark1, '887', noon + 10 * minute),
      round(mark1, '412', noon + 10 * minute + 5000),
      round(mark2, '887', noon + 18 * minute, mark: 'mark_2'),
    ];
    final o = runningOrder(events, fleet: null, now: now);
    expect([order(events), o.clocksUnmatched], [['887', '412'], false]);
  });

  test('two boats level across phones with no offsets at all are flagged and kept in raw order', () {
    final events = [
      round(mark1, '887', noon + 10 * minute, mark: 'gate_left'),
      round(mark2, '412', noon + 10 * minute + 1000, mark: 'gate_right'),
    ];
    final o = runningOrder(events, fleet: null, now: now);
    expect([order(events), o.clocksUnmatched], [['887', '412'], true]);
  });

  test('an offset recorded after a rounding never applies to it', () {
    final a = round(mark1, '887', noon + 10 * minute, mark: 'gate_left');
    final b = round(mark2, '412', noon + 10 * minute + 1000, mark: 'gate_right');
    final events = [
      a,
      b,
      ev(mark1, noon + 11 * minute, ClockKinds.offset, payload: {'offset_ms': 5000}),
      ev(mark2, noon + 11 * minute, ClockKinds.offset, payload: {'offset_ms': 0}),
    ];
    expect(runningOrder(events, fleet: null, now: now).clocksUnmatched, isTrue,
        reason: 'both offsets came after the roundings, so neither phone had one in force');
  });

  test('a fleet with no roundings yet has an empty order, and names every stationed mark as waiting', () {
    final events = [
      ev(pro, noon - 30 * minute, FleetKinds.defined, payload: {'name': 'Lasers', 'class': null}),
      station(mark1, 'mark_1', noon - 5 * minute),
    ];
    final all = runningOrders(events, now: now);
    expect(all, hasLength(1), reason: 'one defined fleet, and no rounding names no fleet');
    expect([all.single.fleet, all.single.entries, all.single.waiting], [events.first.ulid, isEmpty, ['mark_1']]);
  });

  test("roundings that name no fleet on a day that defines fleets are their own order, last", () {
    final lasers = ev(pro, noon - 30 * minute, FleetKinds.defined, payload: {'name': 'Lasers', 'class': null});
    final events = [lasers, round(mark1, '887', noon + 10 * minute)];
    final all = runningOrders(events, now: now);
    expect([for (final o in all) o.fleet], [lasers.ulid, null]);
    expect([for (final e in all.last.entries) e.sail], ['887']);
  });

  test("the reading phone's date decides the race of the day", () {
    final events = [round(mark1, '887', noon + 10 * minute)];
    expect(runningOrder(events, fleet: null, now: now + 24 * 60 * minute).entries, isEmpty,
        reason: "read the next day, yesterday's rounding is in no race");
  });
}
