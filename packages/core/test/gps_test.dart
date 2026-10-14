import 'dart:convert';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #31: every event the core appends carries where its phone was - the last
/// fix with its true age - or, with no fix, a null position and the reason.
void main() {
  const lat = 33.4012;
  const lon = -86.8123;

  /// A monotonic clock a test moves by hand.
  ({int Function() read, void Function(int ms) advance}) handClock() {
    var now = 0;
    return (read: () => now, advance: (ms) => now += ms);
  }

  Future<CoreClient> spawnedCore() async {
    final core = await spawnCore(tempDbPath());
    addTearDown(() async {
      try {
        await core.close();
      } on Object {
        // Closed by the test.
      }
    });
    return core;
  }

  List<Object?> gpsIn(List<String> texts) => [for (final t in texts) (jsonDecode(t) as Map)['gps']];

  /// One of each kind of event a phone writes, so "any event" is not one kind.
  final everyKind = [
    const NewEvent(kind: 'role.assigned', source: 'tap', payload: {'role': 'overall_pro'}),
    const NewEvent(kind: 'start', source: 'race-timer', payload: {'fleet': null}),
    const NewEvent(kind: 'finish', source: 'volume-key', payload: {'fleet': null}),
    const NewEvent(kind: 'note', source: 'manual', payload: {'text': 'Mark 2 — hold'}),
  ];

  group('criterion 1: with a fix no older than 30 s, every event carries latitude, longitude, accuracy and '
      'fix age', () {
    test('in the envelope and in the canonical text as stored', () {
      final clock = handClock();
      final location = LatestFix(elapsedMs: clock.read);
      final store = openStore(tempDbPath(), location: location);
      location.reportFix(const GpsFix(lat: lat, lon: lon, accuracyM: 4.5, ageMs: 3000));
      clock.advance(10000);

      final appended = [for (final e in everyKind) store.append(e)];
      final fix = const GpsFix(lat: lat, lon: lon, accuracyM: 4.5, ageMs: 13000);
      expect([for (final e in appended) e.gps], everyElement(fix),
          reason: 'reported 3 s old, appended 10 s later: 13 s old, and current (30 s or less)');
      expect([for (final e in appended) e.gpsReason], everyElement(isNull));
      expect([for (final e in store.readAll()) e.gps], everyElement(fix));
      expect(gpsIn(store.readCanonical()),
          everyElement({'accuracy_m': 4.5, 'age_ms': 13000, 'lat': lat, 'lon': lon}));
    });

    test('and the hash covers it: a position moved after the fact breaks the chain at the next event', () {
      final location = LatestFix(elapsedMs: () => 0)
        ..reportFix(const GpsFix(lat: lat, lon: lon, accuracyM: 5, ageMs: 1000));
      final store = openStore(tempDbPath(), location: location);
      for (var i = 0; i < 3; i++) {
        store.append(NewEvent(kind: 'note', source: 'tap', payload: {'n': i}));
      }
      final texts = store.readCanonical();
      expect(verifyChain(texts), const ChainVerdict.intact());

      final moved = texts[1].replaceFirst('"lat":$lat', '"lat":33.5012');
      expect(moved, isNot(texts[1]), reason: 'the latitude to move is there');
      final verdict = verifyChain([texts[0], moved, texts[2]]);
      expect([verdict.state, verdict.atSeq, verdict.afterSeq], [ChainState.broken, 3, 2]);
    });

    test('across the core interface, from a fix the UI reports', () async {
      final core = await spawnedCore();
      await core.reportFix(const GpsFix(lat: lat, lon: lon, accuracyM: 3.5, ageMs: 2000));
      final e = await core.append(const NewEvent(kind: 'finish', source: 'tap'));
      expect([e.gps!.lat, e.gps!.lon, e.gps!.accuracyM], [lat, lon, 3.5]);
      expect(e.gps!.ageMs, inInclusiveRange(2000, 30000), reason: 'its age, grown only by the time since the report');
      expect(e.gpsReason, isNull);
      expect((await core.readAll()).single.gps, e.gps);
    });

    test('and the fake core the widget tests use stamps it the same way', () async {
      final clock = handClock();
      final fake = FakeCore(location: LatestFix(elapsedMs: clock.read));
      await fake.reportFix(const GpsFix(lat: lat, lon: lon, accuracyM: 4.5, ageMs: 3000));
      clock.advance(10000);
      final e = await fake.append(const NewEvent(kind: 'finish', source: 'tap'));
      expect(e.gps, const GpsFix(lat: lat, lon: lon, accuracyM: 4.5, ageMs: 13000));
      expect(e.gpsReason, isNull);
    });

    test('a fix with no accuracy carries a null accuracy, never an invented one', () {
      final location = LatestFix(elapsedMs: () => 0)..reportFix(const GpsFix(lat: lat, lon: lon, ageMs: 0));
      final store = openStore(tempDbPath(), location: location);
      store.append(const NewEvent(kind: 'note', source: 'tap'));
      expect(gpsIn(store.readCanonical()).single, {'accuracy_m': null, 'age_ms': 0, 'lat': lat, 'lon': lon});
    });
  });

  group('criterion 2: an older fix is carried with its true age, never presented as current', () {
    test('a fix the phone reported 45 s old is stamped 45 s old, not 0', () {
      final location = LatestFix(elapsedMs: () => 0)
        ..reportFix(const GpsFix(lat: lat, lon: lon, accuracyM: 8, ageMs: 45000));
      final store = openStore(tempDbPath(), location: location);
      final e = store.append(const NewEvent(kind: 'finish', source: 'tap'));
      expect(e.gps, const GpsFix(lat: lat, lon: lon, accuracyM: 8, ageMs: 45000));
      expect(e.gps!.ageMs, greaterThan(30000), reason: 'older than current, and the envelope says so');
    });

    test('a fix that stops being renewed keeps growing older, event by event', () {
      final clock = handClock();
      final location = LatestFix(elapsedMs: clock.read);
      final store = openStore(tempDbPath(), location: location);
      location.reportFix(const GpsFix(lat: lat, lon: lon, accuracyM: 5, ageMs: 1000));

      final ages = <int?>[];
      for (final wait in [0, 29000, 1000, 270000]) {
        clock.advance(wait);
        ages.add(store.append(const NewEvent(kind: 'note', source: 'tap')).gps!.ageMs);
      }
      expect(ages, [1000, 30000, 31000, 301000],
          reason: 'current until 30 s, then older, the same fix all along with its true age');
      expect([for (final g in gpsIn(store.readCanonical())) (g as Map)['age_ms']], ages);
    });

    test('a new fix replaces it, with its own age', () {
      final clock = handClock();
      final location = LatestFix(elapsedMs: clock.read);
      final store = openStore(tempDbPath(), location: location);
      location.reportFix(const GpsFix(lat: lat, lon: lon, accuracyM: 5, ageMs: 0));
      clock.advance(120000);
      location.reportFix(const GpsFix(lat: 33.41, lon: -86.82, accuracyM: 3, ageMs: 500));
      clock.advance(1000);
      expect(store.append(const NewEvent(kind: 'note', source: 'tap')).gps,
          const GpsFix(lat: 33.41, lon: -86.82, accuracyM: 3, ageMs: 1500));
    });

    test('the age is read from a monotonic clock, so setting the phone clock back does not make a fix current', () {
      final clock = handClock();
      var wall = 1727190000000;
      final location = LatestFix(elapsedMs: clock.read);
      final store = openStore(tempDbPath(), clock: () => wall, location: location);
      location.reportFix(const GpsFix(lat: lat, lon: lon, accuracyM: 5, ageMs: 0));
      clock.advance(60000);
      wall -= 3600000;
      expect(store.append(const NewEvent(kind: 'note', source: 'tap')).gps!.ageMs, 60000);
    });
  });

  group('criterion 3: with no fix or no permission, an event appends at once with a null position and the '
      'reason', () {
    test('each reason the phone reports is stamped as given', () {
      final location = LatestFix(elapsedMs: () => 0);
      final store = openStore(tempDbPath(), location: location);
      final stamped = <(GpsFix?, String?)>[];
      for (final reason in [GpsReasons.noPermission, GpsReasons.locationOff, GpsReasons.noFix]) {
        location.reportNone(reason);
        final e = store.append(const NewEvent(kind: 'note', source: 'tap'));
        stamped.add((e.gps, e.gpsReason));
      }
      expect(stamped, [
        (null, GpsReasons.noPermission),
        (null, GpsReasons.locationOff),
        (null, GpsReasons.noFix),
      ]);
      final wires = [for (final t in store.readCanonical()) jsonDecode(t) as Map];
      expect([for (final w in wires) w['gps']], everyElement(isNull));
      expect([for (final w in wires) w['gps_reason']], [GpsReasons.noPermission, GpsReasons.locationOff, GpsReasons.noFix]);
      for (final t in store.readCanonical()) {
        expect(t, contains('"gps":null,"gps_reason":"'), reason: 'the null is written, and the reason beside it');
      }
    });

    test('a core nothing has reported to says so: no_source', () {
      final store = openStore(tempDbPath());
      final e = store.append(const NewEvent(kind: 'note', source: 'tap'));
      expect([e.gps, e.gpsReason], [null, GpsReasons.noSource]);
    });

    test('a reason clears the fix it follows: a revoked permission stops the stamp at once', () {
      final location = LatestFix(elapsedMs: () => 0)
        ..reportFix(const GpsFix(lat: lat, lon: lon, accuracyM: 5, ageMs: 0));
      final store = openStore(tempDbPath(), location: location);
      expect(store.append(const NewEvent(kind: 'note', source: 'tap')).gps, isNotNull);
      location.reportNone(GpsReasons.noPermission);
      final e = store.append(const NewEvent(kind: 'note', source: 'tap'));
      expect([e.gps, e.gpsReason], [null, GpsReasons.noPermission]);
    });

    test('append never waits on GPS: a core with no fix answers at once, through the interface', () async {
      final core = await spawnedCore();
      await core.reportNoFix(GpsReasons.noFix);
      final watch = Stopwatch()..start();
      final e = await core.append(const NewEvent(kind: 'finish', source: 'tap')).timeout(const Duration(seconds: 2));
      expect(watch.elapsedMilliseconds, lessThan(2000));
      expect([e.gps, e.gpsReason], [null, GpsReasons.noFix]);

      final never = await spawnedCore();
      final first = await never.append(const NewEvent(kind: 'finish', source: 'tap')).timeout(const Duration(seconds: 2));
      expect([first.gps, first.gpsReason], [null, GpsReasons.noSource], reason: 'nothing reported at all');
    });

    test('and on the fake core', () async {
      final fake = FakeCore();
      expect((await fake.append(const NewEvent(kind: 'note', source: 'tap'))).gpsReason, GpsReasons.noSource);
      await fake.reportNoFix(GpsReasons.noPermission);
      final e = await fake.append(const NewEvent(kind: 'note', source: 'tap'));
      expect([e.gps, e.gpsReason], [null, GpsReasons.noPermission]);
    });
  });

  group('criterion 5: the envelope writer stamps what the location provider gives it', () {
    test('a mocked provider\'s position is the one every appended event carries', () {
      const mocked = GpsFix(lat: -33.8568, lon: 151.2153, accuracyM: 2.5, ageMs: 750);
      final provider = _MockedProvider(const GpsStamp.at(mocked));
      final store = openStore(tempDbPath(), location: provider);
      final e = store.append(const NewEvent(kind: 'finish', source: 'tap'));
      expect(provider.reads, 1, reason: 'read once, at the append');
      expect(e.gps, mocked);
      expect(e.gpsReason, isNull);
      expect(store.readAll().single.gps, mocked);
      expect(gpsIn(store.readCanonical()).single, {'accuracy_m': 2.5, 'age_ms': 750, 'lat': -33.8568, 'lon': 151.2153});
    });

    test('and its reason, when it has no position', () {
      final provider = _MockedProvider(const GpsStamp.none(GpsReasons.locationOff));
      final store = openStore(tempDbPath(), location: provider);
      final e = store.append(const NewEvent(kind: 'note', source: 'tap'));
      expect([e.gps, e.gpsReason], [null, GpsReasons.locationOff]);
      expect(jsonDecode(store.readCanonical().single), containsPair('gps_reason', GpsReasons.locationOff));
    });

    test('a caller cannot supply a position: NewEvent has none to give, and its wire form carries none', () {
      final wire = const NewEvent(kind: 'note', source: 'tap').toWire();
      expect(wire.keys, isNot(contains('gps')));
      final store = openStore(tempDbPath(), location: _MockedProvider(const GpsStamp.none(GpsReasons.noFix)));
      final e = store.append(NewEvent.fromWire({...wire, 'gps': {'lat': 1, 'lon': 2, 'accuracy_m': 3, 'age_ms': 0}}));
      expect([e.gps, e.gpsReason], [null, GpsReasons.noFix], reason: 'a position in a request is ignored');
    });
  });

  group('a report no phone could have made is refused before the core keeps it', () {
    final bad = [
      const GpsFix(lat: 90.5, lon: lon, ageMs: 0),
      const GpsFix(lat: double.nan, lon: lon, ageMs: 0),
      const GpsFix(lat: lat, lon: -180.5, ageMs: 0),
      const GpsFix(lat: lat, lon: double.infinity, ageMs: 0),
      const GpsFix(lat: lat, lon: lon, accuracyM: -1, ageMs: 0),
      const GpsFix(lat: lat, lon: lon, ageMs: -1),
      const GpsFix(lat: lat, lon: lon, ageMs: null),
    ];

    test('in the core, leaving the position it held', () {
      final location = LatestFix(elapsedMs: () => 0)
        ..reportFix(const GpsFix(lat: lat, lon: lon, accuracyM: 5, ageMs: 0));
      for (final fix in bad) {
        expect(() => location.reportFix(fix), throwsArgumentError, reason: '$fix');
      }
      expect(() => location.reportNone('gone_fishing'), throwsArgumentError);
      expect(location.current().fix, const GpsFix(lat: lat, lon: lon, accuracyM: 5, ageMs: 0));
    });

    test('across the interface, as an invalid request', () async {
      final core = await spawnedCore();
      await expectLater(core.reportFix(const GpsFix(lat: 91, lon: lon, ageMs: 0)),
          throwsA(isA<CoreException>().having((e) => e.code, 'code', 'invalid')));
      await expectLater(core.reportNoFix('gone_fishing'),
          throwsA(isA<CoreException>().having((e) => e.code, 'code', 'invalid')));
      final e = await core.append(const NewEvent(kind: 'note', source: 'tap'));
      expect([e.gps, e.gpsReason], [null, GpsReasons.noSource]);
    });

    test('and on the fake core', () async {
      final fake = FakeCore();
      await expectLater(fake.reportFix(const GpsFix(lat: 91, lon: lon, ageMs: 0)), throwsArgumentError);
      await expectLater(fake.reportNoFix('gone_fishing'), throwsArgumentError);
    });
  });
}

class _MockedProvider implements LocationProvider {
  _MockedProvider(this.stamp);

  final GpsStamp stamp;
  var reads = 0;

  @override
  GpsStamp current() {
    reads++;
    return stamp;
  }
}
