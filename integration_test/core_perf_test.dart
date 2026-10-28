import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';

/// #24 criterion 2: with the ADR 002 engine filled to the benchmark's
/// end-of-day volume, 1,000 appends through the core interface - across the
/// isolate boundary, each committed before it returns - have p95 under 100 ms.
///
/// The volume is the #13 fixture's three-day retained count: 9,084 events
/// from 5 committee phones (tool/store_bench/fixtures/pilot_day.json).
const retainedEvents = 9084;
const devices = 5;
const timedAppends = 1000;
const warmUp = 20;

Map<String, Object?> _payload(int i) => switch (i % 5) {
      0 => {'sail': '${10000 + i % 60}', 'fleet': 'F${i % 3}', 'race': i % 4 + 1, 'line': 'finish'},
      1 => {'mark': 'M${i % 4}', 'sail': '${10000 + i % 60}', 'fleet': 'F${i % 3}', 'leg': i % 6},
      2 => {'signal': 'warning', 'fleet': 'F${i % 3}', 'race': i % 4 + 1, 'flag': 'class'},
      3 => {'text': 'Wind shifted right, about ten degrees; mark boat asked to hold.', 'author': 'pro'},
      _ => {'lat': 33.4 + i * 1e-6, 'lon': -86.8 - i * 1e-6, 'speed_kn': 4.2, 'heading': 210},
    };

int _nearestRank(List<int> sortedMicros, double pct) =>
    sortedMicros[((pct / 100) * sortedMicros.length).ceil().clamp(1, sortedMicros.length) - 1];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('1,000 appends through the core at end-of-day volume: p95 under 100 ms',
      (tester) async {
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'perf-${DateTime.now().microsecondsSinceEpoch}.db');
    addTearDown(() {
      for (final suffix in ['', '-wal', '-shm']) {
        final f = File('$path$suffix');
        if (f.existsSync()) f.deleteSync();
      }
    });

    // Fill the engine directly, in one transaction: the fill is setup, not
    // the thing measured.
    final fill = EventStore.open(path);
    final t0 = DateTime.now().millisecondsSinceEpoch - retainedEvents * 1000;
    fill.debugDatabase.execute('BEGIN');
    for (var i = 0; i < retainedEvents; i++) {
      final device = 'FILLDEVICE${i % devices}'.padRight(26, '0');
      fill.insert(EventEnvelope(
        ulid: newUlid(t0 + i * 1000, _Seq(i)),
        deviceTs: t0 + i * 1000,
        deviceId: device,
        seq: i ~/ devices + 1,
        source: 'tap',
        kind: const ['finish', 'rounding', 'sequence', 'note', 'track'][i % 5],
        payloadVersion: 1,
        role: 'recorder',
        payload: _payload(i),
      ));
    }
    fill.debugDatabase.execute('COMMIT');
    expect(fill.count(), retainedEvents);
    fill.close();

    final core = await spawnCore(path);
    addTearDown(core.close);
    for (var i = 0; i < warmUp; i++) {
      await core.append(NewEvent(kind: 'finish', source: 'tap', payload: _payload(i)));
    }

    final micros = <int>[];
    final sw = Stopwatch();
    for (var i = 0; i < timedAppends; i++) {
      final event = NewEvent(kind: 'finish', source: 'tap', role: 'recorder', payload: _payload(i));
      sw
        ..reset()
        ..start();
      await core.append(event);
      sw.stop();
      micros.add(sw.elapsedMicroseconds);
    }

    // The first finish of each fleet, F0 to F2 and none, joined its race of the day with a clock
    // offset (#55). All four came in the warm-up, so no timed append carried one.
    const joinedRaces = 4;
    expect(await core.count(), retainedEvents + warmUp + timedAppends + joinedRaces,
        reason: 'every timed append landed; a write that did not happen must not time fast');

    micros.sort();
    final p50 = _nearestRank(micros, 50) / 1000;
    final p95 = _nearestRank(micros, 95) / 1000;
    final max = micros.last / 1000;
    binding.reportData = {'p50_ms': p50, 'p95_ms': p95, 'max_ms': max, 'n': micros.length};
    // ignore: avoid_print
    print('CORE_PERF volume=$retainedEvents n=${micros.length} '
        'p50=${p50.toStringAsFixed(2)}ms p95=${p95.toStringAsFixed(2)}ms max=${max.toStringAsFixed(2)}ms');

    expect(p95, lessThan(100), reason: 'the 100 ms bar (ADR 001)');
  });

  // #54's review: a rounding's append also counts the boat's lap from this phone's own roundings,
  // which the store holds in memory, so it is held to the same bar with a mark boat's three days of
  // them in the log. The other phones' fill is as above.
  testWidgets('1,000 rounding appends through the core at end-of-day volume, with a mark boat\'s own '
      'roundings held: p95 under 100 ms', (tester) async {
    const ownRoundings = 1800; // about 600 a day for three days, 60 boats in 3 fleets
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'perf-rounding-${DateTime.now().microsecondsSinceEpoch}.db');
    addTearDown(() {
      for (final suffix in ['', '-wal', '-shm']) {
        final f = File('$path$suffix');
        if (f.existsSync()) f.deleteSync();
      }
    });

    final fill = EventStore.open(path);
    final me = fill.deviceId;
    final t0 = DateTime.now().millisecondsSinceEpoch - (retainedEvents + ownRoundings) * 1000;
    fill.debugDatabase.execute('BEGIN');
    for (var i = 0; i < retainedEvents; i++) {
      final device = 'FILLDEVICE${i % devices}'.padRight(26, '0');
      fill.insert(EventEnvelope(
        ulid: newUlid(t0 + i * 1000, _Seq(i)),
        deviceTs: t0 + i * 1000,
        deviceId: device,
        seq: i ~/ devices + 1,
        source: 'tap',
        kind: const ['finish', 'rounding', 'sequence', 'note', 'track'][i % 5],
        payloadVersion: 1,
        role: 'recorder',
        payload: _payload(i),
      ));
    }
    for (var i = 0; i < ownRoundings; i++) {
      final at = t0 + (retainedEvents + i) * 1000;
      fill.insert(EventEnvelope(
        ulid: newUlid(at, _Seq(retainedEvents + i)),
        deviceTs: at,
        deviceId: me,
        seq: i + 1,
        source: 'tap',
        kind: 'rounding',
        payloadVersion: 1,
        role: 'mark_boat',
        payload: {'fleet': 'F${i % 3}', 'sail': '${10000 + i % 60}', 'mark': 'mark_1', 'race': null, 'lap': 1},
      ));
    }
    fill.debugDatabase.execute('COMMIT');
    expect(fill.count(), retainedEvents + ownRoundings);
    fill.close();

    final core = await spawnCore(path);
    addTearDown(core.close);
    NewEvent rounding(int i) => NewEvent(
          kind: 'rounding',
          source: 'tap',
          role: 'mark_boat',
          payload: {'fleet': 'F${i % 3}', 'sail': '${10000 + i % 60}', 'mark': 'mark_1'},
        );
    for (var i = 0; i < warmUp; i++) {
      await core.append(rounding(i));
    }

    final micros = <int>[];
    final sw = Stopwatch();
    var lastLap = 0;
    for (var i = 0; i < timedAppends; i++) {
      sw
        ..reset()
        ..start();
      final stored = await core.append(rounding(i));
      sw.stop();
      micros.add(sw.elapsedMicroseconds);
      lastLap = stored.payload['lap'] as int;
    }
    // The last timed rounding is boat 10039's 17th of this run (warm-up and timed appends, 60
    // boats). Counting the 30 the store held for her makes it 47. Above 17 is the pin: it holds
    // only if the held roundings were read, so their cost was paid (#54's second review: "> 1" held
    // either way). Not "== 47": run within ~30 minutes of local midnight, some held ones fall on the
    // day before, which the lap does not count.
    expect(lastLap, greaterThan(17), reason: 'the lap was counted from the held roundings, so the cost was paid');

    // The first rounding of each fleet joined its race of the day (#55), in the warm-up.
    const joinedRaces = 3;
    expect(await core.count(), retainedEvents + ownRoundings + warmUp + timedAppends + joinedRaces,
        reason: 'every timed append landed; a write that did not happen must not time fast');

    micros.sort();
    final p50 = _nearestRank(micros, 50) / 1000;
    final p95 = _nearestRank(micros, 95) / 1000;
    final max = micros.last / 1000;
    // ignore: avoid_print
    print('CORE_PERF_ROUNDING volume=${retainedEvents + ownRoundings} n=${micros.length} '
        'p50=${p50.toStringAsFixed(2)}ms p95=${p95.toStringAsFixed(2)}ms max=${max.toStringAsFixed(2)}ms');

    expect(p95, lessThan(100), reason: 'the 100 ms bar (ADR 001)');
  });
}

/// Deterministic ULID randomness for the fill, so a rerun fills identically.
class _Seq implements Random {
  _Seq(this._i);
  int _i;
  @override
  int nextInt(int max) => (_i = (_i * 1103515245 + 12345) & 0x7fffffff) % max;
  @override
  double nextDouble() => nextInt(1 << 30) / (1 << 30);
  @override
  bool nextBool() => nextInt(2) == 1;
}
