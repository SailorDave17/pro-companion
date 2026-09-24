import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';

import 'support/fake_confirmation.dart';

/// #4 criterion 5 at the service: confirmation follows a committed append,
/// never precedes one, and never outlives a failed one.
void main() {
  late FakeConfirmationDevice device;
  late ConfirmationService service;

  setUp(() {
    device = FakeConfirmationDevice();
    service = ConfirmationService(device);
  });

  test('a successful append fires exactly one vibration and one tone, after it completes', () async {
    var committed = false;
    final result = await service.confirm(() async {
      expect(device.vibrations, 0, reason: 'nothing fires before the core confirms');
      committed = true;
      return 'stored';
    });
    await Future<void>.delayed(Duration.zero);
    expect(committed, isTrue);
    expect(result, 'stored');
    expect(device.vibrations, 1);
    expect(device.tones, [BeepStream.notification]);
  });

  test('a failed append fires none and rethrows', () async {
    await expectLater(service.confirm<void>(() async => throw StateError('refused')), throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(device.vibrations, 0);
    expect(device.tones, isEmpty);
  });

  test('the tone follows the notification volume by default (owner decision 2026-09-24)', () {
    expect(ConfirmationService(device).beepStream, BeepStream.notification);
  });

  test('a buzzer that throws does not fail the confirmed append', () async {
    device.vibrateThrows = StateError('no vibrator');
    expect(await service.confirm(() async => 42), 42);
    await Future<void>.delayed(Duration.zero);
    expect(device.tones, [BeepStream.notification]);
  });
}
