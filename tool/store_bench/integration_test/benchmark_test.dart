import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:store_bench/day_generator.dart';
import 'package:store_bench/stores.dart';

/// #13 criteria 1-3, on a device. Run in a profile build:
///   flutter drive --profile --driver=test_driver/integration_test.dart \
///     --target=integration_test/benchmark_test.dart -d DEVICE_ID
/// The report lands in build/integration_response_data.json.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('local store benchmark at end-of-day volume', (tester) async {
    final plan = DayPlan(
        jsonDecode(await rootBundle.loadString('fixtures/pilot_day.json')) as Map<String, Object?>);
    final root = (await getApplicationSupportDirectory()).path;
    final results = <String, Object?>{};

    for (final store in candidates()) {
      final gen = DayGenerator(plan);
      final day = gen.generateRetained();
      final dir = await freshDir(root, 'bench_${store.name}');
      await store.open(dir);

      final fill = Stopwatch()..start();
      for (final e in day) {
        await store.append(e);
      }
      fill.stop();
      final filled = await store.count();

      final samples = <double>[];
      var ts = day.last.deviceTs;
      for (var i = 0; i < plan.timedAppends; i++) {
        final e = gen.next(++ts);
        final sw = Stopwatch()..start();
        await store.append(e);
        final back = await store.readBack(e.ulid);
        sw.stop();
        if (back?.hash != e.hash) throw StateError('${store.name}: read-back mismatch at $i');
        samples.add(sw.elapsedMicroseconds / 1000.0);
      }

      final victim = day[day.length ~/ 2].ulid;
      final update = await store.tryUpdate(victim);
      final delete = await store.tryDelete(victim);
      await store.close();

      final bytes = Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .fold<int>(0, (a, f) => a + f.lengthSync());
      final p95 = percentile(samples, 95);
      results[store.name] = {
        'events_after_fill': filled,
        'fill_ms': fill.elapsedMilliseconds,
        'timed_appends': samples.length,
        'p50_ms': percentile(samples, 50),
        'p95_ms': p95,
        'max_ms': percentile(samples, 100),
        'passes_100ms_p95': p95 < 100,
        'bytes_on_disk': bytes,
        'update': update.toJson(),
        'delete': delete.toJson(),
      };
      expect(filled, plan.eventsRetained, reason: store.name);
    }

    binding.reportData = {
      'events_per_day': plan.eventsPerDay,
      'days_retained': plan.daysRetained,
      'events_retained': plan.eventsRetained,
      'platform': Platform.operatingSystemVersion,
      'results': results,
    };
  }, timeout: Timeout.none);
}
