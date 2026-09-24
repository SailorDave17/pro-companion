import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart' as sql;

import 'envelope.dart';
import 'store.dart';
import 'wire.dart';

/// Serves the wire protocol over one [EventStore]. Hosted by whatever owns the
/// core: an isolate spawned by the app today, the foreground service's engine
/// once #32 lands. The protocol is the same in both.
class CoreServer {
  CoreServer(this.store);

  final EventStore store;

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
      case Wire.count:
        return store.count();
      case Wire.deviceId:
        return store.deviceId;
      case Wire.close:
        store.close();
        return null;
    }
    throw StateError('unreachable: $command');
  }
}
