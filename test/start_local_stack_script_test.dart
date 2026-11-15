import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #140: scripts/start_local_stack.sh, which CI's local-stack job runs to start the stack, moves
/// to another registry when one refuses on its data limit, and retries a throttled pull on the same
/// registry first. On PR #138 ECR answered "Data limit exceeded" to every pull, through five
/// attempts and a job re-run, and the required check held two PRs unmergeable.
///
/// The script runs for real under `sh`, with SUPABASE_CLI pointed at a stand-in that answers each
/// `start` from a scripted list per registry and records every call. Each case sets every input the
/// script reads, GITHUB_ENV included: CI's own GITHUB_ENV is never written, and a registry exported
/// by an earlier step cannot leak in.

/// The stand-in CLI. It records `<registry> <command>` for every call, and answers the nth `start`
/// from a registry with line n of the file named after that registry.
const _fakeCli = r'''
#!/bin/sh
reg="$SUPABASE_INTERNAL_IMAGE_REGISTRY"
echo "$reg $1" >>"$FAKE_DIR/calls"
[ "$1" = start ] || exit 0
n=$(grep -cxF "$reg start" "$FAKE_DIR/calls")
outcome=$(sed -n "${n}p" "$FAKE_DIR/$reg" 2>/dev/null)
case "$outcome" in
  ok) echo "Started supabase local development setup."; exit 0 ;;
  datalimit) echo "failed to pull docker image from all registries: $reg/supabase/kong:2.8.1 attempt 3: Error response from daemon: error from registry: Data limit exceeded"; exit 1 ;;
  rate) echo "failed to pull docker image from all registries: $reg/supabase/kong:2.8.1 attempt 3: toomanyrequests: Rate exceeded"; exit 1 ;;
  migration) echo "ERROR: division by zero (SQLSTATE 22012)"; exit 1 ;;
  portbusy) echo 'failed to start docker container "supabase_db_pro_companion": Error response from daemon: failed to set up container networking: driver failed programming external connectivity on endpoint supabase_db_pro_companion (3965): failed to bind host port 0.0.0.0:54422/tcp: address already in use'; exit 1 ;;
  allocated) echo 'failed to start docker container "supabase_kong_pro_companion": Error response from daemon: driver failed programming external connectivity on endpoint supabase_kong_pro_companion (07ab): Bind for 0.0.0.0:54421 failed: port is already allocated'; exit 1 ;;
  *) echo "no scripted outcome for $reg start $n"; exit 3 ;;
esac
''';

/// The stand-in port probe (#113, PR #188). It records `probe <port>` among the CLI's calls, so a
/// case's call list also shows whether the probe ran and on which port.
const _fakeProbe = r'''
#!/bin/sh
echo "probe $1" >>"$FAKE_DIR/calls"
echo "held by the stand-in"
''';

typedef _Run = ({int exitCode, String out, String err, List<String> calls, String githubEnv});

Future<_Run> _run(Map<String, List<String>> outcomes,
    {String firstRegistry = '', bool withGithubEnv = true}) async {
  final dir = Directory.systemTemp.createTempSync('start_stack_');
  addTearDown(() => dir.deleteSync(recursive: true));
  final p = dir.path.replaceAll(r'\', '/');
  File('$p/fake_supabase.sh').writeAsStringSync(_fakeCli);
  File('$p/fake_probe.sh').writeAsStringSync(_fakeProbe);
  outcomes.forEach((registry, lines) => File('$p/$registry').writeAsStringSync('${lines.join('\n')}\n'));
  final githubEnv = File('$p/github_env')..writeAsStringSync('');
  final result = await Process.run('sh', ['scripts/start_local_stack.sh'], environment: {
    'SUPABASE_CLI': 'sh $p/fake_supabase.sh',
    'STACK_PORT_PROBE': 'sh $p/fake_probe.sh',
    'FAKE_DIR': p,
    'START_STACK_BACKOFF_S': '0',
    'SUPABASE_INTERNAL_IMAGE_REGISTRY': firstRegistry,
    'GITHUB_ENV': withGithubEnv ? '$p/github_env' : '',
  });
  final calls = File('$p/calls');
  return (
    exitCode: result.exitCode,
    out: result.stdout as String,
    err: result.stderr as String,
    calls: calls.existsSync() ? calls.readAsLinesSync() : <String>[],
    githubEnv: githubEnv.readAsStringSync(),
  );
}

void main() {
  test('criterion 1: ECR refusing on its data limit moves to ghcr.io after one attempt', () async {
    final r = await _run({
      'public.ecr.aws': ['datalimit'],
      'ghcr.io': ['ok'],
    });
    expect(r.exitCode, 0, reason: r.out);
    expect(r.calls, ['public.ecr.aws start', 'public.ecr.aws stop', 'ghcr.io start']);
    expect(r.out, contains('started from ghcr.io'));
  });

  test('criterion 2: a throttled pull retries the same registry before anything else', () async {
    final r = await _run({
      'public.ecr.aws': ['rate', 'rate', 'ok'],
    });
    expect(r.exitCode, 0, reason: r.out);
    expect(r.calls, [
      'public.ecr.aws start', 'public.ecr.aws stop',
      'public.ecr.aws start', 'public.ecr.aws stop',
      'public.ecr.aws start',
    ]);
    expect(r.githubEnv, 'SUPABASE_INTERNAL_IMAGE_REGISTRY=public.ecr.aws\n');
  });

  test('criterion 2: three throttled attempts move to the next registry', () async {
    final r = await _run({
      'public.ecr.aws': ['rate', 'rate', 'rate'],
      'ghcr.io': ['ok'],
    });
    expect(r.exitCode, 0, reason: r.out);
    expect(r.calls, [
      'public.ecr.aws start', 'public.ecr.aws stop',
      'public.ecr.aws start', 'public.ecr.aws stop',
      'public.ecr.aws start', 'public.ecr.aws stop',
      'ghcr.io start',
    ]);
  });

  test('criterion 3: a failure that is not an image pull stops at once', () async {
    final r = await _run({
      'public.ecr.aws': ['migration'],
      'ghcr.io': ['ok'],
    });
    expect(r.exitCode, 1, reason: r.out);
    expect(r.calls, ['public.ecr.aws start']);
    expect(r.out, contains('not on an image pull: not retrying'));
    expect(r.githubEnv, '');
  });

  test('criterion 4: the registry that started the stack is exported for the later steps', () async {
    final r = await _run({
      'public.ecr.aws': ['datalimit'],
      'ghcr.io': ['datalimit'],
      'docker.io': ['ok'],
    });
    expect(r.exitCode, 0, reason: r.out);
    expect(r.githubEnv, 'SUPABASE_INTERNAL_IMAGE_REGISTRY=docker.io\n');
  });

  test('criterion 4: with no GITHUB_ENV, as on a laptop, nothing is written and nothing fails', () async {
    final r = await _run({
      'public.ecr.aws': ['ok'],
    }, withGithubEnv: false);
    expect(r.exitCode, 0, reason: r.out);
    expect(r.calls, ['public.ecr.aws start']);
    expect(r.err, isEmpty);
  });

  test('criterion 5: every registry refusing fails and names each one tried', () async {
    final r = await _run({
      'public.ecr.aws': ['datalimit'],
      'ghcr.io': ['datalimit'],
      'docker.io': ['datalimit'],
    });
    expect(r.exitCode, 1, reason: r.out);
    expect(r.calls, [
      'public.ecr.aws start', 'public.ecr.aws stop',
      'ghcr.io start', 'ghcr.io stop',
      'docker.io start', 'docker.io stop',
    ]);
    expect(r.out,
        contains('every registry failed to pull an image (public.ecr.aws ghcr.io docker.io)'));
    expect(r.githubEnv, '');
  });

  test('a registry named in the environment goes first, and the rest follow in order', () async {
    final r = await _run({
      'ghcr.io': ['datalimit'],
      'public.ecr.aws': ['ok'],
    }, firstRegistry: 'ghcr.io');
    expect(r.exitCode, 0, reason: r.out);
    expect(r.calls, ['ghcr.io start', 'ghcr.io stop', 'public.ecr.aws start']);
    expect(r.githubEnv, 'SUPABASE_INTERNAL_IMAGE_REGISTRY=public.ecr.aws\n');
  });

  // #113, PR #188: run 42956155985's database could not bind 54422 on a fresh runner, and the
  // runner was gone before what held the port could be asked. The start still fails at once; it
  // names the port and probes it first. Criterion 3's case above, whose call list holds no probe,
  // is the control: a failure that names no port is not probed.
  test('a host port already bound is probed by number, and the start still stops at once', () async {
    final r = await _run({
      'public.ecr.aws': ['portbusy'],
      'ghcr.io': ['ok'],
    });
    expect(r.exitCode, 1, reason: r.out);
    expect(r.calls, ['public.ecr.aws start', 'probe 54422']);
    expect(r.out, contains('host port 54422 was already bound'));
    expect(r.out, contains('held by the stand-in'));
    expect(r.out, contains('not on an image pull: not retrying'));
    expect(r.githubEnv, '');
  });

  test("a port another container holds, in Docker's other wording, is probed too", () async {
    final r = await _run({
      'public.ecr.aws': ['allocated'],
    });
    expect(r.exitCode, 1, reason: r.out);
    expect(r.calls, ['public.ecr.aws start', 'probe 54421']);
  });

  // The real probe, scripts/probe_port.sh, on ports this test holds. It runs only when a start has
  // already failed, about one CI run in forty, so a probe that printed nothing useful would spend
  // the one chance to see the holder. These prove on Linux (CI's flutter job) that it names a
  // listener and an outgoing connection, the two holders it exists to tell apart.
  group('scripts/probe_port.sh', () {
    Future<String> probe(int port) async {
      final result = await Process.run('sh', ['scripts/probe_port.sh', '$port']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      return result.stdout as String;
    }

    test('names a listener on the port', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final out = await probe(server.port);
      expect(out, matches(RegExp(r'ephemeral range \d+\s+\d+')));
      expect(out, contains(':${server.port}'));
      expect(out, anyOf(contains('LISTEN'), contains(' 0A ')));
    }, skip: Platform.isLinux ? false : 'reads Linux sockets');

    test("names an outgoing connection whose local end is the port", () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final accepted = server.first;
      final client = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      addTearDown(client.destroy);
      addTearDown(() async => (await accepted).destroy());
      final out = await probe(client.port);
      expect(out, contains(':${client.port}'));
      expect(out, anyOf(contains('ESTAB'), contains(' 01 ')));
      expect(out, isNot(contains('LISTEN')));
    }, skip: Platform.isLinux ? false : 'reads Linux sockets');
  });
}
