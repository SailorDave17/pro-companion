import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart' as sql;

import 'envelope.dart';
import 'location.dart';
import 'store.dart';
import 'wire.dart';

/// Serves the wire protocol over one [EventStore]. Hosted by whatever owns the
/// core: the foreground service's engine in the app (#32), or an isolate
/// spawned for a test. The protocol is the same in both.
class CoreServer {
  CoreServer(this.store, {this.closable = true});

  final EventStore store;

  /// False when the host, not a client, owns the core's lifetime: the
  /// foreground service's core serves every client, so a close request from
  /// one of them is refused rather than closing the log under the others.
  final bool closable;

  /// Handles one request, `[replyPort, command, args]`, and sends the reply.
  /// Returns false once the core has been asked to close.
  bool handle(Object? message) {
    if (message is! List || message.length != 3 || message[0] is! SendPort) {
      return true; // Not a request. Nothing to reply to.
    }
    final reply = message[0] as SendPort;
    final command = message[1];
    final args = message[2];
    try {
      if (command is! String || !Wire.commands.contains(command)) {
        reply.send([Wire.err, 'unknown_command', 'the core has no command "$command"']);
        return true;
      }
      if (args is! Map) throw ArgumentError.value(args, 'args', 'must be a map');
      if (command == Wire.close && !closable) {
        reply.send([Wire.err, 'refused', 'the core host owns this core, and it stays open']);
        return true;
      }
      final result = _dispatch(command, args);
      requireWireSafe(result, 'result');
      reply.send([Wire.ok, result]);
      return command != Wire.close;
    } on sql.SqliteException catch (e) {
      reply.send([Wire.err, 'refused', e.message]);
    } on ArgumentError catch (e) {
      reply.send([Wire.err, 'invalid', e.toString()]);
    } on TypeError catch (e) {
      reply.send([Wire.err, 'invalid', e.toString()]);
    } catch (e) {
      reply.send([Wire.err, 'failed', e.toString()]);
    }
    return true;
  }

  Object? _dispatch(String command, Map args) {
    switch (command) {
      case Wire.append:
        requireWireSafe(args, 'args');
        return store.append(NewEvent.fromWire(args['event'] as Map)).toWire();
      case Wire.readAll:
        return [for (final e in store.readAll()) e.toWire()];
      case Wire.readOwn:
        return [for (final e in store.readOwn()) e.toWire()];
      case Wire.count:
        return store.count();
      case Wire.deviceId:
        return store.deviceId;
      case Wire.admissionId:
        return store.admissionId;
      case Wire.setAdmissionId:
        store.setAdmissionId(args['admission_id'] as String);
        return null;
      case Wire.reportLocation:
        final location = store.location;
        if (location is! LatestFix) throw StateError('this core is not fed positions over the wire');
        final fix = args['fix'];
        final gpsTime = args['gps_time'];
        if (fix != null) {
          location.reportFix(GpsFix.fromWire(fix)!);
        } else if (gpsTime != null) {
          location.reportGpsTime(GpsTimeSample.fromWire(gpsTime as Map));
        } else if (args['clock_changed'] == true) {
          store.recordClockChanged();
        } else {
          location.reportNone(args['reason'] as String);
        }
        return null;
      case Wire.uploadStatus:
        return store.uploadStatus().toWire();
      case Wire.revocation:
        return store.revocation()?.toWire();
      case Wire.pullStatus:
        return store.pullStatus().toWire();
      case Wire.chainStatus:
        return store.chainStatus().toWire();
      case Wire.close:
        store.close();
        return null;
    }
    throw StateError('unreachable: $command');
  }
}
