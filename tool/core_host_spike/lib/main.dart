// print is this spike's output channel: the Doze run and the report read it from logcat.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Name the core publishes its SendPort under, process-wide.
const corePortName = 'pro_companion.core';

/// The headless core (#14). Started by CoreService in its own FlutterEngine, with
/// no widget tree. It writes a TICK line every 10 s, writes every forwarded intent,
/// and answers the UI over an isolate port.
@pragma('vm:entry-point')
Future<void> coreMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('core_host/intents');
  late final File log;

  void write(String line) {
    final stamped = '${DateTime.now().toUtc().toIso8601String()} $line';
    log.writeAsStringSync('$stamped\n', mode: FileMode.append, flush: true);
    print('CORE $stamped');
  }

  channel.setMethodCallHandler((call) async {
    if (call.method == 'intent') write('INTENT ${call.arguments}');
  });
  final dir = await channel.invokeMethod<String>('ready');
  log = File('$dir/core_tick.log');
  write('START');

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
