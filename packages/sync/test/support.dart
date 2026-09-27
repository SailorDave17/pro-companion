import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_sync/sync.dart';
import 'package:test/test.dart';

/// A project URL no request ever reaches: every request goes to a [FakeServer].
const projectUrl = 'https://companion.invalid';

/// A publishable key of the right shape, built at run time so no tracked file holds one
/// (test/no_secrets_in_tree_test.dart refuses the shape).
final publishableKey = 'sb_publishable_${'unit' * 5}';

/// A JWT carrying [claims], built at run time for the same reason. Nothing checks the signature:
/// gotrue reads only the payload, and the fake server decodes it as the stack would verify it.
String jwt(Map<String, Object?> claims) {
  String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(claims)}.${part({'unit': 'test'})}';
}

Map<String, Object?> claimsOf(String token) =>
    jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1])))) as Map<String, Object?>;

/// Race days and admissions, as UUIDs in the form Postgres prints.
String uuid(int n) => '00000000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';
final dayOne = uuid(0xd1);
final dayTwo = uuid(0xd2);
final otherClubDay = uuid(0xdc);

/// One request as the fake server saw it.
class Seen {
  Seen(this.method, this.path, this.query, this.apikey, this.bearer, this.body, this.at, this.appendsInFlight);

  /// How many append_event requests were still waiting for their answer when this one arrived.
  final int appendsInFlight;

  final String method;
  final String path;
  final Map<String, String> query;
  final String? apikey;
  final String? bearer;
  final String body;

  /// When it arrived, on package:clock (fake time under fake_async).
  final DateTime at;

  Map<String, Object?> get json => body.isEmpty ? const {} : jsonDecode(body) as Map<String, Object?>;

  /// The user the request's bearer token names, or null when it carried the publishable key.
  String? get caller => bearer == null || bearer!.split('.').length != 3 ? null : claimsOf(bearer!)['sub'] as String?;

  bool get isAppend => method == 'POST' && path == '/rest/v1/rpc/append_event';

  @override
  String toString() => '$method $path ${caller ?? 'anon'}';
}

/// What a hook does with a request: answer it, or return null to let the server answer.
typedef Hook = FutureOr<http.Response?> Function(Seen request);

/// The companion's server as sync meets it, in memory: GoTrue's sign-in, refresh and verify,
/// the phone's own admissions (committee_device), admit_device, and append_event with the
/// judgements #48's function makes, in the order it makes them. Answers are shaped as the real
/// ones: a refusal is a 422 whose body carries code append_event_refused and the reason in
/// details; a refused bearer is PostgREST's 401 JSON; a GoTrue rejection carries its code and the
/// API version header, as measured on the local stack.
///
/// The client under test is the real one; only the transport is this. [hooks] run first, and a
/// hook can answer, throw, hang, or call [answer] itself and then throw (a response lost after
/// the server committed).
class FakeServer extends http.BaseClient {
  final requests = <Seen>[];
  final hooks = <Hook>[];

  /// Hooks that see a request before [offline] does: a request lost in a dead link, say.
  final firstHooks = <Hook>[];

  /// While true, every request fails before it reaches the server.
  bool offline = false;

  var _appendsInFlight = 0;

  /// The event log: ULID to the race day it was sent to and its text.
  final log = <String, ({String event, String canonical})>{};

  /// Admissions: user to admission id to race day.
  final admissions = <String, Map<String, String>>{};
  final revoked = <String>{};

  /// Magic-link token hashes, to the named volunteer each signs in.
  final magicLinks = <String, String>{};
  final _refresh = <String, String>{};
  var _users = 0;
  var _tokens = 0;

  /// Whether each user signed in anonymously.
  final anonymous = <String, bool>{};

  Iterable<Seen> get appends => requests.where((r) => r.isAppend);
  int appendsOf(String ulid) => appends.where((r) => r.json['p_canonical'].toString().contains('"ulid":"$ulid"')).length;

  /// A named volunteer's magic link, as the owner's tooling would generate it.
  String magicLinkFor(String user) {
    final hash = 'hash-${magicLinks.length + 1}';
    magicLinks[hash] = user;
    anonymous[user] = false;
    return hash;
  }

  /// Admits [user] to [event] directly, as another phone's admit_device would.
  String admitDirectly(String user, String event) {
    final id = uuid(0xa00 + admissions.values.fold<int>(0, (n, m) => n + m.length) + 1);
    (admissions[user] ??= {})[id] = event;
    return id;
  }

  /// A session for [user], as GoTrue answers one. Its access token is valid for [validFor] on the
  /// real clock: gotrue judges expiry by DateTime.now, which fake_async does not move.
  Map<String, Object?> session(String user, {Duration validFor = const Duration(hours: 3)}) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final refresh = 'refresh-${++_tokens}';
    _refresh[refresh] = user;
    return {
      'access_token': jwt({
        'sub': user,
        'role': 'authenticated',
        'aud': 'authenticated',
        'iat': now,
        'exp': now + validFor.inSeconds,
        'is_anonymous': anonymous[user] ?? true,
      }),
      'token_type': 'bearer',
      'expires_in': validFor.inSeconds,
      'refresh_token': refresh,
      'user': {'id': user, 'aud': 'authenticated', 'created_at': '2026-09-26T00:00:00Z', 'is_anonymous': anonymous[user] ?? true},
    };
  }

  /// Revokes every refresh token [user] holds, as a sign-out elsewhere does.
  void revokeRefreshTokens(String user) => _refresh.removeWhere((_, u) => u == user);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().bytesToString();
    final auth = request.headers['Authorization'] ?? request.headers['authorization'];
    final seen = Seen(
      request.method,
      request.url.path,
      request.url.queryParameters,
      request.headers['apikey'],
      auth?.startsWith('Bearer ') == true ? auth!.substring(7) : null,
      body,
      clock.now(),
      _appendsInFlight,
    );
    requests.add(seen);
    if (seen.isAppend) _appendsInFlight++;
    http.Response? response;
    try {
      for (final hook in [...firstHooks]) {
        response = await hook(seen);
        if (response != null) break;
      }
      if (response == null && offline) throw http.ClientException('offline', request.url);
      for (final hook in [if (response == null) ...hooks]) {
        response = await hook(seen);
        if (response != null) break;
      }
      response ??= answer(seen);
    } finally {
      if (seen.isAppend) _appendsInFlight--;
    }
    return http.StreamedResponse(Stream.value(response.bodyBytes), response.statusCode,
        request: request, headers: response.headers, contentLength: response.bodyBytes.length);
  }

  /// The server's own answer to [r], applying whatever it changes.
  http.Response answer(Seen r) {
    switch ((r.method, r.path)) {
      case ('POST', '/auth/v1/signup'):
        final user = uuid(0x5000 + ++_users);
        anonymous[user] = true;
        return _json(200, session(user));
      case ('POST', '/auth/v1/verify'):
        final user = magicLinks[r.json['token_hash']];
        if (user == null) return _goTrueError(403, 'otp_expired');
        return _json(200, session(user));
      case ('POST', '/auth/v1/token'):
        final user = _refresh.remove(r.json['refresh_token']);
        if (user == null) return _goTrueError(400, 'refresh_token_not_found');
        return _json(200, session(user));
      case ('GET', '/rest/v1/committee_device'):
        final user = r.caller;
        if (user == null) return _denied('table committee_device');
        return _json(200, [
          for (final MapEntry(key: id, value: event) in (admissions[user] ?? const {}).entries) {'id': id, 'event_id': event},
        ]);
      case ('POST', '/rest/v1/rpc/admit_device'):
        final user = r.caller;
        if (user == null) return _denied('function admit_device');
        final event = r.json['p_event'] as String;
        final held = admissions[user]?.entries.where((e) => e.value == event);
        if (held != null && held.isNotEmpty) return _json(200, held.first.key);
        return _json(200, admitDirectly(user, event));
      case ('POST', '/rest/v1/rpc/append_event'):
        return _append(r);
    }
    return _json(404, {'code': 'PGRST125', 'message': 'no route for ${r.method} ${r.path}'});
  }

  http.Response _append(Seen r) {
    final user = r.caller;
    if (user == null) return _denied('function append_event');
    final event = r.json['p_event'] as String;
    final canonical = r.json['p_canonical'] as String;
    final rows = (admissions[user] ?? const {}).entries.where((e) => e.value == event).map((e) => e.key);
    if (rows.any(revoked.contains)) return refusal('revoked', canonical);
    if (!rows.any((id) => !revoked.contains(id))) return refusal('not_admitted', canonical);
    Object? parsed;
    try {
      parsed = jsonDecode(canonical);
    } on FormatException {
      parsed = null;
    }
    if (parsed is! Map || parsed['ulid'] is! String || parsed['seq'] is! int) {
      return refusal('inconsistent_canonical', canonical);
    }
    final ulid = parsed['ulid'] as String;
    final stored = log[ulid];
    if (stored != null) {
      if (stored.canonical == canonical && stored.event == event) return accepted(canonical, duplicate: true);
      return refusal('ulid_conflict', canonical);
    }
    log[ulid] = (event: event, canonical: canonical);
    return accepted(canonical, duplicate: false);
  }

  static http.Response accepted(String canonical, {required bool duplicate}) =>
      _json(200, {'outcome': 'accepted', 'duplicate': duplicate, 'hash': chainHash(canonical)});

  /// append_event's refusal, exactly as #48 answers it.
  static http.Response refusal(String reason, String canonical) => _json(422, {
        'outcome': 'refused',
        'reason': reason,
        'hash': chainHash(canonical),
        'code': 'append_event_refused',
        'message': 'append_event refused the event: $reason',
        'details': reason,
      });

  static http.Response _denied(String what) =>
      _json(401, {'code': '42501', 'details': null, 'hint': null, 'message': 'permission denied for $what'});

  /// GoTrue's error, in the shape measured on the local stack.
  static http.Response _goTrueError(int status, String code) => http.Response(
        jsonEncode({'code': code, 'message': code}),
        status,
        headers: {'content-type': 'application/json', 'x-supabase-api-version': '2024-01-01'},
      );

  static http.Response _json(int status, Object? body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
}

/// A PostgREST error answer, for hooks.
http.Response postgrestError(int status, String code, [String message = 'error']) =>
    http.Response(jsonEncode({'code': code, 'details': null, 'hint': null, 'message': message}), status,
        headers: {'content-type': 'application/json'});

/// A phone: its store and its session directory, in a temp directory removed after the test.
class TestPhone {
  TestPhone._(this.dir, this.dbPath, this.store);

  factory TestPhone({String? admission, int Function()? clock}) {
    final dir = Directory.systemTemp.createTempSync('pc_sync_');
    final path = '${dir.path}${Platform.pathSeparator}core.db';
    final store = EventStore.open(path, clock: clock);
    addTearDown(() {
      try {
        store.close();
      } catch (_) {
        // Already closed by the test.
      }
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows can hold the WAL file briefly after close; not the test's concern.
      }
    });
    if (admission != null) store.setAdmissionId(admission);
    return TestPhone._(dir.path, path, store);
  }

  final String dir;
  final String dbPath;
  final EventStore store;

  File get sessionFile => File('$dir${Platform.pathSeparator}sync_session.json');

  /// Appends [n] notes, returning their ULIDs.
  List<String> log(int n, {String text = 'Mark 2 hold'}) => [
        for (var i = 0; i < n; i++) store.append(NewEvent(kind: 'note', source: 'tap', payload: {'text': '$text $i'})).ulid,
      ];

  /// Keeps [session] as the phone's session file, as an earlier run of the engine would have.
  void keepSession(Map<String, Object?> session) => sessionFile.writeAsStringSync(jsonEncode(session));

  /// An engine on this phone, with the production timeout and backoff: the timing tests hold
  /// what ships, so a change to either default is a change they see.
  SyncEngine engine(FakeServer server) =>
      SyncEngine.open(url: projectUrl, publishableKey: publishableKey, store: store, sessionDir: dir, transport: server);
}

/// A phone signed in as [user] (anonymously unless named) and admitted to [event]: its session
/// kept where the engine looks, the admission stamped on its events, the race day learned.
Future<(TestPhone, SyncEngine, String)> admittedPhone(FakeServer server, String user, String event) async {
  final phone = TestPhone();
  server.anonymous.putIfAbsent(user, () => true);
  final admission = server.admitDirectly(user, event);
  phone.store.setAdmissionId(admission);
  phone.keepSession(server.session(user));
  final engine = phone.engine(server);
  addTearDown(engine.close);
  return (phone, engine, admission);
}
