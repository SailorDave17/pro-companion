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
  *) echo "no scripted outcome for $reg start $n"; exit 3 ;;
esac
''';

typedef _Run = ({int exitCode, String out, String err, List<String> calls, String githubEnv});

Future<_Run> _run(Map<String, List<String>> outcomes,
    {String firstRegistry = '', bool withGithubEnv = true}) async {
  final dir = Directory.systemTemp.createTempSync('start_stack_');
  addTearDown(() => dir.deleteSync(recursive: true));
  final p = dir.path.replaceAll(r'\', '/');
  File('$p/fake_supabase.sh').writeAsStringSync(_fakeCli);
  outcomes.forEach((registry, lines) => File('$p/$registry').writeAsStringSync('${lines.join('\n')}\n'));
  final githubEnv = File('$p/github_env')..writeAsStringSync('');
  final result = await Process.run('sh', ['scripts/start_local_stack.sh'], environment: {
    'SUPABASE_CLI': 'sh $p/fake_supabase.sh',
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
}
