// The local Supabase stack, for tests that talk to the companion's server (#41). A test asks for a
// race day and for phones and gets them the way the pilot does:
//
// - the club, event, race areas and admission codes through the owner's tooling
//   (scripts/owner.dart, the service key on the owner's path, groom decision G27);
// - each phone through the stack's own auth (an anonymous sign-in, the device-handoff path) and
//   the admission function (admit_device with one of the printed codes).
//
// A phone's requests carry the publishable key and the phone's own token, never the secret key, and
// every one is recorded in [LocalStack.phoneRequests] so a test can say so. The secret key is used
// only by the owner's tooling. Rows no client role can write, like the event log's, are seeded as
// the table owner through psql in the stack's database container.
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

/// A committee phone: a Supabase Auth user signed in on the device-handoff path.
class Phone {
  Phone._(this._stack, this.token, this.userId);

  final LocalStack _stack;

  /// The phone's access token, from its own sign-in.
  final String token;

  /// The Auth user the phone signed in as.
  final String userId;

  /// The admission id admit_device answered with, when the phone was admitted.
  String? admissionId;

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
  /// owner's tooling.
  Future<owner.Provisioned> raceDay({List<String> raceAreas = const ['Alpha']}) => owner.provision(
      _owner,
      owner.ProvisionArgs(
        club: 'Local-stack test ${DateTime.now().microsecondsSinceEpoch}',
        event: 'Test day',
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

  /// A phone admitted to [day] with the code for [role], and for a bound role [raceArea]'s code:
  /// signed in by the stack's auth, then admitted by admit_device.
  Future<Phone> admittedPhone(owner.Provisioned day, String role,
      {String? raceArea, String? person}) async {
    final phone = await this.phone();
    final code = day.codes[raceArea == null ? role : '$role $raceArea'];
    if (code == null) throw ArgumentError('the race day has no code for $role ${raceArea ?? ''}');
    final (status, body) = await phone.send('POST', '/rest/v1/rpc/admit_device', body: {
      'p_event': day.eventId,
      'p_admission_code': code,
      'p_person': ?person,
    });
    if (status != 200) throw StateError('admit_device answered $status: $body');
    return phone..admissionId = body! as String;
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

}

final _random = Random.secure();

/// A ULID-shaped id. The event log keys on it, and a stack kept between runs must not see one twice.
String newUlid() => '01J8${List.generate(22, (_) => owner.codeAlphabet[_random.nextInt(32)]).join()}';

/// A complete, valid event's canonical text (RFC 8785 key order), so a write of it can be refused
/// only by the path it takes.
String sampleEvent(String ulid) => '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001",'
    '"device_ts":1727190002000,"gps":null,"kind":"note","payload":{"text":"local-stack test"},'
    '"payload_version":1,"person":null,"prev_hash":null,"role":null,"seq":1,"source":"tap",'
    '"ulid":"$ulid"}';
