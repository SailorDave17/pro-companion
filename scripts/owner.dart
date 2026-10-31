// The owner's tooling for the pilot. A club admin acts through the owner's service_role scripts
// (groom decision G27), so this is where clubs, events, race areas and admission codes come from.
// #63 adds its first subcommand, #65 its codes, #5 the sign-in mode and #72 revoke.
//
//   dart run scripts/owner.dart provision --club <name> --event <name> --date <yyyy-mm-dd>
//       --race-area <name> [--race-area <name> ...] [--project <ref>]
//   dart run scripts/owner.dart sign-in-mode --club <name>
//       --mode device_handoff|named_volunteers|both [--project <ref>]
//   dart run scripts/owner.dart revoke --club <name> --event <name> --date <yyyy-mm-dd>
//       [--device <id>] [--project <ref>]
//   dart run scripts/owner.dart revoke --event-id <id> [--device <id>] [--project <ref>]
//
// provision reuses the club of exactly that name, or provisions one when there is none. It then
// creates the event and its race areas, and prints every id and the event's admission codes: one
// for each event-wide role, and one per race area for each bound role (groom decisions G26 and
// G38). A code admits a phone to exactly its role and race area. Each is printed once and stored
// only as a hash.
//
// sign-in-mode switches how the club's phones sign in (groom decision G39): device_handoff admits
// an anonymous sign-in, named_volunteers a named account signed in by magic link, and both either.
// A club starts at both. The switch applies to phones admitted after it; a phone already admitted
// is unaffected, and nothing is reinstalled.
//
// revoke takes a sign-in off an event. With no --device it lists the event's admissions and changes
// nothing. Each line starts with the id of the sign-in holding the admission: the Auth user the
// phone signed in as, which a role change keeps (#70). With --device it marks that sign-in's active
// admissions revoked through revoke_device, so its next write to the event is refused. A revocation
// is never lifted.
//
// The id is a sign-in, not a handset. A named volunteer's id is their account, so a revoke takes
// every phone signed in to it off the event, and a device-handoff phone that lost its session signs
// in as a new id, so one phone can hold two. The event is named as provision names it, or by the id
// provision printed, which is the way to tell apart two events sharing a club, name and date.
//
// With no --project it targets the local stack, taking the stack's URL and secret key from
// `supabase status`. It reaches a live project only when --project names it, and then reads that
// project's secret key from SUPABASE_SECRET_KEY, in your shell or in the git-ignored .env.local.
// Owner tooling is not a client path: no phone ever holds this key.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'migrate_live.dart' show parseEnvFile;

/// The Supabase CLI that answers for the local stack. Pinned, because `npx --no-install supabase`
/// resolves the newest published version and refuses it when only an older one is installed.
const localCli = ['npx', '--yes', 'supabase@2.117.0'];

/// Where a live project's secret key is looked for: the shell, then .env.local.
const secretKeyName = 'SUPABASE_SECRET_KEY';

/// Crockford's base32 alphabet: no I, L, O or U, so a code read aloud or typed on a wet phone has no
/// look-alikes.
const codeAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

const usage = 'usage: dart run scripts/owner.dart provision --club <name> --event <name> '
    '--date <yyyy-mm-dd> --race-area <name> [--race-area <name> ...] [--project <ref>]\n'
    '       dart run scripts/owner.dart sign-in-mode --club <name> '
    '--mode device_handoff|named_volunteers|both [--project <ref>]\n'
    '       dart run scripts/owner.dart revoke --club <name> --event <name> '
    '--date <yyyy-mm-dd> [--device <id>] [--project <ref>]\n'
    '       dart run scripts/owner.dart revoke --event-id <id> [--device <id>] [--project <ref>]';

/// How a club's phones may sign in (groom decision G39), spelled as the server stores them.
const signInModes = ['device_handoff', 'named_volunteers', 'both'];

class UsageError implements Exception {
  UsageError(this.message);

  final String message;

  @override
  String toString() => message;
}

class ServiceError implements Exception {
  ServiceError(this.status, this.body);

  final int status;
  final String body;

  @override
  String toString() => 'the project answered $status: $body';
}

class ProvisionArgs {
  ProvisionArgs({
    required this.club,
    required this.event,
    required this.date,
    required this.raceAreas,
    this.project,
  });

  final String club;
  final String event;
  final String date;
  final List<String> raceAreas;
  final String? project;
}

/// The arguments after `provision`. Every flag takes a value, and --race-area repeats. Anything the
/// server would refuse part-way through, after the event exists, is refused here first.
ProvisionArgs parseProvision(List<String> args) {
  String? club, event, date, project;
  final raceAreas = <String>[];
  for (var i = 0; i < args.length; i += 2) {
    final flag = args[i];
    if (i + 1 >= args.length) throw UsageError('$flag needs a value');
    final value = args[i + 1].trim();
    switch (flag) {
      case '--club':
        club = value;
      case '--event':
        event = value;
      case '--date':
        date = value;
      case '--race-area':
        raceAreas.add(value);
      case '--project':
        project = value;
      default:
        throw UsageError('unknown flag $flag');
    }
  }
  if (club == null || club.isEmpty) throw UsageError('--club is required');
  if (event == null || event.isEmpty) throw UsageError('--event is required');
  if (date == null || !isCalendarDate(date)) throw UsageError('--date must be a real yyyy-mm-dd date');
  if (raceAreas.isEmpty) throw UsageError('at least one --race-area is required');
  if (raceAreas.any((name) => name.isEmpty)) throw UsageError('a --race-area needs a name');
  if (raceAreas.toSet().length != raceAreas.length) {
    throw UsageError('a race area is named twice; each name is one race area of the event');
  }
  requireProjectRef(project);
  return ProvisionArgs(club: club, event: event, date: date, raceAreas: raceAreas, project: project);
}

void requireProjectRef(String? project) {
  if (project != null && !RegExp(r'^[a-z]{20}$').hasMatch(project)) {
    throw UsageError('--project takes a project ref: 20 lowercase letters');
  }
}

class SignInModeArgs {
  SignInModeArgs({required this.club, required this.mode, this.project});

  final String club;
  final String mode;
  final String? project;
}

/// The arguments after `sign-in-mode`. Every flag takes a value, and none repeats.
SignInModeArgs parseSignInMode(List<String> args) {
  String? club, mode, project;
  for (var i = 0; i < args.length; i += 2) {
    final flag = args[i];
    if (i + 1 >= args.length) throw UsageError('$flag needs a value');
    final value = args[i + 1].trim();
    switch (flag) {
      case '--club':
        club = value;
      case '--mode':
        mode = value;
      case '--project':
        project = value;
      default:
        throw UsageError('unknown flag $flag');
    }
  }
  if (club == null || club.isEmpty) throw UsageError('--club is required');
  if (mode == null || !signInModes.contains(mode)) {
    throw UsageError('--mode must be one of ${signInModes.join(', ')}');
  }
  requireProjectRef(project);
  return SignInModeArgs(club: club, mode: mode, project: project);
}

class RevokeArgs {
  RevokeArgs({this.club, this.event, this.date, this.eventId, this.device, this.project});

  final String? club;
  final String? event;
  final String? date;
  final String? eventId;
  final String? device;
  final String? project;
}

/// The arguments after `revoke`. The event is named by --club, --event and --date together, or by
/// --event-id alone. Every flag takes a value. A flag given twice is refused: with two phones lost,
/// keeping only the last --device would leave the first one writing behind an exit 0.
RevokeArgs parseRevoke(List<String> args) {
  String? club, event, date, eventId, device, project;
  final seen = <String>{};
  for (var i = 0; i < args.length; i += 2) {
    final flag = args[i];
    if (i + 1 >= args.length) throw UsageError('$flag needs a value');
    if (!seen.add(flag)) {
      throw UsageError('$flag is given twice: revoke acts on one event and one sign-in, so run it '
          'once for each');
    }
    final value = args[i + 1].trim();
    switch (flag) {
      case '--club':
        club = value;
      case '--event':
        event = value;
      case '--date':
        date = value;
      case '--event-id':
        eventId = value;
      case '--device':
        device = value;
      case '--project':
        project = value;
      default:
        throw UsageError('unknown flag $flag');
    }
  }
  if (eventId != null) {
    if (club != null || event != null || date != null) {
      throw UsageError('--event-id stands alone: name the event by it, or by --club, --event and --date');
    }
    if (!isUuid(eventId)) throw UsageError('--event-id takes the event id provision printed');
  } else {
    if (club == null || club.isEmpty) throw UsageError('--club is required');
    if (event == null || event.isEmpty) throw UsageError('--event is required');
    if (date == null || !isCalendarDate(date)) throw UsageError('--date must be a real yyyy-mm-dd date');
  }
  if (device != null && !isUuid(device)) {
    throw UsageError('--device takes the id the event\'s list prints at the start of the phone\'s line');
  }
  requireProjectRef(project);
  return RevokeArgs(
      club: club, event: event, date: date, eventId: eventId, device: device, project: project);
}

/// True for an id in the form the server prints one.
bool isUuid(String value) =>
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').hasMatch(value);

/// True for a yyyy-mm-dd that names a day on the calendar. DateTime.parse would roll 2026-02-30
/// over to 2 March.
bool isCalendarDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final parsed = DateTime.tryParse(value);
  return parsed != null && parsed.toIso8601String().startsWith(value);
}

/// A new admission code: two groups of four characters from [codeAlphabet].
String newAdmissionCode([Random? random]) {
  final r = random ?? Random.secure();
  String group() => List.generate(4, (_) => codeAlphabet[r.nextInt(codeAlphabet.length)]).join();
  return '${group()}-${group()}';
}

/// The roles that work across the whole event, one code each (docs/roles.md).
const eventWideRoles = ['overall_pro', 'scorer', 'safety'];

/// The roles bound to one race area, one code each per race area (docs/roles.md, G38).
const raceAreaRoles = ['course_pro', 'recorder', 'mark_boat'];

/// One admission code's role, and for a bound role the race area it works on.
typedef CodeSlot = ({String role, String? raceArea});

/// Every code an event with [raceAreas] gets, in the order they are printed: the event-wide roles,
/// then each race area's bound roles.
List<CodeSlot> codeSlots(List<String> raceAreas) => [
      for (final role in eventWideRoles) (role: role, raceArea: null),
      for (final raceArea in raceAreas)
        for (final role in raceAreaRoles) (role: role, raceArea: raceArea),
    ];

class Target {
  Target(this.apiUrl, this.secretKey, this.label);

  final Uri apiUrl;
  final String secretKey;
  final String label;
}

typedef StatusReader = Future<Map<String, String>> Function();

/// An event, as revoke prints it.
typedef RaceDay = ({String id, String name, String date});

/// One row of an event's admissions. [device] is the sign-in holding it: the Auth user the phone
/// signed in as, which a role change keeps (#70) where the row's own [id] does not.
class Admission {
  Admission.fromRow(Map<Object?, Object?> row)
      : id = row['id'] as String,
        device = row['auth_uid'] as String,
        role = row['role'] as String,
        raceArea = (row['course'] as Map?)?['name'] as String?,
        person = row['person'] as String?,
        admittedAt = row['admitted_at'] as String,
        superseded = row['superseded_by'] != null,
        revoked = row['revoked_at'] != null;

  final String id;
  final String device;
  final String role;
  final String? raceArea;
  final String? person;
  final String admittedAt;
  final bool superseded;
  final bool revoked;

  bool get isActive => !superseded && !revoked;

  String get state =>
      isActive ? 'active' : [if (superseded) 'superseded', if (revoked) 'revoked'].join(', ');

  /// The printed line: the sign-in, then the admission's role, race area, person, time and state.
  /// [person] is free text a phone supplies, so a control character in it prints as a ?, and it
  /// cannot break the line or move the cursor over the list the owner chooses from.
  String get line => 'admission   $device  $role  ${raceArea ?? 'whole event'}  '
      '${person?.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '?') ?? 'no person'}  $admittedAt  $state';
}

/// The local stack unless [project] names a live one. A secret key in the shell or in .env.local
/// never sends a run live on its own.
Future<Target> resolveTarget(
  String? project, {
  required Map<String, String> environment,
  required Map<String, String> envFile,
  required StatusReader localStatus,
}) async {
  if (project == null) {
    final status = await localStatus();
    final url = status['API_URL'];
    final key = status['SECRET_KEY'];
    if (url == null || url.isEmpty || key == null || key.isEmpty) {
      throw StateError('supabase status gave no API_URL and SECRET_KEY: is the local stack '
          'running? (README, Server side)');
    }
    return Target(Uri.parse(url), key, 'the local stack');
  }
  final key = environment[secretKeyName] ?? envFile[secretKeyName];
  if (key == null || key.isEmpty) {
    throw StateError('no secret key for project $project: looked for $secretKeyName in the '
        'environment and in .env.local, which names: '
        '${envFile.keys.isEmpty ? '(nothing)' : envFile.keys.join(', ')}');
  }
  return Target(Uri.https('$project.supabase.co'), key, 'live project $project');
}

/// `supabase status -o env`, parsed. The values stay in memory; nothing here prints them.
Future<Map<String, String>> readLocalStatus() async {
  final result = await Process.run(
      localCli.first, [...localCli.skip(1), 'status', '-o', 'env'],
      runInShell: true);
  if (result.exitCode != 0) {
    throw StateError('supabase status failed (exit ${result.exitCode}): is the local stack running?');
  }
  return parseEnvFile(result.stdout as String);
}

/// PostgREST under the service key: the owner's path to the service_role functions.
class ServiceApi {
  ServiceApi(this.target);

  final Target target;

  Future<Object?> _send(String method, String path,
      {Map<String, String>? query, Object? body}) async {
    final client = HttpClient();
    try {
      final request =
          await client.openUrl(method, target.apiUrl.replace(path: path, queryParameters: query));
      request.headers.set('apikey', target.secretKey);
      // A legacy service_role key is a JWT and has to travel as a bearer token as well. A new
      // secret key must not: the gateway mints the JWT from the apikey header itself.
      if (target.secretKey.startsWith('eyJ')) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${target.secretKey}');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode ~/ 100 != 2) throw ServiceError(response.statusCode, text);
      return text.isEmpty ? null : jsonDecode(text);
    } finally {
      client.close();
    }
  }

  /// Calls a function with named arguments and returns the text it answers with: an id, or for
  /// set_sign_in_mode the mode it replaced.
  Future<String> rpc(String function, Map<String, Object?> args) async =>
      await _send('POST', '/rest/v1/rpc/$function', body: args) as String;

  /// The ids of the clubs named exactly [name].
  Future<List<String>> clubIdsNamed(String name) async {
    final rows =
        await _send('GET', '/rest/v1/club', query: {'select': 'id', 'name': 'eq.$name'}) as List;
    return [for (final row in rows) (row as Map)['id'] as String];
  }

  /// The sign-in mode the club [id] holds, read back from the server.
  Future<String> signInModeOf(String id) async {
    final rows =
        await _send('GET', '/rest/v1/club', query: {'select': 'sign_in_mode', 'id': 'eq.$id'}) as List;
    return (rows.single as Map)['sign_in_mode'] as String;
  }

  /// The events the PostgREST [filter] matches, oldest first.
  Future<List<RaceDay>> events(Map<String, String> filter) async {
    final rows = await _send('GET', '/rest/v1/event',
        query: {'select': 'id,name,race_day', ...filter, 'order': 'created_at,id'}) as List;
    return [
      for (final row in rows.cast<Map<Object?, Object?>>())
        (id: row['id'] as String, name: row['name'] as String, date: row['race_day'] as String),
    ];
  }

  /// Every admission to the event [eventId], whatever its state, in the order made.
  Future<List<Admission>> admissionsTo(String eventId) async {
    final rows = await _send('GET', '/rest/v1/committee_device', query: {
      'select': 'id,auth_uid,role,person,admitted_at,superseded_by,revoked_at,course(name)',
      'event_id': 'eq.$eventId',
      'order': 'admitted_at,id',
    }) as List;
    return [for (final row in rows.cast<Map<Object?, Object?>>()) Admission.fromRow(row)];
  }

  /// Marks one admission revoked. revoke_device returns nothing, so this cannot go through [rpc].
  Future<void> revokeAdmission(String id) =>
      _send('POST', '/rest/v1/rpc/revoke_device', body: {'p_device': id});
}

/// What [provision] made. [codes] is keyed by role, and for a bound role by role and race area
/// (`overall_pro`, `recorder Alpha`), in the order [codeSlots] gives.
typedef Provisioned = ({
  String clubId,
  String eventId,
  Map<String, String> raceAreaIds,
  Map<String, String> codes,
});

/// Reuses or provisions the club, then creates the event, its race areas and its codes, writing each
/// line to [out] as soon as the thing it names exists. So a failure part-way leaves a record of what
/// was made, and a code is shown once its hash is stored. Returns the same, for the local-stack test
/// helper (#41).
Future<Provisioned> provision(ServiceApi api, ProvisionArgs args, StringSink out) async {
  out.writeln('target      ${api.target.label}');

  final existing = await api.clubIdsNamed(args.club);
  if (existing.length > 1) {
    throw StateError('${existing.length} clubs are named "${args.club}"; nothing was created');
  }
  final clubId = existing.isEmpty
      ? await api.rpc('provision_club', {'p_name': args.club})
      : existing.single;
  out.writeln('club        $clubId  ${args.club} (${existing.isEmpty ? 'provisioned' : 'reused'})');

  final eventId = await api.rpc('create_event', {
    'p_club': clubId,
    'p_name': args.event,
    'p_race_day': args.date,
  });
  out.writeln('event       $eventId  ${args.event} on ${args.date}');

  final courseIds = <String, String>{};
  for (final name in args.raceAreas) {
    final courseId = await api.rpc('create_course', {'p_event': eventId, 'p_name': name});
    courseIds[name] = courseId;
    out.writeln('race area   $courseId  $name');
  }

  // The server refuses one code standing for two slots of an event, so a repeat is drawn again
  // here rather than failing the run part-way.
  final issued = <String>{};
  final codes = <String, String>{};
  for (final slot in codeSlots(args.raceAreas)) {
    String code;
    do {
      code = newAdmissionCode();
    } while (!issued.add(code));
    await api.rpc('issue_admission_code', {
      'p_event': eventId,
      'p_role': slot.role,
      'p_code': code,
      'p_course': slot.raceArea == null ? null : courseIds[slot.raceArea],
    });
    codes[slot.raceArea == null ? slot.role : '${slot.role} ${slot.raceArea}'] = code;
    out.writeln('code        $code  ${slot.role}${slot.raceArea == null ? '' : '  ${slot.raceArea}'}');
  }
  out.writeln('A code admits a phone to this event as the role it is printed with and, for a bound '
      'role, on its race area. The codes are stored only as hashes, so this is the only time they '
      'are shown.');
  return (clubId: clubId, eventId: eventId, raceAreaIds: courseIds, codes: codes);
}

/// What each mode admits, in the words the script prints.
const _modeAdmits = {
  'device_handoff': 'by device handoff only: an anonymous sign-in presenting a role\'s code',
  'named_volunteers': 'as named volunteers only: a named account, signed in by magic link, '
      'presenting a role\'s code',
  'both': 'either way: by device handoff, or as a named volunteer',
};

/// Switches the club named exactly [args.club] to [args.mode] and returns the mode it replaced,
/// writing what changed to [out]. When no club, or more than one, has that name, nothing changes.
/// The mode printed is the one read back from the server after the switch, never the one asked for.
Future<String> setSignInMode(ServiceApi api, SignInModeArgs args, StringSink out) async {
  out.writeln('target      ${api.target.label}');
  final clubId = await _clubNamed(api, args.club);
  final before = await api.rpc('set_sign_in_mode', {'p_club': clubId, 'p_mode': args.mode});
  out.writeln('club        $clubId  ${args.club}');
  final now = await api.signInModeOf(clubId);
  if (now != args.mode) {
    throw StateError('the club reads $now after the switch to ${args.mode} (it was $before)');
  }
  out.writeln('sign-in     $now${before == now ? ' (unchanged)' : ' (was $before)'}');
  out.writeln('Phones admitted from now on sign in ${_modeAdmits[now]}. A phone already admitted '
      'is unaffected.');
  return before;
}

/// The id of the one club named exactly [name]. No such club, or more than one, is a [StateError].
Future<String> _clubNamed(ServiceApi api, String name) async {
  final ids = await api.clubIdsNamed(name);
  if (ids.length != 1) {
    throw StateError(ids.isEmpty
        ? 'no club is named "$name"; nothing was changed'
        : '${ids.length} clubs are named "$name"; nothing was changed');
  }
  return ids.single;
}

/// The one event [args] names. Nothing stops two events sharing a club, name and date, so a match
/// of several is refused with their ids, which --event-id can then tell apart.
Future<RaceDay> _eventNamed(ServiceApi api, RevokeArgs args) async {
  if (args.eventId case final id?) {
    final found = await api.events({'id': 'eq.$id'});
    if (found.isEmpty) throw StateError('no event has the id $id; nothing was changed');
    return found.single;
  }
  final clubId = await _clubNamed(api, args.club!);
  final found = await api.events({
    'club_id': 'eq.$clubId',
    'name': 'eq.${args.event}',
    'race_day': 'eq.${args.date}',
  });
  final named = '"${args.event}" on ${args.date} at "${args.club}"';
  if (found.isEmpty) throw StateError('no event is named $named; nothing was changed');
  if (found.length > 1) {
    throw StateError('${found.length} events are named $named; nothing was changed. '
        'Name one with --event-id: ${found.map((event) => event.id).join(', ')}');
  }
  return found.single;
}

/// With no device, lists the event's admissions and changes nothing. With one, marks every active
/// admission of that sign-in in the event revoked, and reads them back: one still active fails the
/// run, and running it again is safe. A sign-in with none active is reported as no change, and an
/// id with no admission here is a [StateError] that changes nothing. It keys on the sign-in and not
/// the role, since a replacement phone can hold the same role's code (#5 criterion 7).
Future<void> revoke(ServiceApi api, RevokeArgs args, StringSink out) async {
  out.writeln('target      ${api.target.label}');
  final event = await _eventNamed(api, args);
  out.writeln('event       ${event.id}  ${event.name} on ${event.date}');
  final admissions = await api.admissionsTo(event.id);

  final device = args.device;
  if (device == null) {
    admissions.map((admission) => admission.line).forEach(out.writeln);
    out.writeln(admissions.isEmpty
        ? 'No phone has been admitted to this event.'
        : 'To revoke a sign-in, run this again with --device and the id its line starts with. A '
            'phone that changed role has one line for each admission under one id, and a phone '
            'that lost its session has signed in again under a new id.');
    return;
  }

  final held = admissions.where((admission) => admission.device == device).toList();
  if (held.isEmpty) {
    throw StateError('no admission to this event belongs to the id $device; nothing was changed');
  }
  final active = held.where((admission) => admission.isActive).toList();
  if (active.isEmpty) {
    out.writeln('no change   $device was already revoked from this event');
    return;
  }

  for (final admission in active) {
    await api.revokeAdmission(admission.id);
  }
  final after = (await api.admissionsTo(event.id)).where((admission) => admission.device == device);
  if (after.any((admission) => admission.isActive)) {
    throw StateError('$device still holds an active admission to this event: it was admitted '
        'again as this ran. Run revoke again.');
  }
  after.map((admission) => admission.line).forEach(out.writeln);
  out.writeln('This sign-in\'s next write to the event is refused, and so is any code it presents. '
      'What it already wrote stays in the log. A revocation is never lifted.');
  out.writeln('The id is a sign-in, not a handset. A named volunteer\'s id is their account, on '
      'every phone signed in to it: they rejoin this event only under another account, or by '
      'device handoff if the club allows it. A new sign-in with the role\'s code is a new '
      'admission.');
}

/// A parsed subcommand: the project it targets, if any, and what it does there.
typedef Command = ({String? project, Future<void> Function(ServiceApi api, StringSink out) act});

/// The subcommand [args] names. A missing or unknown one is a [UsageError] with no message.
Command parseCommand(List<String> args) {
  switch (args.firstOrNull) {
    case 'provision':
      final parsed = parseProvision(args.sublist(1));
      return (project: parsed.project, act: (api, out) => provision(api, parsed, out));
    case 'sign-in-mode':
      final parsed = parseSignInMode(args.sublist(1));
      return (project: parsed.project, act: (api, out) => setSignInMode(api, parsed, out));
    case 'revoke':
      final parsed = parseRevoke(args.sublist(1));
      return (project: parsed.project, act: (api, out) => revoke(api, parsed, out));
    default:
      throw UsageError('');
  }
}

Future<int> run(
  List<String> args, {
  StringSink? out,
  StringSink? err,
  Map<String, String>? environment,
  StatusReader? localStatus,
}) async {
  final errors = err ?? stderr;
  final Command command;
  try {
    command = parseCommand(args);
  } on UsageError catch (e) {
    errors.writeln(e.message.isEmpty ? usage : '$e\n$usage');
    return 64;
  }
  final envFile = File('.env.local').existsSync()
      ? parseEnvFile(File('.env.local').readAsStringSync())
      : <String, String>{};
  try {
    final target = await resolveTarget(command.project,
        environment: environment ?? Platform.environment,
        envFile: envFile,
        localStatus: localStatus ?? readLocalStatus);
    await command.act(ServiceApi(target), out ?? stdout);
    return 0;
  } on StateError catch (e) {
    errors.writeln(e.message);
    return 1;
  } on ServiceError catch (e) {
    errors.writeln(e);
    return 1;
  } on IOException catch (e) {
    errors.writeln('the connection to the project failed, so the last change may or may not have '
        'landed: $e\nCheck before running this again. Running revoke again is safe.');
    return 1;
  }
}

Future<void> main(List<String> args) async {
  exitCode = await run(args);
}
