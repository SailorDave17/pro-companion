import 'dart:math';

import 'wire.dart';

/// Where a phone was when it logged an event (ADR 001: who, when, where).
/// Filled by #31; null until then and whenever there is no fix.
class GpsFix {
  const GpsFix({required this.lat, required this.lon, this.accuracyM});

  final double lat;
  final double lon;
  final double? accuracyM;

  Map<String, Object?> toWire() => {'lat': lat, 'lon': lon, 'accuracy_m': accuracyM};

  static GpsFix? fromWire(Object? w) {
    if (w == null) return null;
    final m = w as Map;
    return GpsFix(
      lat: (m['lat'] as num).toDouble(),
      lon: (m['lon'] as num).toDouble(),
      accuracyM: (m['accuracy_m'] as num?)?.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GpsFix && other.lat == lat && other.lon == lon && other.accuracyM == accuracyM;

  @override
  int get hashCode => Object.hash(lat, lon, accuracyM);
}

/// What a caller asks the core to append. The core fills in everything that
/// identifies the event: ULID, device, sequence number and device time.
class NewEvent {
  const NewEvent({
    required this.kind,
    required this.source,
    this.payload = const {},
    this.payloadVersion = 1,
    this.person,
    this.role,
    this.gps,
    this.correctsUlid,
  });

  final String kind;
  final String source;
  final Map<String, Object?> payload;
  final int payloadVersion;
  final String? person;
  final String? role;
  final GpsFix? gps;

  /// The event this one corrects. An undo is a new event, never an edit
  /// (ADR 001, scope decision 8).
  final String? correctsUlid;

  Map<String, Object?> toWire() => {
        'kind': kind,
        'source': source,
        'payload': payload,
        'payload_version': payloadVersion,
        'person': person,
        'role': role,
        'gps': gps?.toWire(),
        'corrects_ulid': correctsUlid,
      };

  static NewEvent fromWire(Map w) => NewEvent(
        kind: w['kind'] as String,
        source: w['source'] as String,
        payload: Map<String, Object?>.from(w['payload'] as Map),
        payloadVersion: w['payload_version'] as int,
        person: w['person'] as String?,
        role: w['role'] as String?,
        gps: GpsFix.fromWire(w['gps']),
        correctsUlid: w['corrects_ulid'] as String?,
      );
}

/// One event in the ADR 001 envelope, as stored and as it crosses the ADR 003
/// boundary. Its wire form is plain data: maps, lists, strings and numbers.
class EventEnvelope {
  const EventEnvelope({
    required this.ulid,
    required this.deviceTs,
    required this.deviceId,
    required this.seq,
    required this.source,
    required this.kind,
    required this.payloadVersion,
    required this.payload,
    this.person,
    this.role,
    this.gps,
    this.correctsUlid,
    this.prevHash,
    this.extra = const {},
  });

  /// Client-generated, so every phone can mint ids offline. The merge key.
  final String ulid;

  /// The device's own clock, milliseconds since the epoch, kept verbatim.
  final int deviceTs;
  final String deviceId;

  /// Per-device, from 1, with no gaps on the device that wrote it.
  final int seq;
  final String? person;
  final String? role;
  final GpsFix? gps;

  /// Who produced it: a tap, a hand-typed time (`manual`), `race-timer`...
  final String source;
  final String kind;

  /// The version of [payload]'s schema for this [kind].
  final int payloadVersion;
  final String? correctsUlid;

  /// Reserved for the per-device hash chain. #28 fills it; null until then.
  final String? prevHash;
  final Map<String, Object?> payload;

  /// Envelope fields this version of the core does not know, from an event
  /// written by a newer one. Kept and written back so nothing is dropped.
  final Map<String, Object?> extra;

  static const knownKeys = {
    'ulid',
    'device_ts',
    'device_id',
    'seq',
    'person',
    'role',
    'gps',
    'source',
    'kind',
    'payload_version',
    'corrects_ulid',
    'prev_hash',
    'payload',
  };

  Map<String, Object?> toWire() => {
        ...extra,
        'ulid': ulid,
        'device_ts': deviceTs,
        'device_id': deviceId,
        'seq': seq,
        'person': person,
        'role': role,
        'gps': gps?.toWire(),
        'source': source,
        'kind': kind,
        'payload_version': payloadVersion,
        'corrects_ulid': correctsUlid,
        'prev_hash': prevHash,
        'payload': payload,
      };

  static EventEnvelope fromWire(Map w) => EventEnvelope(
        ulid: w['ulid'] as String,
        deviceTs: w['device_ts'] as int,
        deviceId: w['device_id'] as String,
        seq: w['seq'] as int,
        person: w['person'] as String?,
        role: w['role'] as String?,
        gps: GpsFix.fromWire(w['gps']),
        source: w['source'] as String,
        kind: w['kind'] as String,
        payloadVersion: w['payload_version'] as int,
        correctsUlid: w['corrects_ulid'] as String?,
        prevHash: w['prev_hash'] as String?,
        payload: Map<String, Object?>.from(w['payload'] as Map),
        extra: {
          for (final e in w.entries)
            if (!knownKeys.contains(e.key)) e.key as String: e.value,
        },
      );

  @override
  String toString() => 'EventEnvelope($kind $deviceId#$seq $ulid)';
}

const _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
final _ulidPattern = RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$');

/// A ULID: 48-bit millisecond time, then 80 random bits, in Crockford base32.
/// Sorts by time to the millisecond.
String newUlid(int millis, Random random) {
  final chars = List.filled(26, '0');
  var t = millis;
  for (var i = 9; i >= 0; i--) {
    chars[i] = _crockford[t % 32];
    t ~/= 32;
  }
  for (var i = 10; i < 26; i++) {
    chars[i] = _crockford[random.nextInt(32)];
  }
  return chars.join();
}

bool isUlid(String s) => _ulidPattern.hasMatch(s);

/// Refuses a [NewEvent] the core must not store, before anything is written.
void validateNewEvent(NewEvent e) {
  if (e.kind.isEmpty) throw ArgumentError.value(e.kind, 'kind', 'must not be empty');
  if (e.source.isEmpty) throw ArgumentError.value(e.source, 'source', 'must not be empty');
  if (e.payloadVersion < 1) {
    throw ArgumentError.value(e.payloadVersion, 'payloadVersion', 'must be 1 or more');
  }
  final corrects = e.correctsUlid;
  if (corrects != null && !isUlid(corrects)) {
    throw ArgumentError.value(corrects, 'correctsUlid', 'is not a ULID');
  }
  requireWireSafe(e.payload, 'payload');
}
