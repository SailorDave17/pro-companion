import 'dart:isolate';
import 'dart:math';

import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

import 'support.dart';

/// #24 criterion 3: a stored event cannot be updated or deleted by any code
/// path. The engine refuses, so these statements go straight at the database
/// connection, the way a careless future code path would.
void main() {
  late EventStore store;
  late EventEnvelope stored;
  late String bodyBefore;

  String bodyOf(String ulid) => store.debugDatabase
      .select('SELECT body FROM events WHERE ulid = ?', [ulid]).single['body'] as String;

  setUp(() {
    store = openStore(tempDbPath());
    stored = store.append(const NewEvent(kind: 'finish', source: 'tap', payload: {'sail': '7'}));
    bodyBefore = bodyOf(stored.ulid);
  });

  void expectRefusedAndUnchanged(String statement, [List<Object?> params = const []]) {
    expect(() => store.debugDatabase.execute(statement, params),
        throwsA(isA<sql.SqliteException>()), reason: statement);
    expect(store.count(), 1, reason: 'nothing removed by: $statement');
    expect(bodyOf(stored.ulid), bodyBefore, reason: 'nothing altered by: $statement');
  }

  test('UPDATE is refused', () {
    expectRefusedAndUnchanged("UPDATE events SET body = '{}' WHERE ulid = ?", [stored.ulid]);
  });

  test('DELETE is refused', () {
    expectRefusedAndUnchanged('DELETE FROM events WHERE ulid = ?', [stored.ulid]);
  });

  test('INSERT OR REPLACE over an existing event is refused', () {
    expectRefusedAndUnchanged(
      'INSERT OR REPLACE INTO events (ulid, device_id, seq, device_ts, body) VALUES (?, ?, ?, ?, ?)',
      [stored.ulid, stored.deviceId, stored.seq, stored.deviceTs, '{}'],
    );
  });

  test('REPLACE by the (device, sequence) key is refused too', () {
    expectRefusedAndUnchanged(
      'INSERT OR REPLACE INTO events (ulid, device_id, seq, device_ts, body) VALUES (?, ?, ?, ?, ?)',
      [newUlid(1, _Zero()), stored.deviceId, stored.seq, stored.deviceTs, '{}'],
    );
  });

  test('an upsert that would update is refused', () {
    expectRefusedAndUnchanged(
      'INSERT INTO events (ulid, device_id, seq, device_ts, body) VALUES (?, ?, ?, ?, ?) '
      "ON CONFLICT (ulid) DO UPDATE SET body = '{}'",
      [stored.ulid, stored.deviceId, stored.seq, stored.deviceTs, '{}'],
    );
  });

  test('the core serves no update or delete command', () async {
    final reply = ReceivePort();
    final server = CoreServer(store);
    for (final command in ['update', 'delete', 'replace']) {
      server.handle([reply.sendPort, command, {'ulid': stored.ulid}]);
    }
    final replies = await reply.take(3).toList();
    reply.close();
    for (final r in replies) {
      expect((r as List).first, 'err');
      expect(r[1], 'unknown_command');
    }
    expect(store.count(), 1);
    expect(bodyOf(stored.ulid), bodyBefore);
  });
}

class _Zero implements Random {
  @override
  int nextInt(int max) => 0;
  @override
  double nextDouble() => 0;
  @override
  bool nextBool() => false;
}
