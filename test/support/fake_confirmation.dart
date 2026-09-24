import 'package:pro_companion/confirmation.dart';

/// Counts what the confirmation service fired, in place of the phone's
/// buzzer and speaker.
class FakeConfirmationDevice implements ConfirmationDevice {
  int vibrations = 0;
  final tones = <BeepStream>[];

  /// When set, the buzzer throws - to prove a broken buzzer does not break a
  /// logged finish.
  Object? vibrateThrows;

  @override
  Future<void> vibrate() async {
    vibrations++;
    final error = vibrateThrows;
    if (error != null) throw error;
  }

  @override
  Future<void> tone(BeepStream stream) async => tones.add(stream);
}
