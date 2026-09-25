// Writes the committed chain vectors in fixtures/chain/ (#28).
//
//   dart run tool/write_chain_vectors.dart      (from packages/core)
//
// Each vector is a device's day as the store appends it, then one change a
// tamperer or a slow sync could make. The expected verdict beside each one is
// written here by hand from docs/event-chain.md, never produced by running the
// verifier: a vector made by the code it checks would pass that code by
// construction. Re-running this rewrites the files. Review the diff, check the
// hashes with a second SHA-256, and update fixtures/chain/SHA256SUMS in the
// same commit.

import 'dart:convert';
import 'dart:io';

import 'package:pro_companion_core/store.dart';

const format = 'pro-companion-chain-vector/1';
const outDir = '../../fixtures/chain';

const deviceA = '01J8Z0D0000000000000000001';
const deviceB = '01J8Z0D0000000000000000002';
const dayStart = 1727190000000;

/// A fixed, valid ULID for event [n].
String ulid(int n) => '01J8Z0E${n.toString().padLeft(19, '0')}';

EventEnvelope event(int n, String device, int seq, String kind, String source, Map<String, Object?> payload,
        {String? role, GpsFix? gps, String? corrects}) =>
    EventEnvelope(
      ulid: ulid(n),
      deviceTs: dayStart + n * 1000,
      deviceId: device,
      seq: seq,
      role: role,
      gps: gps,
      source: source,
      kind: kind,
      payloadVersion: 1,
      correctsUlid: corrects,
      payload: payload,
    );

/// Device A, the overall PRO: a fleet, its start, a finish with a GPS fix
/// whose accuracy is a whole number, its sail number, a note in UTF-8, and
/// the gun time corrected by hand.
final dayA = [
  event(1, deviceA, 1, 'fleet.defined', 'tap', {'name': 'Lasers', 'class': 'ILCA 7'}, role: 'overall_pro'),
  event(2, deviceA, 2, 'start', 'race-timer', {'fleet': ulid(1)}, role: 'overall_pro'),
  event(3, deviceA, 3, 'finish', 'tap', {'fleet': ulid(1)},
      role: 'overall_pro', gps: const GpsFix(lat: 33.4012, lon: -86.8123, accuracyM: 5.0)),
  event(4, deviceA, 4, 'finish.sail', 'tap', {'finish': ulid(3), 'sail': '12345'}, role: 'overall_pro'),
  event(5, deviceA, 5, 'note', 'tap', {'text': 'Mark 2 — hold; wind 10° right'}, role: 'overall_pro'),
  event(6, deviceA, 6, 'start.time_corrected', 'manual', {'time': dayStart + 65000},
      role: 'overall_pro', corrects: ulid(2)),
];

/// Device B, a mark boat handed a new phone: its own chain, from genesis.
final dayB = [
  event(11, deviceB, 1, 'finish', 'tap', {'fleet': ulid(1)},
      role: 'mark_boat', gps: const GpsFix(lat: 33.4105, lon: -86.8201, accuracyM: 3.5)),
  event(12, deviceB, 2, 'finish.sail', 'tap', {'finish': ulid(11), 'sail': '4471'}, role: 'mark_boat'),
];

EventEnvelope withPrev(EventEnvelope e, String prev) => EventEnvelope.fromWire({...e.toWire(), 'prev_hash': prev});

/// [events] chained in order from [first], as the store writes them.
List<String> chain(List<EventEnvelope> events, {String first = genesisHash}) {
  final texts = <String>[];
  var prev = first;
  for (final e in events) {
    final text = canonicalJson(withPrev(e, prev).toWire());
    texts.add(text);
    prev = chainHash(text);
  }
  return texts;
}

void write(String name, String description, List<String> texts, Map<String, Map<String, Object?>> expected) {
  final vector = {
    'format': format,
    'name': name,
    'description': description,
    'events': [
      for (final text in texts) {'hash': chainHash(text), 'canonical': text}
    ],
    'expected': expected,
  };
  File('$outDir/$name.json').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(vector)}\n');
}

Map<String, Object?> broken(int atSeq, String atUlid, {int? afterSeq}) =>
    {'verdict': 'broken', 'at_seq': atSeq, 'at_ulid': atUlid, 'after_seq': ?afterSeq};

void main() {
  Directory(outDir).createSync(recursive: true);
  final a = chain(dayA);

  write('intact', "Device A's whole day, seq 1 to 6, every link as written.", a, {
    deviceA: {'verdict': 'intact'},
  });

  write('gapped-middle', 'Seq 3 and 4 have not arrived yet. Seq 5 still links to seq 4, which this '
      'verifier has not seen, so the gap cannot be checked and is not tampering.', [a[0], a[1], a[4], a[5]], {
    deviceA: {'verdict': 'gapped'},
  });

  write('gapped-start', 'A far mark catching up: seq 1 to 3 have not arrived, and seq 4 links to a '
      'seq 3 not yet seen.', [a[3], a[4], a[5]], {
    deviceA: {'verdict': 'gapped'},
  });

  final altered = a[3].replaceFirst('"sail":"12345"', '"sail":"12346"');
  if (altered == a[3]) throw StateError('the sail number to alter was not found');
  write('broken-payload', "One byte of seq 4's payload was altered (sail 12345 became 12346) after "
      "seq 5 linked to it. Seq 5's link no longer holds, so the chain breaks at seq 5, after seq 4: "
      'either one could be the altered event.', [a[0], a[1], a[2], altered, a[4], a[5]], {
    deviceA: broken(5, ulid(5), afterSeq: 4),
  });

  final relinked = [a[0], a[1], ...chain(dayA.sublist(3), first: chainHash(a[1]))];
  write('broken-relinked', 'Seq 3 was removed and seq 4 re-linked to seq 2, with seq 5 and 6 re-linked '
      'after it. Seq 4 links straight across the missing number, which a genuine chain never does.',
      relinked, {
    deviceA: broken(4, ulid(4), afterSeq: 2),
  });

  write('broken-relinked-start', 'Seq 1 and 2 were removed and seq 3 re-linked to genesis, with the rest '
      're-linked after it. Only a first event starts from genesis.', chain(dayA.sublist(2)), {
    deviceA: broken(3, ulid(3)),
  });

  write('broken-first-link', "Seq 1's previous hash is not the genesis value; the rest link to it "
      'correctly.', chain(dayA, first: 'f' * 64), {
    deviceA: broken(1, ulid(1)),
  });

  final forkNote = withPrev(event(7, deviceA, 3, 'note', 'tap', {'text': 'Restored from a backup'},
      role: 'overall_pro'), chainHash(a[1]));
  write('broken-fork', 'Two events hold seq 3, both linking to seq 2, as when a phone restored from a '
      'backup appends again. Verifiers read equal numbers in ULID order and name the later ULID.',
      [a[0], a[1], a[2], canonicalJson(forkNote.toWire())], {
    deviceA: broken(3, ulid(7)),
  });

  write('handoff', "Device A's first three events and device B's two: a phone handed over mid-race is a "
      'new device with its own chain, from genesis. Each device is verified on its own.',
      [...a.sublist(0, 3), ...chain(dayB)], {
    deviceA: {'verdict': 'intact'},
    deviceB: {'verdict': 'intact'},
  });
}
