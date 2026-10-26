import 'envelope.dart';

/// Why an event carries no position (#31). The core stamps one of these as
/// `gps_reason` whenever `gps` is null, so a missing position is always
/// explained in the log rather than left for someone to guess at.
abstract final class GpsReasons {
  /// The phone may not read its location: permission was refused or revoked.
  static const noPermission = 'no_permission';

  /// The phone's location setting is off.
  static const locationOff = 'location_off';

  /// Allowed and on, but no fix has arrived yet.
  static const noFix = 'no_fix';

  /// Nothing has fed this core a position at all: a core started with no
  /// location feed, or one the feed has not reached yet.
  static const noSource = 'no_source';

  static const all = {noPermission, locationOff, noFix, noSource};
}

/// What one event is stamped with: a position, or the reason there is none.
/// Exactly one of the two is set.
class GpsStamp {
  const GpsStamp.at(GpsFix this.fix) : reason = null;
  const GpsStamp.none(String this.reason) : fix = null;

  final GpsFix? fix;
  final String? reason;
}

/// Why a clock-offset event carries no offset (#55). With no satellite time
/// ever reported, the reason is the position's own, one of [GpsReasons.all],
/// when the phone has no position either: the cause is the same. These two
/// say what is left.
abstract final class ClockOffsetReasons {
  /// The phone has a position, but no fix from the GPS provider has carried
  /// the satellites' time yet. A fused fix's time is usually the phone's own
  /// clock, so it measures nothing.
  static const noGpsTime = 'no_gps_time';

  /// The phone's clock was set since the last satellite time, so the offset
  /// measured then no longer holds. Cleared by the next fix that carries
  /// satellite time.
  static const clockChanged = 'clock_changed';

  static const all = {...GpsReasons.all, noGpsTime, clockChanged};
}

/// One fix's time from the satellites, against this phone's own clock at the
/// moment of that fix (#55): what the phone's location feed reports for every
/// fix from the GPS provider, the only provider whose time Android guarantees
/// comes from the satellite constellation.
class GpsTimeSample {
  const GpsTimeSample({required this.gpsTimeMs, required this.deviceTimeMs, this.uncertaintyMs});

  /// The fix's time, milliseconds since the epoch, from the satellites' clock.
  final int gpsTimeMs;

  /// The phone's own clock at the moment of the fix, milliseconds since the
  /// epoch: the clock every event's `device_ts` is read from.
  final int deviceTimeMs;

  /// How far the two readings may be out of step, in milliseconds: the
  /// platform's own 68% figure for the fix's timestamp plus the 2 ms the two
  /// millisecond readings can lose. Null when the phone states no figure of
  /// its own (owner decision on #55): no precision is claimed that nobody
  /// measured.
  final int? uncertaintyMs;

  /// Satellite time minus device time: add it to a `device_ts` of this phone
  /// to read that moment in satellite time.
  int get offsetMs => gpsTimeMs - deviceTimeMs;

  Map<String, Object?> toWire() =>
      {'gps_time_ms': gpsTimeMs, 'device_time_ms': deviceTimeMs, 'uncertainty_ms': uncertaintyMs};

  static GpsTimeSample fromWire(Map w) => GpsTimeSample(
        gpsTimeMs: w['gps_time_ms'] as int,
        deviceTimeMs: w['device_time_ms'] as int,
        uncertaintyMs: w['uncertainty_ms'] as int?,
      );

  @override
  bool operator ==(Object other) =>
      other is GpsTimeSample &&
      other.gpsTimeMs == gpsTimeMs &&
      other.deviceTimeMs == deviceTimeMs &&
      other.uncertaintyMs == uncertaintyMs;

  @override
  int get hashCode => Object.hash(gpsTimeMs, deviceTimeMs, uncertaintyMs);

  @override
  String toString() => 'GpsTimeSample(gps $gpsTimeMs, device $deviceTimeMs, ±${uncertaintyMs}ms)';
}

/// What a clock-offset event records (#55): this phone's offset from
/// satellite time, or the reason it has none. Exactly one of the two is set.
class ClockOffsetStamp {
  const ClockOffsetStamp.at({required int this.offsetMs, required int this.ageMs, this.uncertaintyMs})
      : reason = null;
  const ClockOffsetStamp.none(String this.reason)
      : offsetMs = null,
        ageMs = null,
        uncertaintyMs = null;

  /// Satellite time minus device time, from the latest fix that carried it.
  final int? offsetMs;

  /// The platform's figure for it, or null when the phone stated none.
  final int? uncertaintyMs;

  /// How long ago that fix was, by this phone's clock, when the offset was
  /// read: the last known offset is kept through a GPS outage, with its age.
  final int? ageMs;

  /// Why there is no offset, one of [ClockOffsetReasons.all].
  final String? reason;
}

/// Where the core's positions come from (#31), and its satellite time (#55).
/// Read once per append, and synchronously, so an append never waits on GPS:
/// it takes whatever the provider holds at that moment.
abstract interface class LocationProvider {
  GpsStamp current();

  /// This phone's offset from satellite time, as of [nowMs] on the phone's
  /// own clock, or the reason there is none.
  ClockOffsetStamp clockOffset(int nowMs);
}

/// The position the phone's location feed last reported, held in the core.
///
/// The feed reports each fix with its age at the moment it was reported, and
/// each change in why there is none. The age an event is stamped with is that
/// age plus the time since the report, read from a monotonic clock, so a fix
/// gets older between reports and is never presented as current once it is
/// not. Setting the phone's clock does not change it.
///
/// The latest report wins: a reason clears the fix it follows. A fix that
/// simply stops being renewed (no signal under a bridge, the app in the
/// background) is kept, with its true and growing age.
///
/// It also holds the latest satellite time the feed reported (#55), from
/// which every clock-offset event's offset is read.
class LatestFix implements LocationProvider {
  LatestFix({int Function()? elapsedMs}) : _elapsed = elapsedMs ?? _monotonicMs();

  final int Function() _elapsed;
  GpsFix? _fix;
  int _reportedAt = 0;
  String _reason = GpsReasons.noSource;
  GpsTimeSample? _time;
  String? _timeReason;

  static int Function() _monotonicMs() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMilliseconds;
  }

  /// A fix, [fix]'s `ageMs` old when the feed read it.
  void reportFix(GpsFix fix) {
    validateGpsFix(fix);
    _fix = fix;
    _reportedAt = _elapsed();
  }

  /// No position, for [reason], one of [GpsReasons.all].
  void reportNone(String reason) {
    if (!GpsReasons.all.contains(reason)) {
      throw ArgumentError.value(reason, 'reason', 'is not one of ${GpsReasons.all}');
    }
    _fix = null;
    _reason = reason;
  }

  @override
  GpsStamp current() {
    final fix = _fix;
    if (fix == null) return GpsStamp.none(_reason);
    return GpsStamp.at(GpsFix(
      lat: fix.lat,
      lon: fix.lon,
      accuracyM: fix.accuracyM,
      ageMs: fix.ageMs! + (_elapsed() - _reportedAt),
    ));
  }

  /// The satellites' time from a fix, against the phone's clock at that fix
  /// (#55). Kept until the next one, through a loss of position or of the
  /// fix itself: the offset is a property of the phone's clock, not of where
  /// it is, and it is read with its age.
  void reportGpsTime(GpsTimeSample sample) {
    validateGpsTimeSample(sample);
    _time = sample;
    _timeReason = null;
  }

  /// The phone's clock was set (#55). The offset held was measured against
  /// the clock as it was, so it is dropped until the next satellite time.
  /// With none held there is nothing to drop, and the reason there is none
  /// stays the one that was true.
  void reportClockChanged() {
    if (_time == null) return;
    _time = null;
    _timeReason = ClockOffsetReasons.clockChanged;
  }

  /// The offset from the latest satellite time, aged by the phone's own
  /// clock: the same clock both of its readings are against, and one that,
  /// unlike the monotonic clock that ages a position, keeps counting while
  /// the CPU sleeps. A clock reading earlier than the fix it was measured at
  /// has been set back since, with no word from the phone, so that offset is
  /// dropped as [reportClockChanged] drops it: otherwise, once the clock had
  /// caught up with the fix, it would be served again as though it held
  /// (#55's review). A clock set forward unreported only ages it.
  @override
  ClockOffsetStamp clockOffset(int nowMs) {
    final time = _time;
    if (time != null) {
      final age = nowMs - time.deviceTimeMs;
      if (age >= 0) return ClockOffsetStamp.at(offsetMs: time.offsetMs, uncertaintyMs: time.uncertaintyMs, ageMs: age);
      reportClockChanged();
    }
    final reason = _timeReason;
    if (reason != null) return ClockOffsetStamp.none(reason);
    return ClockOffsetStamp.none(_fix == null ? _reason : ClockOffsetReasons.noGpsTime);
  }
}

/// Refuses a satellite time no fix could have carried, before the core keeps
/// it: every later clock-offset event would carry it.
void validateGpsTimeSample(GpsTimeSample sample) {
  if (sample.gpsTimeMs <= 0) {
    throw ArgumentError.value(sample.gpsTimeMs, 'gpsTimeMs', 'must be a time after the epoch');
  }
  if (sample.deviceTimeMs <= 0) {
    throw ArgumentError.value(sample.deviceTimeMs, 'deviceTimeMs', 'must be a time after the epoch');
  }
  final uncertainty = sample.uncertaintyMs;
  if (uncertainty != null && uncertainty < 0) {
    throw ArgumentError.value(uncertainty, 'uncertaintyMs', 'must be 0 or more');
  }
}

/// Refuses a fix no phone could have read, before the core keeps it: every
/// later event would carry it, and nothing can take a stored event back.
void validateGpsFix(GpsFix fix) {
  if (!fix.lat.isFinite || fix.lat < -90 || fix.lat > 90) {
    throw ArgumentError.value(fix.lat, 'lat', 'must be a latitude, -90 to 90');
  }
  if (!fix.lon.isFinite || fix.lon < -180 || fix.lon > 180) {
    throw ArgumentError.value(fix.lon, 'lon', 'must be a longitude, -180 to 180');
  }
  final accuracy = fix.accuracyM;
  if (accuracy != null && (!accuracy.isFinite || accuracy < 0)) {
    throw ArgumentError.value(accuracy, 'accuracyM', 'must be a distance in metres, 0 or more');
  }
  final age = fix.ageMs;
  if (age == null || age < 0) throw ArgumentError.value(age, 'ageMs', 'must be 0 or more');
}
