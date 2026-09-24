import 'dart:math';

import 'envelope.dart';

/// The fixture's parameters (fixtures/pilot_day.json), each read from its
/// `value` field. The `why` fields justify each one from the pilot scope.
class DayPlan {
  DayPlan(this._raw);

  final Map<String, Object?> _raw;

  num _v(String key) => (_raw[key]! as Map)['value']! as num;

  int get seed => _raw['seed']! as int;
  int get devices => _v('devices').toInt();
  int get fleets => _v('fleets').toInt();
  int get boatsPerFleet => _v('boatsPerFleet').toInt();
  int get racesPerFleet => _v('racesPerFleet').toInt();
  int get roundingsPerBoatPerRace => _v('roundingsPerBoatPerRace').toInt();
  int get sequenceEventsPerStart => _v('sequenceEventsPerStart').toInt();
  int get finishEventsPerBoatPerRace => _v('finishEventsPerBoatPerRace').toInt();
  double get correctionRate => _v('correctionRate').toDouble();
  int get notesPerDay => _v('notesPerDay').toInt();
  int get windReadingsPerDay => _v('windReadingsPerDay').toInt();
  int get gpsTrackSamplesPerMarkBoat => _v('gpsTrackSamplesPerMarkBoat').toInt();
  int get markBoats => _v('markBoats').toInt();
  int get safetyEventsPerBoat => _v('safetyEventsPerBoat').toInt();
  int get assistFlagsPerDay => _v('assistFlagsPerDay').toInt();
  int get daysRetained => _v('daysRetained').toInt();
  int get timedAppends => _v('timedAppends').toInt();

  /// Events per kind for one day, computed from the parameters alone, so a
  /// test can check the generator against arithmetic it did not write.
  Map<String, int> perDay() {
    final races = fleets * racesPerFleet;
    final finishes = races * boatsPerFleet * finishEventsPerBoatPerRace;
    final roundings = races * boatsPerFleet * roundingsPerBoatPerRace;
    return {
      'finish': finishes,
      'rounding': roundings,
      'sequence': races * sequenceEventsPerStart,
      'correction': ((finishes + roundings) * correctionRate).round(),
      'note': notesPerDay,
      'wind': windReadingsPerDay,
      'gps': gpsTrackSamplesPerMarkBoat * markBoats,
      'safety': fleets * boatsPerFleet * safetyEventsPerBoat,
      'assist': assistFlagsPerDay,
    };
  }

  int get eventsPerDay => perDay().values.fold(0, (a, b) => a + b);
  int get eventsRetained => eventsPerDay * daysRetained;
}

/// Device roles, in `devices` order: PRO/signal, recorder, mark boats, safety.
String _deviceFor(String kind, int i, DayPlan plan) {
  switch (kind) {
    case 'finish':
    case 'correction':
      return 'dev-recorder';
    case 'rounding':
    case 'gps':
      return 'dev-mark${i % plan.markBoats + 1}';
    case 'safety':
    case 'assist':
      return 'dev-safety';
    default:
      return 'dev-pro';
  }
}

/// Deterministic generator: the same plan and seed always give the same events,
/// ULIDs and hashes. Keeps each device's chain so [next] continues it past the
/// synthetic days, which is what the timed appends use.
class DayGenerator {
  DayGenerator(this.plan) : _random = Random(plan.seed);

  final DayPlan plan;
  final Random _random;
  final Map<String, ({int seq, String hash})> _chains = {};
  static const _dayStart = 1790000000000; // a fixed epoch-ms, not "now"
  static const _dayLengthMs = 6 * 60 * 60 * 1000;

  /// Every event for [DayPlan.daysRetained] days, in device-time order.
  List<Envelope> generateRetained() {
    final out = <Envelope>[];
    for (var day = 0; day < plan.daysRetained; day++) {
      out.addAll(_generateDay(day));
    }
    return out;
  }

  List<Envelope> _generateDay(int day) {
    final base = _dayStart + day * 24 * 60 * 60 * 1000;
    final specs = <({String kind, int ts, int i})>[];
    plan.perDay().forEach((kind, count) {
      for (var i = 0; i < count; i++) {
        specs.add((kind: kind, ts: base + _random.nextInt(_dayLengthMs), i: i));
      }
    });
    specs.sort((a, b) => a.ts.compareTo(b.ts));
    final out = <Envelope>[];
    for (final s in specs) {
      out.add(_make(s.kind, s.ts, s.i, out));
    }
    return out;
  }

  /// One more event continuing the chains, for the timed appends.
  Envelope next(int ts) => _make('finish', ts, _random.nextInt(1000), const []);

  Envelope _make(String kind, int ts, int i, List<Envelope> soFar) {
    final deviceId = _deviceFor(kind, i, plan);
    final prev = _chains[deviceId] ?? (seq: 0, hash: '0' * 64);
    final seq = prev.seq + 1;
    final id = ulid(ts, _random);
    final payload = _payload(kind, i, soFar);
    final lat = 42.35 + _random.nextDouble() / 100;
    final lon = -83.05 + _random.nextDouble() / 100;
    const person = 'volunteer';
    final hash = chainHash(
      prevHash: prev.hash,
      ulid: id,
      seq: seq,
      deviceId: deviceId,
      person: person,
      kind: kind,
      deviceTs: ts,
      lat: lat,
      lon: lon,
      payload: payload,
    );
    _chains[deviceId] = (seq: seq, hash: hash);
    return Envelope(
      ulid: id,
      seq: seq,
      deviceId: deviceId,
      person: person,
      kind: kind,
      deviceTs: ts,
      lat: lat,
      lon: lon,
      prevHash: prev.hash,
      hash: hash,
      payload: payload,
    );
  }

  Map<String, Object?> _payload(String kind, int i, List<Envelope> soFar) {
    final fleet = 'F${i % plan.fleets + 1}';
    final race = i % plan.racesPerFleet + 1;
    final sail = '${10000 + _random.nextInt(89999)}';
    switch (kind) {
      case 'finish':
        return {'fleet': fleet, 'race': race, 'sail': sail, 'place': i % plan.boatsPerFleet + 1};
      case 'rounding':
        return {'fleet': fleet, 'race': race, 'sail': sail, 'mark': '${i % 3 + 1}'};
      case 'sequence':
        return {'fleet': fleet, 'race': race, 'signal': 'warning', 'source': 'race-timer'};
      case 'correction':
        final target = soFar.isEmpty ? null : soFar[_random.nextInt(soFar.length)].ulid;
        return {'corrects': target, 'reason': 'undo'};
      case 'note':
        return {'text': 'Boat $sail reported gear failure near mark 2, retired, towed in.'};
      case 'wind':
        return {'dir_deg': 180 + _random.nextInt(90), 'kts': 8 + _random.nextInt(12)};
      case 'gps':
        return {'acc_m': 3 + _random.nextInt(8)};
      case 'safety':
        return {'sail': sail, 'direction': i.isEven ? 'out' : 'in'};
      default:
        return {'sail': sail, 'flag': 'assist', 'cleared': false};
    }
  }
}

/// Nearest-rank percentile of [samples] (need not be sorted).
double percentile(List<double> samples, double p) {
  if (samples.isEmpty) throw ArgumentError('no samples');
  final sorted = [...samples]..sort();
  final rank = (p / 100 * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}
