/// An in-memory core for widget tests: the UI is driven against it instead of
/// a real store (#24 criterion 7, and #32's "UI widget tests still pass
/// against the fake core").
library;

import 'dart:math';

import 'src/client.dart';
import 'src/envelope.dart';
import 'src/roles.dart';
import 'src/stations.dart';
import 'src/uploads.dart';
import 'src/wire.dart';

/// Behaves like the real core - sequence numbers, ULIDs, ADR 001 order - and
/// holds the UI to the same boundary rule: an argument that could not cross
/// an isolate-group boundary is refused here too, so a UI test fails where
/// the real core would.
class FakeCore implements CoreClient {
  FakeCore({this.deviceIdValue = '01J0000000FAKEDEVICE00000A', int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final String deviceIdValue;
  final int Function() _clock;
  final _events = <EventEnvelope>[];
  final _random = Random(24);
  String? _admissionId;

  /// When set, every call fails with it, for testing how the UI copes.
  CoreException? failWith;

  /// How many calls the UI has made, by command name.
  final calls = <String, int>{};

  Future<T> _call<T>(String command, T Function() body) async {
    calls[command] = (calls[command] ?? 0) + 1;
    // Async like the real port, but a microtask rather than a timer, so a
    // widget test never ends with a timer still pending.
    await Future<void>.value();
    final failure = failWith;
    if (failure != null) throw failure;
    return body();
  }

  /// Adds events as though they were already in the log.
  void seed(Iterable<EventEnvelope> events) => _events.addAll(events);

  /// What [uploadStatus] answers. The fake runs no sync, so a test sets it.
  UploadStatus uploadStatusValue = UploadStatus.empty;

  @override
  Future<EventEnvelope> append(NewEvent event) => _call(Wire.append, () {
        requireWireSafe(event.toWire(), 'event');
        validateNewEvent(event);
        final now = _clock();
        final seq = 1 + _events.where((e) => e.deviceId == deviceIdValue).length;
        final e = EventEnvelope(
          ulid: newUlid(now, _random),
          deviceTs: now,
          deviceId: deviceIdValue,
          seq: seq,
          person: event.person,
          // As the real core does (#20): the phone's role, unless the event
          // names one. Seeded role picks count, as stored ones do there.
          role: event.role ?? currentRole(_events, deviceIdValue),
          admissionId: _admissionId,
          gps: event.gps,
          source: event.source,
          kind: event.kind,
          payloadVersion: event.payloadVersion,
          correctsUlid: event.correctsUlid,
          // And the phone's station (#26), unless the event names a mark.
          payload: withStation(event.payload, currentStation(_events, deviceIdValue)),
        );
        _events.add(e);
        return e;
      });

  @override
  Future<List<EventEnvelope>> readAll() => _call(Wire.readAll, () {
        final sorted = [..._events]..sort((a, b) {
            final byTs = a.deviceTs.compareTo(b.deviceTs);
            if (byTs != 0) return byTs;
            final byDevice = a.deviceId.compareTo(b.deviceId);
            return byDevice != 0 ? byDevice : a.ulid.compareTo(b.ulid);
          });
        return sorted;
      });

  @override
  Future<int> count() => _call(Wire.count, () => _events.length);

  @override
  Future<String> deviceId() => _call(Wire.deviceId, () => deviceIdValue);

  @override
  Future<String?> admissionId() => _call(Wire.admissionId, () => _admissionId);

  @override
  Future<void> setAdmissionId(String admissionId) => _call(Wire.setAdmissionId, () {
        validateAdmissionId(admissionId);
        _admissionId = admissionId;
      });

  @override
  Future<UploadStatus> uploadStatus() => _call(Wire.uploadStatus, () {
        // Through the wire form, so a status the real core could not send
        // fails here too.
        final wire = uploadStatusValue.toWire();
        requireWireSafe(wire, 'uploadStatus');
        return UploadStatus.fromWire(wire);
      });

  @override
  Future<void> close() => _call(Wire.close, () {});
}
