/// Elapsed times per fleet race across the committee's phones (#69): each
/// finish, at the line or at a mark, on whichever phone took it, timed from its
/// race's gun on whichever phone fired it, through each phone's clock offset
/// ([crossPhoneElapsed], #55). Worked out from the log each time it is asked
/// and never stored, so every device timestamp stays as its phone logged it
/// (ADR 001, "Two clocks").
///
/// Nothing here reconciles. Two phones' finishes for one race are both kept,
/// and the race is flagged (criterion 3); deciding between them stays
/// post-pilot (scope constraint 11).
library;

import 'clock_offsets.dart';
import 'envelope.dart';
import 'finishes.dart';
import 'fleets.dart';
import 'order.dart';
import 'results.dart';
import 'starts.dart';
import 'stations.dart';

/// What a fleet race is flagged for, so that scoring and export read it
/// rather than work it out again (criterion 4).
abstract final class FleetRaceFlags {
  /// At least one finish in the race has no elapsed time ([FinishTime.flags]):
  /// a phone recorded no clock offset or could not measure one, or no gun is
  /// held for the race (criterion 2).
  static const unreconciled = 'unreconciled';

  /// More than one phone recorded finishes for the race (criterion 3). Every
  /// phone's are kept, and none is matched against another's.
  static const twoFinishSources = 'two_finish_sources';

  static const all = {unreconciled, twoFinishSources};
}

/// Why one finish has no elapsed time: one of [CrossPhoneFlags.all], naming
/// the phone whose offset is missing or unmeasured, or [noGun].
abstract final class FinishTimeFlags {
  /// No gun is held for its race: the gun has not been pulled to this phone,
  /// or the finish came before the fleet's first gun that day (owner decision
  /// at #69's pickup). Until #113 starts sync in the app, that is every finish
  /// a mark phone reads of its own, since it fires no gun.
  static const noGun = 'no_gun';

  static const all = {...CrossPhoneFlags.all, noGun};
}

/// One finish in a fleet race, with its elapsed time or why there is none.
class FinishTime {
  const FinishTime({
    required this.ulid,
    required this.kind,
    required this.deviceId,
    required this.deviceTs,
    this.mark,
    this.sail,
    this.elapsedMs,
    this.flags = const [],
    this.gunOffsetAgeMs,
    this.finishOffsetAgeMs,
  });

  /// The finish event.
  final String ulid;

  /// [FinishKinds.finish] at the line, or [FinishKinds.atMark].
  final String kind;

  /// The phone that took it.
  final String deviceId;

  /// When it was tapped, on that phone's own clock, as logged.
  final int deviceTs;

  /// The station its phone held, as the core stamped it (#26): the mark a
  /// finish at a mark was taken at. Null from a phone with no station.
  final String? mark;

  /// Her latest sail number; null while nobody has named her.
  final String? sail;

  /// From the race's gun. Null whenever [flags] is not empty.
  final int? elapsedMs;

  /// Why [elapsedMs] is null, from [FinishTimeFlags.all]. A later gun's flags
  /// are here too when the raw clocks put that gun after the finish, since
  /// they cannot rule its race out ([fleetRaceTimes]).
  final List<String> flags;

  /// How old each phone's offset was at the event it was applied to
  /// ([CrossPhoneElapsed]). Both null when none was applied: a gun and a
  /// finish on one phone whose clock was not set between them.
  final int? gunOffsetAgeMs;
  final int? finishOffsetAgeMs;

  bool get flagged => flags.isNotEmpty;

  Map<String, Object?> toWire() => {
        'ulid': ulid,
        'kind': kind,
        'device_id': deviceId,
        'device_ts': deviceTs,
        'mark': mark,
        'sail': sail,
        'elapsed_ms': elapsedMs,
        'flags': [...flags],
        'gun_offset_age_ms': gunOffsetAgeMs,
        'finish_offset_age_ms': finishOffsetAgeMs,
      };

  static FinishTime fromWire(Map w) => FinishTime(
        ulid: w['ulid'] as String,
        kind: w['kind'] as String,
        deviceId: w['device_id'] as String,
        deviceTs: w['device_ts'] as int,
        mark: w['mark'] as String?,
        sail: w['sail'] as String?,
        elapsedMs: w['elapsed_ms'] as int?,
        flags: [for (final f in w['flags'] as List) f as String],
        gunOffsetAgeMs: w['gun_offset_age_ms'] as int?,
        finishOffsetAgeMs: w['finish_offset_age_ms'] as int?,
      );

  @override
  bool operator ==(Object other) =>
      other is FinishTime &&
      other.ulid == ulid &&
      other.kind == kind &&
      other.deviceId == deviceId &&
      other.deviceTs == deviceTs &&
      other.mark == mark &&
      other.sail == sail &&
      other.elapsedMs == elapsedMs &&
      _sameList(other.flags, flags) &&
      other.gunOffsetAgeMs == gunOffsetAgeMs &&
      other.finishOffsetAgeMs == finishOffsetAgeMs;

  @override
  int get hashCode => Object.hash(ulid, kind, deviceId, deviceTs, mark, sail, elapsedMs, Object.hashAll(flags),
      gunOffsetAgeMs, finishOffsetAgeMs);

  @override
  String toString() => 'FinishTime(${sail ?? '-'} on $deviceId at $deviceTs: '
      '${flagged ? 'flagged $flags' : '${elapsedMs}ms'} $ulid)';
}

/// One fleet race's finishes and their elapsed times, as
/// [CoreClient.raceTimes] answers them.
class FleetRaceTimes {
  const FleetRaceTimes({required this.fleet, required this.gun, required this.finishes, required this.flags});

  /// The fleet, or null on a single-fleet day.
  final String? fleet;

  /// The gun the race began with. Null when none is held: the race is then
  /// the fleet's race of the day, on the local date its finishes were tapped
  /// (ADR 001, "Two clocks").
  final String? gun;

  /// The race's finishes at the line and at marks, undone ones left out.
  /// Phone by phone, each phone's in the order it logged them: two phones'
  /// finishes are kept side by side, never merged into one order
  /// (criterion 3).
  final List<FinishTime> finishes;

  /// From [FleetRaceFlags.all].
  final List<String> flags;

  bool get unreconciled => flags.contains(FleetRaceFlags.unreconciled);
  bool get twoFinishSources => flags.contains(FleetRaceFlags.twoFinishSources);

  Map<String, Object?> toWire() => {
        'fleet': fleet,
        'gun': gun,
        'finishes': [for (final f in finishes) f.toWire()],
        'flags': [...flags],
      };

  static FleetRaceTimes fromWire(Map w) => FleetRaceTimes(
        fleet: w['fleet'] as String?,
        gun: w['gun'] as String?,
        finishes: [for (final f in w['finishes'] as List) FinishTime.fromWire(f as Map)],
        flags: [for (final f in w['flags'] as List) f as String],
      );

  @override
  bool operator ==(Object other) =>
      other is FleetRaceTimes &&
      other.fleet == fleet &&
      other.gun == gun &&
      _sameList(other.finishes, finishes) &&
      _sameList(other.flags, flags);

  @override
  int get hashCode => Object.hash(fleet, gun, Object.hashAll(finishes), Object.hashAll(flags));

  @override
  String toString() => 'FleetRaceTimes($fleet race ${gun ?? 'of the day'}, $finishes'
      '${flags.isEmpty ? '' : ', $flags'})';
}

bool _sameList<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The finishes that have a time: at the line, and at a mark. A missed finish
/// has none, so it has no elapsed time; its place is [finishOrder]'s.
const _timed = {FinishKinds.finish, FinishKinds.atMark};

/// The order events were logged in: by phone, then that phone's sequence
/// number.
int _logged(EventEnvelope a, EventEnvelope b) {
  final byDevice = a.deviceId.compareTo(b.deviceId);
  return byDevice != 0 ? byDevice : a.seq.compareTo(b.seq);
}

/// The events [crossPhoneElapsed] looks up besides the gun and the finish it
/// is handed: the clock events, and a gun's time corrections and their undos.
/// Handing it only these keeps a day of finishes, each tried against the
/// day's guns, from scanning the whole log every time.
List<EventEnvelope> _lookups(Iterable<EventEnvelope> events) => [
      for (final e in events)
        if (ClockKinds.all.contains(e.kind) || e.kind == StartKinds.timeCorrected || e.kind == StartKinds.undo) e,
    ];

/// The phone's local date of [ms], as one number: [sameLocalDay]'s reading,
/// taken once per gun and once per finish rather than at every comparison.
int _localDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return d.year * 10000 + d.month * 100 + d.day;
}

/// [fleet]'s races as every phone's events tell them, oldest first: each with
/// its finishes timed from its gun, and its flags (#69). Races nobody has
/// finished are left out, as [racesOf] leaves them out.
///
/// A finish's race is the latest of [raceStarts] it came after, among those
/// whose gun went on the finish's local date (#55's race rule). "After" reads
/// both phones' times through their clock offsets where both are measured,
/// the same reading its elapsed time is, so a finish is never timed before
/// its gun. Where either phone's is missing or unmeasured, it reads the two
/// raw clocks, and that finish is flagged anyway (owner decision at #69's
/// pickup). That holds for a later gun the raw clocks put after the finish
/// too: those clocks cannot rule that race out, so its flags pass to the
/// finish, which is not timed from whichever earlier gun takes it (#69's
/// review). A finish after no such gun is in the fleet's race of the day,
/// with no gun, one race per local date, and first among that date's races.
List<FleetRaceTimes> fleetRaceTimes(Iterable<EventEnvelope> events, {required String? fleet}) {
  final lookups = _lookups(events);
  final guns = [
    for (final s in raceStarts(events, fleet: fleet))
      if (gunTime(lookups, s) case final at) (start: s, at: at, date: _localDate(at)),
  ];
  final undone = undoneBy(events, FinishKinds.undo);
  // A sail number whose payload is not two strings, as no phone of this app
  // writes, is passed over rather than failing every race (#69's review).
  final sails = <String, String>{
    for (final e in events.where((e) => e.kind == FinishKinds.sail).toList()..sort(happened))
      if ((e.payload['finish'], e.payload['sail']) case (final String finish, final String sail)) finish: sail,
  };
  final finishes = [
    for (final e in events)
      if (_timed.contains(e.kind) && fleetOf(e) == fleet && !undone.contains(e.ulid)) e,
  ]..sort(_logged);

  final races = <(String?, int?), ({int date, int startedAt, List<FinishTime> finishes})>{};
  for (final f in finishes) {
    final date = _localDate(f.deviceTs);
    ({EventEnvelope start, int at, int date})? race;
    CrossPhoneElapsed? timed;
    // The flags of later guns read on the raw clocks and put after the finish.
    final unsettled = <String>{};
    for (final g in guns.reversed) {
      if (g.date != date) continue;
      final t = crossPhoneElapsed(lookups, gun: g.start, finish: f);
      final elapsed = t.elapsedMs ?? f.deviceTs - g.at;
      if (elapsed > 0 || (elapsed == 0 && happened(g.start, f) < 0)) {
        (race, timed) = (g, t);
        break;
      }
      unsettled.addAll(t.flags);
    }
    final settled = unsettled.isEmpty;

    final key = race == null ? (null, date) : (race.start.ulid, null);
    final entry = races[key] ??= (date: date, startedAt: race?.at ?? f.deviceTs, finishes: <FinishTime>[]);
    entry.finishes.add(FinishTime(
      ulid: f.ulid,
      kind: f.kind,
      deviceId: f.deviceId,
      deviceTs: f.deviceTs,
      mark: markOf(f),
      sail: switch (sails[f.ulid]) {
        null || '' => null,
        final s => s,
      },
      elapsedMs: settled ? timed?.elapsedMs : null,
      flags: [...{...?timed?.flags, ...unsettled, if (timed == null) FinishTimeFlags.noGun}],
      gunOffsetAgeMs: settled ? timed?.gunOffsetAgeMs : null,
      finishOffsetAgeMs: settled ? timed?.finishOffsetAgeMs : null,
    ));
  }

  // By local date, the race of the day first: it holds only finishes that
  // came before every gun of its date, as they were read, where the phones'
  // raw clocks could put a fast phone's finish after the gun (#69's review).
  // Then by gun. A date has one race of the day at most.
  final keys = races.keys.toList()
    ..sort((a, b) {
      final (x, y) = (races[a]!, races[b]!);
      if (x.date != y.date) return x.date.compareTo(y.date);
      if (a.$1 == null || b.$1 == null) return a.$1 == null ? -1 : 1;
      return x.startedAt.compareTo(y.startedAt);
    });
  return [
    for (final key in keys)
      FleetRaceTimes(
        fleet: fleet,
        gun: key.$1,
        finishes: races[key]!.finishes,
        flags: [
          if (races[key]!.finishes.any((f) => f.flagged)) FleetRaceFlags.unreconciled,
          if ({for (final f in races[key]!.finishes) f.deviceId}.length > 1) FleetRaceFlags.twoFinishSources,
        ],
      ),
  ];
}

/// Every fleet's [fleetRaceTimes] (criterion 4): each fleet the day defines
/// that has a finish, in the order defined, then any other fleet a finish
/// names, then the single-fleet day's. What [CoreClient.raceTimes] answers.
List<FleetRaceTimes> raceTimesOf(Iterable<EventEnvelope> events) {
  final all = events.toList();
  final named = {for (final e in all) if (_timed.contains(e.kind)) fleetOf(e)};
  final defined = [for (final f in fleets(all)) f.id];
  return [
    for (final fleet in [
      ...defined.where(named.contains),
      ...named.where((f) => f != null && !defined.contains(f)),
      if (named.contains(null)) null,
    ])
      ...fleetRaceTimes(all, fleet: fleet),
  ];
}
