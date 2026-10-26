/// What the committee log view shows (#67), worked out in the core from the
/// canonical text it stores and the refusal stubs sync pulls (#64), since
/// neither crosses to the UI: whether this phone's own chain stands, and how
/// each other committee phone's log reads on each race day this phone pulled
/// it from. docs/event-chain.md, "What a phone shows", states the rules.
library;

import 'chain.dart';
import 'stations.dart';

/// How another phone's log reads, worst first: a row shows the first that
/// applies (owner decision at #67's pickup), and the others as lines under it.
abstract final class DeviceChainStates {
  /// A link does not hold: the chain is broken ([ChainState.broken]).
  static const altered = 'altered';

  /// A number is missing between the lowest and highest held. Numbers below
  /// the lowest held do not count: a phone's first events, logged before it
  /// was admitted, never reach shore (#64).
  static const catchingUp = 'catching_up';

  /// The server refused at least one of its events, and every link holds,
  /// each refusal standing in for the event it refused.
  static const refused = 'refused';

  /// Every number from the lowest held to the highest is held, and every link
  /// holds.
  static const verified = 'verified';

  /// Worst first.
  static const all = [altered, catchingUp, refused, verified];
}

/// One event in a chain, named by its number and, where this phone holds its
/// text, its ULID and the time its phone logged it. A refused event has no
/// text here, so only its number.
class ChainPoint {
  const ChainPoint({required this.seq, this.ulid, this.deviceTs});

  final int seq;
  final String? ulid;

  /// On the logging phone's clock, milliseconds since the epoch.
  final int? deviceTs;

  Map<String, Object?> toWire() => {'seq': seq, 'ulid': ulid, 'device_ts': deviceTs};

  static ChainPoint fromWire(Map w) =>
      ChainPoint(seq: w['seq'] as int, ulid: w['ulid'] as String?, deviceTs: w['device_ts'] as int?);

  @override
  bool operator ==(Object other) =>
      other is ChainPoint && other.seq == seq && other.ulid == ulid && other.deviceTs == deviceTs;

  @override
  int get hashCode => Object.hash(seq, ulid, deviceTs);

  @override
  String toString() => 'ChainPoint($seq${ulid == null ? '' : ' $ulid'}${deviceTs == null ? '' : ' at $deviceTs'})';
}

/// Where a broken chain breaks ([ChainVerdict]): the first event whose link
/// does not hold, [at], and the one before it, [afterSeq], which may be the
/// one changed instead (docs/event-chain.md).
class ChainBreak {
  const ChainBreak({required this.at, this.afterSeq, required this.reason});

  final ChainPoint at;
  final int? afterSeq;
  final String reason;

  Map<String, Object?> toWire() => {'at': at.toWire(), 'after_seq': afterSeq, 'reason': reason};

  static ChainBreak fromWire(Map w) =>
      ChainBreak(at: ChainPoint.fromWire(w['at'] as Map), afterSeq: w['after_seq'] as int?, reason: w['reason'] as String);

  @override
  bool operator ==(Object other) =>
      other is ChainBreak && other.at == at && other.afterSeq == afterSeq && other.reason == reason;

  @override
  int get hashCode => Object.hash(at, afterSeq, reason);

  @override
  String toString() => 'ChainBreak(at $at${afterSeq == null ? '' : ' after seq $afterSeq'}: $reason)';
}

/// Another committee phone's log on one race day, as this phone holds it.
class DeviceChain {
  const DeviceChain({
    required this.eventId,
    this.raceDayName,
    required this.deviceId,
    this.role,
    this.mark,
    required this.state,
    required this.first,
    required this.last,
    this.missing = 0,
    this.lastVerified,
    this.refusals = const [],
    this.breakAt,
  });

  /// The race day it was pulled from, and its name when sync read one.
  final String eventId;
  final String? raceDayName;
  final String deviceId;

  /// The role and the station its latest event held carries, as its core
  /// stamped them (#20, #26), so a person can tell the phones apart.
  final String? role;
  final String? mark;

  /// One of [DeviceChainStates.all].
  final String state;

  /// The lowest and highest numbers held, events and refusals both.
  final int first;
  final int last;

  /// How many numbers between [first] and [last] are not held.
  final int missing;

  /// The highest number held unbroken from [first]: everything up to it is
  /// held, and every link in that run holds. Null when the chain is broken.
  final ChainPoint? lastVerified;

  /// Each refusal held for it, by number.
  final List<ChainRefusal> refusals;

  /// Where it breaks, when its state is [DeviceChainStates.altered].
  final ChainBreak? breakAt;

  Map<String, Object?> toWire() => {
        'event_id': eventId,
        'race_day_name': raceDayName,
        'device_id': deviceId,
        'role': role,
        'mark': mark,
        'state': state,
        'first': first,
        'last': last,
        'missing': missing,
        'last_verified': lastVerified?.toWire(),
        'refusals': [for (final r in refusals) r.toWire()],
        'break_at': breakAt?.toWire(),
      };

  static DeviceChain fromWire(Map w) => DeviceChain(
        eventId: w['event_id'] as String,
        raceDayName: w['race_day_name'] as String?,
        deviceId: w['device_id'] as String,
        role: w['role'] as String?,
        mark: w['mark'] as String?,
        state: w['state'] as String,
        first: w['first'] as int,
        last: w['last'] as int,
        missing: w['missing'] as int,
        lastVerified: w['last_verified'] == null ? null : ChainPoint.fromWire(w['last_verified'] as Map),
        refusals: [for (final r in w['refusals'] as List) ChainRefusal.fromWire(r as Map)],
        breakAt: w['break_at'] == null ? null : ChainBreak.fromWire(w['break_at'] as Map),
      );

  @override
  bool operator ==(Object other) =>
      other is DeviceChain &&
      other.eventId == eventId &&
      other.raceDayName == raceDayName &&
      other.deviceId == deviceId &&
      other.role == role &&
      other.mark == mark &&
      other.state == state &&
      other.first == first &&
      other.last == last &&
      other.missing == missing &&
      other.lastVerified == lastVerified &&
      _sameList(other.refusals, refusals) &&
      other.breakAt == breakAt;

  @override
  int get hashCode => Object.hash(eventId, raceDayName, deviceId, role, mark, state, first, last, missing,
      lastVerified, Object.hashAll(refusals), breakAt);

  @override
  String toString() => 'DeviceChain($deviceId on $eventId: $state, $first..$last, missing $missing'
      '${refusals.isEmpty ? '' : ', refused at ${[for (final r in refusals) r.seq].join(', ')}'}'
      '${breakAt == null ? '' : ', $breakAt'})';
}

/// What [CoreClient.chainStatus] answers: this phone's own chain, [ownBreak]
/// being null while it stands, and every other phone's log by race day, the
/// race day with the newest event first, then by device id.
class ChainStatus {
  const ChainStatus({this.ownBreak, this.devices = const []});

  static const empty = ChainStatus();

  final ChainBreak? ownBreak;
  final List<DeviceChain> devices;

  Map<String, Object?> toWire() =>
      {'own_break': ownBreak?.toWire(), 'devices': [for (final d in devices) d.toWire()]};

  static ChainStatus fromWire(Map w) => ChainStatus(
        ownBreak: w['own_break'] == null ? null : ChainBreak.fromWire(w['own_break'] as Map),
        devices: [for (final d in w['devices'] as List) DeviceChain.fromWire(d as Map)],
      );

  @override
  bool operator ==(Object other) =>
      other is ChainStatus && other.ownBreak == ownBreak && _sameList(other.devices, devices);

  @override
  int get hashCode => Object.hash(ownBreak, Object.hashAll(devices));

  @override
  String toString() => 'ChainStatus(own ${ownBreak ?? 'stands'}, $devices)';
}

bool _sameList<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One device's log on one race day, read from [events] (each held event's
/// canonical text, with its decoded wire form) and [refusals]: the state it
/// reads as, worst first, and what the row says beside it.
DeviceChain classifyDeviceChain({
  required String eventId,
  String? raceDayName,
  required String deviceId,
  required List<(String text, Map wire)> events,
  required List<ChainRefusal> refusals,
}) {
  final verdict = verifyChain([for (final (text, _) in events) text], refusals: refusals);
  final bySeq = {for (final (_, w) in events) w['seq'] as int: w};
  final byUlid = {for (final (_, w) in events) w['ulid'] as String: w};
  final held = {...bySeq.keys, for (final r in refusals) r.seq}.toList()..sort();
  final first = held.first;
  final last = held.last;
  var unbroken = first;
  final heldSet = held.toSet();
  while (heldSet.contains(unbroken + 1)) {
    unbroken++;
  }
  ChainPoint point(int seq, Map? w) =>
      ChainPoint(seq: seq, ulid: w?['ulid'] as String?, deviceTs: w?['device_ts'] as int?);

  final seen = <(int, String)>{};
  final refused = [
    for (final r in [...refusals]..sort((a, b) => a.seq != b.seq ? a.seq.compareTo(b.seq) : a.hash.compareTo(b.hash)))
      if (seen.add((r.seq, r.hash))) r,
  ];
  final missing = last - first + 1 - held.length;
  final latest = bySeq.isEmpty ? null : bySeq[bySeq.keys.reduce((a, b) => a > b ? a : b)];
  final broken = verdict.state == ChainState.broken;
  return DeviceChain(
    eventId: eventId,
    raceDayName: raceDayName,
    deviceId: deviceId,
    role: latest?['role'] as String?,
    mark: (latest?['payload'] as Map?)?[markPayloadKey] as String?,
    state: broken
        ? DeviceChainStates.altered
        : missing > 0
            ? DeviceChainStates.catchingUp
            : refused.isNotEmpty
                ? DeviceChainStates.refused
                : DeviceChainStates.verified,
    first: first,
    last: last,
    missing: missing,
    lastVerified: broken ? null : point(unbroken, bySeq[unbroken]),
    refusals: refused,
    breakAt: broken ? breakOf(verdict, byUlid) : null,
  );
}

/// [verdict]'s break point, named by the time its event was logged where
/// [byUlid] holds it.
ChainBreak breakOf(ChainVerdict verdict, Map<String, Map> byUlid) {
  final ulid = verdict.atUlid;
  return ChainBreak(
    at: ChainPoint(seq: verdict.atSeq!, ulid: ulid, deviceTs: ulid == null ? null : byUlid[ulid]?['device_ts'] as int?),
    afterSeq: verdict.afterSeq,
    reason: verdict.reason!,
  );
}
