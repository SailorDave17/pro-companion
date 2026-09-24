import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// One committee event in the ADR 001 envelope: a client-generated ULID, a
/// per-device sequence number, device and person, the device's own clock, a
/// GPS position, and the per-device hash chain.
class Envelope {
  Envelope({
    required this.ulid,
    required this.seq,
    required this.deviceId,
    required this.person,
    required this.kind,
    required this.deviceTs,
    required this.lat,
    required this.lon,
    required this.prevHash,
    required this.hash,
    required this.payload,
  });

  final String ulid;
  final int seq;
  final String deviceId;
  final String person;
  final String kind;
  final int deviceTs;
  final double lat;
  final double lon;
  final String prevHash;
  final String hash;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {
        'ulid': ulid,
        'seq': seq,
        'device_id': deviceId,
        'person': person,
        'kind': kind,
        'device_ts': deviceTs,
        'lat': lat,
        'lon': lon,
        'prev_hash': prevHash,
        'hash': hash,
        'payload': payload,
      };

  factory Envelope.fromJson(Map<String, Object?> j) => Envelope(
        ulid: j['ulid']! as String,
        seq: j['seq']! as int,
        deviceId: j['device_id']! as String,
        person: j['person']! as String,
        kind: j['kind']! as String,
        deviceTs: j['device_ts']! as int,
        lat: (j['lat']! as num).toDouble(),
        lon: (j['lon']! as num).toDouble(),
        prevHash: j['prev_hash']! as String,
        hash: j['hash']! as String,
        payload: Map<String, Object?>.from(j['payload']! as Map),
      );

  String encode() => jsonEncode(toJson());

  static Envelope decode(String s) =>
      Envelope.fromJson(jsonDecode(s) as Map<String, Object?>);
}

/// The hash over everything but the hash itself, chained to the device's
/// previous event. A removed or altered event breaks the chain (ADR 001).
String chainHash({
  required String prevHash,
  required String ulid,
  required int seq,
  required String deviceId,
  required String person,
  required String kind,
  required int deviceTs,
  required double lat,
  required double lon,
  required Map<String, Object?> payload,
}) {
  final canonical = jsonEncode([
    prevHash,
    ulid,
    seq,
    deviceId,
    person,
    kind,
    deviceTs,
    lat,
    lon,
    payload,
  ]);
  return sha256.convert(utf8.encode(canonical)).toString();
}

const _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// A ULID: 48-bit millisecond time then 80 random bits, Crockford base32,
/// 26 characters. Sorts by time to the millisecond.
String ulid(int millis, Random random) {
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
