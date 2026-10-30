import 'dart:math';

import 'envelope.dart';
import 'finishes.dart';
import 'fleets.dart';
import 'location.dart';
import 'roundings.dart';
import 'starts.dart';

/// Each phone's clock against satellite time, recorded per race (#55, groom
/// decision G10: a finish at any boat uses GPS time, with a clock offset
/// recorded per device per race). Every `device_ts` stays its phone's own
/// clock, verbatim (ADR 001). The offset is what lets a finish on one phone be
/// timed against a gun on another.
///
/// The core appends the clock-offset event itself, as it stamps the position,
/// role and station, so no screen and no race-timer path has to remember to.
/// It goes in just before the event that joins the race ([raceToJoin]), in the
/// same commit, so that event's offset is its phone's latest before it.
abstract final class ClockKinds {
  /// This phone's offset from satellite time as it joined a race.
  /// `payload.offset_ms` is satellite time minus device time,
  /// `uncertainty_ms` the platform's figure for it (null when the phone stated
  /// none), and `age_ms` how long before this event the fix that measured it
  /// was. With no offset all three are null and `payload.reason` says why, one
  /// of `ClockOffsetReasons.all`. `payload.fleet` is the race's fleet, and
  /// `payload.race` the gun it began with, or null when the phone knows of no
  /// gun for that fleet.
  static const offset = 'clock.offset';

  /// This phone's clock was set, by hand or by network time (owner decision
  /// on #55, after its review). Every offset recorded before it was measured
  /// against the clock as it was, so a race counts as joined only by an
  /// offset after it, and one phone's own two readings either side of it are
  /// no longer comparable as they stand.
  static const changed = 'clock.changed';

  static const all = {offset, changed};
}

/// Builds the clock events. Only the core appends one.
abstract final class ClockEvents {
  /// Who writes a clock event: the core, on its own account.
  static const source = 'core';

  static NewEvent changed() => const NewEvent(kind: ClockKinds.changed, source: source);

  static NewEvent offset({required String? fleet, required String? race, required ClockOffsetStamp stamp}) =>
      NewEvent(
        kind: ClockKinds.offset,
        source: source,
        payload: {
          fleetPayloadKey: fleet,
          'race': race,
          'offset_ms': stamp.offsetMs,
          'uncertainty_ms': stamp.uncertaintyMs,
          'age_ms': stamp.ageMs,
          'reason': stamp.reason,
        },
      );
}

/// A race an event joins, on a phone with no clock offset for it yet.
class RaceJoin {
  const RaceJoin({required this.fleet, required this.race}) : atOwnGun = false;

  /// The event is itself the race's gun, so the race is named by the ULID the
  /// gun is about to be given.
  const RaceJoin.atOwnGun({required this.fleet})
      : race = null,
        atOwnGun = true;

  final String? fleet;

  /// The gun the race began with, or null when the phone knows of none.
  final String? race;
  final bool atOwnGun;
}

/// The events a phone joins a race with: its gun, and its finishes at the line
/// or at a mark. Those are the two ends of an elapsed time. And its roundings
/// (#54), since the running order (#68) puts two phones' roundings at a gate
/// side by side.
const _joining = {StartKinds.start, FinishKinds.finish, FinishKinds.atMark, RoundingKinds.rounding};

/// True when [a] and [b], milliseconds since the epoch, fall on the same local
/// date on this phone.
bool sameLocalDay(int a, int b) {
  final x = DateTime.fromMillisecondsSinceEpoch(a);
  final y = DateTime.fromMillisecondsSinceEpoch(b);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

/// The gun [fleet]'s race began with, as [events] tell it at [now]: the
/// fleet's latest gun not recalled, its own phone's or pulled from another
/// (#64), when that gun went on the local date of [now]. Null when there is no
/// such gun, which is the fleet's race of the day. The rule [raceToJoin]
/// states; a rounding is stamped with it (#54), and the running order (#68)
/// reads it.
String? raceGun(Iterable<EventEnvelope> events, String? fleet, {required int now}) {
  final anchor = elapsedAnchor(events, fleet);
  return anchor != null && sameLocalDay(anchor.deviceTs, now) ? anchor.ulid : null;
}

/// The race [event] joins when it is appended as [deviceId]'s next event at
/// [now], or null when it joins none or one that phone already has an offset
/// for (owner decision on #55, 2026-10-26):
///
/// - a gun always joins its fleet's race, which it begins;
/// - a finish, at the line or at a mark, or a rounding (#54), joins its fleet's
///   race when the phone has no offset for that race yet. The race is the
///   fleet's latest gun not recalled that the phone knows of, its own or
///   pulled from another phone (#64), when that gun went on the phone's local
///   date of [now] ([raceGun]). With no such gun known, it is that fleet's
///   race of the day on this phone.
///
/// Only an offset recorded since the phone's last `clock.changed` counts, so
/// a set clock makes the next finish join again. And a race joined only by
/// offsets that could not be measured is joined again once [measuredNow]
/// says the phone has satellite time, so its later finishes are not left
/// unmeasured for the rest of the race. Both after #55's review.
///
/// [events] is everything the phone holds, every phone's guns included.
RaceJoin? raceToJoin(Iterable<EventEnvelope> events, NewEvent event,
    {required String deviceId, required int now, required bool measuredNow}) {
  if (!_joining.contains(event.kind)) return null;
  final fleet = event.payload[fleetPayloadKey] as String?;
  if (event.kind == StartKinds.start) return RaceJoin.atOwnGun(fleet: fleet);

  bool sameDay(EventEnvelope e) => sameLocalDay(e.deviceTs, now);

  final race = raceGun(events, fleet, now: now);
  final own = [for (final e in events) if (e.deviceId == deviceId && ClockKinds.all.contains(e.kind)) e];
  final lastChange = [for (final e in own) if (e.kind == ClockKinds.changed) e.seq].fold(0, max);
  final joins = [
    for (final e in own)
      if (e.kind == ClockKinds.offset &&
          e.seq > lastChange &&
          fleetOf(e) == fleet &&
          e.payload['race'] == race &&
          (race != null || sameDay(e)))
        e,
  ];
  if (joins.isEmpty) return RaceJoin(fleet: fleet, race: race);
  final measured = joins.any((e) => e.payload['offset_ms'] != null);
  return measured || !measuredNow ? null : RaceJoin(fleet: fleet, race: race);
}

/// The clock-offset event in force for [event]: the latest its own phone
/// recorded before it, by that phone's sequence numbers. Null when that phone
/// recorded none before it. That is the last known offset, however old; its
/// `age_ms` and the time since say how old. A `clock.changed` needs no check
/// here: [raceToJoin] makes the phone's next gun or finish after one record a
/// fresh offset, so a timed event never reaches back across a set.
EventEnvelope? offsetFor(Iterable<EventEnvelope> events, EventEnvelope event) {
  EventEnvelope? latest;
  for (final e in events) {
    if (e.kind == ClockKinds.offset &&
        e.deviceId == event.deviceId &&
        e.seq < event.seq &&
        (latest == null || e.seq > latest.seq)) {
      latest = e;
    }
  }
  return latest;
}

/// Why an elapsed time across two phones was not computed (#55 criterion 5).
abstract final class CrossPhoneFlags {
  /// The gun's phone recorded no clock offset before the gun.
  static const gunPhoneNoOffset = 'gun_phone_no_offset';

  /// The gun's phone recorded one, but it says the offset could not be
  /// measured.
  static const gunPhoneUnmeasured = 'gun_phone_offset_unmeasured';

  /// As [gunPhoneNoOffset], for the finish's phone.
  static const finishPhoneNoOffset = 'finish_phone_no_offset';

  /// As [gunPhoneUnmeasured], for the finish's phone.
  static const finishPhoneUnmeasured = 'finish_phone_offset_unmeasured';

  static const all = {gunPhoneNoOffset, gunPhoneUnmeasured, finishPhoneNoOffset, finishPhoneUnmeasured};
}

/// A finish's elapsed time from a gun, or why it was not computed.
class CrossPhoneElapsed {
  /// Both taken on one phone, its clock not set between them: its own clock
  /// times both, so no offset enters.
  const CrossPhoneElapsed.samePhone(int this.elapsedMs)
      : flags = const [],
        gunOffsetAgeMs = null,
        finishOffsetAgeMs = null;

  /// Read in satellite time through each phone's offset, each offset with its
  /// age at the event it was applied to: two phones, or one whose clock was
  /// set between the two.
  const CrossPhoneElapsed.measured(int this.elapsedMs,
      {required int this.gunOffsetAgeMs, required int this.finishOffsetAgeMs})
      : flags = const [];

  /// At least one had no measured offset: flagged, never computed from the
  /// raw clocks.
  const CrossPhoneElapsed.flagged(this.flags)
      : elapsedMs = null,
        gunOffsetAgeMs = null,
        finishOffsetAgeMs = null;

  /// Null whenever [flags] is not empty.
  final int? elapsedMs;

  /// Every reason it was not computed, from [CrossPhoneFlags.all].
  final List<String> flags;

  /// How old each phone's offset was at the event it was applied to: its fix
  /// age when recorded, plus the time from then to the event (criterion 4).
  final int? gunOffsetAgeMs;
  final int? finishOffsetAgeMs;

  bool get flagged => flags.isNotEmpty;

  @override
  String toString() => flagged
      ? 'CrossPhoneElapsed(flagged: $flags)'
      : 'CrossPhoneElapsed(${elapsedMs}ms, offsets ${gunOffsetAgeMs}ms and ${finishOffsetAgeMs}ms old)';
}

/// [finish]'s elapsed time from [gun] (#55): from the gun's [gunTime], so a
/// corrected gun counts, to the finish's device time. On one phone whose clock
/// was not set between the two, that is the difference of its own two
/// readings. Otherwise each reading is first moved to satellite time by its
/// own phone's offset in force ([offsetFor]); a phone with none recorded, or
/// one that could not be measured, flags the result instead (criterion 5).
/// #69 reads this per fleet race.
CrossPhoneElapsed crossPhoneElapsed(Iterable<EventEnvelope> events,
    {required EventEnvelope gun, required EventEnvelope finish}) {
  final gunAt = gunTime(events, gun);
  if (gun.deviceId == finish.deviceId) {
    final (from, to) = gun.seq < finish.seq ? (gun.seq, finish.seq) : (finish.seq, gun.seq);
    final clockSet = events.any(
        (e) => e.kind == ClockKinds.changed && e.deviceId == gun.deviceId && e.seq > from && e.seq < to);
    if (!clockSet) return CrossPhoneElapsed.samePhone(finish.deviceTs - gunAt);
  }

  final gunOffset = offsetFor(events, gun);
  final finishOffset = offsetFor(events, finish);
  final flags = [
    if (gunOffset == null)
      CrossPhoneFlags.gunPhoneNoOffset
    else if (gunOffset.payload['offset_ms'] == null)
      CrossPhoneFlags.gunPhoneUnmeasured,
    if (finishOffset == null)
      CrossPhoneFlags.finishPhoneNoOffset
    else if (finishOffset.payload['offset_ms'] == null)
      CrossPhoneFlags.finishPhoneUnmeasured,
  ];
  if (flags.isNotEmpty) return CrossPhoneElapsed.flagged(flags);

  int offsetMs(EventEnvelope offset) => offset.payload['offset_ms'] as int;
  int ageAt(EventEnvelope offset, EventEnvelope at) => (offset.payload['age_ms'] as int) + at.deviceTs - offset.deviceTs;
  return CrossPhoneElapsed.measured(
    (finish.deviceTs + offsetMs(finishOffset!)) - (gunAt + offsetMs(gunOffset!)),
    gunOffsetAgeMs: ageAt(gunOffset, gun),
    finishOffsetAgeMs: ageAt(finishOffset, finish),
  );
}
