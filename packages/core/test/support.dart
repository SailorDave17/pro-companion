import 'dart:io';
import 'dart:math';

import 'package:pro_companion_core/store.dart';
import 'package:test/test.dart';

/// A fresh log in its own temp directory, closed and removed after the test.
String tempDbPath() {
  final dir = Directory.systemTemp.createTempSync('pc_core_');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold the WAL file briefly after close; not the test's concern.
    }
  });
  return '${dir.path}${Platform.pathSeparator}core.db';
}

EventStore openStore(String path, {int Function()? clock, int seed = 1}) {
  final store = EventStore.open(path, clock: clock, random: Random(seed));
  addTearDown(() {
    try {
      store.close();
    } catch (_) {
      // Already closed by the test.
    }
  });
  return store;
}

/// A clock that returns [times] in turn, then keeps returning the last one.
int Function() steppingClock(List<int> times) {
  var i = 0;
  return () => times[i < times.length ? i++ : times.length - 1];
}
