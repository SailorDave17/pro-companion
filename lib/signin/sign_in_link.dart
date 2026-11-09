import 'dart:async';

import 'package:flutter/services.dart';

/// The addresses a magic link opens the app with (#104), behind an interface
/// so tests can open one.
///
/// The server's verify step sends the browser to `signInRedirect` with a
/// one-time code, and Android hands that address to MainActivity: as the
/// intent that started it when the app was not running, or as a new intent
/// when it was. The role gate reads both and gives the sign-in screen any
/// that are its own.
abstract interface class SignInLinks {
  /// The address that started the app, once: null after the first read, and
  /// when the app was started any other way.
  Future<String?> takeInitial();

  /// Addresses that open the app while it runs.
  Stream<String> get incoming;
}

/// No links: what a test gets unless it asks for some.
class NoSignInLinks implements SignInLinks {
  const NoSignInLinks();

  @override
  Future<String?> takeInitial() async => null;

  @override
  Stream<String> get incoming => const Stream.empty();
}

/// The real links, through MainActivity's `pro_companion/sign_in_link`
/// channel: `initialLink` answers the address that started the app and
/// forgets it, and each later one arrives as `link`.
///
/// [incoming] is single-subscription and is listened to once, by the role
/// gate: a link that arrives before the gate listens is kept until it does
/// (#104's review), since the handler is set while `runApp` starts and the
/// gate subscribes only once it is built.
class PlatformSignInLinks implements SignInLinks {
  PlatformSignInLinks() {
    _channel.setMethodCallHandler((call) async {
      final uri = call.arguments;
      if (call.method == 'link' && uri is String) _incoming.add(uri);
    });
  }

  static const _channel = MethodChannel('pro_companion/sign_in_link');
  final _incoming = StreamController<String>();

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Future<String?> takeInitial() async {
    try {
      return await _channel.invokeMethod<String>('initialLink');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
