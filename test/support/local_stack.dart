// The local Supabase stack, for tests that talk to the companion's server (#41). A test asks for a
// race day and for phones and gets them the way the pilot does:
//
// - the club, event, race areas and admission codes through the owner's tooling
//   (scripts/owner.dart, the service key on the owner's path, groom decision G27);
// - each phone through the stack's own auth and the admission function (admit_device with one of
//   the printed codes). A device-handoff phone signs in anonymously. A named volunteer's phone signs
//   in by magic link (#5): a test cannot click an email link, so the account is seeded and its link
//   generated through the stack's admin API, and the phone verifies the link's token itself.
//
// A phone's requests carry the publishable key and the phone's own token, never the secret key, and
// every one is recorded in [LocalStack.phoneRequests] so a test can say so. The secret key is used
// only by the owner's tooling and to seed a named volunteer's account. Rows no client role can
// write, like the event log's, are seeded as the table owner through psql in the stack's database
// container.
//
// Needs the stack started (README, Server side) and PRO_COMPANION_LOCAL_STACK=1. A test using it
// skips without that variable, and the local-stack CI job sets it and runs the whole suite, so a
// new local-stack test runs in CI with nothing to register.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../scripts/owner.dart' as owner;

/// Whether the local-stack tests were asked for. Once asked for, a stack that is down fails them
/// rather than skipping them.
final bool localStackRequested = Platform.environment['PRO_COMPANION_LOCAL_STACK'] == '1';

/// The skip reason for a local-stack test that was not asked for.
const String localStackSkip = 'set PRO_COMPANION_LOCAL_STACK=1 with the local stack running';

/// A committee phone: a Supabase Auth user signed in on the device-handoff path, or as a named
/// volunteer by magic link.
class Phone {
  Phone._(this._stack, this.token, this.userId, {this.email});

  final LocalStack _stack;

  /// The phone's access token, from its own sign-in.
  final String token;

  /// The Auth user the phone signed in as.
  final String userId;

  /// The named volunteer's address, for a phone signed in by magic link; null on device handoff.
  final String? email;

  /// The admission id admit_device answered with, when the phone was admitted (its latest).
  String? admissionId;

  /// The role of that admission.
  String? role;

  /// The phone's latest admission and role on each event it was admitted to, by event id.
  final Map<String, ({String admission, String role})> admissions = {};

  /// A valid event from this phone's own device (or [deviceId]), naming the admission and role it
  /// holds on [eventId], or its latest when none is given, as the core stamps them since #49 and
  /// #73's append_event checks.
  String event(String ulid, {String? eventId, String deviceId = '01J8Z0D0000000000000000001', int seq = 1}) {
    final held = eventId == null ? null : admissions[eventId];
    return sampleEvent(ulid, deviceId: deviceId, seq: seq,
        admissionId: held?.admission ?? admissionId, role: held?.role ?? role);
  }

  /// The claims the token carries (its `role` is `authenticated`, never `service_role`).
  Map<String, Object?> get claims {
    final payload = token.split('.')[1];
    return jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload))))
        as Map<String, Object?>;
  }

  /// A request to the stack's API as this phone. Returns the status and the decoded body.
  Future<(int, Object?)> send(String method, String path,
          {Map<String, String>? query, Object? body}) =>
      _stack._send(method, path, token: token, query: query, body: body);
}

/// The local stack, reached through its API as the owner's tooling and as phones.
class LocalStack {
  LocalStack._(this.api, this._publishableKey, this._secretKey, this._dbContainer)
      : _owner = owner.ServiceApi(owner.Target(api, _secretKey, 'the local stack'));

  /// The stack's API URL.
  final Uri api;

  final String _publishableKey;
  final String _secretKey;
  final String _dbContainer;
  final owner.ServiceApi _owner;

  /// Every request made as a phone, as `METHOD path key`, where key is the key the request carried
  /// (`publishable` or `secret`) and `+token` marks a phone's bearer token.
  final List<String> phoneRequests = [];

  /// The publishable key, for a client a test builds the way the app would (#6's sync engine).
  String get publishableKey => _publishableKey;

  /// The secret key, only so a test can show sync refusing it. Nothing a phone does uses it.
  String get secretKeyForRefusal => _secretKey;

  /// Connects to the running stack, reading its URL and keys from `supabase status`.
  static Future<LocalStack> connect() async {
    final status = await owner.readLocalStatus();
    final url = status['API_URL'];
    final publishable = status['PUBLISHABLE_KEY'];
    final secret = status['SECRET_KEY'];
    if (url == null || publishable == null || secret == null) {
      throw StateError('supabase status gave no API_URL, PUBLISHABLE_KEY and SECRET_KEY');
    }
    final projectId = RegExp(r'^project_id\s*=\s*"([^"]+)"', multiLine: true)
        .firstMatch(File('supabase/config.toml').readAsStringSync())!
        .group(1)!;
    return LocalStack._(Uri.parse(url), publishable, secret, 'supabase_db_$projectId');
  }

  /// A club, an event on it and its race areas, with every admission code, provisioned by the
  /// owner's tooling. [club] names the club, so a test can hand the name to another subcommand, and
  /// [event] names the event, so a club's second race day can be told from its first.
  Future<owner.Provisioned> raceDay(
          {List<String> raceAreas = const ['Alpha'], String? club, String event = 'Test day'}) =>
      owner.provision(
          _owner,
          owner.ProvisionArgs(
            club: club ?? 'Local-stack test ${DateTime.now().microsecondsSinceEpoch}',
            event: event,
            date: '2026-09-27',
            raceAreas: raceAreas,
          ),
          StringBuffer());

  /// A phone signed in anonymously, as the device-handoff path signs one in, and not admitted.
  Future<Phone> phone() async {
    final (status, body) = await _send('POST', '/auth/v1/signup', body: <String, Object?>{});
    if (status != 200) throw StateError('anonymous sign-in answered $status: $body');
    final session = body! as Map;
    return Phone._(this, session['access_token'] as String, (session['user'] as Map)['id'] as String);
  }

  /// A phone signed in by magic link as a named volunteer, and not admitted (#5). The account is
  /// created confirmed and its magic link generated through the stack's admin API, because a test
  /// cannot click an email link. The phone then verifies the link's token with the publishable
  /// key, which is the request the link makes when it opens.
  Future<Phone> namedPhone() async {
    final email = 'volunteer.${newUlid().toLowerCase()}@pro-companion.test';
    await _admin('/auth/v1/admin/users', {'email': email, 'email_confirm': true});
    final link = await _admin('/auth/v1/admin/generate_link', {'type': 'magiclink', 'email': email});
    final (status, body) = await _send('POST', '/auth/v1/verify',
        body: {'type': 'magiclink', 'token_hash': link['hashed_token']});
    if (status != 200) throw StateError('magic-link verify answered $status: $body');
    final session = body! as Map;
    return Phone._(this, session['access_token'] as String, (session['user'] as Map)['id'] as String,
        email: email);
  }

  /// The account [phone] signed in to, signed in again on another phone: a new session for the same
  /// Auth user, as a volunteer's spare gets. Spends a verification. The account's admissions are
  /// the spare's too, so it writes under them (#73).
  Future<Phone> signInAgain(Phone phone) async {
    final (status, body) = await _send('POST', '/auth/v1/verify',
        body: {'type': 'magiclink', 'token_hash': await magicLink(phone.email!)});
    if (status != 200) throw StateError('magic-link verify answered $status: $body');
    final session = body! as Map;
    return Phone._(this, session['access_token'] as String, (session['user'] as Map)['id'] as String,
        email: phone.email)
      ..admissionId = phone.admissionId
      ..role = phone.role
      ..admissions.addAll(phone.admissions);
  }

  /// A named volunteer's magic link, for a phone that verifies it itself (#6's sync engine): the
  /// account [email] is created confirmed the first time, and each call generates a new link.
  /// Returns the link's token hash. Each verification spends one of the stack's 30 per 5 minutes.
  Future<String> magicLink(String email) async {
    try {
      await _admin('/auth/v1/admin/users', {'email': email, 'email_confirm': true});
    } on StateError catch (e) {
      // Signing in again: the account is already there.
      if (!'$e'.contains('email_exists')) rethrow;
    }
    final link = await _admin('/auth/v1/admin/generate_link', {'type': 'magiclink', 'email': email});
    return link['hashed_token'] as String;
  }

  /// A phone admitted to [day] on the device-handoff path with the code for [role], and for a bound
  /// role [raceArea]'s code: signed in anonymously, then admitted by admit_device. It names no
  /// person, which only a named volunteer's admission may (#5).
  Future<Phone> admittedPhone(owner.Provisioned day, String role, {String? raceArea}) async =>
      admit(await phone(), day, role, raceArea: raceArea);

  /// A phone admitted to [day] as a named volunteer with the code for [role] (and [raceArea]'s code
  /// for a bound role): signed in by magic link, then admitted by admit_device, naming [person].
  Future<Phone> admittedNamedPhone(owner.Provisioned day, String role,
          {String? raceArea, String? person}) async =>
      admit(await namedPhone(), day, role, raceArea: raceArea, person: person);

  /// Admits [phone] to [day] with the code for [role] (and [raceArea]'s code for a bound role).
  Future<Phone> admit(Phone phone, owner.Provisioned day, String role,
      {String? raceArea, String? person}) async {
    final (status, body) = await tryAdmit(phone, day, role, raceArea: raceArea, person: person);
    if (status != 200) throw StateError('admit_device answered $status: $body');
    phone.admissions[day.eventId] = (admission: body! as String, role: role);
    return phone
      ..admissionId = body as String
      ..role = role;
  }

  /// [phone] presenting the code for [role] (and [raceArea]'s code for a bound role) to [day], and
  /// admit_device's answer as it came: a refusal is returned, not thrown.
  Future<(int, Object?)> tryAdmit(Phone phone, owner.Provisioned day, String role,
      {String? raceArea, String? person}) {
    final code = day.codes[raceArea == null ? role : '$role $raceArea'];
    if (code == null) throw ArgumentError('the race day has no code for $role ${raceArea ?? ''}');
    return phone.send('POST', '/rest/v1/rpc/admit_device', body: {
      'p_event': day.eventId,
      'p_admission_code': code,
      'p_person': ?person,
    });
  }

  /// Stores one event in [eventId]'s log, as the table owner. No client role can write the log
  /// (#48's append_event is its client path), so this is psql in the database container. Returns
  /// the event's ULID and canonical text.
  Future<({String ulid, String canonical})> seedEventLogRow(String eventId) async {
    final ulid = newUlid();
    final canonical = sampleEvent(ulid);
    await _psql("insert into public.event_log (event_id, canonical) values ('$eventId', "
        '\$e\$$canonical\$e\$);');
    return (ulid: ulid, canonical: canonical);
  }

  /// Stores [canonical] in [eventId]'s log as the table owner, as another phone's upload would.
  Future<void> seedCanonical(String eventId, String canonical) =>
      _psql("insert into public.event_log (event_id, canonical) values ('$eventId', \$e\$$canonical\$e\$);");

  /// Every row in [eventId]'s log, read as the table owner, ordered by the ADR 001 rule (device
  /// time, then device, then sequence number): `ulid`, `canonical`, `device_id`, `seq`,
  /// `device_ts`, `received_at` (milliseconds since the epoch, the server's clock) and `hash`, the
  /// SHA-256 of the stored text as the server computes it.
  Future<List<Map<String, Object?>>> eventLogRows(String eventId) async {
    final out = await _psql("select coalesce(json_agg(json_build_object('ulid', ulid, 'canonical', canonical, "
        "'device_id', device_id, 'seq', seq, 'device_ts', device_ts, "
        "'received_at', (extract(epoch from received_at) * 1000)::bigint, "
        "'hash', encode(sha256(convert_to(canonical, 'UTF8')), 'hex')) "
        "order by device_ts, device_id, seq), '[]') from public.event_log where event_id = '$eventId';");
    return [for (final row in jsonDecode(out) as List) Map<String, Object?>.from(row as Map)];
  }

  /// The race day [ulid] is stored under, read as the table owner; null when there is no row.
  Future<String?> eventOf(String ulid) async {
    final out = await _psql("select event_id from public.event_log where ulid = '$ulid';");
    return out.isEmpty ? null : out;
  }

  /// Revokes the admission [admissionId], as the owner's revoke_device does (service_role only).
  Future<void> revoke(String admissionId) => _psql("select public.revoke_device('$admissionId');");

  /// The canonical text stored under [ulid], read as the table owner; null when there is no row.
  Future<String?> eventLogCanonical(String ulid) async {
    final out = await _psql("select canonical from public.event_log where ulid = '$ulid';");
    return out.isEmpty ? null : out;
  }

  /// The refusals kept for [eventId] (#48), each as `reason hash`, read as the table owner. No
  /// client role can read them.
  Future<List<String>> refusals(String eventId) async {
    final out = await _psql("select reason || ' ' || event_hash from public.event_refusal "
        "where event_id = '$eventId' order by refused_at, event_hash;");
    return out.isEmpty ? [] : out.split('\n');
  }

  /// Every admission to [eventId] in the order made, read as the table owner, with the Auth user
  /// behind each: `id`, `auth_uid`, `role`, `race_area` (its name, null when event-wide), `person`,
  /// `revoked`, `revoked_at`, `superseded_by`, `admitted_at`, and the user's `is_anonymous` and
  /// `email`. No client role can read auth_uid or the users.
  Future<List<Map<String, Object?>>> admissions(String eventId) async {
    final out = await _psql('select coalesce(json_agg(a order by a.admitted_at, a.id), \'[]\') from ('
        'select d.id, d.auth_uid, d.role, c.name as race_area, d.person, '
        'd.revoked_at is not null as revoked, d.revoked_at, d.superseded_by, '
        'u.is_anonymous, u.email, d.admitted_at '
        'from public.committee_device d '
        'left join public.course c on c.id = d.course_id '
        'left join auth.users u on u.id = d.auth_uid '
        "where d.event_id = '$eventId') a;");
    return [for (final row in jsonDecode(out) as List) Map<String, Object?>.from(row as Map)];
  }

  /// Every event in [eventId]'s log, as its canonical text, by device and sequence number, read as
  /// the table owner.
  Future<List<String>> eventLog(String eventId) async {
    final out = await _psql("select coalesce(json_agg(canonical order by device_id, seq), '[]') "
        "from public.event_log where event_id = '$eventId';");
    return [for (final text in jsonDecode(out) as List) text as String];
  }

  /// admit_device called for the phone [uid] from a database session of its own, as PostgREST calls
  /// it (role authenticated, the token's claims as a device-handoff sign-in), with the transaction
  /// then held open for [hold] before it commits. Returns the admission id, or `refused: <error>`.
  /// A call started while another is held overlaps it, which no API request can arrange (#70: an
  /// admission overlapping a role change of the same phone). No sign-in is spent.
  Future<String> admitInSession(String uid, String eventId, String code,
      {Duration hold = Duration.zero}) async {
    final claims = jsonEncode({'sub': uid, 'role': 'authenticated', 'is_anonymous': true});
    final result = await Process.run('docker', [
      'exec', _dbContainer, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q', '-t', '-A',
      '-c', 'begin',
      '-c', 'set local role authenticated',
      '-c', "select set_config('request.jwt.claims', '$claims', true) is null",
      '-c', "select 'admitted ' || public.admit_device('$eventId', '$code')",
      '-c', "select '$uid', pg_sleep(${hold.inMilliseconds / 1000})",
      '-c', 'commit',
    ]);
    if (result.exitCode != 0) return 'refused: ${(result.stderr as String).trim()}';
    final line = (result.stdout as String)
        .split('\n')
        .firstWhere((l) => l.startsWith('admitted '), orElse: () => '');
    return line.isEmpty ? 'no answer: ${result.stdout}' : line.substring('admitted '.length).trim();
  }

  /// Waits until the session [admitInSession] started for the phone [uid] with a hold is sleeping:
  /// its admission is made and its locks are held, so a call started now overlaps it. It names the
  /// phone because test files run at once, and another file's held session must not count.
  Future<void> untilHeld(String uid, {Duration timeout = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final out = await _psql("select count(*) from pg_stat_activity where pid <> pg_backend_pid() "
          "and state = 'active' and query like 'select ''$uid'', pg_sleep(%';");
      if (out != '0') return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('no held admission session appeared within $timeout');
  }

  /// The admissions of the phone [uid] to [eventId] in the order made, read as the table owner:
  /// `id`, `role` and `superseded_by` (null on the active one), #70's chain.
  Future<List<Map<String, Object?>>> admissionChain(String eventId, String uid) async {
    final out = await _psql('select coalesce(json_agg(json_build_object('
        "'id', id, 'role', role, 'superseded_by', superseded_by) order by admitted_at, id), '[]') "
        "from public.committee_device where event_id = '$eventId' and auth_uid = '$uid';");
    return [for (final row in jsonDecode(out) as List) Map<String, Object?>.from(row as Map)];
  }

  Future<String> _psql(String sql) async {
    final result = await Process.run('docker', [
      'exec', _dbContainer, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q', '-t', '-A',
      '-c', sql,
    ]);
    if (result.exitCode != 0) throw StateError('psql failed: ${result.stderr}');
    return (result.stdout as String).trim();
  }

  Future<(int, Object?)> _send(String method, String path,
      {String? token, Map<String, String>? query, Object? body}) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, api.replace(path: path, queryParameters: query));
      request.headers.set('apikey', _publishableKey);
      if (token != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final key = request.headers.value('apikey') == _secretKey ? 'secret' : 'publishable';
      phoneRequests.add('$method $path $key${token == null ? '' : '+token'}');
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
    } finally {
      client.close();
    }
  }

  /// A POST to the stack's auth admin API with the secret key, to seed a named volunteer. It is
  /// not a phone's request, so it is not in [phoneRequests].
  Future<Map<String, Object?>> _admin(String path, Map<String, Object?> body) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl('POST', api.replace(path: path));
      request.headers.set('apikey', _secretKey);
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode ~/ 100 != 2) {
        throw StateError('$path answered ${response.statusCode}: $text');
      }
      return Map<String, Object?>.from(jsonDecode(text) as Map);
    } finally {
      client.close();
    }
  }
}

final _random = Random.secure();

/// A ULID-shaped id. The event log keys on it, and a stack kept between runs must not see one twice.
String newUlid() => '01J8${List.generate(22, (_) => owner.codeAlphabet[_random.nextInt(32)]).join()}';

/// A random v4 UUID, for a phone's Auth user id in a database session that spends no sign-in.
String randomUuid() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// A complete, valid event's canonical text (RFC 8785 key order), so a write of it can be refused
/// only by the path it takes. [deviceId] and [seq] let each phone write its own device's events.
/// [admissionId] and [role] are what #73's append_event holds the text to; a phone's own go through
/// [Phone.event]. Null for a row seeded as the table owner, which no check reads.
String sampleEvent(String ulid,
        {String deviceId = '01J8Z0D0000000000000000001', int seq = 1, String? admissionId, String? role}) =>
    '{"admission_id":${_jsonString(admissionId)},"corrects_ulid":null,"device_id":"$deviceId",'
    '"device_ts":${1727190001000 + seq},"gps":null,"kind":"note","payload":{"text":"local-stack test"},'
    '"payload_version":1,"person":null,"prev_hash":null,"role":${_jsonString(role)},"seq":$seq,"source":"tap",'
    '"ulid":"$ulid"}';

String _jsonString(String? s) => s == null ? 'null' : '"$s"';
