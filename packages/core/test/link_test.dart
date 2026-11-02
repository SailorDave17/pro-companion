import 'dart:convert';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

import 'support.dart';

/// #33, the core's half: what an event from race-timer is logged as, through
/// the real store. The contract is ADR 004's. FakeCore is held to the same
/// rules at the end, so a widget test cannot pass on a rule the phone lacks.
/// The Android half is integration_test/race_timer_link.sh, and the screen's
/// half is the app's test/sequence_link_test.dart.
void main() {
  late String path;
  late EventStore store;
  late int now;

  setUp(() {
    now = DateTime(2026, 11, 1, 14).millisecondsSinceEpoch;
    path = tempDbPath();
    store = openStore(path, clock: () => now);
  });

  List<EventEnvelope> log() => store.readAll();

  /// What race-timer logged here, the copies a fix made included.
  List<EventEnvelope> linked() => [for (final e in log()) if (e.source == raceTimerSource) e];

  /// What still stands of what race-timer logged for [fleet].
  List<EventEnvelope> standing(String? fleet) {
    final undone = {for (final e in log()) if (e.kind == StartKinds.undo) e.correctsUlid};
    return [for (final e in linked()) if (fleetOf(e) == fleet && !undone.contains(e.ulid)) e];
  }

  String body(String ulid) =>
      store.debugDatabase.select('SELECT body FROM events WHERE ulid = ?', [ulid]).single['body'] as String;

  String contract(String kind, String id, {int? at, String sequence = 'seq-1', Map<String, Object?> fields = const {}}) =>
      jsonEncode({'v': 1, 'id': id, 'kind': kind, 'at_ms': at ?? now, 'sequence': sequence, ...fields});

  /// Delivers one contract event, received now, then moves the clock on a
  /// second.
  LinkAnswer send(String kind, String id, {int? at, String sequence = 'seq-1', Map<String, Object?> fields = const {}}) {
    final answer = store.receiveLink(contract(kind, id, at: at, sequence: sequence, fields: fields), receivedMs: now);
    now += 1000;
    return answer;
  }

  String fleet(String name) => store.append(FleetEvents.define(name)).ulid;

  void select(String fleet) => store.append(FleetEvents.select(fleet));

  EventEnvelope gunOf(String sequence) =>
      linked().lastWhere((e) => e.kind == StartKinds.start && e.payload[linkSequenceKey] == sequence);

  /// Holds sequence number [seq], so whatever reaches it cannot be stored.
  void blockSeq(int seq) => store.debugDatabase.execute(
      'INSERT INTO events (ulid, device_id, seq, device_ts, body) VALUES (?, ?, ?, ?, ?)',
      ['01J8${'9'.padLeft(22, '0')}', store.deviceId, seq, 1, '{}']);

  /// What blocked it goes, which only a test reaching past the core can do.
  void unblock() {
    store.debugDatabase.execute('DROP TRIGGER events_no_delete');
    store.debugDatabase.execute("DELETE FROM events WHERE ulid = '01J8${'9'.padLeft(22, '0')}'");
  }

  int nextSeq() => log().where((e) => e.deviceId == store.deviceId).length + 1;

  void expectIntactChain() =>
      expect(verifyChains(store.readCanonical()).values.single, const ChainVerdict.intact());

  group('criterion 1: one event per emission, source race-timer, its time verbatim and the receipt time', () {
    const logged = {
      LinkContract.sequenceStart: StartKinds.sequenceStart,
      LinkContract.signal: StartKinds.signal,
      LinkContract.postponement: StartKinds.postponement,
      LinkContract.individualRecall: StartKinds.individualRecall,
      LinkContract.generalRecall: StartKinds.generalRecall,
      LinkContract.start: StartKinds.start,
    };

    for (final MapEntry(key: kind, value: stored) in logged.entries) {
      test('$kind is logged as one $stored', () {
        final lasers = fleet('Lasers');
        select(lasers);
        final at = now - 40;
        final receivedAt = now - 29;
        final text = contract(kind, 'evt-1', at: at, fields: {'seconds_to_start': 60});

        final answer = store.receiveLink(text, receivedMs: receivedAt);

        expect([answer.status, answer.stored, answer.reason], [LinkContract.accepted, true, null]);
        final event = linked().single;
        expect(event.kind, stored);
        expect(event.deviceTs, now, reason: 'device_ts is the commit');
        expect(event.payload, {
          fleetPayloadKey: lasers,
          linkAtKey: at,
          linkReceivedKey: receivedAt,
          linkSequenceKey: 'seq-1',
          linkFieldsKey: jsonDecode(text),
          if (kind == LinkContract.individualRecall) 'start': null,
        });
        final others = [for (final e in log()) if (e.source != raceTimerSource) e.kind];
        expect(others, [FleetKinds.defined, FleetKinds.selected, if (kind == LinkContract.start) ClockKinds.offset],
            reason: 'one event per emission, and a gun brings its clock offset as a manual gun does');
      });
    }

    test('a day of every kind stores one event per emission, in the order they came', () {
      const day = [
        LinkContract.sequenceStart,
        LinkContract.signal,
        LinkContract.signal,
        LinkContract.postponement,
        LinkContract.start,
        LinkContract.individualRecall,
        LinkContract.generalRecall,
      ];
      for (final (i, kind) in day.indexed) {
        expect(send(kind, 'evt-$i').stored, isTrue, reason: kind);
      }
      expect(linked().map((e) => e.kind), [for (final k in day) logged[k]]);
    });

    test('a held event: told at T and committed later, it reads T, with race-timer\'s time apart from both', () {
      const heldMs = 30 * 1000;
      final told = now;
      final fired = told - 11;
      now += heldMs;
      store.receiveLink(contract(LinkContract.signal, 'evt-1', at: fired), receivedMs: told);

      final event = linked().single;
      expect(event.payload[linkReceivedKey], told);
      expect(event.payload[linkAtKey], fired);
      expect(event.deviceTs, told + heldMs);
    });

    test("a time the phone's clock would never have given is kept exactly", () {
      const at = 1793000000123;
      send(LinkContract.start, 'evt-1', at: at);
      expect(linked().single.payload[linkAtKey], at);
      expect(firedAt(linked().single), at);
    });

    test('the contract object is kept whole under payload.link, fields no version knows included', () {
      const fields = {'sequence_name': '5-4-1-0', 'x_emit_ns': 123456, 'added_later': {'deep': [1, 'two', null]}};
      final text = contract(LinkContract.sequenceStart, 'evt-1', fields: fields);
      store.receiveLink(text, receivedMs: now);
      expect(linked().single.payload[linkFieldsKey], jsonDecode(text));
    });

    test('an unknown field named fleet, mark, race or lap changes nothing about the event', () {
      final lasers = fleet('Lasers');
      final other = fleet('420s');
      select(lasers);
      const stray = ['mark', 'race', 'lap'];
      send(LinkContract.start, 'evt-1', fields: {fleetPayloadKey: other, for (final k in stray) k: 'stray'});

      final event = linked().single;
      expect(fleetOf(event), lasers, reason: 'the field stays inside the contract object');
      for (final k in stray) {
        expect(event.payload.containsKey(k), isFalse, reason: k);
      }
      expect(event.payload[linkFieldsKey], containsPair(fleetPayloadKey, other));
      expect(elapsedAnchor(log(), other), isNull);
      expect(elapsedAnchor(log(), lasers)?.ulid, event.ulid);
    });

    test('a kind this version does not know is logged as a signal, moves no anchor, and keeps its own name', () {
      send('wind_shift', 'evt-1');
      final event = linked().single;
      expect(event.kind, StartKinds.signal);
      expect((event.payload[linkFieldsKey] as Map)['kind'], 'wind_shift');
      expect(elapsedAnchor(log(), null), isNull);
      expect(sequenceOf(log(), null), isEmpty);
    });

    test('sequence_start and signal stay out of the sequence, so the card never reads one as a recall', () {
      send(LinkContract.sequenceStart, 'evt-1');
      send(LinkContract.signal, 'evt-2');
      expect(sequenceOf(log(), null), isEmpty);
      expect(StartKinds.all, containsAll([StartKinds.sequenceStart, StartKinds.signal]));
      expect(StartKinds.sequence, isNot(contains(StartKinds.signal)));
      expect(EventKinds.all, containsAll([StartKinds.sequenceStart, StartKinds.signal]));
    });
  });

  group('criterion 2: an event id delivered twice stores one event', () {
    test('the second delivery is accepted and stores nothing', () {
      final first = send(LinkContract.signal, 'evt-1');
      final count = store.count();
      final second = send(LinkContract.signal, 'evt-1');
      expect([first.status, first.stored], [LinkContract.accepted, true]);
      expect([second.status, second.stored], [LinkContract.accepted, false]);
      expect(store.count(), count);
    });

    test('the id decides, not the content: a retry with another time stores nothing', () {
      send(LinkContract.signal, 'evt-1', at: now);
      final at = linked().single.payload[linkAtKey];
      expect(send(LinkContract.signal, 'evt-1', at: now + 5000).stored, isFalse);
      expect(linked().single.payload[linkAtKey], at);
    });

    test('across a close and a reopen', () {
      send(LinkContract.start, 'evt-1');
      final count = store.count();
      store.close();
      store = openStore(path, clock: () => now, seed: 2);

      final retry = send(LinkContract.start, 'evt-1');
      expect([retry.status, retry.stored], [LinkContract.accepted, false]);
      expect(store.count(), count);
    });

    test('a retry after the original was undone brings nothing back', () {
      send(LinkContract.start, 'evt-1');
      final gun = gunOf('seq-1');
      store.append(StartEvents.undo(gun.ulid));
      final count = store.count();

      final retry = send(LinkContract.start, 'evt-1');
      expect([retry.status, retry.stored], [LinkContract.accepted, false]);
      expect(store.count(), count);
      expect(elapsedAnchor(log(), null), isNull);
    });

    test('a retry after a re-log stores nothing, on either fleet', () {
      final lasers = fleet('Lasers');
      final fourTwenties = fleet('420s');
      select(lasers);
      send(LinkContract.start, 'evt-1');
      store.relogSequence('seq-1', fourTwenties);
      final count = store.count();

      final retry = send(LinkContract.start, 'evt-1');
      expect([retry.status, retry.stored], [LinkContract.accepted, false]);
      expect(store.count(), count);
      expect(standing(lasers), isEmpty);
    });
  });

  group('the event and its id land in one commit', () {
    /// A failure SQLite raises itself, between the event and its id's row.
    void failLinkInsert() => store.debugDatabase.execute('''
        CREATE TRIGGER link_event_fails BEFORE INSERT ON link_event
        BEGIN SELECT RAISE(ABORT, 'the disk went away'); END''');

    void restoreLinkInsert() => store.debugDatabase.execute('DROP TRIGGER link_event_fails');

    int idRows() => store.debugDatabase.select('SELECT 1 FROM link_event').length;

    test('a failure at the id leaves neither the event nor the row, and the retry stores it once', () {
      failLinkInsert();
      final text = contract(LinkContract.signal, 'evt-1');
      expect(() => store.receiveLink(text, receivedMs: now), throwsA(isA<sql.SqliteException>()));
      expect([store.count(), idRows()], [0, 0]);

      restoreLinkInsert();
      expect(store.receiveLink(text, receivedMs: now).stored, isTrue, reason: 'not told it was stored already');
      expect([store.count(), idRows()], [1, 1]);
      expect(linked().single.seq, 1, reason: 'the failed event gave its sequence number back');
      expectIntactChain();
    });

    test('a failure leaves memory as it was: the retry arms on the fleet selected now, as a first arrival', () {
      final lasers = fleet('Lasers');
      final fourTwenties = fleet('420s');
      select(lasers);
      failLinkInsert();
      final text = contract(LinkContract.sequenceStart, 'evt-1');
      expect(() => store.receiveLink(text, receivedMs: now), throwsA(anything));
      restoreLinkInsert();
      select(fourTwenties);

      store.receiveLink(text, receivedMs: now);
      expect(fleetOf(linked().single), fourTwenties, reason: 'nothing remembered the event that failed');
    });

    test('a gun failing after its offset leaves neither, and the retry joins afresh', () {
      final seq = nextSeq();
      blockSeq(seq + 1);
      final text = contract(LinkContract.start, 'evt-1');
      expect(() => store.receiveLink(text, receivedMs: now), throwsA(anything));
      expect([store.count(), idRows()], [1, 0], reason: 'the blocker alone');

      unblock();
      expect(store.receiveLink(text, receivedMs: now).stored, isTrue);
      expect(log().map((e) => e.kind), [ClockKinds.offset, StartKinds.start]);
      expect(log().map((e) => e.seq), [seq, seq + 1]);
      expect(elapsedAnchor(log(), null)?.ulid, gunOf('seq-1').ulid);
      expectIntactChain();
    });

    test('a late event of a sequence taken back fails whole: the event, its undo and the row', () {
      send(LinkContract.sequenceStart, 'evt-1');
      store.takeBackSequence('seq-1');
      final count = store.count();
      failLinkInsert();
      final text = contract(LinkContract.start, 'evt-2');
      expect(() => store.receiveLink(text, receivedMs: now), throwsA(anything));
      expect(store.count(), count);
      expect(idRows(), 1);
    });
  });

  group('link_event is append-only for every code path', () {
    Matcher refusedBy(String what) => throwsA(isA<sql.SqliteException>()
        .having((e) => e.message, 'message', contains('link_event is append-only: $what')));

    test('it refuses UPDATE, DELETE and a replacing INSERT', () {
      send(LinkContract.signal, 'evt-1');
      final db = store.debugDatabase;
      final before = db.select('SELECT * FROM link_event').toString();
      expect(before, isNot('[]'), reason: 'the fixture wrote a row to link_event');
      expect(() => db.execute('UPDATE link_event SET at = 0'), refusedBy('UPDATE refused'));
      expect(() => db.execute('DELETE FROM link_event'), refusedBy('DELETE refused'));
      expect(() => db.execute("INSERT OR REPLACE INTO link_event VALUES ('evt-1', 'x', 0)"),
          refusedBy('an existing row cannot be replaced'));
      expect(db.select('SELECT * FROM link_event').toString(), before);
    });

    test('its row names the id, the event it stored and when', () {
      send(LinkContract.signal, 'evt-1');
      final row = store.debugDatabase.select('SELECT * FROM link_event').single;
      expect([row['id'], row['ulid'], row['at']], ['evt-1', linked().single.ulid, linked().single.deviceTs]);
    });

    test('a log written before #33 gains the table when it opens', () {
      store.debugDatabase.execute('DROP TABLE link_event');
      store.close();
      store = openStore(path, clock: () => now, seed: 2);
      expect(send(LinkContract.signal, 'evt-1').stored, isTrue);
    });
  });

  group('what the log could not store is malformed, on the real store and on the fake alike', () {
    const good = {'v': 1, 'id': 'evt-1', 'kind': 'signal', 'at_ms': 1793000000000, 'sequence': 'seq-1'};

    Map<String, Object?> without(String key) => {...good}..remove(key);

    String withRaw(String field) => '{"v":1,"id":"evt-1","kind":"signal","at_ms":1793000000000,"sequence":"seq-1",$field}';

    final cases = <String, String>{
      'not JSON': '{not json',
      'an empty string': '',
      'a list, not an object': '[1, 2]',
      'a bare number, not an object': '12',
      'v absent': jsonEncode(without('v')),
      'v 2': jsonEncode({...good, 'v': 2}),
      'v 1.0': jsonEncode(good).replaceFirst('"v":1', '"v":1.0'),
      "v '1'": jsonEncode({...good, 'v': '1'}),
      'id absent': jsonEncode(without('id')),
      'id empty': jsonEncode({...good, 'id': ''}),
      'id numeric': jsonEncode({...good, 'id': 7}),
      'kind absent': jsonEncode(without('kind')),
      'at_ms absent': jsonEncode(without('at_ms')),
      'at_ms 1.5': jsonEncode({...good, 'at_ms': 1.5}),
      "at_ms '1'": jsonEncode({...good, 'at_ms': '1'}),
      'sequence absent': jsonEncode(without('sequence')),
      'sequence numeric': jsonEncode({...good, 'sequence': 7}),
      'a 2^53 at_ms': jsonEncode(good).replaceFirst('1793000000000', '9007199254740992'),
      'a lone surrogate in an unknown field': withRaw(r'"x_note":"\ud800"'),
      '1e400 in an unknown field': withRaw('"x_big":1e400'),
      'a 2^53 integer in an unknown field': withRaw('"x_emit_ns":9007199254740992'),
    };

    test('the good event these are made from is accepted', () {
      expect(store.receiveLink(jsonEncode(good), receivedMs: now).status, LinkContract.accepted);
      expect(store.receiveLink(withRaw('"x_note":"fine"').replaceFirst('evt-1', 'evt-2'), receivedMs: now).stored, isTrue);
      expect(store.receiveLink(jsonEncode(good).replaceFirst('evt-1', 'evt-3').replaceFirst('1793000000000', '9007199254740991'),
          receivedMs: now).stored, isTrue, reason: '2^53 - 1 is the last integer the log can hold');
    });

    for (final MapEntry(key: name, value: text) in cases.entries) {
      test('$name answers malformed and stores nothing', () async {
        final real = store.receiveLink(text, receivedMs: now);
        expect([real.status, real.stored], [LinkContract.malformed, false]);
        expect(real.reason, isNotNull, reason: 'it says why');
        expect(store.count(), 0);
        expect(store.debugDatabase.select('SELECT 1 FROM link_event'), isEmpty);

        final fake = FakeCore(clock: () => now);
        final answer = await fake.receiveLink(text, receivedMs: now);
        expect([answer.status, answer.stored], [LinkContract.malformed, false]);
        expect(await fake.count(), 0);
      });
    }

    test('a malformed event spends no id: the good one that follows under it is stored', () {
      final bad = jsonEncode({...good, 'at_ms': 1.5});
      store.receiveLink(bad, receivedMs: now);
      expect(store.receiveLink(jsonEncode(good), receivedMs: now).stored, isTrue);
    });
  });

  group('criterion 4, arming: a sequence takes the fleet selected when it first arrived', () {
    late String lasers;
    late String fourTwenties;

    setUp(() {
      lasers = fleet('Lasers');
      fourTwenties = fleet('420s');
    });

    test('the first event takes the selected fleet', () {
      select(fourTwenties);
      send(LinkContract.sequenceStart, 'evt-1');
      expect(fleetOf(linked().single), fourTwenties);
    });

    test('later events keep it after the selection moves', () {
      select(lasers);
      send(LinkContract.sequenceStart, 'evt-1');
      select(fourTwenties);
      send(LinkContract.signal, 'evt-2');
      send(LinkContract.start, 'evt-3');
      send(LinkContract.generalRecall, 'evt-4');
      expect(linked().map(fleetOf), everyElement(lasers));
      expect(elapsedAnchor(log(), fourTwenties), isNull);
    });

    test('a signal resent ahead of its sequence_start arms the sequence', () {
      select(lasers);
      send(LinkContract.signal, 'evt-2');
      select(fourTwenties);
      send(LinkContract.sequenceStart, 'evt-1');
      expect(linked().map(fleetOf), [lasers, lasers]);
    });

    test('the next sequence arms afresh', () {
      select(lasers);
      send(LinkContract.sequenceStart, 'evt-1');
      select(fourTwenties);
      send(LinkContract.sequenceStart, 'evt-2', sequence: 'seq-2');
      expect(linked().map(fleetOf), [lasers, fourTwenties]);
    });

    test('with no fleet selected the sequence carries none, and keeps none once one is', () {
      send(LinkContract.sequenceStart, 'evt-1');
      select(lasers);
      send(LinkContract.start, 'evt-2');
      expect(linked().map(fleetOf), [null, null]);
      expect(elapsedAnchor(log(), null)?.ulid, gunOf('seq-1').ulid);
    });

    test('its fleet survives a close and a reopen', () {
      select(lasers);
      send(LinkContract.sequenceStart, 'evt-1');
      store.close();
      store = openStore(path, clock: () => now, seed: 2);
      select(fourTwenties);

      send(LinkContract.start, 'evt-2');
      expect(linked().map(fleetOf), [lasers, lasers]);
    });

    test('a fleet that was never defined does not arm a sequence', () {
      select('01J8${'7'.padLeft(22, '0')}');
      send(LinkContract.sequenceStart, 'evt-1');
      expect(fleetOf(linked().single), isNull);
    });
  });

  group('individual_recall names its start', () {
    test('the gun of its sequence', () {
      send(LinkContract.start, 'evt-1');
      send(LinkContract.individualRecall, 'evt-2');
      final recall = linked().last;
      final gun = gunOf('seq-1');
      expect(recall.payload['start'], gun.ulid);
      expect(individualRecallsOf(log(), gun).map((e) => e.ulid), [recall.ulid]);
    });

    test('and its newest gun, when the first was undone', () {
      send(LinkContract.sequenceStart, 'evt-0');
      send(LinkContract.start, 'evt-1');
      final first = gunOf('seq-1');
      store.append(StartEvents.undo(first.ulid));
      send(LinkContract.start, 'evt-2');
      send(LinkContract.individualRecall, 'evt-3');
      final second = gunOf('seq-1');
      expect(second.ulid, isNot(first.ulid));
      expect(linked().last.payload['start'], second.ulid);
    });

    test('a manual anchor, when race-timer\'s gun was missed', () {
      final lasers = fleet('Lasers');
      select(lasers);
      send(LinkContract.sequenceStart, 'evt-1');
      final manual = store.append(StartEvents.start(fleet: lasers, source: 'manual'));
      send(LinkContract.individualRecall, 'evt-2');
      expect(linked().last.payload['start'], manual.ulid);
      expect(individualRecallsOf(log(), manual), hasLength(1));
    });

    test('and is found through the sequence when it arrived before the gun', () {
      send(LinkContract.individualRecall, 'evt-2');
      expect(linked().single.payload['start'], isNull);
      send(LinkContract.start, 'evt-1');
      final gun = gunOf('seq-1');
      expect(individualRecallsOf(log(), gun).map((e) => e.kind), [StartKinds.individualRecall]);
    });

    test("another sequence's recall with no gun named is not this gun's", () {
      send(LinkContract.individualRecall, 'evt-1', sequence: 'seq-2');
      send(LinkContract.start, 'evt-2');
      expect(individualRecallsOf(log(), gunOf('seq-1')), isEmpty);
    });

    // The anchor is a manual gun's only while race-timer's is missing, and a
    // recall that named it must not count again on race-timer's when it comes.
    test("a recall that named a manual gun is not counted again on race-timer's late gun", () {
      final lasers = fleet('Lasers');
      select(lasers);
      send(LinkContract.sequenceStart, 'evt-1');
      final manual = store.append(StartEvents.start(fleet: lasers, source: 'manual'));
      send(LinkContract.individualRecall, 'evt-2');
      send(LinkContract.start, 'evt-3');
      expect(elapsedAnchor(log(), lasers)!.ulid, gunOf('seq-1').ulid);
      expect(individualRecallsOf(log(), gunOf('seq-1')), isEmpty);
      expect(individualRecallsOf(log(), manual), hasLength(1));
    });

    // An anchor that fired before the sequence began is an earlier race's
    // gun, and race-timer's own was only late (#33's review).
    test("a recall before its gun, on a fleet's second race, names no earlier race's gun", () {
      final lasers = fleet('Lasers');
      final fourTwenties = fleet('420s');
      select(lasers);
      send(LinkContract.sequenceStart, 'evt-1');
      send(LinkContract.start, 'evt-2');
      final first = gunOf('seq-1');
      final began = now;
      send(LinkContract.sequenceStart, 'evt-3', sequence: 'seq-2');
      send(LinkContract.individualRecall, 'evt-5', sequence: 'seq-2');
      final recall = linked().last;
      expect(recall.payload['start'], isNull);

      send(LinkContract.start, 'evt-4', sequence: 'seq-2', at: began + 500);
      final second = gunOf('seq-2');
      expect(elapsedAnchor(log(), lasers)!.ulid, second.ulid);
      expect(individualRecallsOf(log(), second).map((e) => e.ulid), [recall.ulid]);
      expect(individualRecallsOf(log(), first), isEmpty);

      store.relogSequence('seq-2', fourTwenties);
      final copy = elapsedAnchor(log(), fourTwenties)!;
      expect(individualRecallsOf(log(), copy), hasLength(1), reason: 'the copy follows the moved gun');
      expect(individualRecallsOf(log(), first), isEmpty);
    });
  });

  group('criterion 3: a postponement or a recall is its own row, and the earlier start row is not modified', () {
    for (final kind in [LinkContract.postponement, LinkContract.generalRecall]) {
      test(kind, () {
        send(LinkContract.start, 'evt-1');
        final gun = gunOf('seq-1');
        final before = body(gun.ulid);
        final count = store.count();
        send(kind, 'evt-2');
        expect(store.count(), count + 1);
        expect(body(gun.ulid), before);
      });
    }

    test('a general recall clears the anchor, and a postponement leaves it', () {
      send(LinkContract.start, 'evt-1');
      send(LinkContract.postponement, 'evt-2');
      expect(elapsedAnchor(log(), null)?.ulid, gunOf('seq-1').ulid);
      send(LinkContract.generalRecall, 'evt-3');
      expect(elapsedAnchor(log(), null), isNull);
    });
  });

  group('criterion 5: a race-timer gun anchors exactly as a manual gun would', () {
    test('anchor, race state, clock offset and elapsed time, measured from race-timer\'s own time', () {
      final at = now - 15;
      send(LinkContract.start, 'evt-1', at: at);
      final gun = gunOf('seq-1');
      expect(elapsedAnchor(log(), null)?.ulid, gun.ulid);
      expect(anchorTime(log(), null), at);
      expect(raceState(log(), null), FleetRaceState(starts: 1, recalls: 0, anchorUlid: gun.ulid));
      final offset = log().singleWhere((e) => e.kind == ClockKinds.offset);
      expect([offset.payload['race'], offset.seq], [gun.ulid, gun.seq - 1]);

      now += 60000;
      final finish = store.append(FinishEvents.finish(fleet: null));
      final all = log();
      expect(crossPhoneElapsed(all, gun: gun, finish: finish).elapsedMs, finish.deviceTs - at);
    });

    test('undone, or overtaken by the next gun, the same as a manual gun', () {
      final at = now;
      final manual = store.append(StartEvents.start(fleet: null, source: 'manual'));
      send(LinkContract.start, 'evt-1');
      final gun = gunOf('seq-1');
      expect(elapsedAnchor(log(), null)?.ulid, gun.ulid);
      store.append(StartEvents.undo(gun.ulid));
      expect(elapsedAnchor(log(), null)?.ulid, manual.ulid);
      expect(anchorTime(log(), null), at);
    });
  });

  group('criterion 4, the fix: relogSequence moves a sequence to its right fleet in one commit', () {
    late String lasers;
    late String fourTwenties;
    late String optis;

    setUp(() {
      lasers = fleet('Lasers');
      fourTwenties = fleet('420s');
      optis = fleet('Optis');
      select(lasers);
    });

    /// A sequence that landed on Lasers, up to and past its gun.
    void sequence() {
      send(LinkContract.sequenceStart, 'evt-1');
      send(LinkContract.signal, 'evt-2');
      send(LinkContract.start, 'evt-3');
      send(LinkContract.postponement, 'evt-4');
    }

    group('what the PRO tapped on that fleet\'s card while it ran moves with it', () {
      test('a manual general recall: the moved gun does not anchor as if never recalled', () {
        send(LinkContract.sequenceStart, 'evt-1');
        send(LinkContract.start, 'evt-2');
        store.append(StartEvents.generalRecall(fleet: lasers, source: 'manual'));
        now += 1000;
        expect(elapsedAnchor(log(), lasers), isNull);

        store.relogSequence('seq-1', fourTwenties);

        expect(elapsedAnchor(log(), fourTwenties), isNull, reason: 'the recall moved with its gun');
        expect(sequenceOf(log(), lasers), isEmpty, reason: 'and left nothing behind');
        final moved = sequenceOf(log(), fourTwenties);
        expect(moved.map((e) => e.kind), [StartKinds.start, StartKinds.generalRecall]);
        expect(moved.last.source, 'manual', reason: 'it was tapped, and stays so');
      });

      test('a manual gun keeps the moment it was tapped, and what names it follows', () {
        send(LinkContract.sequenceStart, 'evt-1');
        final tappedAt = now;
        final gun = store.append(StartEvents.start(fleet: lasers, source: 'manual'));
        now += 1000;
        send(LinkContract.individualRecall, 'evt-2');
        now += 60000;

        store.relogSequence('seq-1', fourTwenties);

        final copy = elapsedAnchor(log(), fourTwenties)!;
        expect(copy.source, 'manual');
        expect(gunTime(log(), copy), tappedAt, reason: 'not the moment of the fix');
        expect(copy.deviceTs, now, reason: 'the copy was logged at the fix');
        expect(copy.payload[reloggedFromKey], gun.ulid);
        expect(individualRecallsOf(log(), copy), hasLength(1), reason: "race-timer's recall follows the gun it named");
      });

      test('a manual postponement moves too, in its place', () {
        send(LinkContract.sequenceStart, 'evt-1');
        store.append(StartEvents.postponement(fleet: lasers, source: 'manual'));
        now += 1000;
        send(LinkContract.start, 'evt-2');

        store.relogSequence('seq-1', fourTwenties);

        expect(sequenceOf(log(), fourTwenties).map((e) => e.kind), [StartKinds.postponement, StartKinds.start]);
      });

      test('what came before the sequence stays', () {
        final earlier = store.append(StartEvents.start(fleet: lasers, source: 'manual'));
        now += 1000;
        sequence();

        store.relogSequence('seq-1', fourTwenties);

        expect(sequenceOf(log(), lasers).map((e) => e.ulid), [earlier.ulid]);
      });

      test('the fleet\'s next race-timer sequence ends it, and what was tapped in that one stays', () {
        send(LinkContract.sequenceStart, 'evt-1');
        send(LinkContract.start, 'evt-2');
        send(LinkContract.sequenceStart, 'evt-3', sequence: 'seq-2');
        send(LinkContract.start, 'evt-4', sequence: 'seq-2');
        store.append(StartEvents.generalRecall(fleet: lasers, source: 'manual'));
        now += 1000;

        store.relogSequence('seq-1', fourTwenties);

        expect(sequenceOf(log(), fourTwenties).map((e) => e.kind), [StartKinds.start]);
        expect(sequenceOf(log(), lasers).map((e) => e.kind), [StartKinds.start, StartKinds.generalRecall]);
      });

      test('another fleet\'s tap in the same stretch stays', () {
        send(LinkContract.sequenceStart, 'evt-1');
        final other = store.append(StartEvents.generalRecall(fleet: optis, source: 'manual'));
        now += 1000;
        send(LinkContract.start, 'evt-2');

        store.relogSequence('seq-1', fourTwenties);

        expect(sequenceOf(log(), optis).map((e) => e.ulid), [other.ulid]);
      });

      test('a take-back takes them too', () {
        send(LinkContract.sequenceStart, 'evt-1');
        send(LinkContract.start, 'evt-2');
        store.append(StartEvents.generalRecall(fleet: lasers, source: 'manual'));
        now += 1000;

        store.takeBackSequence('seq-1');

        expect(sequenceOf(log(), lasers), isEmpty);
      });
    });

    test('the old fleet reads nothing of it, and the new fleet reads it whole', () {
      sequence();
      final before = linked().map((e) => e.kind).toList();
      store.relogSequence('seq-1', fourTwenties);

      expect(standing(lasers), isEmpty);
      expect(sequenceOf(log(), lasers), isEmpty);
      expect(elapsedAnchor(log(), lasers), isNull);
      expect(lastRaceTimerEvent(log(), fleet: lasers), isNull);
      expect(standing(fourTwenties).map((e) => e.kind), before);
      expect(sequenceOf(log(), fourTwenties).map((e) => e.kind), [StartKinds.start, StartKinds.postponement]);
      expect(elapsedAnchor(log(), fourTwenties)?.ulid, gunOf('seq-1').ulid);
    });

    test('race-timer\'s times, its sequence id and the source copy across, and each copy names its original', () {
      sequence();
      final originals = linked();
      final bodies = [for (final e in originals) body(e.ulid)];
      store.relogSequence('seq-1', fourTwenties);

      final copies = standing(fourTwenties);
      expect(copies, hasLength(originals.length));
      for (final (i, copy) in copies.indexed) {
        final original = originals[i];
        expect(copy.ulid, isNot(original.ulid));
        expect(copy.source, raceTimerSource);
        expect(copy.payload[reloggedFromKey], original.ulid);
        for (final key in [linkAtKey, linkReceivedKey, linkSequenceKey, linkFieldsKey]) {
          expect(copy.payload[key], original.payload[key], reason: key);
        }
        expect(body(original.ulid), bodies[i], reason: 'the original is kept as it landed');
      }
    });

    test('it undoes each original with a start.undo, and answers with everything it appended but the gun\'s offset', () {
      sequence();
      final originals = {for (final e in linked()) e.ulid};
      final before = {for (final e in log()) e.ulid};
      final appended = store.relogSequence('seq-1', fourTwenties);

      expect({for (final e in appended) if (e.kind == StartKinds.undo) e.correctsUlid}, originals);
      final added = [for (final e in log()) if (!before.contains(e.ulid)) e];
      expect(added.where((e) => e.kind != ClockKinds.offset).map((e) => e.ulid).toSet(), appended.map((e) => e.ulid).toSet());
    });

    test('a re-logged gun gets a fresh clock offset, naming the copy under the new fleet', () {
      sequence();
      final first = log().singleWhere((e) => e.kind == ClockKinds.offset);
      expect(first.payload['race'], gunOf('seq-1').ulid);
      store.relogSequence('seq-1', fourTwenties);

      final copy = gunOf('seq-1');
      final offset = log().singleWhere((e) => e.kind == ClockKinds.offset && e.payload['race'] == copy.ulid);
      expect(fleetOf(offset), fourTwenties);
      expect(offset.seq, copy.seq - 1);
    });

    test('a typed time follows the gun', () {
      send(LinkContract.start, 'evt-1');
      final gun = gunOf('seq-1');
      final typed = store.append(StartEvents.correctTime(gun.ulid, time: now - 90000));
      store.relogSequence('seq-1', fourTwenties);

      final copy = gunOf('seq-1');
      expect(gunTime(log(), copy), now - 90000);
      expect(anchorTime(log(), fourTwenties), now - 90000);
      final fix = log().lastWhere((e) => e.kind == StartKinds.timeCorrected);
      expect(fix.correctsUlid, copy.ulid, reason: 'remapped');
      expect(fix.payload[reloggedFromKey], typed.ulid);
    });

    test('OCS boats, their clearances and a manual individual recall follow, their ULIDs remapped', () {
      send(LinkContract.start, 'evt-1');
      final gun = gunOf('seq-1');
      final recall = store.append(StartEvents.individualRecall(gun.ulid, fleet: lasers, source: 'manual'));
      final over = store.append(StartEvents.ocs(gun.ulid, fleet: lasers, sail: '1234'));
      store.append(StartEvents.ocs(gun.ulid, fleet: lasers, sail: '887'));
      store.append(StartEvents.clearOcs(over.ulid));
      store.relogSequence('seq-1', fourTwenties);

      final copy = gunOf('seq-1');
      expect(ocsAt(log(), copy).map((o) => (o.sail, o.cleared)), [('1234', true), ('887', false)]);
      final moved = individualRecallsOf(log(), copy).single;
      expect([moved.source, fleetOf(moved), moved.payload['start'], moved.payload[reloggedFromKey]],
          ['manual', fourTwenties, copy.ulid, recall.ulid]);
      expect(ocsAt(log(), gun), isEmpty, reason: 'the undone gun keeps none');
      expect(log().where((e) => e.kind == StartKinds.ocs).map((e) => e.source), everyElement('manual'));
    });

    test('a race-timer individual recall follows too, naming the copy', () {
      send(LinkContract.start, 'evt-1');
      send(LinkContract.individualRecall, 'evt-2');
      store.relogSequence('seq-1', fourTwenties);
      expect(individualRecallsOf(log(), gunOf('seq-1')).map((e) => e.source), [raceTimerSource]);
    });

    test("what another fleet's gun carries stays where it is", () {
      final other = store.append(StartEvents.start(fleet: optis, source: 'manual'));
      final ocs = store.append(StartEvents.ocs(other.ulid, fleet: optis, sail: '5'));
      sequence();
      store.relogSequence('seq-1', fourTwenties);
      expect(ocsAt(log(), other).map((o) => o.ulid), [ocs.ulid]);
      expect(elapsedAnchor(log(), optis)?.ulid, other.ulid);
    });

    test('the phone switches to the right fleet', () {
      sequence();
      final appended = store.relogSequence('seq-1', fourTwenties);
      expect(selectedFleet(log(), store.deviceId), fourTwenties);
      expect(appended.first.kind, FleetKinds.selected);
    });

    test('no switch is logged when the phone is on the right fleet already', () {
      sequence();
      select(fourTwenties);
      final appended = store.relogSequence('seq-1', fourTwenties);
      expect(appended.where((e) => e.kind == FleetKinds.selected), isEmpty);
    });

    test('later signals follow it, wherever the phone has gone since', () {
      sequence();
      store.relogSequence('seq-1', fourTwenties);
      select(optis);
      send(LinkContract.signal, 'evt-5');
      expect(fleetOf(linked().last), fourTwenties);
    });

    test('it survives a close and a reopen: a later signal still finds the fixed fleet', () {
      sequence();
      store.relogSequence('seq-1', fourTwenties);
      store.close();
      store = openStore(path, clock: () => now, seed: 2);
      select(optis);
      send(LinkContract.signal, 'evt-5');
      expect(fleetOf(linked().last), fourTwenties);
    });

    test('the fleet it is already on appends nothing', () {
      sequence();
      final count = store.count();
      expect(store.relogSequence('seq-1', lasers), isEmpty);
      expect(store.count(), count);
    });

    test('a sequence this phone has nothing of appends nothing', () {
      final count = store.count();
      expect(store.relogSequence('seq-9', fourTwenties), isEmpty);
      expect(store.count(), count);
    });

    test('an undefined fleet is refused, and nothing moves', () {
      sequence();
      final count = store.count();
      expect(() => store.relogSequence('seq-1', '01J8${'7'.padLeft(22, '0')}'), throwsArgumentError);
      expect(store.count(), count);
    });

    test('one failing part way leaves nothing, and the fix can be run again', () {
      sequence();
      final originals = linked().map((e) => e.ulid).toList();
      final count = store.count();
      // The switch and the undos land, and the second copy cannot.
      blockSeq(nextSeq() + 1 + originals.length + 1);
      expect(() => store.relogSequence('seq-1', fourTwenties), throwsA(anything));
      expect(store.count(), count + 1, reason: 'the blocker alone');

      unblock();
      expect(store.count(), count);
      expect(standing(lasers).map((e) => e.ulid), originals);
      expect(standing(fourTwenties), isEmpty);
      expect(selectedFleet(log(), store.deviceId), lasers, reason: 'the switch went back out with the rest');

      // Memory went back too: what the failed fix undid there would hide the
      // gun from a recall arriving now.
      send(LinkContract.individualRecall, 'evt-5');
      expect(linked().last.payload['start'], gunOf('seq-1').ulid);

      expect(store.relogSequence('seq-1', fourTwenties), isNotEmpty);
      expect(standing(lasers), isEmpty);
      expect(standing(fourTwenties), hasLength(originals.length + 1));
      expectIntactChain();
    });

    test('a second fix works, and takes the dependents with it', () {
      send(LinkContract.start, 'evt-1');
      final gun = gunOf('seq-1');
      store.append(StartEvents.correctTime(gun.ulid, time: now - 5000));
      final ocs = store.append(StartEvents.ocs(gun.ulid, fleet: lasers, sail: '1234'));
      store.append(StartEvents.clearOcs(ocs.ulid));

      store.relogSequence('seq-1', fourTwenties);
      store.relogSequence('seq-1', optis);

      expect(standing(lasers), isEmpty);
      expect(standing(fourTwenties), isEmpty);
      final copy = gunOf('seq-1');
      expect(fleetOf(copy), optis);
      expect(gunTime(log(), copy), now - 5000);
      expect(ocsAt(log(), copy).map((o) => (o.sail, o.cleared)), [('1234', true)]);
      expect(selectedFleet(log(), store.deviceId), optis);
      expectIntactChain();
    });

    test('and it can go back to the fleet it came from', () {
      sequence();
      store.relogSequence('seq-1', fourTwenties);
      expect(store.relogSequence('seq-1', lasers), isNotEmpty);
      expect(standing(fourTwenties), isEmpty);
      expect(standing(lasers), hasLength(4));
    });

    test('over a real isolate, the fix and the fleet refusal both cross', () async {
      final core = await spawnCore(tempDbPath());
      addTearDown(() async {
        try {
          await core.close();
        } on Object {
          // Closed by the test.
        }
      });
      final from = await core.append(FleetEvents.define('Lasers'));
      final to = await core.append(FleetEvents.define('420s'));
      await core.append(FleetEvents.select(from.ulid));
      final answer = await core.receiveLink(contract(LinkContract.start, 'evt-1'), receivedMs: now);
      expect(answer.stored, isTrue);

      final moved = await core.relogSequence('seq-1', to.ulid);
      expect(moved.where((e) => e.kind == StartKinds.start).map(fleetOf), [to.ulid]);
      await expectLater(core.relogSequence('seq-1', '01J8${'7'.padLeft(22, '0')}'),
          throwsA(isA<CoreException>().having((e) => e.code, 'code', 'invalid')));
      expect(await core.takeBackSequence('seq-1'), isNotEmpty);
    });
  });

  group('takeBackSequence, for a sequence that should never have counted', () {
    late String lasers;

    setUp(() {
      lasers = fleet('Lasers');
      select(lasers);
    });

    test('an ordinary undo of all there is of a sequence is not a take-back: the rest of it counts', () {
      send(LinkContract.start, 'evt-1');
      store.append(StartEvents.undo(gunOf('seq-1').ulid));
      now += 1000;
      expect(sequenceOf(log(), lasers), isEmpty);

      send(LinkContract.start, 'evt-2');

      expect(elapsedAnchor(log(), lasers)?.ulid, gunOf('seq-1').ulid, reason: 'the gun fired again stands');
    });

    test('it undoes all of it, its dependents too, and leaves the phone on its fleet', () {
      send(LinkContract.sequenceStart, 'evt-1');
      send(LinkContract.start, 'evt-2');
      final ocs = store.append(StartEvents.ocs(gunOf('seq-1').ulid, fleet: lasers, sail: '7'));
      final appended = store.takeBackSequence('seq-1');

      expect(appended.map((e) => e.kind), everyElement(StartKinds.undo));
      expect(appended.map((e) => e.correctsUlid), contains(ocs.ulid));
      expect(standing(lasers), isEmpty);
      expect(elapsedAnchor(log(), lasers), isNull);
      expect(selectedFleet(log(), store.deviceId), lasers);
    });

    test('later events are stored and undone at once, one commit each, and a retry of one stores nothing', () {
      send(LinkContract.sequenceStart, 'evt-1');
      store.takeBackSequence('seq-1');
      final count = store.count();

      expect(send(LinkContract.signal, 'evt-2').stored, isTrue);
      expect(store.count(), count + 2);
      final late = linked().last;
      expect(log().where((e) => e.kind == StartKinds.undo && e.correctsUlid == late.ulid), hasLength(1));
      expect(send(LinkContract.signal, 'evt-2').stored, isFalse);
      expect(store.count(), count + 2);
    });

    test('a gun of it never anchors, and no event of it counts as a race', () {
      send(LinkContract.sequenceStart, 'evt-1');
      store.takeBackSequence('seq-1');
      send(LinkContract.start, 'evt-2');

      expect(linked().where((e) => e.kind == StartKinds.start), hasLength(1), reason: 'nothing goes missing');
      expect(elapsedAnchor(log(), lasers), isNull);
      expect(sequenceOf(log(), lasers), isEmpty);
      expect(lastRaceTimerEvent(log(), fleet: lasers), isNull);
      expect(anchorTime(log(), lasers), isNull);
    });

    test('that holds across a close and a reopen', () {
      send(LinkContract.sequenceStart, 'evt-1');
      store.takeBackSequence('seq-1');
      store.close();
      store = openStore(path, clock: () => now, seed: 2);
      send(LinkContract.start, 'evt-2');
      expect(elapsedAnchor(log(), lasers), isNull);
    });

    test('a later sequence is untouched', () {
      send(LinkContract.sequenceStart, 'evt-1');
      store.takeBackSequence('seq-1');
      send(LinkContract.sequenceStart, 'evt-2', sequence: 'seq-2');
      send(LinkContract.start, 'evt-3', sequence: 'seq-2');
      expect(elapsedAnchor(log(), lasers)?.ulid, gunOf('seq-2').ulid);
    });

    test('a sequence this phone has nothing of, or nothing left of, appends nothing', () {
      send(LinkContract.sequenceStart, 'evt-1');
      expect(store.takeBackSequence('seq-9'), isEmpty);
      store.takeBackSequence('seq-1');
      final count = store.count();
      expect(store.takeBackSequence('seq-1'), isEmpty);
      expect(store.relogSequence('seq-1', fleet('420s')), isEmpty, reason: 'nothing left to move');
      expect(store.count(), count + 1, reason: 'the fleet this test defined');
    });

    test('one failing part way leaves nothing', () {
      send(LinkContract.sequenceStart, 'evt-1');
      send(LinkContract.signal, 'evt-2');
      final count = store.count();
      blockSeq(nextSeq() + 1);
      expect(() => store.takeBackSequence('seq-1'), throwsA(anything));
      unblock();
      expect(store.count(), count);
      expect(standing(lasers), hasLength(2));
    });
  });

  group('the store and the fake core agree', () {
    test('one scenario through both: the same answers, kinds, fleets and order', () async {
      final fakeNow = _Clock(now);
      final realNow = _Clock(now);
      final fake = FakeCore(clock: () => fakeNow.ms);
      final real = openStore(tempDbPath(), clock: () => realNow.ms);

      Future<List<_Row>> run(_Phone phone) async {
        final a = await phone.append(FleetEvents.define('Lasers'));
        final b = await phone.append(FleetEvents.define('420s'));
        final c = await phone.append(FleetEvents.define('Optis'));
        final answers = <Object?>[];
        Future<void> link(String kind, String id, {String sequence = 'seq-1'}) async {
          final answer = await phone.receive(contract(kind, id, sequence: sequence));
          answers.add((answer.status, answer.stored));
        }

        await phone.append(FleetEvents.select(a.ulid));
        await link(LinkContract.sequenceStart, 'evt-1');
        await link(LinkContract.signal, 'evt-2');
        await phone.append(FleetEvents.select(b.ulid));
        await link(LinkContract.start, 'evt-3');
        await link(LinkContract.signal, 'evt-2');
        await link(LinkContract.individualRecall, 'evt-4');
        final gun = (await phone.read()).lastWhere((e) => e.kind == StartKinds.start);
        await phone.append(StartEvents.correctTime(gun.ulid, time: gun.deviceTs - 1000));
        final ocs = await phone.append(StartEvents.ocs(gun.ulid, fleet: a.ulid, sail: '7'));
        await phone.append(StartEvents.clearOcs(ocs.ulid));
        answers.add((await phone.relog('seq-1', c.ulid)).map((e) => e.kind).toList());
        answers.add((await phone.relog('seq-1', c.ulid)).length);
        await link(LinkContract.signal, 'evt-5');
        await link(LinkContract.generalRecall, 'evt-6');
        await phone.append(FleetEvents.select(b.ulid));
        await link(LinkContract.sequenceStart, 'evt-7', sequence: 'seq-2');
        answers.add((await phone.takeBack('seq-2')).length);
        await link(LinkContract.start, 'evt-8', sequence: 'seq-2');
        await link(LinkContract.signal, 'evt-8', sequence: 'seq-2');
        answers.add((await phone.takeBack('seq-9')).length);
        await link('wind_shift', 'evt-9', sequence: 'seq-3');
        answers.add((await phone.receive('[]')).status);

        final names = {a.ulid: 'Lasers', b.ulid: '420s', c.ulid: 'Optis'};
        final all = [...await phone.read()]..sort((x, y) => x.seq.compareTo(y.seq));
        final ordinal = {for (final (i, e) in all.indexed) e.ulid: i};
        return [
          for (final e in all)
            _Row(e.kind, e.source, names[e.payload[fleetPayloadKey]], e.payload[linkAtKey], e.payload[linkReceivedKey],
                e.payload[linkSequenceKey], ordinal[e.correctsUlid], ordinal[e.payload['start']],
                ordinal[e.payload[reloggedFromKey]]),
          _Row('answers', '$answers', null, null, null, null, null, null, null),
        ];
      }

      final onFake = await run(_Phone(
        fake.append,
        (t) => fake.receiveLink(t, receivedMs: 42),
        fake.relogSequence,
        fake.takeBackSequence,
        fake.readOwn,
        fakeNow.tick,
      ));
      final onStore = await run(_Phone(
        (e) async => real.append(e),
        (t) async => real.receiveLink(t, receivedMs: 42),
        (s, f) async => real.relogSequence(s, f),
        (s) async => real.takeBackSequence(s),
        () async => real.readOwn(),
        realNow.tick,
      ));

      expect(onStore, hasLength(greaterThan(20)), reason: 'the scenario reached the log');
      expect(onFake.map((r) => r.toString()).toList(), onStore.map((r) => r.toString()).toList());
    });
  });

  group('criterion 9, the rule: linkActive', () {
    EventEnvelope received(int receivedMs, {String? deviceId, Map<String, Object?> extra = const {}, bool stamped = true}) =>
        EventEnvelope(
          ulid: '01J8${'1'.padLeft(22, '0')}',
          deviceTs: receivedMs,
          deviceId: deviceId ?? store.deviceId,
          seq: 1,
          source: raceTimerSource,
          kind: StartKinds.signal,
          payloadVersion: 1,
          payload: {if (stamped) linkReceivedKey: receivedMs, linkSequenceKey: 'seq-1', ...extra},
        );

    bool activeAt(List<EventEnvelope> events, int at) => linkActive(events, deviceId: store.deviceId, now: at);

    test('active at 9:59.999 since the last arrival, and not at 10:00.000', () {
      send(LinkContract.signal, 'evt-1');
      final at = linked().single.payload[linkReceivedKey] as int;
      expect(linkQuietMs, 600000, reason: 'the owner\'s ten minutes');
      expect(activeAt(log(), at + 599999), isTrue);
      expect(activeAt(log(), at + 600000), isFalse);
    });

    test('it counts from the receipt, not the commit or race-timer\'s clock', () {
      final told = now;
      now += 30 * 60000;
      store.receiveLink(contract(LinkContract.signal, 'evt-1', at: told + 3 * 3600000), receivedMs: told);
      expect(activeAt(log(), told + 599999), isTrue);
      expect(activeAt(log(), now), isFalse, reason: 'an event held half an hour says nothing about the link now');
    });

    test('nothing from race-timer is not active', () {
      store.append(StartEvents.start(fleet: null, source: 'manual'));
      expect(activeAt(log(), now), isFalse);
      expect(activeAt(const [], now), isFalse);
    });

    test('a receipt ahead of the clock is not active: the clock was set back, and it says nothing', () {
      expect(activeAt([received(now + 1)], now), isFalse);
      expect(activeAt([received(now)], now), isTrue, reason: 'the edge of the same rule');
    });

    test("another device's event says nothing about this phone's link", () {
      expect(activeAt([received(now, deviceId: '01J8${'2'.padLeft(22, '0')}')], now), isFalse);
    });

    test('an undone event still arrived, so it counts', () {
      send(LinkContract.signal, 'evt-1');
      store.append(StartEvents.undo(linked().single.ulid));
      expect(activeAt(log(), now), isTrue);
    });

    test('a retry that stored nothing counts for nothing', () {
      send(LinkContract.signal, 'evt-1');
      final at = linked().single.payload[linkReceivedKey] as int;
      now = at + linkQuietMs;
      send(LinkContract.signal, 'evt-1');
      expect(activeAt(log(), now), isFalse);
    });

    test('a fix wakes nothing: a copy keeps when its original arrived', () {
      final lasers = fleet('Lasers');
      final fourTwenties = fleet('420s');
      select(lasers);
      send(LinkContract.signal, 'evt-1');
      final at = linked().single.payload[linkReceivedKey] as int;
      now = at + linkQuietMs - 1;
      store.relogSequence('seq-1', fourTwenties);
      expect(activeAt(log(), at + linkQuietMs), isFalse, reason: 'moved a minute ago, last arrived ten ago');
    });

    test('an event with no receipt stamp counts from its commit', () {
      expect(activeAt([received(now, stamped: false)], now + linkQuietMs - 1), isTrue);
      expect(activeAt([received(now, stamped: false)], now + linkQuietMs), isFalse);
    });

    test('a manual event is never the link, however new', () {
      final manual = EventEnvelope(
        ulid: '01J8${'1'.padLeft(22, '0')}',
        deviceTs: now,
        deviceId: store.deviceId,
        seq: 1,
        source: 'manual',
        kind: StartKinds.start,
        payloadVersion: 1,
        payload: {linkReceivedKey: now},
      );
      expect(activeAt([manual], now), isFalse);
    });
  });

  group('lastRaceTimerEvent, what UNDO LAST reaches a sequence through', () {
    late String lasers;
    late String fourTwenties;

    setUp(() {
      lasers = fleet('Lasers');
      fourTwenties = fleet('420s');
    });

    test('the newest of its fleet, a signal included, and none of another fleet\'s', () {
      select(lasers);
      send(LinkContract.sequenceStart, 'evt-1');
      send(LinkContract.signal, 'evt-2');
      final last = linked().last;
      select(fourTwenties);
      send(LinkContract.sequenceStart, 'evt-3', sequence: 'seq-2');

      expect(lastRaceTimerEvent(log(), fleet: lasers)?.ulid, last.ulid);
      expect(lastRaceTimerEvent(log(), fleet: fourTwenties)?.ulid, linked().last.ulid);
    });

    test('it skips what is undone', () {
      select(lasers);
      send(LinkContract.sequenceStart, 'evt-1');
      final first = linked().single;
      send(LinkContract.signal, 'evt-2');
      store.append(StartEvents.undo(linked().last.ulid));
      expect(lastRaceTimerEvent(log(), fleet: lasers)?.ulid, first.ulid);
      store.append(StartEvents.undo(first.ulid));
      expect(lastRaceTimerEvent(log(), fleet: lasers), isNull);
    });

    test('a manual event is not race-timer\'s', () {
      select(lasers);
      store.append(StartEvents.start(fleet: lasers, source: 'manual'));
      expect(lastRaceTimerEvent(log(), fleet: lasers), isNull);
    });

    // A backlog resent out of order (#33's review): race 1's signal arrives
    // after race 2's gun, and must not become the fleet's last.
    test('the last to fire, not the last to arrive', () {
      select(lasers);
      final start = now;
      send(LinkContract.sequenceStart, 'evt-1', at: start);
      send(LinkContract.sequenceStart, 'evt-4', sequence: 'seq-2', at: start + 240000);
      send(LinkContract.start, 'evt-6', sequence: 'seq-2', at: start + 300000);
      final gun = gunOf('seq-2');
      send(LinkContract.signal, 'evt-2', at: start + 60000);
      expect(lastRaceTimerEvent(log(), fleet: lasers)?.ulid, gun.ulid);
    });

    test('a day with no fleet reads the same way', () {
      send(LinkContract.signal, 'evt-1');
      expect(lastRaceTimerEvent(log(), fleet: null)?.ulid, linked().single.ulid);
      expect(lastRaceTimerEvent(log(), fleet: lasers), isNull);
    });
  });
}

/// A clock each side of the comparison moves by itself, one step per call.
class _Clock {
  _Clock(this._ms);

  int _ms;

  int get ms => _ms;

  void tick() => _ms += 1000;
}

/// The same calls on a store, which answers at once, or a fake, which does
/// not, each followed by a tick of its clock.
class _Phone {
  _Phone(this._append, this._receive, this._relog, this._takeBack, this.read, this.tick);

  final Future<EventEnvelope> Function(NewEvent) _append;
  final Future<LinkAnswer> Function(String) _receive;
  final Future<List<EventEnvelope>> Function(String, String) _relog;
  final Future<List<EventEnvelope>> Function(String) _takeBack;
  final Future<List<EventEnvelope>> Function() read;
  final void Function() tick;

  Future<EventEnvelope> append(NewEvent event) async {
    final stored = await _append(event);
    tick();
    return stored;
  }

  Future<LinkAnswer> receive(String text) async {
    final answer = await _receive(text);
    tick();
    return answer;
  }

  Future<List<EventEnvelope>> relog(String sequence, String fleet) async {
    final appended = await _relog(sequence, fleet);
    tick();
    return appended;
  }

  Future<List<EventEnvelope>> takeBack(String sequence) async {
    final undone = await _takeBack(sequence);
    tick();
    return undone;
  }
}

/// One event as the two sides can be compared: nothing either minted for itself.
class _Row {
  const _Row(this.kind, this.source, this.fleet, this.at, this.received, this.sequence, this.corrects, this.start,
      this.copyOf);

  final String kind;
  final String source;
  final String? fleet;
  final Object? at;
  final Object? received;
  final Object? sequence;
  final int? corrects;
  final int? start;
  final int? copyOf;

  @override
  String toString() => '$kind $source $fleet $at $received $sequence $corrects $start $copyOf';
}
