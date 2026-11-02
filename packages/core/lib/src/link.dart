import 'dart:convert';

import 'chain.dart';
import 'envelope.dart';
import 'fleets.dart';
import 'order.dart';
import 'starts.dart';

/// The companion's half of the race-timer link (ADR 004, #33): what an event
/// from race-timer must look like, what it is logged as, and how a sequence
/// that landed on the wrong fleet is moved. Pure, so the store and FakeCore
/// share every rule and cannot differ.

/// The `source` of everything race-timer logs.
const raceTimerSource = 'race-timer';

/// The sequence card says the link is not active once this long has passed
/// with nothing from race-timer (owner decision on #33, 2026-11-01). race-timer
/// binds only while a sequence runs, so the link is quiet between starts.
const linkQuietMs = 10 * 60 * 1000;

/// The payload key every event of a race-timer sequence carries that
/// sequence's id in.
const linkSequenceKey = 'sequence';

/// race-timer's own clock when the signal fired, kept verbatim (criterion 1).
const linkAtKey = 'at_ms';

/// The phone's clock when the event reached it, stamped before anything else
/// ran, so an event held while the core started keeps its real receipt time.
/// The envelope's `device_ts` is when it was committed.
const linkReceivedKey = 'received_ms';

/// The contract object as race-timer sent it, nested so that a field it adds
/// later can never be read as one of ours: a stray `fleet` or `mark` at the
/// payload's top level would change what the event means.
const linkFieldsKey = 'link';

/// On an event re-logged by a fix, the event it was copied from.
const reloggedFromKey = 'relogged_from';

/// On an undo that took a sequence back, the sequence. A take-back is recorded
/// rather than worked out from what is undone, because an ordinary UNDO GUN
/// can leave nothing of a sequence standing and must not turn the rest off.
const takenBackKey = 'taken_back';

/// The words of the contract. Not a `*Kinds` class: those hold the log's event
/// kinds, and kinds_test reads every string in one as a kind.
abstract final class LinkContract {
  static const version = 1;

  static const sequenceStart = 'sequence_start';
  static const signal = 'signal';
  static const postponement = 'postponement';
  static const individualRecall = 'individual_recall';
  static const generalRecall = 'general_recall';
  static const start = 'start';

  /// The event is stored, or was already. `no_core` and `refused` are answered
  /// by the app's native half, which never reaches this far with either.
  static const accepted = 'accepted';

  /// race-timer's bug: it does not resend this, and resending could not help.
  static const malformed = 'malformed';
}

const _kinds = {
  LinkContract.sequenceStart: StartKinds.sequenceStart,
  LinkContract.signal: StartKinds.signal,
  LinkContract.postponement: StartKinds.postponement,
  LinkContract.individualRecall: StartKinds.individualRecall,
  LinkContract.generalRecall: StartKinds.generalRecall,
  LinkContract.start: StartKinds.start,
};

/// One event from race-timer, checked. Everything [parse] refuses is
/// `malformed`, including JSON the log could never store, because an event
/// the store refused would otherwise read as a failure and be resent for ever.
///
/// "The log" is this phone's. An escaped NUL (`\u0000`) in a string is stored
/// here, but the shore can never take it, so that event stays on this phone.
/// A stated limit, not an oversight: only a race-timer bug sends one, and
/// refusing it would lose the gun here too (owner decision at #33's review,
/// ADR 004).
class LinkEvent {
  const LinkEvent._(this.id, this.kind, this.atMs, this.sequence, this.fields);

  /// race-timer's id for the event, the same on every retry: the dedupe key.
  final String id;

  /// A kind this version does not know is kept and logged as a signal, which
  /// moves no anchor (owner decision on #33): race-timer never resends a
  /// `malformed`, so refusing a kind it adds later would lose the event.
  final String kind;
  final int atMs;
  final String sequence;
  final Map<String, Object?> fields;

  static LinkEvent parse(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const FormatException('not JSON');
    }
    if (json is! Map<String, Object?>) throw const FormatException('not a JSON object');
    final v = json['v'];
    if (v is! int || v != LinkContract.version) throw FormatException('unknown contract version $v');
    final id = json['id'];
    if (id is! String || id.isEmpty) throw const FormatException('no string id');
    final kind = json['kind'];
    if (kind is! String || kind.isEmpty) throw const FormatException('no string kind');
    final atMs = json['at_ms'];
    if (atMs is! int) throw const FormatException('no integer at_ms');
    final sequence = json['sequence'];
    if (sequence is! String || sequence.isEmpty) throw const FormatException('no string sequence');
    try {
      canonicalJson(json);
    } on ArgumentError catch (e) {
      throw FormatException('the log could not store it: ${e.message}');
    }
    return LinkEvent._(id, kind, atMs, sequence, json);
  }
}

/// The core's answer to one event from race-timer.
class LinkAnswer {
  const LinkAnswer({required this.status, this.stored = false, this.reason});

  /// [LinkContract.accepted] or [LinkContract.malformed].
  final String status;

  /// True when this call stored the event. A retry is accepted and stores
  /// nothing, and fires no confirmation (criterion 8).
  final bool stored;

  /// Why it was malformed.
  final String? reason;

  Map<String, Object?> toWire() => {'status': status, 'stored': stored, 'reason': reason};

  static LinkAnswer fromWire(Map w) =>
      LinkAnswer(status: w['status'] as String, stored: w['stored'] as bool, reason: w['reason'] as String?);
}

/// Where a race-timer sequence stands in [events], or null when this phone has
/// logged none of it. Its fleet is its newest event's, undone or not, since a
/// fix's copies are always the newest.
({String? fleet, bool takenBack})? sequenceStanding(Iterable<EventEnvelope> events, String deviceId, String sequence) {
  final own = [
    for (final e in events)
      if (e.deviceId == deviceId && e.payload[linkSequenceKey] == sequence) e,
  ];
  if (own.isEmpty) return null;
  final newest = own.reduce((a, b) => a.seq > b.seq ? a : b);
  return (
    fleet: fleetOf(newest),
    takenBack: events.any((e) => e.kind == StartKinds.undo && e.payload[takenBackKey] == sequence),
  );
}

/// The undo of [ulid] that a take-back of [sequence] is made of.
NewEvent takeBackUndo(String ulid, String sequence) => NewEvent(
      kind: StartKinds.undo,
      source: 'tap',
      correctsUlid: ulid,
      payload: {takenBackKey: sequence},
    );

/// The start an individual recall names: the newest gun of [sequence] still
/// standing, or the fleet's anchor if it fired during [sequence], which is a
/// manual gun when race-timer's was missed. An anchor that fired before the
/// sequence began is an earlier race's gun, and race-timer's own may only be
/// late (#33's review). Null when neither exists yet, and then the recall
/// still finds its gun by [sequence] (`individualRecallsOf`). So is a recall
/// that is the first of its sequence to arrive.
String? _recalledStart(Iterable<EventEnvelope> events, String deviceId, String sequence, String? fleet) {
  final undone = undoneBy(events, StartKinds.undo);
  EventEnvelope? gun;
  int? began;
  for (final e in events) {
    if (e.deviceId != deviceId || e.payload[linkSequenceKey] != sequence) continue;
    final at = firedAt(e);
    if (began == null || at < began) began = at;
    if (e.kind == StartKinds.start && !undone.contains(e.ulid) && (gun == null || onTheWater(e, gun) > 0)) gun = e;
  }
  if (gun != null) return gun.ulid;
  final anchor = elapsedAnchor(events, fleet);
  return anchor != null && began != null && firedAt(anchor) >= began ? anchor.ulid : null;
}

/// What [link] is logged as on [deviceId]. The first event of a sequence to
/// arrive arms it with the fleet selected at that moment ([armed], groom
/// decision G25 and the owner's decisions on #33), normally its
/// `sequence_start`, or a signal resent ahead of it. Every later event of the
/// sequence takes the sequence's fleet. [takenBack] says the PRO took the
/// sequence back, so this late event is logged and undone at once: nothing
/// race-timer fired goes missing, and none of it counts as a race.
({NewEvent event, bool takenBack}) planLink(
  LinkEvent link,
  Iterable<EventEnvelope> events, {
  required String deviceId,
  required int receivedMs,
  required String? Function() armed,
}) {
  final standing = sequenceStanding(events, deviceId, link.sequence);
  final fleet = standing == null ? armed() : standing.fleet;
  final kind = _kinds[link.kind] ?? StartKinds.signal;
  return (
    event: NewEvent(
      kind: kind,
      source: raceTimerSource,
      payload: {
        fleetPayloadKey: fleet,
        linkAtKey: link.atMs,
        linkReceivedKey: receivedMs,
        linkSequenceKey: link.sequence,
        linkFieldsKey: link.fields,
        if (kind == StartKinds.individualRecall) 'start': _recalledStart(events, deviceId, link.sequence, fleet),
      },
    ),
    takenBack: standing?.takenBack ?? false,
  );
}

/// What a fix on [sequence] moves, oldest first (owner decisions on #33). Every
/// event of the sequence still standing. What the PRO tapped on that fleet's
/// card while it ran, up to the fleet's next race-timer sequence: a manual gun,
/// postponement or general recall names no gun, so left behind, a recall would
/// stay on the wrong fleet and the moved gun would anchor as if never recalled.
/// And what names a gun moving, which would otherwise stop matching when it
/// gets a new ULID: a typed time, an individual recall, OCS boats and their
/// clearances.
List<EventEnvelope> sequenceEvents(Iterable<EventEnvelope> events, String deviceId, String sequence) {
  final undone = undoneBy(events, StartKinds.undo);
  final standing = [
    for (final e in events)
      if (e.deviceId == deviceId && !undone.contains(e.ulid)) e,
  ]..sort((a, b) => a.seq.compareTo(b.seq));
  final moving = <String>{};
  final guns = <String>{};
  final result = <EventEnvelope>[];
  var running = false;
  String? fleet;
  for (final e in standing) {
    final inSequence = e.payload[linkSequenceKey] == sequence;
    if (inSequence) {
      running = true;
      fleet = fleetOf(e);
    } else if (running && e.payload[linkSequenceKey] is String && fleetOf(e) == fleet) {
      running = false;
    }
    final tappedDuring = running &&
        StartKinds.sequence.contains(e.kind) &&
        fleetOf(e) == fleet &&
        e.payload[linkSequenceKey] == null;
    final namesGun = (e.kind == StartKinds.ocs || e.kind == StartKinds.individualRecall) && guns.contains(e.payload['start']);
    final corrects = (e.kind == StartKinds.timeCorrected || e.kind == StartKinds.ocsCleared) && moving.contains(e.correctsUlid);
    if (!inSequence && !tappedDuring && !namesGun && !corrects) continue;
    moving.add(e.ulid);
    if (e.kind == StartKinds.start) guns.add(e.ulid);
    result.add(e);
  }
  return result;
}

/// [e] re-logged under [fleet], or as it stood where it carries no fleet of its
/// own: a time fix and a clearance follow the event they name. [moved] maps
/// each event already copied to its copy, so what names one follows it.
/// race-timer's times, its sequence id and the event's source copy across
/// verbatim. The copy's own `device_ts` is when the fix was made, so a tap
/// keeps when it happened in `at_ms`, as race-timer's does ([firedAt]).
NewEvent relogCopy(EventEnvelope e, String? fleet, Map<String, String> moved) {
  final payload = {linkAtKey: e.deviceTs, ...e.payload, reloggedFromKey: e.ulid};
  if (payload.containsKey(fleetPayloadKey)) payload[fleetPayloadKey] = fleet;
  final start = payload['start'];
  if (start is String) payload['start'] = moved[start] ?? start;
  final corrects = e.correctsUlid;
  return NewEvent(
    kind: e.kind,
    source: e.source,
    payload: payload,
    payloadVersion: e.payloadVersion,
    person: e.person,
    role: e.role,
    correctsUlid: corrects == null ? null : moved[corrects] ?? corrects,
  );
}

/// The newest event of [fleet] that race-timer sent and that still stands, or
/// null: the last to fire, not the last to arrive, so a backlog resent out of
/// order cannot put an earlier race back on the card (#33's review). UNDO LAST
/// reaches a sequence through it: before the gun, a sequence is only signals,
/// which are not among a fleet's starts.
EventEnvelope? lastRaceTimerEvent(Iterable<EventEnvelope> events, {required String? fleet}) {
  final undone = undoneBy(events, StartKinds.undo);
  EventEnvelope? last;
  for (final e in events) {
    if (e.source == raceTimerSource &&
        e.payload[linkSequenceKey] is String &&
        fleetOf(e) == fleet &&
        !undone.contains(e.ulid) &&
        (last == null || onTheWater(e, last) > 0)) {
      last = e;
    }
  }
  return last;
}

/// True while something from race-timer reached [deviceId] within the last
/// [linkQuietMs] of [now], by when it arrived: an undone event still did, and
/// a fix's copy keeps its original's time, so a fix wakes nothing. Another
/// phone's event says nothing about this phone's link.
bool linkActive(Iterable<EventEnvelope> events, {required String deviceId, required int now}) {
  for (final e in events) {
    if (e.deviceId != deviceId || e.source != raceTimerSource) continue;
    final received = e.payload[linkReceivedKey];
    final age = now - (received is int ? received : e.deviceTs);
    if (age >= 0 && age < linkQuietMs) return true;
  }
  return false;
}
