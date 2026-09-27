import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_sync/sync.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #6 criterion 12: with events pending, an upload starts within 30 s of signal returning, with
/// nobody touching anything. In fake time, so the worst case is exact.
///
/// fake_async fakes Timers and package:clock, and not DateTime.now, which gotrue judges a token's
/// expiry by (measured in the #6 design critique). So each case here either holds a token valid
/// for hours on the real clock, which keeps gotrue off its timed path, or is written to be
/// indifferent to how long gotrue's own retry takes. The engine is built inside the zone, and time
/// moves only by elapse.
void main() {
  const alice = '00000000-0000-4000-8000-00000000a11c';
  const bound = Duration(seconds: 30);

  /// A phone signed in as alice and admitted to day one, with one event waiting, and an engine
  /// started on it inside the zone.
  (TestPhone, SyncEngine) startedPhone(FakeServer server, {Duration sessionValidFor = const Duration(hours: 3)}) {
    final phone = TestPhone(admission: server.admitDirectly(alice, dayOne));
    phone.keepSession(server.session(alice, validFor: sessionValidFor));
    phone.log(1);
    final engine = phone.engine(server);
    engine.start();
    return (phone, engine);
  }

  void closeIn(FakeAsync async, SyncEngine engine) {
    unawaited(engine.close());
    async.elapse(const Duration(seconds: 30));
  }

  /// How long after [t] the first append_event went out.
  Duration firstAppendAfter(FakeServer server, DateTime t) =>
      server.appends.firstWhere((r) => !r.at.isBefore(t)).at.difference(t);

  /// Signal comes back the moment the next request goes out, and that request is lost in the dead
  /// link: the worst moment for it to come back. Returns when that was, once it happens.
  DateTime Function() backDuringALostRequest(FakeServer server) {
    DateTime? back;
    server.firstHooks.add((r) {
      if (!server.offline || back != null) return null;
      server.offline = false;
      back = r.at;
      return Completer<http.Response?>().future; // never answered: the transport's timeout ends it
    });
    return () => back!;
  }

  test('the defaults keep the bound: a request lost as signal returns, then the longest wait, is '
      'under 30 s', () {
    // A band whose edge is the product's statement (#6 criterion 12), not the values spelled twice.
    final phone = TestPhone();
    final engine = phone.engine(FakeServer());
    addTearDown(engine.close);
    expect(engine.requestTimeout + engine.maxBackoff, lessThan(bound));
    expect(engine.maxBackoff, greaterThanOrEqualTo(const Duration(seconds: 5)),
        reason: 'and it does not hammer a dead link: the club shares one refresh limit per IP');
  });

  test('offline, runs back off to 15 s apart; signal back while a request is lost in a dead link, '
      'and the upload still starts within 30 s', () {
    fakeAsync((async) {
      final server = FakeServer()..offline = true;
      final (phone, engine) = startedPhone(server);
      async.elapse(const Duration(minutes: 2));

      final tries = [for (final r in server.requests) r.at];
      expect(tries.length, greaterThanOrEqualTo(6));
      // Control: by now the backoff is at its cap.
      expect(tries[tries.length - 1].difference(tries[tries.length - 2]), const Duration(seconds: 15));
      expect(server.appends, isEmpty);

      final back = backDuringALostRequest(server);
      async.elapse(const Duration(minutes: 1));

      expect(server.appends, isNotEmpty, reason: 'the upload started, with nobody touching anything');
      final waited = firstAppendAfter(server, back());
      expect(waited, lessThanOrEqualTo(bound));
      expect(waited, greaterThanOrEqualTo(const Duration(seconds: 25)),
          reason: 'the worst case was exercised: the lost request timed out, then the capped backoff ran');
      expect(phone.store.uploadStatus().accepted, 1);
      closeIn(async, engine);
    });
  });

  test('half an hour offline, sync still tries every 15 s, and uploads within 30 s of signal '
      'returning', () {
    fakeAsync((async) {
      final server = FakeServer()..offline = true;
      final (phone, engine) = startedPhone(server);
      // Past the 56th failed run, where an uncapped backoff overflowed and parked the timer for
      // good (the #6 review: 12 min 45 s when each run fails at once).
      async.elapse(const Duration(minutes: 30));

      final tries = [for (final r in server.requests) r.at];
      expect(tries.length, greaterThan(100), reason: 'control: well past the 56th failed run');
      expect(clock.now().difference(tries.last), lessThanOrEqualTo(const Duration(seconds: 15)),
          reason: 'still trying at the end of the half hour');
      expect(tries.last.difference(tries[tries.length - 2]), const Duration(seconds: 15));

      final back = clock.now();
      server.offline = false;
      async.elapse(const Duration(minutes: 1));
      expect(server.appends, isNotEmpty, reason: 'the upload started, with nobody touching anything');
      expect(firstAppendAfter(server, back), lessThanOrEqualTo(bound));
      expect(phone.store.uploadStatus().accepted, 1);
      closeIn(async, engine);
    });
  });

  test('a phone restarted with no signal and an expired token keeps trying on its own, and uploads '
      'within 30 s of signal returning', () {
    fakeAsync((async) {
      final server = FakeServer()..offline = true;
      // Expired on the real clock: the cold start must refresh, and cannot.
      final (phone, engine) = startedPhone(server, sessionValidFor: const Duration(minutes: -5));
      // Well past gotrue's own retry of the refresh, so only sync's timer can try again.
      async.elapse(const Duration(minutes: 3));

      // Control: runs were blocked for want of signal, and nobody was signed in.
      expect(phone.store.uploadStatus().lastRun?.state, UploadRunState.unreachable);
      expect(server.requests.where((r) => r.path == '/auth/v1/token').length, greaterThan(1));
      expect(server.requests.where((r) => r.path == '/auth/v1/signup'), isEmpty);
      expect(phone.sessionFile.existsSync(), isTrue);

      final back = clock.now();
      server.offline = false;
      async.elapse(const Duration(minutes: 1));
      expect(server.appends, isNotEmpty);
      expect(firstAppendAfter(server, back), lessThanOrEqualTo(bound));
      expect(engine.userId, alice, reason: 'the same user, refreshed');
      expect(phone.store.uploadStatus().accepted, 1);
      closeIn(async, engine);
    });
  });

  test('a token the server has expired while the phone clock calls it current is refreshed at once, '
      'and no more than once a minute', () {
    fakeAsync((async) {
      final server = FakeServer();
      var refreshed = false;
      var alwaysExpired = false;
      server.hooks.add((r) {
        if (r.path == '/auth/v1/token') {
          refreshed = true;
          return null;
        }
        if (r.path.startsWith('/rest/') && (!refreshed || alwaysExpired)) {
          return postgrestError(401, 'PGRST303', 'JWT expired');
        }
        return null;
      });
      final (phone, engine) = startedPhone(server);
      async.elapse(const Duration(seconds: 30));
      expect(refreshed, isTrue);
      expect(firstAppendAfter(server, server.requests.first.at), lessThanOrEqualTo(bound));
      expect(phone.store.uploadStatus().accepted, 1);

      // A clock the server keeps disagreeing with: sync must not refresh on every run.
      alwaysExpired = true;
      phone.log(1);
      engine.nudge();
      async.elapse(const Duration(minutes: 5));
      final refreshes = server.requests.where((r) => r.path == '/auth/v1/token').length;
      expect(refreshes, inInclusiveRange(2, 7), reason: 'one a minute at most, over five minutes');
      closeIn(async, engine);
    });
  });

  test('an event appended while the loop is idle goes at once', () {
    fakeAsync((async) {
      final server = FakeServer();
      final (phone, engine) = startedPhone(server);
      async.elapse(const Duration(seconds: 5));
      expect(phone.store.uploadStatus().accepted, 1);

      phone.store.append(const NewEvent(kind: 'finish', source: 'tap'));
      final at = clock.now();
      engine.nudge();
      async.elapse(const Duration(seconds: 1));
      expect(firstAppendAfter(server, at), lessThan(const Duration(seconds: 1)));
      expect(phone.store.uploadStatus().accepted, 2);
      closeIn(async, engine);
    });
  });
}

