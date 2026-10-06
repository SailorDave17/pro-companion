import 'dart:async';

import 'package:flutter/services.dart';

/// The hardware volume-down key as a finish (#19), behind an interface so
/// tests can press it.
///
/// The finish screen arms it while it is the screen showing. Armed, the phone
/// keeps volume-down from the system and reports one [presses] event per
/// distinct press: a held key's repeats are one press, and the volume never
/// changes, so another app's media session keeps its volume too. Volume-up
/// always behaves normally (owner decision, 2026-10-06). Nothing is armed with
/// the screen off (groom decision G4).
abstract interface class VolumeKeyCapture {
  /// Starts taking volume-down. True when this phone can, which is what the
  /// screen shows.
  Future<bool> arm();

  /// Gives volume-down back to the system.
  Future<void> disarm();

  /// One event per distinct volume-down press while armed.
  Stream<void> get presses;
}

/// No volume key: [arm] answers false, so the screen shows no volume key.
/// What a test gets unless it asks for one.
class NoVolumeKeyCapture implements VolumeKeyCapture {
  const NoVolumeKeyCapture();

  @override
  Future<bool> arm() async => false;

  @override
  Future<void> disarm() async {}

  @override
  Stream<void> get presses => const Stream.empty();
}

/// The real key, through MainActivity's `pro_companion/volume_key` channel.
class PlatformVolumeKeyCapture implements VolumeKeyCapture {
  PlatformVolumeKeyCapture() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'press') _presses.add(null);
    });
  }

  static const _channel = MethodChannel('pro_companion/volume_key');
  final _presses = StreamController<void>.broadcast();

  @override
  Stream<void> get presses => _presses.stream;

  // A phone that cannot take the key is told apart from one that can, so the
  // screen never shows a key that does nothing.
  @override
  Future<bool> arm() async {
    try {
      return await _channel.invokeMethod<bool>('arm') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> disarm() async {
    try {
      await _channel.invokeMethod<void>('disarm');
    } on MissingPluginException {
      // Nothing was armed.
    } on PlatformException {
      // Nothing more can be done about it here.
    }
  }
}
