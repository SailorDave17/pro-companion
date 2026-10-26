import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/location/location_feed.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

/// #31: the app hands the core every position the phone reports, in the
/// platform's shape, so the core can stamp each event it appends.
void main() {
  late _Feed feed;
  late FakeCore core;
  late StreamSubscription<void> forwarding;
  var elapsed = 0;

  setUp(() {
    feed = _Feed();
    elapsed = 0;
    core = FakeCore(location: LatestFix(elapsedMs: () => elapsed));
    forwarding = forwardLocation(feed, core);
  });

  tearDown(() async {
    await forwarding.cancel();
    await feed.close();
  });

  Future<EventEnvelope> appendAfter(Map<Object?, Object?> report) async {
    feed.add(report);
    await pumpEventQueue();
    return core.append(const NewEvent(kind: 'note', source: 'tap'));
  }

  test('a fix in the platform\'s shape is stamped on the next event, with its age', () async {
    final e = await appendAfter({'lat': 33.4012, 'lon': -86.8123, 'accuracy_m': 4.5, 'age_ms': 1200});
    expect(e.gps, const GpsFix(lat: 33.4012, lon: -86.8123, accuracyM: 4.5, ageMs: 1200));
    expect(e.gpsReason, isNull);
  });

  test('a fix with no accuracy, and whole-number coordinates, as a platform channel may send them', () async {
    final e = await appendAfter({'lat': 33, 'lon': -86, 'accuracy_m': null, 'age_ms': 0});
    expect(e.gps, const GpsFix(lat: 33, lon: -86, ageMs: 0));
  });

  test('each reason the phone reports is stamped as the reason', () async {
    for (final reason in [GpsReasons.noPermission, GpsReasons.locationOff, GpsReasons.noFix]) {
      final e = await appendAfter({'reason': reason});
      expect([e.gps, e.gpsReason], [null, reason]);
    }
  });

  test('reports reach the core in the order the phone made them', () async {
    feed
      ..add({'lat': 1.0, 'lon': 2.0, 'accuracy_m': 3.0, 'age_ms': 0})
      ..add({'reason': GpsReasons.locationOff})
      ..add({'lat': 5.0, 'lon': 6.0, 'accuracy_m': 7.0, 'age_ms': 8});
    await pumpEventQueue();
    expect((await core.append(const NewEvent(kind: 'note', source: 'tap'))).gps,
        const GpsFix(lat: 5, lon: 6, accuracyM: 7, ageMs: 8));
    expect(core.calls['reportLocation'], 3);
  });

  test('a report the core cannot use is dropped, and events still append with what it held', () async {
    await appendAfter({'lat': 1.0, 'lon': 2.0, 'accuracy_m': 3.0, 'age_ms': 0});
    final afterBad = [
      await appendAfter({'lat': 'north', 'lon': 2.0, 'age_ms': 0}),
      await appendAfter({'lat': 91.0, 'lon': 2.0, 'accuracy_m': 3.0, 'age_ms': 0}),
      await appendAfter({'reason': 'gone_fishing'}),
    ];
    expect([for (final e in afterBad) e.gps], everyElement(const GpsFix(lat: 1, lon: 2, accuracyM: 3, ageMs: 0)));
  });

  test('a core that refuses, or a channel that errors, never stops the forwarding', () async {
    core.failWith = const CoreException('failed', 'closed');
    feed.add({'reason': GpsReasons.noFix});
    feed.addError(Exception('channel'));
    await pumpEventQueue();
    core.failWith = null;
    final e = await appendAfter({'reason': GpsReasons.noPermission});
    expect(e.gpsReason, GpsReasons.noPermission);
  });

  group('#55: the satellites\' time', () {
    Future<Map<String, Object?>> offsetAfter(List<Map<Object?, Object?>> reports) async {
      reports.forEach(feed.add);
      await pumpEventQueue();
      await core.append(StartEvents.start(fleet: null, source: 'manual'));
      return (await core.readAll()).lastWhere((e) => e.kind == ClockKinds.offset).payload;
    }

    test('a GPS fix\'s time, in the platform\'s shape, is the offset the next race is joined with', () async {
      final fixAt = DateTime.now().millisecondsSinceEpoch - 1000;
      final offset = await offsetAfter([
        // A Kotlin Long arrives as an int, and no uncertainty as null.
        {'gps_time_ms': fixAt + 4000, 'device_time_ms': fixAt, 'uncertainty_ms': 7},
      ]);
      expect([offset['offset_ms'], offset['uncertainty_ms'], offset['reason']], [4000, 7, null]);
      expect(offset['age_ms'], inInclusiveRange(1000, 30000));
      expect(core.calls['reportLocation'], 1);
    });

    test('a phone that states no uncertainty sends null, and it stays null', () async {
      final fixAt = DateTime.now().millisecondsSinceEpoch;
      final offset = await offsetAfter([
        {'gps_time_ms': fixAt - 250, 'device_time_ms': fixAt, 'uncertainty_ms': null},
      ]);
      expect([offset['offset_ms'], offset['uncertainty_ms']], [-250, null]);
    });

    test('the phone\'s clock being set drops the offset the core held', () async {
      final fixAt = DateTime.now().millisecondsSinceEpoch;
      final offset = await offsetAfter([
        {'gps_time_ms': fixAt, 'device_time_ms': fixAt, 'uncertainty_ms': 3},
        {'clock_changed': true},
      ]);
      expect([offset['offset_ms'], offset['reason']], [null, ClockOffsetReasons.clockChanged]);
      expect((await core.readAll()).where((e) => e.kind == ClockKinds.changed), hasLength(1),
          reason: 'and the set is in the log');
    });

    test('a time the core cannot use is dropped, and the offset held is kept', () async {
      final fixAt = DateTime.now().millisecondsSinceEpoch;
      final offset = await offsetAfter([
        {'gps_time_ms': fixAt + 4000, 'device_time_ms': fixAt, 'uncertainty_ms': 1},
        {'gps_time_ms': 'noon', 'device_time_ms': fixAt},
        {'gps_time_ms': 0, 'device_time_ms': fixAt},
      ]);
      expect(offset['offset_ms'], 4000);
    });
  });
}

class _Feed implements LocationFeed {
  final _reports = StreamController<Map<Object?, Object?>>();

  void add(Map<Object?, Object?> report) => _reports.add(report);
  void addError(Object error) => _reports.addError(error);
  Future<void> close() => _reports.close();

  @override
  Stream<Map<Object?, Object?>> get reports => _reports.stream;
}
