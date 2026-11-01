import 'dart:async';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart' as sql;

import 'admissions.dart';
import 'envelope.dart';
import 'location.dart';
import 'race_times.dart';
import 'store.dart';
import 'wire.dart';

/// What a core's host wires `join` to (#71): given a role's admission code,
/// admits the phone and stamps the admission on the store, and answers with
/// what the code granted. In the app that is sync, in the core host's engine
/// (#113); the core itself makes no network call. It throws a [CoreException]
/// coded from [JoinCodes] for anything the screen must tell apart.
typedef JoinHandler = Future<Admission> Function(String code);

/// Serves the wire protocol over one [EventStore]. Hosted by whatever owns the
/// core: the foreground service's engine in the app (#32), or an isolate
/// spawned for a test. The protocol is the same in both.
class CoreServer {
  CoreServer(this.store, {this.closable = true, this.join});

  final EventStore store;

  /// False when the host, not a client, owns the core's lifetime: the
  /// foreground service's core serves every client, so a close request from
  /// one of them is refused rather than closing the log under the others.
  final bool closable;

  /// What a `join` request runs (#71), or null for a core nothing is wired
  /// to, which refuses a join as `no_server`.
  final JoinHandler? join;

  /// Handles one request, `[replyPort, command, args]`, and sends the reply.
  /// Returns false once the core has been asked to close. A `join` replies
  /// later, when its handler answers; everything else replies before this
  /// returns.
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
      if (command == Wire.join) {
        _replyLater(reply, _dispatchJoin(args));
        return true;
      }
      final result = _dispatch(command, args);
      requireWireSafe(result, 'result');
      reply.send([Wire.ok, result]);
      return command != Wire.close;
    } catch (e) {
      reply.send(_failure(e));
    }
    return true;
  }

  static List<Object?> _failure(Object e) => switch (e) {
        CoreException(:final code, :final message) => [Wire.err, code, message],
        sql.SqliteException(:final message) => [Wire.err, 'refused', message],
        ArgumentError() || TypeError() => [Wire.err, 'invalid', e.toString()],
        _ => [Wire.err, 'failed', e.toString()],
      };

  /// Replies with [result] once it completes, as the synchronous commands do
  /// at once. A handler that throws something other than a [CoreException]
  /// is a failure, never a crash of the core.
  void _replyLater(SendPort reply, Future<Object?> result) {
    result.then((value) {
      requireWireSafe(value, 'result');
      reply.send([Wire.ok, value]);
    }).catchError((Object e) {
      reply.send(_failure(e));
    });
  }

  Future<Object?> _dispatchJoin(Map args) async {
    final code = args['code'];
    if (code is! String || code.isEmpty) throw ArgumentError.value(code, 'code', 'must be a non-empty string');
    final handler = join;
    if (handler == null) {
      throw joinException(JoinCodes.noServer, 'this core has no server to join through: nothing is wired to it');
    }
    return (await handler(code)).toWire();
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
      case Wire.raceTimes:
        return [for (final r in raceTimesOf(store.readAll())) r.toWire()];
      case Wire.close:
        store.close();
        return null;
    }
    throw StateError('unreachable: $command');
  }
}
