import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../finish/volume_key.dart';
import '../join/join_screen.dart';
import '../signin/sign_in_link.dart';
import '../signin/sign_in_screen.dart';
import '../ui/bars.dart';
import '../ui/clock.dart';
import '../ui/fill_or_scroll.dart';
import '../ui/fit_label.dart';
import '../ui/sunlight.dart';
import 'role_home.dart';
import 'roles.dart';

/// Where the app opens (#20): the role picker on a phone with no role, and
/// that role's home on one that has one. The role is read from this phone's
/// own picks in the log, so a restart opens where the phone left off.
///
/// A pick and its undo are each one event, confirmed by one buzz and one tone
/// once committed, with no confirm dialog: a wrong pick is undone, not
/// guarded against.
///
/// From the picker, JOIN WITH CODE opens the join screen (#71): a phone
/// admitted there comes back with the pick of the role its code granted,
/// and that role's home opens. #77 later narrows the picker to that role.
///
/// SIGN IN BY EMAIL opens the sign-in screen (#104), which hands back the same
/// pick once the volunteer's account is admitted. The gate also reads the
/// magic links that open the app, for as long as it lives, which is the app's
/// whole life: one that opens it while the sign-in screen shows goes to that
/// screen, and any other opens the screen on it, as after the app was killed
/// on the way to the mail app.
class RoleGate extends StatefulWidget {
  const RoleGate({
    super.key,
    required this.core,
    required this.confirmation,
    this.clock = systemClock,
    this.volumeKeys = const NoVolumeKeyCapture(),
    this.signInLinks = const NoSignInLinks(),
  });

  final CoreClient core;
  final ConfirmationService confirmation;
  final int Function() clock;
  final VolumeKeyCapture volumeKeys;

  /// The magic links that open the app (#104).
  final SignInLinks signInLinks;

  @override
  State<RoleGate> createState() => _RoleGateState();
}

class _RoleGateState extends State<RoleGate> {
  final _roleEvents = <EventEnvelope>[];
  String? _deviceId;
  bool _unreadable = false;
  bool _notLogged = false;
  bool _busy = false;

  /// The sign-in links for the sign-in screen while it shows (#104): one
  /// controller per screen, single-subscription, so a link that arrives
  /// between the push and the screen's first listen is kept for it rather
  /// than dropped (#104's review). Null while no sign-in screen shows.
  StreamController<SignInLink>? _screenLinks;
  StreamSubscription<String>? _incoming;

  /// A link that arrived before the gate had read whether this phone runs a
  /// role, routed once the read answers.
  SignInLink? _early;

  @override
  void initState() {
    super.initState();
    Future.wait([widget.core.readOwn(), widget.core.deviceId()]).then((r) {
      if (!mounted) return;
      setState(() {
        _roleEvents.addAll((r[0] as List<EventEnvelope>).where((e) => RoleKinds.all.contains(e.kind)));
        _deviceId = r[1] as String;
      });
      _routeEarly();
    }, onError: (Object _) {
      if (!mounted) return;
      setState(() => _unreadable = true);
      _routeEarly();
    });
    _incoming = widget.signInLinks.incoming.listen(_onLink);
    widget.signInLinks.takeInitial().then((uri) {
      if (uri != null) _onLink(uri);
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    _incoming?.cancel();
    _screenLinks?.close();
    super.dispose();
  }

  /// A link that opened the app. An address that is not a sign-in is ignored.
  void _onLink(String uri) {
    final link = SignInLink.parse(uri);
    if (link != null && mounted) _route(link);
  }

  /// The sign-in screen's link, if it shows. Otherwise it opens the screen,
  /// but only on the picker: a link never covers a role's home or a screen
  /// opened over the picker, the race-time screens and the join screen
  /// among them (#104's review), and there it is let go. One that arrives
  /// before the gate knows which it shows waits for that read.
  void _route(SignInLink link) {
    final screen = _screenLinks;
    if (screen != null) {
      screen.add(link);
      return;
    }
    final deviceId = _deviceId;
    if (deviceId == null && !_unreadable) {
      _early = link;
      return;
    }
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    final runsARole = deviceId != null && currentRole(_roleEvents, deviceId) != null;
    if (onTop && !runsARole) _signIn(opening: link);
  }

  void _routeEarly() {
    final early = _early;
    _early = null;
    if (early != null) _route(early);
  }

  /// SIGN IN BY EMAIL (#104), or a link that opened the app: the sign-in
  /// screen hands back the role pick the join screen logged, as [_join] gets.
  Future<void> _signIn({SignInLink? opening}) async {
    if (_screenLinks != null) return;
    final links = _screenLinks = StreamController<SignInLink>();
    final Object? result;
    try {
      result = await Navigator.of(context).push<Object?>(MaterialPageRoute(
        builder: (_) => SignInScreen(
          core: widget.core,
          confirmation: widget.confirmation,
          links: links.stream,
          opening: opening,
        ),
      ));
    } finally {
      _screenLinks = null;
      // Not awaited: a single-subscription controller's close completes only
      // once a listener has seen the done event, which may never come.
      unawaited(links.close());
    }
    _picked(result);
  }

  /// Appends [event] and, once the core confirms it, moves to what it means.
  /// A failed append says "Not logged" where it was tapped and fires nothing.
  Future<void> _log(NewEvent event) async {
    if (_busy) return; // A second tap while the first is in flight is the same tap.
    _busy = true;
    try {
      final stored = await widget.confirmation.confirm(() => widget.core.append(event));
      if (!mounted) return;
      setState(() {
        _roleEvents.add(stored);
        // A log that could not be read still took this pick, and the pick is
        // this phone's latest whatever the log held before it.
        _deviceId ??= stored.deviceId;
        _unreadable = false;
        _notLogged = false;
      });
    } catch (_) {
      if (mounted) setState(() => _notLogged = true);
    } finally {
      _busy = false;
    }
  }

  /// JOIN WITH CODE (#71): the join screen logs the granted role's pick itself
  /// and hands it back, so this phone's home opens on it.
  Future<void> _join() async {
    final result = await Navigator.of(context).push<Object?>(MaterialPageRoute(
      builder: (_) => JoinScreen(core: widget.core, confirmation: widget.confirmation),
    ));
    _picked(result);
  }

  /// A role pick a set-up screen logged and handed back opens that role's home.
  void _picked(Object? result) {
    if (!mounted || result is! EventEnvelope) return;
    setState(() {
      _roleEvents.add(result);
      _deviceId ??= result.deviceId;
      _unreadable = false;
      _notLogged = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final deviceId = _deviceId;
    final pick = deviceId == null ? null : currentRolePick(_roleEvents, deviceId);
    final role = deviceId == null ? null : currentRole(_roleEvents, deviceId);
    if (pick != null && role != null) {
      return RoleHome(
        // A new pick is a new home, which reads the log afresh.
        key: ValueKey(pick.ulid),
        role: role,
        core: widget.core,
        confirmation: widget.confirmation,
        clock: widget.clock,
        volumeKeys: widget.volumeKeys,
        notLogged: _notLogged,
        onUndo: () => _log(RoleEvents.undo(pick.ulid)),
      );
    }
    if (deviceId == null && !_unreadable) {
      return const Scaffold(body: Center(child: Text('Reading the log…')));
    }
    return RolePicker(
      problem: _unreadable
          ? 'The log on this phone could not be read'
          : _notLogged
              ? 'Not logged. Tap again.'
              : null,
      onPick: (role) => _log(RoleEvents.assign(role)),
      onJoin: _join,
      onSignIn: _signIn,
    );
  }
}

/// The role picker (#20 criterion 1): one tap on a role logs the pick and
/// opens that role's home. Below the roles, JOIN WITH CODE (#71) opens the
/// join screen for a phone handed a role's admission code, and SIGN IN BY
/// EMAIL (#104) the sign-in screen for a named volunteer.
class RolePicker extends StatelessWidget {
  const RolePicker({super.key, required this.onPick, required this.onJoin, required this.onSignIn, this.problem});

  final ValueChanged<String> onPick;
  final VoidCallback onJoin;
  final VoidCallback onSignIn;

  /// Shown above the roles: a pick that did not log, or a log that could not
  /// be read.
  final String? problem;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Nothing here is typed. UNDO ROLE can bring a phone here with the
      // keyboard from FLEETS still up, the race #25 met on home.
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: FillOrScroll(
          children: [
            const SizedBox.shrink(),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // One line each, shrunk to fit at 200% text.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('PRO Companion', style: Theme.of(context).textTheme.titleLarge),
                ),
                const SizedBox(height: 8),
                Semantics(
                  header: true,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('Pick your role', style: Theme.of(context).textTheme.headlineMedium),
                  ),
                ),
              ],
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (problem != null)
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      width: double.infinity,
                      color: SunlightTokens.danger,
                      padding: const EdgeInsets.all(16),
                      margin: const EdgeInsets.only(bottom: 16),
                      child: Text(problem!,
                          style: const TextStyle(
                              color: SunlightTokens.onDanger, fontSize: 22, fontWeight: FontWeight.w700)),
                    ),
                  ),
                for (var i = 0; i < pickableRoles.length; i++) ...[
                  if (i > 0) const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 88,
                    child: ElevatedButton(
                      key: ValueKey('pick-${pickableRoles[i]}'),
                      onPressed: () => onPick(pickableRoles[i]),
                      child: FitLabel(roleName(pickableRoles[i]).toUpperCase()),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                // Set-up, apart from the picks: a phone handed a code (#71).
                SizedBox(
                  width: double.infinity,
                  height: Bars.minTargetDp + 8,
                  child: OutlinedButton(
                    key: const ValueKey('join-with-code'),
                    onPressed: onJoin,
                    child: const FitLabel('JOIN WITH CODE'),
                  ),
                ),
                const SizedBox(height: 16),
                // A named volunteer signs in first (#104), then joins with the code.
                SizedBox(
                  width: double.infinity,
                  height: Bars.minTargetDp + 8,
                  child: OutlinedButton(
                    key: const ValueKey('sign-in-by-email'),
                    onPressed: onSignIn,
                    child: const FitLabel('SIGN IN BY EMAIL'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
