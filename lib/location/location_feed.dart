import 'dart:async';

import 'package:flutter/services.dart';
import 'package:pro_companion_core/core.dart';

/// Where the phone is (#31), as the platform reports it. Each report is one
/// map: a fix, `{lat, lon, accuracy_m, age_ms}` with `age_ms` the fix's age
/// when reported, or no fix, `{reason}`, one of [GpsReasons.all]. Since #55
/// also the satellites' time from a GPS fix, `{gps_time_ms, device_time_ms,
/// uncertainty_ms}` ([GpsTimeSample]), and `{clock_changed: true}` when the
/// phone's clock is set.
abstract interface class LocationFeed {
  Stream<Map<Object?, Object?>> get reports;
}

/// The phone's own, from the `pro_companion/location` channel. Since #32
/// CoreService serves it, on the core host's engine (lib/core_host.dart), so
/// it keeps reporting with the UI gone.
class PlatformLocationFeed implements LocationFeed {
  const PlatformLocationFeed();

  static const _channel = EventChannel('pro_companion/location');

  @override
  Stream<Map<Object?, Object?>> get reports => _channel.receiveBroadcastStream().cast<Map<Object?, Object?>>();
}

/// Hands every report from [feed] to [core], which stamps each event it
/// appends with the latest (#31). The core never asks for a position, so an
/// append never waits on one.
///
/// A report the core refuses, one it cannot read, and one arriving after the
/// core has closed are each dropped. The core keeps what it held, and events
/// still append. Each call is sent before the next report is read, so the
/// core receives the reports in the order the phone made them.
StreamSubscription<void> forwardLocation(LocationFeed feed, CoreClient core) => feed.reports.listen(
      (report) async {
        try {
          final reason = report['reason'];
          if (reason is String) {
            await core.reportNoFix(reason);
          } else if (report['clock_changed'] == true) {
            await core.reportClockChanged();
          } else if (report.containsKey('gps_time_ms')) {
            await core.reportGpsTime(GpsTimeSample(
              gpsTimeMs: (report['gps_time_ms'] as num).toInt(),
              deviceTimeMs: (report['device_time_ms'] as num).toInt(),
              uncertaintyMs: (report['uncertainty_ms'] as num?)?.toInt(),
            ));
          } else {
            await core.reportFix(GpsFix(
              lat: (report['lat'] as num).toDouble(),
              lon: (report['lon'] as num).toDouble(),
              accuracyM: (report['accuracy_m'] as num?)?.toDouble(),
              ageMs: (report['age_ms'] as num).toInt(),
            ));
          }
        } on Object {
          // Dropped, as above. Nothing on screen depends on it.
        }
      },
      // A phone with no channel (MissingPluginException) or a failed one.
      onError: (Object _) {},
    );
