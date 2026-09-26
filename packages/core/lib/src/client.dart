import 'dart:async';
import 'dart:isolate';

import 'envelope.dart';
import 'wire.dart';

/// The only way the UI reaches the core (ADR 001, ADR 003). Every call is
/// async, and every argument and result crosses as plain data.
abstract interface class CoreClient {
  /// Appends [event] as this device's next event. Completes once it is
  /// committed on the phone, with the event as stored.
  Future<EventEnvelope> append(NewEvent event);

  /// Every event in the log, in ADR 001 order.
  Future<List<EventEnvelope>> readAll();

  /// How many events the log holds.
  Future<int> count();

  /// This install's device id.
  Future<String> deviceId();

  /// The admission this phone holds (#49), or null when it has never been
  /// admitted.
  Future<String?> admissionId();

  /// Caches [admissionId], `admit_device`'s answer, so that every event
  /// appended from now on carries it (#49). A re-admission calls this again;
  /// events already stored keep the admission they were written under.
  Future<void> setAdmissionId(String admissionId);

  /// Closes the store and stops the core.
  Future<void> close();
}

/// A [CoreClient] speaking the wire protocol to a core behind [SendPort].
class PortCoreClient implements CoreClient {
  PortCoreClient(this._core);

  final SendPort _core;

  Future<Object?> _call(String command, Map<String, Object?> args) {
    requireWireSafe(args, 'args');
    final completer = Completer<Object?>();
    final port = RawReceivePort();
    port.handler = (Object? reply) {
      port.close();
      final r = reply as List;
      if (r[0] == Wire.ok) {
        completer.complete(r[1]);
      } else {
        completer.completeError(CoreException(r[1] as String, r[2] as String));
      }
    };
    _core.send([port.sendPort, command, args]);
    return completer.future;
  }

  @override
  Future<EventEnvelope> append(NewEvent event) async =>
      EventEnvelope.fromWire(await _call(Wire.append, {'event': event.toWire()}) as Map);

  @override
  Future<List<EventEnvelope>> readAll() async => [
        for (final w in await _call(Wire.readAll, const {}) as List) EventEnvelope.fromWire(w as Map),
      ];

  @override
  Future<int> count() async => await _call(Wire.count, const {}) as int;

  @override
  Future<String> deviceId() async => await _call(Wire.deviceId, const {}) as String;

  @override
  Future<String?> admissionId() async => await _call(Wire.admissionId, const {}) as String?;

  @override
  Future<void> setAdmissionId(String admissionId) async {
    await _call(Wire.setAdmissionId, {'admission_id': admissionId});
  }

  @override
  Future<void> close() async {
    await _call(Wire.close, const {});
  }
}
