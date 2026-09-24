// print is this harness's output channel: crash_test.sh reads it from logcat.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'envelope.dart';
import 'stores.dart';

/// The #13 crash harness for the chosen engine (sqlite3). On every launch it
/// first reports what the previous run left in the store, then appends events
/// until it is killed, printing `ACK <seq>` after each append returns.
/// tool/store_bench/crash_test.sh force-stops it mid-append and compares the
/// last ACK printed with what the next launch finds.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('store_bench crash writer')))));

  final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'crash'));
  await dir.create(recursive: true);
  final store = SqliteStore();
  await store.open(dir.path);

  final stored = await store.all();
  var seq = 0;
  var hash = '0' * 64;
  var contiguous = true;
  var chainIntact = true;
  for (final e in stored) {
    if (e.seq != seq + 1) contiguous = false;
    if (e.prevHash != hash) chainIntact = false;
    seq = e.seq;
    hash = e.hash;
  }
  print('STORED count=${stored.length} maxseq=$seq contiguous=$contiguous chain=$chainIntact');

  final random = Random();
  while (true) {
    final next = seq + 1;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final id = ulid(ts, random);
    final payload = <String, Object?>{'fleet': 'F1', 'sail': '${10000 + random.nextInt(89999)}'};
    final h = chainHash(
      prevHash: hash,
      ulid: id,
      seq: next,
      deviceId: 'dev-crash',
      person: 'volunteer',
      kind: 'finish',
      deviceTs: ts,
      lat: 42.35,
      lon: -83.05,
      payload: payload,
    );
    await store.append(Envelope(
      ulid: id,
      seq: next,
      deviceId: 'dev-crash',
      person: 'volunteer',
      kind: 'finish',
      deviceTs: ts,
      lat: 42.35,
      lon: -83.05,
      prevHash: hash,
      hash: h,
      payload: payload,
    ));
    print('ACK $next');
    seq = next;
    hash = h;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
