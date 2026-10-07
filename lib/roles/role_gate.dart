import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../finish/volume_key.dart';
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
class RoleGate extends StatefulWidget {
  const RoleGate({
    super.key,
    required this.core,
    required this.confirmation,
    this.clock = systemClock,
    this.volumeKeys = const NoVolumeKeyCapture(),
  });

  final CoreClient core;
  final ConfirmationService confirmation;
  final int Function() clock;
  final VolumeKeyCapture volumeKeys;

  @override
  State<RoleGate> createState() => _RoleGateState();
}

class _RoleGateState extends State<RoleGate> {
  final _roleEvents = <EventEnvelope>[];
  String? _deviceId;
  bool _unreadable = false;
  bool _notLogged = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Future.wait([widget.core.readAll(), widget.core.deviceId()]).then((r) {
      if (!mounted) return;
      setState(() {
        _roleEvents.addAll((r[0] as List<EventEnvelope>).where((e) => RoleKinds.all.contains(e.kind)));
        _deviceId = r[1] as String;
      });
    }, onError: (Object _) {
      if (mounted) setState(() => _unreadable = true);
    });
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
    );
  }
}

/// The role picker (#20 criterion 1): one tap on a role logs the pick and
/// opens that role's home.
class RolePicker extends StatelessWidget {
  const RolePicker({super.key, required this.onPick, this.problem});

  final ValueChanged<String> onPick;

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
              ],
            ),
          ],
        ),
      ),
    );
  }
}
