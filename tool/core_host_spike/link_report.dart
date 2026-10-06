// #15: reads a link_run.sh log (logcat, tags LINK and flutter) and reports each run:
// what the harness emitted and was told, what the companion's endpoint received, and
// what reached the headless core, with latencies.
//   dart tool/core_host_spike/link_report.dart build/link_run_<stamp>.log
// ignore_for_file: avoid_print
import 'dart:io';

final _field = RegExp(r'(\w+)=(\S+)');

Map<String, String> _fields(String line, String marker) {
  final i = line.indexOf(marker);
  return {for (final m in _field.allMatches(line.substring(i + marker.length))) m[1]!: m[2]!};
}

String _pct(List<num> xs) {
  if (xs.isEmpty) return '-';
  final s = [...xs]..sort();
  num at(double p) => s[((p * s.length).ceil() - 1).clamp(0, s.length - 1)];
  return 'p50 ${at(0.5)}, p95 ${at(0.95)}, max ${s.last}';
}

class Run {
  Run(this.id);
  final String id;
  String mech = '?';
  Map<String, String> begin = {}, done = {};
  final emitted = <String, Map<String, String>>{};
  final received = <String, Map<String, String>>{};
  final core = <String, Map<String, String>>{};
  int coreDuplicates = 0;
}

void main(List<String> args) {
  final runs = <String, Run>{};
  Run run(String id) => runs.putIfAbsent(id, () => Run(id));
  var rejects = 0;
  for (final line in File(args.single).readAsLinesSync()) {
    if (line.contains('BEGIN run=')) {
      final f = _fields(line, 'BEGIN');
      run(f['run']!)
        ..begin = f
        ..mech = f['mech']!;
    } else if (line.contains('DONE run=')) {
      final f = _fields(line, 'DONE');
      run(f['run']!).done = f;
    } else if (line.contains('EMIT run=')) {
      final f = _fields(line, 'EMIT');
      run(f['run']!).emitted[f['id']!] = f;
    } else if (line.contains('RECV run=')) {
      final f = _fields(line, 'RECV');
      run(f['run']!).received[f['id']!] = f;
    } else if (line.contains(' LINK run=')) {
      final f = _fields(line, ' LINK');
      final r = run(f['run']!);
      if (f['dup'] == 'true' || r.core.containsKey(f['id'])) {
        r.coreDuplicates++;
      } else {
        r.core[f['id']!] = f;
      }
    } else if (line.contains('REJECT mech=')) {
      rejects++;
    }
  }

  for (final r in runs.values) {
    final statuses = <String, int>{};
    for (final e in r.emitted.values) {
      statuses.update(e['status']!, (n) => n + 1, ifAbsent: () => 1);
    }
    final idle = r.emitted.values.where((e) => e['idle'] == 'true').length;
    final missing = r.emitted.keys.where((id) => !r.core.containsKey(id)).toList();
    final maxCount = r.core.values.map((c) => int.parse(c['count']!)).fold(0, (a, b) => a > b ? a : b);
    print('${r.id}  (${r.mech}, interval ${r.begin['interval_ms']} ms, sdk ${r.begin['sdk']})');
    print('  emitted ${r.emitted.length} of ${r.begin['count']}, device idle at $idle of them; '
        'harness told: ${statuses.entries.map((e) => '${e.key} ${e.value}').join(', ')}');
    print('  endpoint received ${r.received.length}; core stored ${r.core.length} distinct '
        '(its own count reached $maxCount), ${r.coreDuplicates} duplicates');
    print('  DELIVERED ${r.core.length}/${r.emitted.length}'
        '${missing.isEmpty ? '' : '  missing: ${missing.map((id) => 'n=${r.emitted[id]!['n']}').join(' ')}'}');
    print('  send call (harness) us: ${_pct([for (final e in r.emitted.values) int.parse(e['send_us']!)])}');
    print('  emit -> endpoint us:    ${_pct([for (final e in r.received.values) int.parse(e['hop_us']!)])}');
    print('  emit -> core ms:        ${_pct([
          for (final c in r.core.values)
            if (c['e2e_ms'] != '-') int.parse(c['e2e_ms']!)
        ])}');
    print('  done: ${r.done.isEmpty ? 'NO DONE LINE' : r.done.entries.map((e) => '${e.key}=${e.value}').join(' ')}');
  }
  print('refusals logged: $rejects');
}
