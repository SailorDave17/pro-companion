// The owner's tooling for the pilot. A club admin acts through the owner's service_role scripts
// (groom decision G27), so this is where clubs, events, race areas and admission codes come from.
// #63 adds its first subcommand, #65 its codes and #5 the sign-in mode; revoke (#72) extends it.
//
//   dart run scripts/owner.dart provision --club <name> --event <name> --date <yyyy-mm-dd>
//       --race-area <name> [--race-area <name> ...] [--project <ref>]
//   dart run scripts/owner.dart sign-in-mode --club <name>
//       --mode device_handoff|named_volunteers|both [--project <ref>]
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
    '--mode device_handoff|named_volunteers|both [--project <ref>]';

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
  final ids = await api.clubIdsNamed(args.club);
  if (ids.length != 1) {
    throw StateError(ids.isEmpty
        ? 'no club is named "${args.club}"; nothing was changed'
        : '${ids.length} clubs are named "${args.club}"; nothing was changed');
  }
  final before = await api.rpc('set_sign_in_mode', {'p_club': ids.single, 'p_mode': args.mode});
  out.writeln('club        ${ids.single}  ${args.club}');
  final now = await api.signInModeOf(ids.single);
  if (now != args.mode) {
    throw StateError('the club reads $now after the switch to ${args.mode} (it was $before)');
  }
  out.writeln('sign-in     $now${before == now ? ' (unchanged)' : ' (was $before)'}');
  out.writeln('Phones admitted from now on sign in ${_modeAdmits[now]}. A phone already admitted '
      'is unaffected.');
  return before;
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
    default:
      throw UsageError('');
  }
}

Future<int> run(
  List<String> args, {
  StringSink? out,
  Map<String, String>? environment,
  StatusReader? localStatus,
}) async {
  final Command command;
  try {
    command = parseCommand(args);
  } on UsageError catch (e) {
    stderr.writeln(e.message.isEmpty ? usage : '$e\n$usage');
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
    stderr.writeln(e.message);
    return 1;
  } on ServiceError catch (e) {
    stderr.writeln(e);
    return 1;
  }
}

Future<void> main(List<String> args) async {
  exitCode = await run(args);
}
