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

/// Where the core's positions come from (#31). Read once per append, and
/// synchronously, so an append never waits on GPS: it takes whatever the
/// provider holds at that moment.
abstract interface class LocationProvider {
  GpsStamp current();
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
class LatestFix implements LocationProvider {
  LatestFix({int Function()? elapsedMs}) : _elapsed = elapsedMs ?? _monotonicMs();

  final int Function() _elapsed;
  GpsFix? _fix;
  int _reportedAt = 0;
  String _reason = GpsReasons.noSource;

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
