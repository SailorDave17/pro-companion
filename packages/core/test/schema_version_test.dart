import 'dart:isolate';

import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #24 criterion 6: an event written by a newer version of the app - a newer
/// payload schema, or envelope fields this core does not know - is kept whole,
/// not dropped and not trimmed.
void main() {
  // Assertions compare against this literal, never against a value built by
  // the code under test: fromWire dropping a field would drop it from both
  // sides of the comparison, and the test would pass (measured - mutation M5).
  final raw = <String, Object?>{
    'ulid': '01J1FUTURE0000000000000000',
    'device_ts': 1727190000000,
    'device_id': '01J1NEWERPHONE000000000000',
    'seq': 1,
    'person': null,
    'role': 'recorder',
    'admission_id': '7d2e9b40-1c5a-4f83-a6d0-2b9e8c4f1a57',
    'gps': null,
    'source': 'tap',
    'kind': 'finish',
    'payload_version': 99,
    'corrects_ulid': null,
    'prev_hash': null,
    'payload': {
      'sail': '12345',
      'photo_hash': 'sha256:abc',
      'nested': {'a': [1, 2, 3]},
    },
    'envelope_field_from_v9': {'signed_by': 'club-key-2'},
  };
  final fromTheFuture = EventEnvelope.fromWire(raw);

  test('a newer payload version and unknown fields are preserved by the store', () {
    final path = tempDbPath();
    final store = EventStore.open(path);
    store.insert(fromTheFuture);
    store.append(const NewEvent(kind: 'note', source: 'tap'));
    store.close();

    final all = openStore(path).readAll();
    expect(all, hasLength(2), reason: 'the newer event is not dropped');
    final back = all.singleWhere((e) => e.ulid == fromTheFuture.ulid);
    expect(back.payloadVersion, 99);
    expect(back.payload, raw['payload']);
    expect(back.extra, {'envelope_field_from_v9': {'signed_by': 'club-key-2'}});
    expect(back.toWire(), raw);
  });

  test('it crosses the core interface whole', () async {
    final store = openStore(tempDbPath());
    store.insert(fromTheFuture);
    final reply = ReceivePort();
    CoreServer(store).handle([reply.sendPort, 'readAll', <String, Object?>{}]);
    final r = await reply.first as List;
    expect(r.first, 'ok');
    final wire = (r[1] as List).single as Map;
    expect(wire, raw);
  });
}
