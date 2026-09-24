import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which Android volume the confirmation beep follows. A user setting from
/// #86; until then the default below (owner decision 2026-09-24, #4).
enum BeepStream { notification, alarm, media }

/// The phone's buzzer and speaker, behind an interface so tests can count
/// what fired.
abstract interface class ConfirmationDevice {
  Future<void> vibrate();
  Future<void> tone(BeepStream stream);
}

/// The real buzzer and speaker, through MainActivity's `pro_companion/confirm`
/// channel.
class PlatformConfirmationDevice implements ConfirmationDevice {
  const PlatformConfirmationDevice();

  static const _channel = MethodChannel('pro_companion/confirm');

  @override
  Future<void> vibrate() => _channel.invokeMethod<void>('vibrate');

  @override
  Future<void> tone(BeepStream stream) => _channel.invokeMethod<void>('tone', {'stream': stream.name});
}

/// Confirms an action by feel and by sound, so a PRO with wet hands in glare
/// never has to look down: one vibration and one tone, only once the core
/// has committed the event.
class ConfirmationService {
  ConfirmationService(this._device, {this.beepStream = BeepStream.notification});

  final ConfirmationDevice _device;
  final BeepStream beepStream;

  /// Runs [append]. When it completes, fires one vibration and one tone and
  /// returns its result; when it fails, fires nothing and rethrows.
  Future<T> confirm<T>(Future<T> Function() append) async {
    final result = await append();
    // A buzzer that fails must not turn a logged finish into an error: the
    // event is committed, and that is what the screen shows.
    unawaited(_quietly(_device.vibrate));
    unawaited(_quietly(() => _device.tone(beepStream)));
    return result;
  }

  static Future<void> _quietly(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      debugPrint('confirmation failed: $e');
    }
  }
}
