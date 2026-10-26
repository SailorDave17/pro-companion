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

  /// The refusal records (#48): what a phone admitted to the race day reads as a stub (#60).
  final refusals = <({String event, String? device, int? seq, String hash, String reason})>[];

  /// Another phone's event, already on shore, as its own append_event would have left it.
  void seedLog(String event, String canonical) {
    final ulid = (jsonDecode(canonical) as Map)['ulid'] as String;
    log[ulid] = (event: event, canonical: canonical);
  }

  /// Whether [user] may read race day [event]: an admission there, and none of them revoked, as
  /// is_admitted_to_event answers (#50, #70).
  bool readable(String? user, String event) {
    final rows = [
      for (final MapEntry(key: id, value: e) in (admissions[user] ?? const <String, String>{}).entries)
        if (e == event) id,
    ];
    return rows.isNotEmpty && !rows.any(revoked.contains);
  }

  /// Admissions: user to admission id to race day.
  final admissions = <String, Map<String, String>>{};
  final revoked = <String>{};

  /// Each race day's name, as the event table holds it (#53).
  final eventNames = <String, String>{};

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
          for (final MapEntry(key: id, value: event) in (admissions[user] ?? const {}).entries)
            {
              'id': id,
              'event_id': event,
              'revoked_at': revoked.contains(id) ? '2026-10-24T12:00:00+00:00' : null,
              'superseded_by': null,
            },
        ]);
      case ('GET', '/rest/v1/event_log'):
        if (r.caller == null) return _denied('table event_log');
        return _json(200, _read(r, [
          for (final MapEntry(key: ulid, value: row) in log.entries)
            if (readable(r.caller, row.event))
              {
                'ulid': ulid,
                'event_id': row.event,
                'device_id': (jsonDecode(row.canonical) as Map)['device_id'],
                'seq': (jsonDecode(row.canonical) as Map)['seq'],
                'canonical': row.canonical,
              },
        ]));
      case ('GET', '/rest/v1/event'):
        // The real policy is is_admitted_to_club, so a phone admitted to another race day of the
        // club reads this one too. The fake has no clubs and answers per race day, which is
        // narrower: a read it answers, the stack answers too.
        if (r.caller == null) return _denied('table event');
        return _json(200, _read(r, [
          for (final MapEntry(key: id, value: name) in eventNames.entries)
            if (readable(r.caller, id)) {'id': id, 'name': name},
        ]));
      case ('GET', '/rest/v1/event_refusal'):
        if (r.caller == null) return _denied('table event_refusal');
        return _json(200, _read(r, [
          for (final x in refusals)
            if (readable(r.caller, x.event))
              {'event_id': x.event, 'device_id': x.device, 'seq': x.seq, 'event_hash': x.hash, 'reason': x.reason},
        ]));
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
    Object? parsed;
    try {
      parsed = jsonDecode(canonical);
    } on FormatException {
      parsed = null;
    }
    // Kept as #48 keeps them, from a caller holding a row: what a phone of the race day reads back
    // as a stub (#60), with no device or number when the text names none.
    http.Response kept(String reason) {
      final map = parsed is Map ? parsed : const {};
      final hash = chainHash(canonical);
      if (!refusals.any((x) => x.event == event && x.hash == hash)) {
        refusals.add((
          event: event,
          device: map['device_id'] is String ? map['device_id'] as String : null,
          seq: map['seq'] is int ? map['seq'] as int : null,
          hash: hash,
          reason: reason,
        ));
      }
      return refusal(reason, canonical);
    }

    if (rows.any(revoked.contains)) return kept('revoked');
    if (!rows.any((id) => !revoked.contains(id))) return refusal('not_admitted', canonical);
    if (parsed is! Map || parsed['ulid'] is! String || parsed['seq'] is! int) {
      return kept('inconsistent_canonical');
    }
    final ulid = parsed['ulid'] as String;
    final stored = log[ulid];
    if (stored != null) {
      if (stored.canonical == canonical && stored.event == event) return accepted(canonical, duplicate: true);
      return kept('ulid_conflict');
    }
    log[ulid] = (event: event, canonical: canonical);
    return accepted(canonical, duplicate: false);
  }

  /// A read as PostgREST answers one: `col=eq.value` filters, one `or` logic tree, `order`, `limit`
  /// and the `select` column list, over the rows RLS already lets the caller see. Only what the
  /// pull sends is understood, and anything else fails the test rather than being ignored.
  List<Map<String, Object?>> _read(Seen r, List<Map<String, Object?>> rows) {
    final out = _filtered(r, rows);
    reads.add((path: r.path, query: r.query, rows: out.length));
    return out;
  }

  /// Every read the pull made, with how many rows it was answered with.
  final reads = <({String path, Map<String, String> query, int rows})>[];

  /// The rows answered to [path] reads, in order.
  List<int> rowsRead(String path) => [for (final x in reads) if (x.path == path) x.rows];

  List<Map<String, Object?>> _filtered(Seen r, List<Map<String, Object?>> rows) {
    var out = [...rows];
    for (final MapEntry(key: k, value: v) in r.query.entries) {
      switch (k) {
        case 'select' || 'order' || 'limit':
          break;
        case 'or':
          if (!v.startsWith('(') || !v.endsWith(')')) fail('or=$v is not a parenthesised list');
          final terms = splitLogic(v.substring(1, v.length - 1)).map(parseLogic).toList();
          out = [for (final row in out) if (terms.any((t) => t(row))) row];
        default:
          if (!v.startsWith('eq.')) fail('the fake reads $k=$v only as eq.');
          out = [for (final row in out) if ('${row[k]}' == v.substring(3)) row];
      }
    }
    final order = r.query['order'];
    if (order != null) {
      final keys = [
        for (final o in order.split(','))
          if (o.split('.') case [final col, 'asc', ...]) col else fail('the fake orders ascending only: $o'),
      ];
      out.sort((a, b) {
        for (final k in keys) {
          final c = compareValues(a[k], b[k]);
          if (c != 0) return c;
        }
        return 0;
      });
    }
    final limit = r.query['limit'];
    if (limit != null) out = out.take(int.parse(limit)).toList();
    final select = r.query['select'];
    if (select != null && select != '*') {
      final cols = select.split(',').map((c) => c.trim()).toList();
      out = [for (final row in out) {for (final c in cols) c: row[c]}];
    }
    return out;
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

/// The terms of a PostgREST logic list, split at its top-level commas: `a.eq.1,or(b.gt.2,b.lt.1)`
/// is two terms, and `c.in.(x,y)` one. A double-quoted value is text, its `,` and `(` included,
/// and inside it a backslash escapes the next character.
List<String> splitLogic(String s) {
  final terms = <String>[];
  var depth = 0, start = 0;
  var quoted = false;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (quoted) {
      if (ch == r'\') i++;
      if (ch == '"') quoted = false;
      continue;
    }
    if (ch == '"') quoted = true;
    if (ch == '(') depth++;
    if (ch == ')') depth--;
    if (ch == ',' && depth == 0) {
      terms.add(s.substring(start, i));
      start = i + 1;
    }
  }
  terms.add(s.substring(start));
  return terms;
}

/// One PostgREST logic term as a test of a row: `or(...)`, `and(...)`, or `col.[not.]op.value`
/// with op one of eq, gt, lt, in and match (a regular expression). A value may be double-quoted,
/// with `\"` and `\\` escaped. SQL's rule for a null holds: no comparison of one is true, and
/// neither is its negation.
bool Function(Map<String, Object?>) parseLogic(String t) {
  for (final (prefix, all) in const [('or(', false), ('and(', true)]) {
    if (t.startsWith(prefix) && t.endsWith(')')) {
      final parts = splitLogic(t.substring(prefix.length, t.length - 1)).map(parseLogic).toList();
      return all ? (row) => parts.every((p) => p(row)) : (row) => parts.any((p) => p(row));
    }
  }
  final dot = t.indexOf('.');
  final col = t.substring(0, dot);
  var rest = t.substring(dot + 1);
  final negate = rest.startsWith('not.');
  if (negate) rest = rest.substring(4);
  final op = rest.substring(0, rest.indexOf('.'));
  final raw = rest.substring(op.length + 1);
  final value = raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')
      ? raw.substring(1, raw.length - 1).replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!)
      : raw;
  if (value == raw && RegExp(r'[,()"]').hasMatch(raw) && op != 'in') {
    fail('an unquoted value holds a reserved character, which PostgREST would not read as text: $t');
  }
  bool? test(Object? v) {
    if (v == null) return null;
    return switch (op) {
      'eq' => '$v' == value,
      'gt' => compareValues(v, v is int ? int.parse(value) : value) > 0,
      'lt' => compareValues(v, v is int ? int.parse(value) : value) < 0,
      'in' => value.substring(1, value.length - 1).split(',').contains('$v'),
      'match' => RegExp(value).hasMatch('$v'),
      _ => fail('the fake does not read the operator $op in $t'),
    };
  }

  return (row) {
    final result = test(row[col]);
    return result != null && (negate ? !result : result);
  };
}

/// Orders two column values as Postgres would here: numbers as numbers, text by code unit (every
/// id compared is upper-case Crockford base32 or hex, where a collation agrees with code units).
int compareValues(Object? a, Object? b) => switch ((a, b)) {
      (int x, int y) => x.compareTo(y),
      (String x, String y) => x.compareTo(y),
      _ => fail('the fake cannot order $a against $b'),
    };

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
  /// [pullPageSize] is small in the pull tests, so a few rows make several pages.
  SyncEngine engine(FakeServer server, {int pullPageSize = 500}) => SyncEngine.open(
      url: projectUrl,
      publishableKey: publishableKey,
      store: store,
      sessionDir: dir,
      transport: server,
      pullPageSize: pullPageSize);
}

/// A phone signed in as [user] (anonymously unless named) and admitted to [event]: its session
/// kept where the engine looks, the admission stamped on its events, the race day learned.
Future<(TestPhone, SyncEngine, String)> admittedPhone(FakeServer server, String user, String event,
    {int pullPageSize = 500}) async {
  final phone = TestPhone();
  server.anonymous.putIfAbsent(user, () => true);
  final admission = server.admitDirectly(user, event);
  phone.store.setAdmissionId(admission);
  phone.keepSession(server.session(user));
  final engine = phone.engine(server, pullPageSize: pullPageSize);
  addTearDown(engine.close);
  return (phone, engine, admission);
}
