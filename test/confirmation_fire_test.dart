import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';

import 'support/fake_confirmation.dart';

/// #33 criterion 8 at the service: the core host works out for itself that a
/// race-timer event was committed, so it fires rather than confirms.
void main() {
  late FakeConfirmationDevice device;
  late ConfirmationService service;

  setUp(() {
    device = FakeConfirmationDevice();
    service = ConfirmationService(device);
  });

  test('fire() fires one vibration and one tone, on the beep stream the service was given', () async {
    service.fire();
    await Future<void>.delayed(Duration.zero);
    expect(device.vibrations, 1);
    expect(device.tones, [BeepStream.notification]);

    ConfirmationService(device, beepStream: BeepStream.alarm).fire();
    await Future<void>.delayed(Duration.zero);
    expect(device.vibrations, 2);
    expect(device.tones, [BeepStream.notification, BeepStream.alarm]);
  });

  test('a failing buzzer does not throw, and the tone still fires', () async {
    device.vibrateThrows = StateError('no vibrator');
    expect(service.fire, returnsNormally);
    await Future<void>.delayed(Duration.zero);
    expect(device.vibrations, 1);
    expect(device.tones, [BeepStream.notification]);
  });
}
