/// The sync client the #47 spike runs inside the headless core engine (ADR 003).
///
/// Pure Dart on purpose: package:supabase, never supabase_flutter. supabase_flutter keeps its
/// session in shared_preferences (a Flutter plugin) and refreshes on app-lifecycle callbacks,
/// which a headless engine with no activity does not get. So this client keeps its own session
/// in a file under the engine's files directory, rewritten on every auth change, and recovers it
/// when the engine starts.
///
/// Every outcome is a `SYNC ...` line through [Log], which the spike writes to logcat and its log
/// file for `sync_run.dart` to read. No line carries a key or a token: a token is named by its
/// `iat` and `exp` claims.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supabase/supabase.dart';

/// Where a `SYNC ...` line goes.
typedef Log = void Function(String line);

/// A Supabase client with its session kept in a file.
class SyncClient {
  SyncClient._(this.url, this._key, this.client, this._sessionFile, this._log) {
    _auth = client.auth.onAuthStateChange.listen(_persist,
        onError: (Object e) => _log('SYNC AUTH_ERROR ${_describe(e)}'));
  }

  /// The project's API URL.
  final String url;
  final String _key;

  /// The pure-Dart client, with its default auto-refresh ticker running.
  final SupabaseClient client;

  final File _sessionFile;
  final Log _log;
  late final StreamSubscription<AuthState> _auth;

  /// A token remembered by [rememberToken], for [probeRemembered].
  Session? _remembered;

  /// Opens a client on [url] with the publishable [key], keeping its session in [dir], and
  /// recovers the session kept there by an earlier run of the engine.
  static Future<SyncClient> open(
      {required String url, required String key, required String dir, required Log log}) async {
    final sync = SyncClient._(
        url, key, SupabaseClient(url, key), File('$dir/sync_session.json'), log);
    await sync._resume();
    return sync;
  }

  /// The user the client is signed in as, or null.
  String? get uid => client.auth.currentSession?.user.id;

  Future<void> _resume() async {
    if (!_sessionFile.existsSync()) {
      _log('SYNC NO_SESSION');
      return;
    }
    final sw = Stopwatch()..start();
    try {
      final session = (await client.auth.recoverSession(_sessionFile.readAsStringSync())).session;
      _log('SYNC RESUMED uid=${session?.user.id} ${_token(session)} ms=${sw.elapsedMilliseconds}');
    } catch (e) {
      _log('SYNC RESUME_FAILED ${_describe(e)}');
    }
  }

  /// Rewrites the session file on every auth change, so a refresh-token rotation is on disk
  /// before the next one. Written to a temporary file and renamed, so a kill mid-write leaves
  /// the previous session rather than half of one.
  void _persist(AuthState state) {
    final session = state.session;
    _log('SYNC AUTH ${state.event.name} uid=${session?.user.id} ${_token(session)}');
    if (state.event == AuthChangeEvent.signedOut) {
      if (_sessionFile.existsSync()) _sessionFile.deleteSync();
      return;
    }
    if (session == null) return;
    final tmp = File('${_sessionFile.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(session.toJson()), flush: true);
    tmp.renameSync(_sessionFile.path);
  }

  /// Signs in anonymously, the device-handoff path, unless a session is already held.
  Future<void> signIn() async {
    if (uid != null) {
      _log('SYNC ALREADY_SIGNED_IN uid=$uid');
      return;
    }
    final sw = Stopwatch()..start();
    try {
      final session = (await client.auth.signInAnonymously()).session;
      _log('SYNC SIGNED_IN uid=${session?.user.id} ${_token(session)} ms=${sw.elapsedMilliseconds}');
    } catch (e) {
      _log('SYNC SIGN_IN_FAILED ${_describe(e)} ms=${sw.elapsedMilliseconds}');
    }
  }

  /// Calls admit_device with [code] for [event], then [repeats] more times: admit_device answers
  /// an already-admitted phone with the same admission, so the repeats time the round trip alone.
  Future<void> admit(String event, String code, {int repeats = 20}) async {
    final samples = <int>[];
    String? admission;
    for (var i = 0; i <= repeats; i++) {
      final sw = Stopwatch()..start();
      try {
        final id = await client.rpc<String>('admit_device',
            params: {'p_event': event, 'p_admission_code': code});
        sw.stop();
        if (admission != null && id != admission) {
          _log('SYNC ADMIT_CHANGED from=$admission to=$id');
        }
        admission = id;
        samples.add(sw.elapsedMicroseconds);
      } catch (e) {
        _log('SYNC ADMIT_FAILED ${_describe(e)}');
        return;
      }
    }
    final first = samples.removeAt(0);
    samples.sort();
    String ms(int us) => (us / 1000).toStringAsFixed(1);
    _log('SYNC ADMITTED id=$admission uid=$uid first_ms=${ms(first)} '
        'n=${samples.length} p50_ms=${ms(samples[samples.length ~/ 2])} '
        'p95_ms=${ms(samples[(samples.length * 95 ~/ 100).clamp(0, samples.length - 1)])} '
        'max_ms=${ms(samples.last)}');
  }

  /// Inserts a fleet named [name] on [course] of [event], and says whether the server took it.
  Future<void> insertFleet(String event, String course, String name, {required String label}) async {
    final before = client.auth.currentSession;
    final sw = Stopwatch()..start();
    try {
      await client.from('fleet').insert({'event_id': event, 'course_id': course, 'name': name});
      _log('SYNC FLEET_OK label=$label uid=$uid ms=${sw.elapsedMilliseconds} '
          'before_iat=${_claims(before?.accessToken)?['iat']} '
          'after_iat=${_claims(client.auth.currentSession?.accessToken)?['iat']}');
    } on PostgrestException catch (e) {
      _log('SYNC FLEET_REFUSED label=$label uid=$uid code=${e.code} ms=${sw.elapsedMilliseconds} '
          'message="${e.message}"');
    } catch (e) {
      _log('SYNC FLEET_FAILED label=$label ${_describe(e)} ms=${sw.elapsedMilliseconds}');
    }
  }

  /// Writes the session's user and token claims.
  void whoami() => _log('SYNC WHOAMI uid=$uid ${_token(client.auth.currentSession)} '
      'now=${DateTime.now().millisecondsSinceEpoch ~/ 1000}');

  /// Stops the auto-refresh ticker, standing in for a phone whose CPU slept through every tick,
  /// so the next write finds its access token already expired.
  void stopAutoRefresh() {
    client.auth.stopAutoRefresh();
    _log('SYNC AUTO_REFRESH off');
  }

  /// Starts the auto-refresh ticker again.
  void startAutoRefresh() {
    client.auth.startAutoRefresh();
    _log('SYNC AUTO_REFRESH on');
  }

  /// Remembers the current session, so [probeRemembered] can present its tokens later.
  void rememberToken() {
    _remembered = client.auth.currentSession;
    _log('SYNC REMEMBERED ${_token(_remembered)}');
  }

  /// Presents the remembered access token to the API directly, outside the client, and writes
  /// the answer: the control that shows the token really expired rather than the client
  /// refreshing a token the server would still have taken.
  Future<void> probeRemembered() async {
    final session = _remembered;
    if (session == null) {
      _log('SYNC PROBE_NONE');
      return;
    }
    final (status, body) = await _raw('GET', '/rest/v1/fleet', {'select': 'id', 'limit': '1'},
        bearer: session.accessToken);
    _log('SYNC PROBE_ACCESS status=$status ${_token(session)} '
        'now=${DateTime.now().millisecondsSinceEpoch ~/ 1000} body="${_short(body)}"');
  }

  /// Presents the remembered refresh token to the auth API directly, after the client has
  /// rotated it: what a phone killed between a refresh and its session write would send.
  Future<void> reuseRememberedRefresh() async {
    final token = _remembered?.refreshToken;
    if (token == null) {
      _log('SYNC PROBE_NONE');
      return;
    }
    final (status, body) = await _raw('POST', '/auth/v1/token', {'grant_type': 'refresh_token'},
        body: {'refresh_token': token});
    _log('SYNC PROBE_REFRESH status=$status body="${_short(body)}"');
  }

  Future<(int, String)> _raw(String method, String path, Map<String, String> query,
      {String? bearer, Object? body}) async {
    final http = HttpClient();
    try {
      final request = await http.openUrl(method, Uri.parse(url).replace(path: path, queryParameters: query));
      request.headers.set('apikey', _key);
      if (bearer != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close();
      return (response.statusCode, await response.transform(utf8.decoder).join());
    } finally {
      http.close();
    }
  }

  /// Stops listening and closes the client.
  Future<void> close() async {
    await _auth.cancel();
    await client.dispose();
  }
}

/// The commands `sync_run.dart` sends the headless core, run one at a time in the order they
/// arrive. Each is a JSON object naming its `cmd`.
class SyncCommands {
  SyncCommands(this.dir, this._log);

  /// The engine's files directory, where the config and the session are kept.
  final String dir;
  final Log _log;
  SyncClient? _client;
  Future<void> _chain = Future.value();

  File get _config => File('$dir/sync_config.json');

  /// Opens the client from the config an earlier run of the engine kept, recovering its session.
  /// This is what a restarted engine does with no UI and no command.
  Future<void> resume() => _then(() async {
        if (!_config.existsSync()) {
          _log('SYNC NOT_CONFIGURED');
          return;
        }
        final config = jsonDecode(_config.readAsStringSync()) as Map<String, Object?>;
        _client = await SyncClient.open(
            url: config['url']! as String, key: config['key']! as String, dir: dir, log: _log);
      });

  /// Queues the command [encoded] (base64url JSON) behind every earlier one.
  void enqueue(String encoded) => _then(() => _run(encoded));

  Future<void> _then(Future<void> Function() step) => _chain = _chain
      .then((_) => step())
      .catchError((Object e) => _log('SYNC COMMAND_FAILED ${_describe(e)}'));

  Future<void> _run(String encoded) async {
    final cmd = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded))))
        as Map<String, Object?>;
    String arg(String name) => cmd[name]! as String;
    final name = arg('cmd');
    _log('SYNC CMD $name');
    if (name == 'configure') {
      await _client?.close();
      _config.writeAsStringSync(jsonEncode({'url': arg('url'), 'key': arg('key')}), flush: true);
      _client = await SyncClient.open(url: arg('url'), key: arg('key'), dir: dir, log: _log);
      _log('SYNC CONFIGURED url=${arg('url')}');
      return;
    }
    final client = _client;
    if (client == null) {
      _log('SYNC NOT_CONFIGURED cmd=$name');
      return;
    }
    switch (name) {
      case 'sign_in':
        await client.signIn();
      case 'admit':
        await client.admit(arg('event'), arg('code'), repeats: (cmd['repeats'] as int?) ?? 20);
      case 'insert_fleet':
        await client.insertFleet(arg('event'), arg('course'), arg('name'), label: arg('label'));
      case 'whoami':
        client.whoami();
      case 'auto_refresh':
        cmd['on'] == true ? client.startAutoRefresh() : client.stopAutoRefresh();
      case 'remember':
        client.rememberToken();
      case 'probe_access':
        await client.probeRemembered();
      case 'probe_refresh':
        await client.reuseRememberedRefresh();
      default:
        _log('SYNC UNKNOWN_CMD $name');
    }
  }
}

/// A token named by its claims, never by its value.
String _token(Session? session) {
  if (session == null) return 'token=none';
  final claims = _claims(session.accessToken);
  return 'iat=${claims?['iat']} exp=${claims?['exp']}';
}

Map<String, Object?>? _claims(String? jwt) {
  if (jwt == null) return null;
  try {
    final part = jwt.split('.')[1];
    return jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(part))))
        as Map<String, Object?>;
  } catch (_) {
    return null;
  }
}

String _describe(Object e) => switch (e) {
      AuthException(:final code, :final message, :final statusCode) =>
        'auth code=$code status=$statusCode message="$message"',
      PostgrestException(:final code, :final message) => 'postgrest code=$code message="$message"',
      _ => '${e.runtimeType} "${_short(e.toString())}"',
    };

/// A response body shortened for one log line, with anything shaped like a token removed.
String _short(String text) {
  final clean = text
      .replaceAll(RegExp(r'eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+'), '<jwt>')
      .replaceAllMapped(RegExp(r'"(access_token|refresh_token)"\s*:\s*"[^"]*"'),
          (m) => '"${m.group(1)}":"<redacted>"')
      .replaceAll('\n', ' ')
      .trim();
  return clean.length <= 160 ? clean : clean.substring(0, 160);
}
