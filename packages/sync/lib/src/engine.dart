import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:pro_companion_core/store.dart';
import 'package:supabase/supabase.dart';

import 'inline_json.dart';
import 'key.dart';
import 'session_file.dart';
import 'transport.dart';

/// How one run of [SyncEngine.syncOnce] ended.
class SyncRun {
  const SyncRun({
    required this.state,
    this.accepted = 0,
    this.refused = 0,
    this.paused = 0,
    this.remaining = 0,
    this.neverAdmitted = 0,
    this.error,
    this.pull,
  });

  /// One of [UploadRunState.all], or [deferred].
  final String state;

  /// The run did not start, or stopped early, because a sign-in or an
  /// admission was in progress or the engine was closing. It is not recorded.
  static const deferred = 'deferred';

  /// Events the server holds after this run, as it answered.
  final int accepted;

  /// Events the server refused in this run, now final.
  final int refused;

  /// Events that wait for a race day the signed-in phone is not admitted to.
  final int paused;

  /// Events carrying an admission that are still to go after this run,
  /// [paused] ones included.
  final int remaining;

  /// Events written before the phone was ever admitted. They never upload.
  final int neverAdmitted;

  /// The last error the run met, described without any token.
  final String? error;

  /// How the run's pull of the other phones' events ended (#64), or null when
  /// it did not pull: the upload half found no signal or no session, or the
  /// run was deferred.
  final PullRun? pull;

  bool get progressed => accepted + refused > 0;

  SyncRun _withPull(PullRun? pull) => SyncRun(
        state: state,
        accepted: accepted,
        refused: refused,
        paused: paused,
        remaining: remaining,
        neverAdmitted: neverAdmitted,
        error: error,
        pull: pull,
      );

  @override
  String toString() => 'SyncRun($state: accepted $accepted, refused $refused, paused $paused, '
      'remaining $remaining, never admitted $neverAdmitted${error == null ? '' : ', $error'}'
      '${pull == null ? '' : '; $pull'})';
}

/// Why a pull stopped before reading everything, carried out of the page loop.
class _PullStop implements Exception {
  const _PullStop(this.state, [this.error]);

  /// One of [PullRunState.all], or null when the run was deferred.
  final String? state;
  final String? error;
}

/// append_event's answer to a request it did not judge: why it failed, and so
/// what it proves.
enum _Failure {
  /// PostgREST rejected the token (PGRST30x), with a session held. The token
  /// is stale: the phone's clock can call a token current that the server
  /// has expired, since gotrue judges expiry by it.
  tokenRejected,

  /// The request ran as nobody: its session is gone.
  noSession,

  /// The server answered with an error of its own. The call rolled back, so
  /// nothing was stored, and the event is retried.
  serverError,

  /// No answer from the server itself: a gateway's status, or no answer at
  /// all. Whether the event was stored is unknown.
  unreachable,
}

/// Uploads this phone's own events to the companion's server through
/// append_event, exactly once each, and keeps every outcome in the core's
/// store (#6, ADR 006); then pulls the other committee phones' events down
/// (#64). Pure Dart: it runs in the headless core engine beside the store,
/// never in the UI's.
///
/// Each event goes as its stored canonical text, verbatim, to the race day
/// its own admission belongs to. The server keys it by its ULID, and a
/// byte-identical re-send is a no-op, so a retry after a lost answer is
/// harmless. An answer of accepted is kept as accepted; a refusal
/// (`append_event_refused`) is kept as refused, final and never sent again;
/// anything else is retried.
///
/// A run is bound to one signed-in user. Nothing is sent to a race day that
/// user holds no admission to: a lost session, or a new user not yet
/// admitted, pauses sync rather than turning events into refusals (owner
/// decision on #6).
///
/// The pull reads every race day the signed-in user is admitted to and not
/// revoked on, from each device's cursor (`EventStore.pullCursors`), and
/// stores what it reads page by page, so a pull cut off mid-page resumes from
/// exactly what it stored. A race day where the phone was revoked is not read
/// at all, and nothing already stored is touched (#64 criterion 10).
class SyncEngine {
  SyncEngine._(this._store, this._client, this._session, this._transport, this._ownsTransport,
      this.requestTimeout, this.maxBackoff, this.refreshSpacing, this.pullInterval, this.pullPageSize, this._log) {
    // Subscribed before anything can change the session, so no change is missed.
    _auth = _client.auth.onAuthStateChange.listen(_onAuth,
        onError: (Object e) => _log('SYNC AUTH_ERROR ${_describe(e)}'));
  }

  /// Opens sync on [store] against the project at [url].
  ///
  /// [publishableKey] must be the project's publishable key: anything else is
  /// refused before a request is made. The session is kept in [sessionDir],
  /// which must be app-private and **excluded from backup and device
  /// transfer** (Android: `getNoBackupFilesDir`). A restored copy of the
  /// session is a refresh token many rotations old, and presenting one costs
  /// the whole session (ADR 006).
  ///
  /// Nothing is sent until the first run. [transport] replaces the network,
  /// for tests. [pullInterval] is how often a phone with nothing left to
  /// upload runs again to pull (#64; owner decision at pickup, 15 s), or null
  /// for never.
  static SyncEngine open({
    required String url,
    required String publishableKey,
    required EventStore store,
    required String sessionDir,
    http.Client? transport,
    Duration requestTimeout = const Duration(seconds: 10),
    Duration maxBackoff = const Duration(seconds: 15),
    Duration refreshSpacing = const Duration(seconds: 60),
    Duration? pullInterval = const Duration(seconds: 15),
    int pullPageSize = 500,
    void Function(String line)? log,
  }) {
    if (pullPageSize < 1) throw ArgumentError.value(pullPageSize, 'pullPageSize', 'must be at least 1');
    requirePublishableKey(publishableKey);
    final inner = transport ?? IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 5));
    final guarded = GuardedTransport(inner, timeout: requestTimeout);
    final client = SupabaseClient(
      url,
      publishableKey,
      httpClient: guarded,
      isolate: InlineJson(),
      // Sync owns every retry, so a run's length is bounded by its own
      // timeout and backoff and nothing is re-sent behind its back.
      postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
    );
    return SyncEngine._(store, client, SessionFile(sessionDir), guarded, transport == null, requestTimeout,
        maxBackoff, refreshSpacing, pullInterval, pullPageSize, log ?? (_) {});
  }

  final EventStore _store;
  final SupabaseClient _client;
  final SessionFile _session;
  final GuardedTransport _transport;
  final bool _ownsTransport;
  final void Function(String line) _log;

  /// The longest any request may take, its answer included.
  final Duration requestTimeout;

  /// The longest wait between two runs while events remain. With
  /// [requestTimeout], it bounds how long after signal returns an upload
  /// starts: a request lost in a dead link as signal returns, then this wait.
  final Duration maxBackoff;

  /// The least time between two refreshes sync forces itself. A phone clock
  /// far ahead of the server would otherwise refresh on every run, against
  /// the club's shared per-IP refresh limit.
  final Duration refreshSpacing;

  /// How long a phone with nothing left to upload waits before the next run,
  /// which pulls (#64). Null: it waits for a [nudge].
  final Duration? pullInterval;

  /// The most rows one pull request asks for.
  final int pullPageSize;

  late final StreamSubscription<AuthState> _auth;
  Future<SyncRun>? _running;
  bool _dirty = false;
  int _authOps = 0;
  Future<void> _authQueue = Future.value();
  Timer? _timer;
  int _failures = 0;
  bool _started = false;
  bool _closed = false;
  DateTime? _lastForcedRefresh;

  /// The user the phone is signed in as, or null.
  String? get userId => _client.auth.currentUser?.id;

  /// The client sync sends with, exactly as it is built, so a test can show
  /// what the database refuses from the sync code path. Not for production
  /// code.
  SupabaseClient get clientForTests => _client;

  // The loop ----------------------------------------------------------------

  /// Starts syncing: a run now, then a run after every [nudge] and, while
  /// anything remains, on a backoff that grows to [maxBackoff]; once nothing
  /// remains, every [pullInterval], to pull.
  void start() {
    if (_started || _closed) return;
    _started = true;
    syncOnce();
  }

  /// Something changed, such as an event appended: runs now, unless a run is
  /// waiting out a failure, whose backoff then decides.
  void nudge() {
    if (!_started || _closed) return;
    if (_timer != null && _failures > 0) return;
    _runNow();
  }

  void _runNow() {
    _timer?.cancel();
    _timer = null;
    if (_started && !_closed) syncOnce();
  }

  /// One run: every event this phone may upload now, in sequence order. A
  /// call while a run is active joins it, and that run goes round once more.
  Future<SyncRun> syncOnce() {
    if (_closed) return Future.value(const SyncRun(state: SyncRun.deferred));
    final running = _running;
    if (running != null) {
      _dirty = true;
      return running;
    }
    return _running = _loop();
  }

  Future<SyncRun> _loop() async {
    var run = const SyncRun(state: SyncRun.deferred);
    try {
      do {
        _dirty = false;
        if (_authOps > 0 || _closed) {
          run = const SyncRun(state: SyncRun.deferred);
          break;
        }
        run = await _runRecorded();
      } while (_dirty && !_closed && _authOps == 0);
    } finally {
      _running = null;
    }
    _schedule(run);
    return run;
  }

  void _schedule(SyncRun run) {
    _timer?.cancel();
    _timer = null;
    if (!_started || _closed || run.state == SyncRun.deferred) return;
    if (run.remaining == 0) {
      _failures = 0;
      // Nothing to upload, but other phones keep logging: pull again soon.
      final every = pullInterval;
      if (every != null) {
        _timer = Timer(every, () {
          _timer = null;
          syncOnce();
        });
      }
      return;
    }
    // Blocked and paused runs are retried too: after a cold start with no
    // signal, nothing else will ever try again.
    _failures = run.progressed ? 0 : _failures + 1;
    // The exponent stops at 20 (about 12 days, past any backoff): uncapped, 2^54
    // seconds overflows, and at 56 failures, about 13 minutes offline, the
    // timer was parked for 73,000 years and nudge() then waited on it for good.
    final delay = _failures == 0
        ? const Duration(seconds: 1)
        : Duration(milliseconds: min(1000 * pow(2, min(_failures - 1, 20)).toInt(), maxBackoff.inMilliseconds));
    _timer = Timer(delay, () {
      _timer = null;
      syncOnce();
    });
  }

  Future<SyncRun> _runRecorded() async {
    SyncRun run;
    try {
      run = await _run();
    } catch (e) {
      // Whatever it was, sync must not stop over it: the run counts as a
      // failed one, is recorded, and is retried. The store may be what failed,
      // so reading it again here must not throw from the catch: counted as
      // one waiting, the run is still retried.
      int remaining;
      try {
        remaining = _uploadable().length;
      } catch (_) {
        remaining = 1;
      }
      run = SyncRun(state: UploadRunState.retrying, remaining: remaining, error: _describe(e));
    }
    if (run.state != SyncRun.deferred) {
      try {
        _store.recordUploadRun(UploadRun(
          state: run.state,
          at: clock.now().millisecondsSinceEpoch,
          paused: run.paused,
          error: run.error,
        ));
      } catch (e) {
        _log('SYNC RECORD_FAILED ${_describe(e)}');
      }
    }
    _log('SYNC RUN $run');
    // The pull goes only where the upload half reached the server: offline,
    // or with no session, it would only fail the same way again.
    if (const {UploadRunState.done, UploadRunState.notAdmitted, UploadRunState.retrying}.contains(run.state) &&
        _authOps == 0 &&
        !_closed) {
      run = run._withPull(await _pullRecorded());
    }
    return run;
  }

  // The pull (#64) ---------------------------------------------------------

  /// One pull, recorded. Null when it was deferred, and then not recorded.
  Future<PullRun?> _pullRecorded() async {
    PullRun? pull;
    try {
      pull = await _pull();
    } catch (e) {
      // As for the upload: whatever it was, the pull counts as a failed one
      // and is tried again on the next run.
      pull = PullRun(state: PullRunState.retrying, at: clock.now().millisecondsSinceEpoch, error: _describe(e));
    }
    if (pull == null) return null;
    try {
      _store.recordPullRun(pull);
    } catch (e) {
      _log('SYNC PULL_RECORD_FAILED ${_describe(e)}');
    }
    _log('SYNC PULL $pull');
    return pull;
  }

  Future<PullRun?> _pull() async {
    var stored = 0, rejected = 0, revokedDays = 0;
    PullRun ended(String state, {String? error}) => PullRun(
          state: state,
          at: clock.now().millisecondsSinceEpoch,
          stored: stored,
          revoked: revokedDays,
          rejected: rejected,
          error: error,
        );

    final blocked = await _ensureSession();
    if (blocked != null) return ended(blocked.$1, error: blocked.$2);
    _persistIfStale();
    final runUid = userId;
    try {
      // The phone's own admissions: which race days it may read, and which
      // revoked it. revoked_at is granted to the phone (#39), so a revoked
      // race day is refused here, by the phone, without reading its log: the
      // server's RLS would answer it with no rows rather than an error (owner
      // decision on #64).
      final rows = await _read(() => _client.rest.from('committee_device').select('event_id, revoked_at, superseded_by'));
      final revoked = <String>{}, active = <String>{};
      for (final row in rows) {
        final r = row as Map;
        final day = r['event_id'] as String;
        if (r['revoked_at'] != null) {
          revoked.add(day);
        } else if (r['superseded_by'] == null) {
          active.add(day);
        }
      }
      revokedDays = revoked.length;
      final readable = active.difference(revoked).toList()..sort();
      if (readable.isEmpty) return ended(revoked.isEmpty ? PullRunState.notAdmitted : PullRunState.revoked);

      for (final day in readable) {
        final scope = _scope(_store.pullCursors(day));
        // The stubs first: a stubbed number counts as seen, and is what lets
        // the cursor past a refused event.
        await _pages(
          runUid,
          table: 'event_refusal',
          columns: 'device_id,seq,event_hash,reason',
          day: day,
          scope: scope,
          keys: const ['device_id', 'seq', 'event_hash'],
          take: (r) {
            // A text refused as unreadable names no device or number
            // (event_refusal's device_id and seq are nullable). The scope
            // never asks for one, since SQL's NOT IN and comparisons are null
            // for a null; a row that arrives anyway is refused, not a crash.
            final (device, seq, hash, reason) = (r['device_id'], r['seq'], r['event_hash'], r['reason']);
            if (device is! String || seq is! int || hash is! String || reason is! String) {
              throw const PullRefused('a refusal stub that names no device and sequence number');
            }
            final taken = _store.insertRefusalStub(
                RefusalStub(eventId: day, deviceId: device, seq: seq, eventHash: hash, reason: reason));
            if (taken) stored++;
          },
          onRefused: () => rejected++,
        );
        await _pages(
          runUid,
          table: 'event_log',
          columns: 'ulid,device_id,seq,canonical',
          day: day,
          scope: scope,
          keys: const ['device_id', 'seq', 'ulid'],
          take: (r) {
            final canonical = r['canonical'];
            if (canonical is! String) throw const PullRefused('a log row with no canonical text');
            if (_store.insertPulled(day, canonical)) stored++;
          },
          onRefused: () => rejected++,
        );
      }
    } on _PullStop catch (stop) {
      final state = stop.state;
      return state == null ? null : ended(state, error: stop.error);
    }
    return ended(PullRunState.done);
  }

  /// Reads [table]'s rows for race day [day] within [scope], page by page in
  /// [keys] order, handing each row to [take] before the next page is asked
  /// for. Within one run the pages go by keyset, after the last row read, so
  /// rows the cursor still asks for (above a gap not yet filled) never hold a
  /// later page back.
  Future<void> _pages(
    String? runUid, {
    required String table,
    required String columns,
    required String day,
    required String scope,
    required List<String> keys,
    required void Function(Map row) take,
    required void Function() onRefused,
  }) async {
    List<Object?>? after;
    while (true) {
      // A new event to upload, or a sign-in, goes first. The run goes round
      // again and the pull resumes from what it has stored: at least one page
      // is read per run, so it still progresses (review of #64).
      if (_authOps > 0 || _closed || (_dirty && after != null)) throw const _PullStop(null);
      if (userId != runUid) throw const _PullStop(PullRunState.noSession, 'the session changed during the pull');
      final filter = after == null ? scope : 'and(or($scope),${_after(keys, after)})';
      final query = _client.rest.from(table).select(columns).eq('event_id', day).or(filter);
      final rows = await _read(() {
        var ordered = query.order(keys.first, ascending: true);
        for (final k in keys.skip(1)) {
          ordered = ordered.order(k, ascending: true);
        }
        return ordered.limit(pullPageSize);
      });
      for (final row in rows) {
        try {
          take(row as Map);
        } on PullRefused catch (e) {
          onRefused();
          _log('SYNC PULL_REFUSED $table ${e.message}');
        }
      }
      if (rows.length < pullPageSize) return;
      final last = rows.last as Map;
      after = [for (final k in keys) last[k]];
    }
  }

  /// The most missing ranges one device's part of the scope names. Past it,
  /// the scope asks for everything above the last range it names, so a request
  /// stays a bounded size whatever a chain's holes.
  static const maxMissingRanges = 8;

  /// The core's ULID rule (`isUlid`), as a Postgres regular expression: a
  /// device not seen yet is asked for only when its id is one this phone's
  /// store would take, so a row it would refuse is never sent at all.
  static const _ulidPattern = r'^[0-9A-HJKMNP-TV-Z]{26}$';

  /// What a pull asks for, from [cursors]: for each device seen, exactly the
  /// numbers not held (below its floor, above its highest, and each missing
  /// range); and every device not seen yet whose id is a ULID. This device's
  /// own cursor covers all it wrote, so its own events are not sent back.
  ///
  /// Every id here came out of the store, which holds only ULIDs, so none
  /// carries a character PostgREST reserves.
  static String _scope(Map<String, PullCursor> cursors) {
    final devices = cursors.keys.toList()..sort();
    return [
      for (final d in devices) 'and(device_id.eq.$d,or(${_notHeld(cursors[d]!)}))',
      'and(device_id.not.in.(${devices.join(',')}),device_id.match.${_quoted(_ulidPattern)})',
    ].join(',');
  }

  static String _notHeld(PullCursor c) {
    final named = c.missing.take(maxMissingRanges).toList();
    final above = c.missing.length > maxMissingRanges ? c.missing[maxMissingRanges].$1 - 1 : c.highest;
    return [
      'seq.lt.${c.floor}',
      'seq.gt.$above',
      for (final (from, to) in named) 'and(seq.gt.${from - 1},seq.lt.${to + 1})',
    ].join(',');
  }

  /// Rows after [values] in [keys] order: a keyset, as a PostgREST filter.
  /// The values come from the server's last row, which is a phone's own text,
  /// so each text value is quoted and read by PostgREST as text, whatever
  /// characters it holds.
  static String _after(List<String> keys, List<Object?> values) {
    String v(Object? value) => value is int ? '$value' : _quoted('$value');
    final terms = <String>[];
    for (var i = 0; i < keys.length; i++) {
      final equal = [for (var j = 0; j < i; j++) '${keys[j]}.eq.${v(values[j])}'];
      final greater = '${keys[i]}.gt.${v(values[i])}';
      terms.add(equal.isEmpty ? greater : 'and(${[...equal, greater].join(',')})');
    }
    return 'or(${terms.join(',')})';
  }

  /// [value] in PostgREST's double-quoted form, which reads reserved
  /// characters as text: a backslash and a double quote are escaped.
  static String _quoted(String value) => '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  /// Runs one read of the pull, turning a failure into the [_PullStop] that
  /// says what it proves, as the upload half does.
  Future<List<dynamic>> _read(Future<List<dynamic>> Function() read) async {
    try {
      return await read();
    } on PostgrestException catch (e) {
      final failure = _classify(e);
      if (failure == _Failure.tokenRejected) await _forceRefresh();
      throw _PullStop(_stateOf(failure), _describe(e));
    } on AuthRetryableFetchException catch (e) {
      throw _PullStop(PullRunState.unreachable, _describe(e));
    } on AuthException catch (e) {
      throw _PullStop(PullRunState.noSession, _describe(e));
    } on http.ClientException catch (e) {
      throw _PullStop(PullRunState.unreachable, _describe(e));
    }
  }

  List<PendingUpload> _uploadable() => [
        for (final p in _store.pendingUploads())
          if (p.admissionId != null) p,
      ];

  Future<SyncRun> _run() async {
    final pending = _store.pendingUploads();
    final uploadable = [
      for (final p in pending)
        if (p.admissionId != null) p,
    ];
    final neverAdmitted = pending.length - uploadable.length;
    SyncRun ended(String state, {String? error, int accepted = 0, int refused = 0, int paused = 0}) => SyncRun(
          state: state,
          accepted: accepted,
          refused: refused,
          paused: paused,
          remaining: uploadable.length - accepted - refused,
          neverAdmitted: neverAdmitted,
          error: error,
        );
    if (uploadable.isEmpty) return ended(UploadRunState.done);

    final blocked = await _ensureSession();
    if (blocked != null) return ended(blocked.$1, error: blocked.$2);
    _persistIfStale();
    final runUid = userId;

    // The race days this user holds an admission to, revoked ones included:
    // a revoked phone's events are still sent, and get their final refusal.
    final List<dynamic> rows;
    try {
      // Through rest, not SupabaseClient.from: in supabase 2.16.1 from() builds
      // its query without the client's PostgrestClientOptions, so a GET there
      // is retried three times (1, 2 and 4 s) whatever retryEnabled says, and a
      // run offline would last 7 s longer than its own timeout and backoff.
      rows = await _client.rest.from('committee_device').select('id, event_id');
    } on PostgrestException catch (e) {
      final failure = _classify(e);
      if (failure == _Failure.tokenRejected) await _forceRefresh();
      return ended(_stateOf(failure), error: _describe(e));
    } on AuthRetryableFetchException catch (e) {
      return ended(UploadRunState.unreachable, error: _describe(e));
    } on AuthException catch (e) {
      return ended(UploadRunState.noSession, error: _describe(e));
    } on http.ClientException catch (e) {
      return ended(UploadRunState.unreachable, error: _describe(e));
    }
    final held = <String>{};
    for (final row in rows) {
      final r = row as Map;
      _store.recordAdmissionEvent(r['id'] as String, r['event_id'] as String);
      held.add(r['event_id'] as String);
    }

    var accepted = 0, refused = 0, paused = 0, serverErrors = 0;
    String? error;
    for (final p in uploadable) {
      if (_authOps > 0 || _closed) {
        return SyncRun(
            state: SyncRun.deferred,
            accepted: accepted,
            refused: refused,
            remaining: uploadable.length - accepted - refused,
            neverAdmitted: neverAdmitted);
      }
      if (userId != runUid) {
        // Signed out, or someone else signed in, mid-run: what was held
        // under the old user is not held under this one.
        return ended(UploadRunState.noSession, accepted: accepted, refused: refused, paused: paused, error: error);
      }
      final eventId = _store.admissionEvent(p.admissionId!);
      if (eventId == null || !held.contains(eventId)) {
        paused++;
        continue;
      }
      final attempt = _store.beginAttempt(p.ulid);
      try {
        final answer =
            await _client.rpc<dynamic>('append_event', params: {'p_event': eventId, 'p_canonical': p.canonical});
        final hash = chainHash(p.canonical);
        if (answer is Map && answer['outcome'] == 'accepted' && answer['hash'] == hash) {
          _store.recordAccepted(p.ulid, hash);
          accepted++;
        } else {
          // Never acknowledged unless the server says it holds these exact
          // bytes. It may have stored them, so the send is not voided.
          serverErrors++;
          error = 'append_event answered without accepting the text as sent';
        }
      } on PostgrestException catch (e) {
        if (e.code == 'append_event_refused') {
          final reason = '${e.details}';
          if (reason == 'not_admitted') {
            // This user holds a row on this race day, and rows are never
            // deleted, so the server could only answer this to someone else:
            // the session changed under the send. Never kept; the next run
            // judges again.
            _store.voidAttempt(p.ulid, attempt.n);
            return ended(UploadRunState.notAdmitted,
                accepted: accepted, refused: refused, paused: paused, error: _describe(e));
          }
          _store.recordRefused(p.ulid, reason, mayBeOnShore: attempt.earlierUnknown);
          refused++;
          continue;
        }
        final failure = _classify(e);
        error = _describe(e);
        switch (failure) {
          case _Failure.serverError:
            // Judged by nothing but the server's own error, and rolled back.
            // The next event may fare better (a fleet another phone has not
            // uploaded yet, say), so the run goes on.
            _store.voidAttempt(p.ulid, attempt.n);
            serverErrors++;
          case _Failure.tokenRejected:
            _store.voidAttempt(p.ulid, attempt.n);
            await _forceRefresh();
            return ended(UploadRunState.retrying, accepted: accepted, refused: refused, paused: paused, error: error);
          case _Failure.noSession:
            _store.voidAttempt(p.ulid, attempt.n);
            return ended(UploadRunState.noSession, accepted: accepted, refused: refused, paused: paused, error: error);
          case _Failure.unreachable:
            return ended(UploadRunState.unreachable,
                accepted: accepted, refused: refused, paused: paused, error: error);
        }
      } on AuthRetryableFetchException catch (e) {
        // The token could not be refreshed, so nothing was sent.
        _store.voidAttempt(p.ulid, attempt.n);
        return ended(UploadRunState.unreachable,
            accepted: accepted, refused: refused, paused: paused, error: _describe(e));
      } on AuthException catch (e) {
        _store.voidAttempt(p.ulid, attempt.n);
        return ended(UploadRunState.noSession,
            accepted: accepted, refused: refused, paused: paused, error: _describe(e));
      } on http.ClientException catch (e) {
        // Lost on the way there or on the way back: unknown, so not voided.
        return ended(UploadRunState.unreachable,
            accepted: accepted, refused: refused, paused: paused, error: _describe(e));
      }
    }
    final remaining = uploadable.length - accepted - refused;
    final state = remaining == 0
        ? UploadRunState.done
        : serverErrors > 0
            ? UploadRunState.retrying
            : UploadRunState.notAdmitted;
    return ended(state, accepted: accepted, refused: refused, paused: paused, error: error);
  }

  static final _jwtCode = RegExp(r'^PGRST30\d$');
  static final _serverCode = RegExp(r'^(?:[0-9A-Z]{5}|PGRST\d+)$');

  /// What a PostgREST error that is not a refusal proves. PostgrestException
  /// carries no HTTP status, only the body's code, so this reads the code: a
  /// SQLSTATE or PostgREST's own is the server answering; a bare status is a
  /// gateway, or no server at all.
  _Failure _classify(PostgrestException e) {
    final code = e.code ?? '';
    if (_jwtCode.hasMatch(code) || code == '401') {
      return _client.auth.currentSession == null ? _Failure.noSession : _Failure.tokenRejected;
    }
    // Only a caller with no session is refused this: append_event and the
    // phone's own admissions are granted to every signed-in user.
    if (code == '42501') return _Failure.noSession;
    if (_serverCode.hasMatch(code)) return _Failure.serverError;
    return _Failure.unreachable;
  }

  static String _stateOf(_Failure f) => switch (f) {
        _Failure.tokenRejected || _Failure.serverError => UploadRunState.retrying,
        _Failure.noSession => UploadRunState.noSession,
        _Failure.unreachable => UploadRunState.unreachable,
      };

  Future<void> _forceRefresh() async {
    final now = clock.now();
    final last = _lastForcedRefresh;
    if (last != null && now.difference(last) < refreshSpacing) return;
    _lastForcedRefresh = now;
    try {
      await _client.auth.refreshSession();
    } catch (e) {
      _log('SYNC REFRESH_FAILED ${_describe(e)}');
    }
  }

  // The session -------------------------------------------------------------

  void _onAuth(AuthState state) {
    try {
      if (state.event == AuthChangeEvent.signedOut) {
        // GoTrue rejected the session, or the phone signed out. The guarded
        // transport lets through only GoTrue's own rejections, so nothing in
        // the file can be used again.
        _session.delete();
        return;
      }
      final session = state.session;
      if (session != null) _session.write(jsonEncode(session.toJson()));
    } catch (e) {
      _log('SYNC SESSION_WRITE_FAILED ${_describe(e)}');
    }
  }

  /// A write that failed leaves the file behind the session in memory, and a
  /// file two rotations behind costs the session on the next cold start.
  void _persistIfStale() {
    final session = _client.auth.currentSession;
    if (session == null || _session.refreshToken() == session.refreshToken) return;
    try {
      _session.write(jsonEncode(session.toJson()));
    } catch (e) {
      _log('SYNC SESSION_WRITE_FAILED ${_describe(e)}');
    }
  }

  /// Makes sure a session is held, recovering the kept one if need be. gotrue
  /// never retries a recovery that failed for want of signal, so every run
  /// tries again. Never signs anyone in. Null when a session is held;
  /// otherwise why not, and the error.
  Future<(String, String?)?> _ensureSession() async {
    if (_client.auth.currentSession != null) return null;
    final String? text;
    try {
      text = _session.read();
    } on FileSystemException catch (e) {
      // Bytes that are not text, from a torn write: as unreadable as bad JSON,
      // and set aside the same way, or no run and no sign-in could get past it.
      _session.setAside();
      return (UploadRunState.sessionUnreadable, _describe(e));
    }
    if (text == null) return (UploadRunState.noSession, null);
    try {
      await _client.auth.recoverSession(text);
    } on AuthRetryableFetchException catch (e) {
      return (UploadRunState.unreachable, _describe(e));
    } on http.ClientException catch (e) {
      return (UploadRunState.unreachable, _describe(e));
    } on TimeoutException catch (e) {
      return (UploadRunState.unreachable, _describe(e));
    } on AuthException catch (e) {
      // GoTrue rejected it, and gotrue signed out, which deleted the file. A
      // file still there is one gotrue could not read.
      if (_session.exists) {
        _session.setAside();
        return (UploadRunState.sessionUnreadable, _describe(e));
      }
      return (UploadRunState.noSession, _describe(e));
    } catch (e) {
      _session.setAside();
      return (UploadRunState.sessionUnreadable, _describe(e));
    }
    return _client.auth.currentSession == null ? (UploadRunState.noSession, null) : null;
  }

  // Signing in and admission ------------------------------------------------
  //
  // Each waits for the active run to stop, at its next event boundary, and no
  // run starts until it is done: a run is bound to the user it started with.

  Future<T> _exclusive<T>(Future<T> Function() op) {
    if (_closed) return Future.error(StateError('sync is closed'));
    final result = _authQueue.then((_) async {
      _authOps++;
      try {
        _timer?.cancel();
        _timer = null;
        final running = _running;
        if (running != null) await running;
        return await op();
      } finally {
        _authOps--;
        if (_authOps == 0) _runNow();
      }
    });
    _authQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Signs in anonymously, the device-handoff path (ADR 005), and returns the
  /// user. Refused while the phone holds a session, or keeps one it cannot
  /// reach the server to check: a new user holds no admission, and minting
  /// one over a live session would strand the events it was admitted for.
  Future<String> signInAnonymously() => _exclusive(() async {
        await _ensureSession();
        if (_client.auth.currentSession != null || _session.exists) {
          throw StateError('this phone already holds a session; sign in again only once it is gone');
        }
        return _userOf(await _signIn(_client.auth.signInAnonymously));
      });

  /// Signs in as a named volunteer with the token hash from a magic link, and
  /// returns the user. The account's admissions come with it.
  Future<String> signInWithMagicLink(String tokenHash) => _exclusive(() async =>
      _userOf(await _signIn(() => _client.auth.verifyOTP(type: OtpType.magiclink, tokenHash: tokenHash))));

  Future<AuthResponse> _signIn(Future<AuthResponse> Function() call) async {
    final AuthResponse response;
    try {
      response = await call();
    } on AuthException catch (e) {
      if (e.statusCode == '429') {
        throw SignInRateLimited('the server refused the sign-in: RATE LIMITED (${e.message})');
      }
      rethrow;
    }
    // gotrue announces the new session a turn later; the file must hold it
    // before the sign-in returns, or a kill in that turn loses it.
    _persistIfStale();
    return response;
  }

  static String _userOf(AuthResponse r) {
    final id = r.user?.id;
    if (id == null) throw StateError('the sign-in answered with no user');
    return id;
  }

  /// Admits the signed-in phone to race day [eventId] with an admission
  /// [code] (ADR 005's admit_device), remembers which race day the admission
  /// is for, and returns its id. It does not stamp the admission on the
  /// core's events: the caller does that with [EventStore.setAdmissionId], so
  /// #71 can log its role-change marker under the old admission first.
  Future<String> admit(String eventId, String code, {String? person}) => _exclusive(() async {
        // Checked before the server admits: afterwards, the store would refuse
        // the race day and the admission the server made would be lost.
        if (!isAdmissionId(eventId)) {
          throw ArgumentError.value(eventId, 'eventId', 'is not a UUID in the form Postgres prints');
        }
        final id = await _client.rpc<dynamic>('admit_device', params: {
          'p_event': eventId,
          'p_admission_code': code,
          'p_person': ?person,
        });
        if (id is! String) throw StateError('admit_device answered with no admission id');
        _store.recordAdmissionEvent(id, eventId);
        return id;
      });

  /// Stops syncing: no run starts after this, and the one in progress, if any,
  /// stops at its next event.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _timer = null;
    final running = _running;
    if (running != null) await running;
    await _auth.cancel();
    await _client.dispose();
    if (_ownsTransport) _transport.close();
  }
}

/// A sign-in the server refused for the rate limit, not for anything about
/// the phone.
class SignInRateLimited implements Exception {
  const SignInRateLimited(this.message);
  final String message;

  @override
  String toString() => 'SignInRateLimited: $message';
}

/// An error in one line, with nothing shaped like a token in it.
String _describe(Object e) {
  final text = switch (e) {
    PostgrestException(:final code, :final message, :final details) =>
      'postgrest code=$code details=$details message="$message"',
    AuthException(:final code, :final statusCode, :final message) =>
      '${e.runtimeType} code=$code status=$statusCode message="$message"',
    _ => '${e.runtimeType} "$e"',
  };
  final clean = text
      .replaceAll(RegExp(r'eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+'), '<jwt>')
      .replaceAll(RegExp(r'sb_(?:secret|publishable)_[A-Za-z0-9_\-]+'), '<key>')
      .replaceAll('\n', ' ');
  return clean.length <= 240 ? clean : clean.substring(0, 240);
}
