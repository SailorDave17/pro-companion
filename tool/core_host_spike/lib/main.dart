// print is this spike's output channel: the Doze run and the report read it from logcat.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:core_host_spike_sync/sync.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Name the core publishes its SendPort under, process-wide.
const corePortName = 'pro_companion.core';

/// Prefix of an intent payload carrying a sync command (#47): `sync:` then the command's JSON,
/// base64url-encoded so it survives `adb shell` quoting.
const syncPrefix = 'sync:';

/// Prefix of a payload carrying a race-timer link event (#15), handed in by the
/// Kotlin link endpoints once the caller is trusted: `link:` then
/// `{"mech", "recv_ns", "handed_ns", "event"}`.
const linkPrefix = 'link:';

/// The core's side of the #15 link spike: one `LINK` line per event that reaches
/// it, with the run's count of distinct event ids, so a lost log line cannot hide
/// a delivery and a duplicate cannot pass as one.
class LinkLog {
  LinkLog(this._write);

  final void Function(String line) _write;
  final _seen = <String>{};
  final _perRun = <String, int>{};

  void receive(String json) {
    final forwarded = jsonDecode(json) as Map<String, Object?>;
    final event = forwarded['event']! as Map<String, Object?>;
    final id = event['id']! as String;
    final run = '${event['x_run'] ?? '-'}';
    final dup = !_seen.add(id);
    final count = dup ? (_perRun[run] ?? 0) : (_perRun[run] = (_perRun[run] ?? 0) + 1);
    // race-timer's own timestamp against the core's clock: the same wall clock, read in
    // two processes, so this is end to end at millisecond resolution.
    final atMs = event['at_ms'] as int?;
    final e2e = atMs == null ? '-' : '${DateTime.now().millisecondsSinceEpoch - atMs}';
    _write('LINK run=$run mech=${forwarded['mech']} n=${event['x_n']} id=$id '
        'kind=${event['kind']} count=$count dup=$dup e2e_ms=$e2e');
  }
}

/// The headless core (#14). Started by CoreService in its own FlutterEngine, with
/// no widget tree. It writes a TICK line every 10 s, writes every forwarded intent,
/// and answers the UI over an isolate port. Since #47 it also hosts the sync client,
/// driven by `sync:` intents (see [SyncCommands]), and since #15 it logs race-timer
/// link events (see [LinkLog]).
@pragma('vm:entry-point')
Future<void> coreMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('core_host/intents');
  late final File log;
  File? mirror;
  late final SyncCommands sync;

  void write(String line) {
    final stamped = '${DateTime.now().toUtc().toIso8601String()} $line';
    log.writeAsStringSync('$stamped\n', mode: FileMode.append, flush: true);
    mirror?.writeAsStringSync('$stamped\n', mode: FileMode.append, flush: true);
    print('CORE $stamped');
  }

  final link = LinkLog(write);

  channel.setMethodCallHandler((call) async {
    if (call.method != 'intent') return;
    final payload = '${call.arguments}';
    if (payload.startsWith(syncPrefix)) {
      sync.enqueue(payload.substring(syncPrefix.length));
    } else if (payload.startsWith(linkPrefix)) {
      link.receive(payload.substring(linkPrefix.length));
    } else {
      write('INTENT $payload');
    }
  });
  // #21: a copy of every line where adb can read it on a retail phone. logcat cannot
  // carry a 30-minute run there: the club phone caps the main buffer at 5 MiB, about
  // 20 minutes of the whole phone's logging. Asked before 'ready', whose reply releases
  // the queued intents, so the mirror misses none of them.
  final mirrorDir = await channel.invokeMethod<String>('mirrorDir');
  if (mirrorDir != null) mirror = File('$mirrorDir/core_tick.log');
  final dir = await channel.invokeMethod<String>('ready');
  log = File('$dir/core_tick.log');
  sync = SyncCommands(dir!, write);
  write('START pid=$pid');
  // Not awaited: a refresh on an unreachable network must not hold up the port or the ticks.
  unawaited(sync.resume());

  final inbox = ReceivePort();
  IsolateNameServer.removePortNameMapping(corePortName);
  IsolateNameServer.registerPortWithName(inbox.sendPort, corePortName);
  inbox.listen((message) {
    // Messages between engines cross isolate GROUPS, which carry only primitive
    // types (null, num, bool, String, List, Map, SendPort, typed data). A Dart
    // record or object is refused at send time, so the protocol is [replyPort, payload].
    final parts = message as List<Object?>;
    (parts[0]! as SendPort).send(parts[1]);
  });

  var n = 0;
  Timer.periodic(const Duration(seconds: 10), (_) => write('TICK ${++n}'));
}

void main() => runApp(const MaterialApp(home: SpikeHome()));

class SpikeHome extends StatefulWidget {
  const SpikeHome({super.key});

  @override
  State<SpikeHome> createState() => _SpikeHomeState();
}

class _SpikeHomeState extends State<SpikeHome> {
  static const _ui = MethodChannel('core_host/ui');
  String _status = 'Core not started';

  Future<void> _start() async {
    await _ui.invokeMethod('startCore');
    setState(() => _status = 'Core starting');
  }

  /// UI -> core round trips over the isolate port (the ADR 003 question).
  Future<void> _ping() async {
    final core = IsolateNameServer.lookupPortByName(corePortName);
    if (core == null) {
      setState(() => _status = 'Core port not found');
      return;
    }
    final reply = ReceivePort();
    final replies = StreamIterator(reply);
    final samples = <int>[];
    for (var i = 0; i < 1000; i++) {
      final sw = Stopwatch()..start();
      core.send([reply.sendPort, i]);
      await replies.moveNext();
      sw.stop();
      if (replies.current != i) throw StateError('reply $i out of order');
      samples.add(sw.elapsedMicroseconds);
    }
    reply.close();
    samples.sort();
    final summary = 'PING n=1000 p50=${samples[499]}us p95=${samples[949]}us max=${samples.last}us';
    print(summary);
    setState(() => _status = summary);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(_status, key: const Key('status')),
              const SizedBox(height: 16),
              FilledButton(onPressed: _start, child: const Text('Start core')),
              FilledButton(onPressed: _ping, child: const Text('Ping core')),
              FilledButton(
                  onPressed: () => SystemNavigator.pop(), child: const Text('Close UI (destroy activity)')),
            ]),
          ),
        ),
      );
}
