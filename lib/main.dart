import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import 'confirmation.dart';
import 'core_bootstrap.dart';
import 'finish/volume_key.dart';
import 'revocation/revoked_banner.dart';
import 'roles/race_area.dart';
import 'roles/role_gate.dart';
import 'signin/sign_in_link.dart';
import 'ui/clock.dart';
import 'ui/sunlight.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The core runs in the foreground service, which also tells it where the
  // phone is (#31), so it keeps logging with the UI gone (ADR 003, #32).
  final core = await startCore();
  runApp(ProCompanionApp(
    core: core,
    confirmation: ConfirmationService(const PlatformConfirmationDevice()),
    volumeKeys: PlatformVolumeKeyCapture(),
    signInLinks: PlatformSignInLinks(),
  ));
}

class ProCompanionApp extends StatelessWidget {
  const ProCompanionApp({
    super.key,
    required this.core,
    required this.confirmation,
    this.navigatorObservers = const [],
    this.clock = systemClock,
    this.volumeKeys = const NoVolumeKeyCapture(),
    this.signInLinks = const NoSignInLinks(),
  });

  /// The only way UI code reaches the log (ADR 001, ADR 003).
  final CoreClient core;

  /// The buzz and beep every logged race-time action gets.
  final ConfirmationService confirmation;
  final List<NavigatorObserver> navigatorObservers;

  /// The phone's clock, which a gun's typed time is held to (#25).
  final int Function() clock;

  /// The volume-down key, which logs a finish on the finish screen (#19).
  final VolumeKeyCapture volumeKeys;

  /// The magic links that open the app, for the sign-in screen (#104).
  final SignInLinks signInLinks;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PRO Companion',
      theme: sunlightTheme(),
      navigatorObservers: navigatorObservers,
      // The revoked banner, above every screen once the phone's admission is revoked (#53).
      // And the race area every header names (#74), which the role home sets.
      builder: (context, navigator) =>
          RaceAreaFrame(child: RevokedFrame(core: core, child: navigator ?? const SizedBox.shrink())),
      // The role picker, or the home of the role this phone runs as (#20).
      home: RoleGate(
          core: core, confirmation: confirmation, clock: clock, volumeKeys: volumeKeys, signInLinks: signInLinks),
    );
  }
}
