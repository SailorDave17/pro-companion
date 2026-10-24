import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/core_host.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

/// #32: what the core host does with an append CoreService hands it from an intent. The device half,
/// an intent sent once the activity is destroyed, is CoreHostTest (android/app/src/androidTest), run
/// by integration_test/core_host.sh.
void main() {
  MethodCall append(Object? argument) => MethodCall('append', argument);
  String event(Map<String, Object?> payload) =>
      jsonEncode(NewEvent(kind: 'probe.intent', source: 'test', payload: payload).toWire());

  test("an intent's event is appended, and the stored event comes back as JSON", () async {
    final core = FakeCore();
    final reply = await handleHostCall(core, append(event({'n': 1})));
    final stored = jsonDecode(reply as String) as Map<String, Object?>;
    expect(stored['kind'], 'probe.intent');
    expect(stored['payload'], {'n': 1});
    expect(stored['seq'], 1);
    expect(stored['ulid'], (await core.readAll()).single.ulid, reason: 'the reply is the event as stored');
  });

  test('an argument that is not an event is refused as malformed, and nothing is appended', () async {
    final core = FakeCore();
    for (final bad in <Object?>[null, 'not json', '[1, 2]', jsonEncode({'kind': 'probe.intent'})]) {
      await expectLater(handleHostCall(core, append(bad)),
          throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'malformed')),
          reason: '$bad');
    }
    expect(await core.count(), 0);
  });

  test("a refusal by the core comes back with the core's own code", () async {
    final core = FakeCore()..failWith = const CoreException('refused', 'the store said no');
    await expectLater(handleHostCall(core, append(event({}))),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'refused')));
  });

  test('the host answers no method but append', () async {
    await expectLater(handleHostCall(FakeCore(), const MethodCall('delete', null)),
        throwsA(isA<MissingPluginException>()));
  });
}
