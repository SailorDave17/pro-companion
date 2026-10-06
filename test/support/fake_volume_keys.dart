import 'dart:async';

import 'package:pro_companion/finish/volume_key.dart';

/// The phone's volume-down key, in place of MainActivity's handler (#19).
class FakeVolumeKeyCapture implements VolumeKeyCapture {
  FakeVolumeKeyCapture({this.canArm = true});

  /// What [arm] answers: false stands for a phone that cannot take the key.
  final bool canArm;

  /// Whether the key is taken now.
  bool armed = false;
  final _presses = StreamController<void>.broadcast();

  @override
  Future<bool> arm() async => armed = canArm;

  @override
  Future<void> disarm() async => armed = false;

  @override
  Stream<void> get presses => _presses.stream;

  /// A press as MainActivity reports one: only while armed, since disarmed the
  /// key goes to the system. True when it was reported.
  bool press() {
    if (armed) _presses.add(null);
    return armed;
  }
}
