import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:store_bench/day_generator.dart';
import 'package:store_bench/envelope.dart';
import 'package:store_bench/stores.dart';

DayPlan loadPlan() => DayPlan(
    jsonDecode(File('fixtures/pilot_day.json').readAsStringSync()) as Map<String, Object?>);

void main() {
  group('percentile', () {
    final hundred = [for (var i = 100; i >= 1; i--) i.toDouble()];

    test('nearest-rank on 1..100, given unsorted', () {
      expect(percentile(hundred, 50), 50);
      expect(percentile(hundred, 95), 95);
      expect(percentile(hundred, 100), 100);
    });

    test('p95 of 20 samples is the 19th smallest', () {
      final twenty = [for (var i = 1; i <= 20; i++) i.toDouble()];
      expect(percentile(twenty, 95), 19);
    });
  });

  group('ulid', () {
    test('is 26 Crockford characters and its time prefix sorts with time', () {
      final a = ulid(1790000000000, Random(1));
      final b = ulid(1790000000001, Random(1));
      expect(a, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$')));
      expect(a.substring(0, 10).compareTo(b.substring(0, 10)), lessThan(0));
    });
  });

  group('day generator', () {
    final plan = loadPlan();

    test('per-day counts match arithmetic on the fixture, not on the generator', () {
      // Written out by hand from fixtures/pilot_day.json: 3 fleets x 4 races x 20 boats.
      expect(plan.perDay(), {
        'finish': 3 * 4 * 20 * 2,
        'rounding': 3 * 4 * 20 * 3,
        'sequence': 3 * 4 * 8,
        'correction': ((480 + 720) * 0.05).round(),
        'note': 30,
        'wind': 72,
        'gps': 720 * 2,
        'safety': 3 * 20 * 2,
        'assist': 10,
      });
      expect(plan.eventsPerDay, 3028);
    });

    test('generates exactly the retained volume, kind by kind', () {
      final events = DayGenerator(plan).generateRetained();
      expect(events.length, plan.eventsRetained);
      final byKind = <String, int>{};
      for (final e in events) {
        byKind[e.kind] = (byKind[e.kind] ?? 0) + 1;
      }
      plan.perDay().forEach((kind, n) => expect(byKind[kind], n * plan.daysRetained, reason: kind));
    });

    test('is deterministic for a seed', () {
      final a = DayGenerator(plan).generateRetained().map((e) => e.hash).toList();
      final b = DayGenerator(plan).generateRetained().map((e) => e.hash).toList();
      expect(a, b);
    });

    test('every device chain is contiguous from 1 and every hash recomputes', () {
      final gen = DayGenerator(plan);
      final events = [...gen.generateRetained(), for (var i = 0; i < 20; i++) gen.next(1800000000000 + i)];
      final byDevice = <String, List<Envelope>>{};
      for (final e in events) {
        byDevice.putIfAbsent(e.deviceId, () => []).add(e);
      }
      expect(byDevice.keys, hasLength(plan.devices));
      for (final chain in byDevice.values) {
        var prevHash = '0' * 64;
        for (var i = 0; i < chain.length; i++) {
          final e = chain[i];
          expect(e.seq, i + 1);
          expect(e.prevHash, prevHash);
          expect(
              e.hash,
              chainHash(
                  prevHash: e.prevHash,
                  ulid: e.ulid,
                  seq: e.seq,
                  deviceId: e.deviceId,
                  person: e.person,
                  kind: e.kind,
                  deviceTs: e.deviceTs,
                  lat: e.lat,
                  lon: e.lon,
                  payload: e.payload));
          prevHash = e.hash;
        }
      }
    });

    test('ulids are unique across the retained days', () {
      final events = DayGenerator(plan).generateRetained();
      expect(events.map((e) => e.ulid).toSet(), hasLength(events.length));
    });
  });

  group('store contract', () {
    final plan = loadPlan();
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('store_bench_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    for (final name in ['sqlite3', 'sembast', 'hive_ce']) {
      test('$name appends, reads back, counts, refuses a duplicate and persists', () async {
        final events = DayGenerator(plan).generateRetained().take(50).toList();
        final dir = await freshDir(tmp.path, name);
        var store = storeNamed(name);
        await store.open(dir);
        for (final e in events) {
          await store.append(e);
        }
        expect((await store.readBack(events[7].ulid))!.hash, events[7].hash);
        expect(await store.count(), 50);
        await expectLater(store.append(events.first), throwsA(anything));
        expect(await store.count(), 50);
        await store.close();

        store = storeNamed(name);
        await store.open(dir);
        expect(await store.count(), 50);
        expect((await store.readBack(events.last.ulid))!.encode(), events.last.encode());
        await store.close();
      });
    }

    test('only sqlite3 refuses UPDATE and DELETE at the engine', () async {
      final e = DayGenerator(plan).generateRetained().first;
      final outcomes = <String, List<bool>>{};
      for (final name in ['sqlite3', 'sembast', 'hive_ce']) {
        final store = storeNamed(name);
        await store.open(await freshDir(tmp.path, name));
        await store.append(e);
        final u = await store.tryUpdate(e.ulid);
        final d = await store.tryDelete(e.ulid);
        outcomes[name] = [u.refusedNatively, d.refusedNatively];
        await store.close();
      }
      expect(outcomes, {
        'sqlite3': [true, true],
        'sembast': [false, false],
        'hive_ce': [false, false],
      });
    });
  });
}
