// #47: drives the sync spike end to end on one emulator against the local stack, and prints a
// verdict per criterion.
//
//   dart run tool/core_host_spike/sync_run.dart [--skip-build] [--reuse-probe] [--out <file>]
//
// Run from the repo root. It needs:
// - the local stack running (README, Server side);
// - one emulator attached whose image allows `adb root` (google_apis, not google_apis_playstore).
//   Root is how the run kills the core's process the way the system would, and how it reaches the
//   service, which is not exported;
// - ADB naming adb when it is not on PATH.
//
// Criterion 4 needs the stack started with a short `jwt_expiry` in supabase/config.toml (60 s was
// used, docs/adr/006). The run reads the token lifetime from the first sign-in and skips criterion
// 4 when it is over 120 s.
//
// --reuse-probe adds a destructive last step: it presents a refresh token the client has already
// rotated, as a phone killed between a refresh and its session write would, and reports what that
// does to the live session.
//
// The phone reaches the stack over `adb reverse`, at the device's own 127.0.0.1. Everything the
// core does is read from its `SYNC` lines in logcat. Every server-side claim is read from the
// database as the table owner, through psql in the stack's database container. Nothing it prints
// carries a key, a token or an admission code.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../scripts/owner.dart' as owner;

const pkg = 'com.procompanion.core_host_spike';
const spikeDir = 'tool/core_host_spike';
final String adb = Platform.environment['ADB'] ?? 'adb';

final transcript = StringBuffer();
final verdicts = <String, String>{};

void say(String line) {
  stdout.writeln(line);
  transcript.writeln(line);
}

void verdict(String criterion, bool pass, String evidence) {
  verdicts[criterion] = '${pass ? 'PASS' : 'FAIL'}  $evidence';
  say('>> criterion $criterion: ${pass ? 'PASS' : 'FAIL'}  $evidence');
}

Future<void> main(List<String> args) async {
  final skipBuild = args.contains('--skip-build');
  final reuseProbe = args.contains('--reuse-probe');
  final outIndex = args.indexOf('--out');
  final out = outIndex < 0 ? null : args[outIndex + 1];

  try {
    await run(skipBuild: skipBuild, reuseProbe: reuseProbe);
  } catch (e, st) {
    say('RUN ABORTED: $e');
    say('$st');
    exitCode = 1;
  } finally {
    say('');
    say('== verdicts ==');
    for (final c in ['1', '2', '3', '3b', '4a', '4b', 'reuse parent', 'reuse grandparent']) {
      if (verdicts.containsKey(c)) say('criterion $c: ${verdicts[c]}');
    }
    say('');
    say('== every SYNC and START line the core wrote ==');
    try {
      for (final line in await coreLines()) {
        if (line.contains(' SYNC ') || line.contains(' START')) say(line);
      }
    } catch (e) {
      say('logcat unreadable: $e');
    }
    if (out != null) File(out).writeAsStringSync(transcript.toString());
    if (verdicts.values.any((v) => v.startsWith('FAIL'))) exitCode = 1;
  }
}

Future<void> run({required bool skipBuild, required bool reuseProbe}) async {
  final status = await owner.readLocalStatus();
  final api = Uri.parse(status['API_URL']!);
  final service = owner.ServiceApi(owner.Target(api, status['SECRET_KEY']!, 'the local stack'));
  say('stack ${api.origin}; emulator API ${(await shell('getprop ro.build.version.sdk')).trim()}, '
      '${(await shell('getprop ro.product.model')).trim()}');

  // Two clubs, so "another club's event" is a real one with a race area of its own.
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '').substring(0, 14);
  Future<owner.Provisioned> day(String who) => owner.provision(
      service,
      owner.ProvisionArgs(
          club: 'Spike 47 $who $stamp', event: 'Sync spike', date: '2026-09-27', raceAreas: ['Alpha']),
      StringBuffer());
  final home = await day('home');
  final away = await day('away');
  say('provisioned home event ${home.eventId} and away event ${away.eventId} (another club)');

  await prepareDevice(skipBuild: skipBuild, port: api.port);

  // --- Criterion 1: sign in and admit from the headless core with the activity destroyed.
  await shell('am start -n $pkg/.MainActivity --ez autostart true');
  final pid1 = (await expectLine(RegExp(r' START pid=(\d+)'))).group(1)!;
  await expectLine(RegExp(r' SYNC NOT_CONFIGURED'));
  await shell('input keyevent KEYCODE_BACK');
  await Future<void>.delayed(const Duration(seconds: 3));
  final activitiesAfterBack = await activityCount();
  final serviceUp = await serviceRunning();
  say('after BACK: activities $activitiesAfterBack, service running $serviceUp, core pid $pid1');

  await send({'cmd': 'configure', 'url': 'http://127.0.0.1:${api.port}', 'key': status['PUBLISHABLE_KEY']});
  await expectLine(RegExp(r' SYNC CONFIGURED'));
  await send({'cmd': 'sign_in'});
  final signIn = await expectLine(RegExp(r' SYNC (SIGNED_IN|SIGN_IN_FAILED)\b(.*)'));
  if (signIn.group(1) != 'SIGNED_IN') {
    verdict('1', false, 'sign-in failed:${signIn.group(2)}');
    return;
  }
  final signedIn = fields(signIn.group(2)!);
  final uid = signedIn['uid']!;
  final lifetime = int.parse(signedIn['exp']!) - int.parse(signedIn['iat']!);
  say('token lifetime ${lifetime}s');

  await send({'cmd': 'admit', 'event': home.eventId, 'code': home.codes['overall_pro'], 'repeats': 20});
  final admit = await expectLine(RegExp(r' SYNC (ADMITTED|ADMIT_FAILED)\b(.*)'));
  final admitted = fields(admit.group(2)!);
  final row = admit.group(1) == 'ADMITTED'
      ? await psql("select d.auth_uid || ' ' || d.role || ' ' || u.is_anonymous from public.committee_device d "
          "join auth.users u on u.id = d.auth_uid where d.id = '${admitted['id']}';")
      : '';
  final activitiesAfterAdmit = await activityCount();
  verdict(
      '1',
      activitiesAfterBack == 0 &&
          activitiesAfterAdmit == 0 &&
          serviceUp &&
          admit.group(1) == 'ADMITTED' &&
          row == '$uid overall_pro true',
      'activities $activitiesAfterBack/$activitiesAfterAdmit; anonymous sign-in ${signedIn['ms']} ms; '
      'admit_device first call ${admitted['first_ms']} ms, then n=${admitted['n']} p50 '
      '${admitted['p50_ms']} ms p95 ${admitted['p95_ms']} ms max ${admitted['max_ms']} ms; '
      'server row: ${row.isEmpty ? admit.group(2) : row}');

  // --- Criterion 2: RLS takes a fleet on the phone's own event and refuses another club's.
  final ownName = 'Spike own $stamp';
  await send({
    'cmd': 'insert_fleet', 'event': home.eventId, 'course': home.raceAreaIds['Alpha'],
    'name': ownName, 'label': 'own',
  });
  final own = await expectLine(RegExp(r' SYNC FLEET_(\w+) label=own\b(.*)'));
  await send({
    'cmd': 'insert_fleet', 'event': away.eventId, 'course': away.raceAreaIds['Alpha'],
    'name': 'Spike other $stamp', 'label': 'other',
  });
  final other = await expectLine(RegExp(r' SYNC FLEET_(\w+) label=other\b(.*)'));
  final homeFleets = await psql("select count(*) from public.fleet where event_id = '${home.eventId}';");
  final awayFleets = await psql("select count(*) from public.fleet where event_id = '${away.eventId}';");
  verdict(
      '2',
      own.group(1) == 'OK' &&
          other.group(1) == 'REFUSED' &&
          fields(other.group(2)!)['code'] == '42501' &&
          homeFleets == '1' &&
          awayFleets == '0',
      'own event: ${own.group(1)}${own.group(2)}; another club\'s event: ${other.group(1)}${other.group(2)}; '
      'fleets on the server: own event $homeFleets, other club\'s event $awayFleets');

  // --- Criterion 3: kill the process; the core restarts with no UI and resumes the same user.
  final resumed = await killAndResume('3', uid, home, pid1, 'restart');

  // --- Criterion 4: the access token expires, and the next write refreshes inside the engine.
  if (lifetime > 120) {
    say('criterion 4 skipped: the token lives ${lifetime}s; start the stack with a short jwt_expiry');
  } else if (resumed != null) {
    await expiry(home, stamp);
    // A kill after the refreshes: the core must resume from the rotated refresh token it wrote.
    await killAndResume('3b', uid, home, resumed, 'after-refresh');
    if (reuseProbe) await reuse(home, stamp);
  }
}

/// Kills the core's process as the system would, waits for the system to restart the service with
/// no activity, and checks it resumed [uid]'s session without signing in. Returns the new pid.
Future<String?> killAndResume(
    String criterion, String uid, owner.Provisioned home, String pid, String label) async {
  final anonBefore = await psql('select count(*) from auth.users where is_anonymous;');
  final sessionsBefore = await psql("select count(*) from auth.sessions where user_id = '$uid';");
  say('[$criterion] service before the kill: ${await foregroundState()}');
  final livePid = (await shell('pidof $pkg')).trim();
  say('[$criterion] killing core pid $livePid (the run last saw $pid)');
  final killedAt = DateTime.now();
  await shell('kill -9 $livePid');

  final start = await expectLine(RegExp(r' START pid=(\d+)'), timeout: const Duration(minutes: 3),
      onTimeout: () async => say('[$criterion] no restart in 3 min; '
          'system log: ${await systemLogAbout('CoreService')}'));
  final restartedIn = DateTime.now().difference(killedAt).inMilliseconds;
  final newPid = start.group(1)!;
  final activities = await activityCount();
  say('[$criterion] service after the system restarted it: ${await foregroundState()}');
  final resume = await expectLine(RegExp(r' SYNC (RESUMED|RESUME_FAILED|NO_SESSION|NOT_CONFIGURED)\b(.*)'));
  final resumedFields = fields(resume.group(2)!);
  await send({
    'cmd': 'insert_fleet', 'event': home.eventId, 'course': home.raceAreaIds['Alpha'],
    'name': 'Spike $label ${DateTime.now().millisecondsSinceEpoch}', 'label': label,
  });
  final write = await expectLine(RegExp(' SYNC FLEET_(\\w+) label=$label\\b(.*)'));
  final anonAfter = await psql('select count(*) from auth.users where is_anonymous;');
  final sessionsAfter = await psql("select count(*) from auth.sessions where user_id = '$uid';");
  final restartLog = await systemLogAbout('Scheduling restart of crashed service');
  verdict(
      criterion,
      newPid != livePid &&
          activities == 0 &&
          resume.group(1) == 'RESUMED' &&
          resumedFields['uid'] == uid &&
          fields(write.group(2)!)['uid'] == uid &&
          write.group(1) == 'OK' &&
          anonAfter == anonBefore &&
          sessionsAfter == sessionsBefore,
      'pid $livePid -> $newPid, core back $restartedIn ms after the kill, activities $activities; '
      '${resume.group(1)}${resume.group(2)}; write as ${fields(write.group(2)!)['uid']}: ${write.group(1)}; '
      'anonymous users $anonBefore -> $anonAfter, auth sessions for the user $sessionsBefore -> $sessionsAfter; '
      'system: ${restartLog.isEmpty ? 'no restart line' : restartLog}');
  return newPid;
}

/// Criterion 4, two arms. (a) The client's own ticker, as shipped: wait past the first token's
/// expiry and show a refresh happened in the engine and a write goes through. (b) The ticker
/// stopped, standing in for a phone whose CPU slept through it: the token really expires (the
/// server refuses it, the control), then a write refreshes it on the way and succeeds.
Future<void> expiry(owner.Provisioned home, String stamp) async {
  await send({'cmd': 'whoami'});
  final now = fields((await expectLine(RegExp(r' SYNC WHOAMI (.*)'))).group(1)!);
  final exp = int.parse(now['exp']!);
  final mark = cursor;
  final wait = exp - int.parse(now['now']!) + 5;
  say('[4a] waiting ${wait}s, past the current token\'s expiry, with the ticker running');
  await Future<void>.delayed(Duration(seconds: wait));
  final refreshed = (await coreLines())
      .skip(mark)
      .where((l) => l.contains(' SYNC AUTH tokenRefreshed'))
      .map((l) => fields(l.split(' SYNC AUTH tokenRefreshed').last))
      .toList();
  await send({
    'cmd': 'insert_fleet', 'event': home.eventId, 'course': home.raceAreaIds['Alpha'],
    'name': 'Spike ticker $stamp', 'label': 'ticker',
  });
  final a = await expectLine(RegExp(r' SYNC FLEET_(\w+) label=ticker\b(.*)'));
  verdict(
      '4a',
      refreshed.isNotEmpty &&
          refreshed.every((r) => int.parse(r['iat']!) > int.parse(now['iat']!)) &&
          a.group(1) == 'OK',
      'ticker refreshed ${refreshed.length} time(s) in ${wait}s (new iat ${refreshed.map((r) => r['iat']).join(', ')}); '
      'write: ${a.group(1)}${a.group(2)}');

  await send({'cmd': 'auto_refresh', 'on': false});
  await expectLine(RegExp(r' SYNC AUTO_REFRESH off'));
  await send({'cmd': 'remember'});
  final remembered = fields((await expectLine(RegExp(r' SYNC REMEMBERED (.*)'))).group(1)!);
  await send({'cmd': 'whoami'});
  final nowB = fields((await expectLine(RegExp(r' SYNC WHOAMI (.*)'))).group(1)!);
  // Two probes of the remembered token: 5 s past its exp, and 40 s past it. PostgREST was measured
  // taking a token 5 s past exp (run 2), so only the second is the control that it expired.
  Future<Map<String, String>> probeAt(int pastExp) async {
    await send({'cmd': 'whoami'});
    final now = int.parse(fields((await expectLine(RegExp(r' SYNC WHOAMI (.*)'))).group(1)!)['now']!);
    final wait = int.parse(remembered['exp']!) + pastExp - now;
    say('[4b] waiting ${wait}s, to ${pastExp}s past the remembered token\'s exp ${remembered['exp']}');
    if (wait > 0) await Future<void>.delayed(Duration(seconds: wait));
    await send({'cmd': 'probe_access'});
    return fields((await expectLine(RegExp(r' SYNC PROBE_ACCESS (.*)'))).group(1)!);
  }

  say('[4b] ticker stopped at ${nowB['now']}');
  final early = await probeAt(5);
  final probe = await probeAt(40);
  final markB = cursor;
  await send({
    'cmd': 'insert_fleet', 'event': home.eventId, 'course': home.raceAreaIds['Alpha'],
    'name': 'Spike expired $stamp', 'label': 'expired',
  });
  final b = await expectLine(RegExp(r' SYNC FLEET_(\w+) label=expired\b(.*)'));
  final between = (await coreLines()).skip(markB).takeWhile((l) => !l.contains('label=expired'));
  final refreshedOnWrite = between.any((l) => l.contains(' SYNC AUTH tokenRefreshed'));
  await send({'cmd': 'auto_refresh', 'on': true});
  await expectLine(RegExp(r' SYNC AUTO_REFRESH on'));
  final written = fields(b.group(2)!);
  verdict(
      '4b',
      probe['status'] == '401' &&
          b.group(1) == 'OK' &&
          refreshedOnWrite &&
          written['before_iat'] == remembered['iat'] &&
          int.parse(written['after_iat'] ?? '0') > int.parse(remembered['iat']!),
      'the remembered token (exp ${remembered['exp']}) presented directly: 5 s past exp ${early['status']}, '
      '40 s past exp ${probe['status']} ${probe['body'] ?? ''}; '
      'refresh during the write: $refreshedOnWrite; write: ${b.group(1)}${b.group(2)}');
}

/// Not a criterion: what a refresh token the client already rotated does when presented again,
/// after the 10 s reuse interval. First the parent of the active token (one rotation back, as a
/// phone killed between a refresh and its session write would send), then a grandparent (two
/// back). After each, whether the live session survives its next refresh and can still write.
Future<void> reuse(owner.Provisioned home, String stamp) async {
  for (final (rotations, name) in [(1, 'parent'), (2, 'grandparent')]) {
    await send({'cmd': 'remember'});
    final remembered = fields((await expectLine(RegExp(r' SYNC REMEMBERED (.*)'))).group(1)!);
    say('[reuse] $name: waiting for $rotations rotation(s) of the remembered token, then 15 s more');
    final seen = <String>{};
    while (seen.length < rotations) {
      final m = await expectLine(RegExp(r' SYNC AUTH tokenRefreshed (.*)'), timeout: const Duration(minutes: 2));
      final iat = fields(m.group(1)!)['iat']!;
      if (int.parse(iat) > int.parse(remembered['iat']!)) seen.add(iat);
    }
    await Future<void>.delayed(const Duration(seconds: 15));
    await send({'cmd': 'probe_refresh'});
    final probe = (await expectLine(RegExp(r' SYNC PROBE_REFRESH (.*)'))).group(1)!;
    say('[reuse] $name presented: $probe');
    final next = await expectLine(RegExp(r' SYNC (AUTH tokenRefreshed|AUTH signedOut|AUTH_ERROR)(.*)'),
        timeout: const Duration(minutes: 2));
    final label = 'reuse-$name';
    await send({
      'cmd': 'insert_fleet', 'event': home.eventId, 'course': home.raceAreaIds['Alpha'],
      'name': 'Spike $label $stamp', 'label': label,
    });
    final write = await expectLine(RegExp(' SYNC FLEET_(\\w+) label=$label\\b(.*)'));
    extra('reuse $name',
        'the $name of the active refresh token (issued with iat ${remembered['iat']}) presented 15 s after '
        'its rotation: $probe; the live session\'s next refresh: '
        '${next.group(1)}${next.group(2)}; then a write: ${write.group(1)}${write.group(2)}');
    if (write.group(1) != 'OK') return;
  }
}

/// A measurement that is not one of the issue's criteria.
void extra(String name, String evidence) {
  verdicts[name] = 'EXTRA  $evidence';
  say('>> $name: $evidence');
}

// --- The device.

Future<void> prepareDevice({required bool skipBuild, required int port}) async {
  if (!skipBuild) {
    say('building the profile APK');
    final build = await Process.run('flutter', ['build', 'apk', '--profile'],
        workingDirectory: spikeDir, runInShell: true);
    if (build.exitCode != 0) throw StateError('flutter build failed: ${build.stderr}');
  }
  await adbRun(['install', '-r', '$spikeDir/build/app/outputs/flutter-apk/app-profile.apk']);
  await adbRun(['root']);
  await adbRun(['wait-for-device']);
  await Future<void>.delayed(const Duration(seconds: 2));
  final whoami = (await shell('id -u')).trim();
  if (whoami != '0') throw StateError('adb root did not take (uid $whoami): use a google_apis image');
  await adbRun(['reverse', 'tcp:$port', 'tcp:$port']);
  await shell('am force-stop $pkg');
  await shell('pm clear $pkg');
  for (final p in ['POST_NOTIFICATIONS', 'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION']) {
    await shell('pm grant $pkg android.permission.$p');
  }
  await adbRun(['logcat', '-c']);
}

Future<String> adbRun(List<String> args) async {
  final r = await Process.run(adb, args);
  if (r.exitCode != 0) throw StateError('adb ${args.join(' ')} exited ${r.exitCode}: ${r.stderr}');
  return (r.stdout as String).replaceAll('\r', '');
}

Future<String> shell(String command) => adbRun(['shell', command]);

/// Sends [command] to the running core, as the payload of an intent to its service.
Future<void> send(Map<String, Object?> command) async {
  final payload = 'sync:${base64Url.encode(utf8.encode(jsonEncode(command)))}';
  final out = await shell('am startservice -n $pkg/.CoreService --es payload $payload');
  if (out.contains('Error')) throw StateError('am startservice: $out');
}

Future<int> activityCount() async =>
    RegExp('$pkg/\\.MainActivity').allMatches(await shell('dumpsys activity activities')).length;

Future<bool> serviceRunning() async =>
    (await shell('dumpsys activity services $pkg')).contains('CoreService');

/// The service's foreground state as the system holds it: whether it is foreground, of which
/// type, and whether it has while-in-use access (location, for the real core's GPS).
Future<String> foregroundState() async => RegExp(
        r'(isForeground=\S+ foregroundId=\S+ types=\S+|mAllowWhileInUsePermissionInFgsReason=\S+'
        r'|allowStartForeground=\S+|startForegroundCount=\S+)')
    .allMatches(await shell('dumpsys activity services $pkg'))
    .map((m) => m.group(1))
    .toSet()
    .join(' ');

/// The system log's lines naming [needle], for the record.
Future<String> systemLogAbout(String needle) async => (await adbRun(['logcat', '-d', '-b', 'main,system,crash']))
    .split('\n')
    .where((l) => l.contains(needle) && (l.contains(pkg) || l.contains('core_host_spike')))
    .map((l) => l.trim())
    .join(' | ');

// --- The core's output.

/// Every line the core printed since the run cleared logcat, without the `CORE ` prefix.
Future<List<String>> coreLines() async {
  final r = await Process.run(adb, ['logcat', '-d', '-v', 'raw', '-s', 'flutter']);
  return [
    for (final l in (r.stdout as String).replaceAll('\r', '').split('\n'))
      if (l.startsWith('CORE ')) l.substring(5),
  ];
}

/// Index of the first core line [expectLine] has not yet consumed.
int cursor = 0;

/// Waits for the next core line matching [pattern] after [cursor], and consumes up to it.
Future<RegExpMatch> expectLine(RegExp pattern,
    {Duration timeout = const Duration(seconds: 60), Future<void> Function()? onTimeout}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final lines = await coreLines();
    for (var i = cursor; i < lines.length; i++) {
      final match = pattern.firstMatch(lines[i]);
      if (match != null) {
        cursor = i + 1;
        return match;
      }
    }
    if (DateTime.now().isAfter(deadline)) {
      if (onTimeout != null) await onTimeout();
      throw TimeoutException('no core line matching /${pattern.pattern}/ in $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

/// The `key=value` fields of a line (a quoted value may hold spaces).
Map<String, String> fields(String text) => {
      for (final m in RegExp(r'(\w+)=("([^"]*)"|\S+)').allMatches(text))
        m.group(1)!: m.group(3) ?? m.group(2)!,
    };

// --- The server.

final String dbContainer = 'supabase_db_${RegExp(r'^project_id\s*=\s*"([^"]+)"', multiLine: true)
    .firstMatch(File('supabase/config.toml').readAsStringSync())!.group(1)!}';

Future<String> psql(String sql) async {
  final r = await Process.run('docker',
      ['exec', dbContainer, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q', '-t', '-A', '-c', sql]);
  if (r.exitCode != 0) throw StateError('psql failed: ${r.stderr}');
  return (r.stdout as String).trim();
}
