import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../finish/finish_screen.dart';
import '../finish/volume_key.dart';
import '../fleets/fleets_screen.dart';
import '../results/results_screen.dart';
import '../sequence/sequence_screen.dart';
import '../ui/bars.dart';
import '../ui/clock.dart';
import '../ui/fill_or_scroll.dart';
import '../ui/fit_label.dart';
import '../ui/sunlight.dart';
import 'roles.dart';

/// A role's home (#20): the role's name, UNDO ROLE, and the screens that
/// role's job needs, each one tap away ([homeActions]).
class RoleHome extends StatefulWidget {
  const RoleHome({
    super.key,
    required this.role,
    required this.core,
    required this.confirmation,
    required this.onUndo,
    this.notLogged = false,
    this.clock = systemClock,
    this.volumeKeys = const NoVolumeKeyCapture(),
  });

  final String role;
  final CoreClient core;
  final ConfirmationService confirmation;

  /// Takes the role pick back, which returns the phone to the picker.
  final VoidCallback onUndo;

  /// True when the last UNDO ROLE did not log.
  final bool notLogged;
  final int Function() clock;
  final VolumeKeyCapture volumeKeys;

  @override
  State<RoleHome> createState() => _RoleHomeState();
}

class _RoleHomeState extends State<RoleHome> {
  late Future<int> _count = widget.core.count();

  Future<void> _open(Widget Function() screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen()));
    if (mounted) {
      setState(() {
        _count = widget.core.count();
      });
    }
  }

  Widget _button(HomeAction action) => switch (action) {
        // Naming the day's fleets is set-up, done before racing (#18).
        HomeAction.fleets => _outlined('FLEETS', () => FleetsScreen(core: widget.core, confirmation: widget.confirmation)),
        // The start, then the finishes: the order a race runs in (#25).
        HomeAction.sequence => _big('SEQUENCE', () => SequenceScreen(
              core: widget.core,
              confirmation: widget.confirmation,
              clock: widget.clock,
            )),
        HomeAction.finishes => _big('FINISHES', () => FinishScreen(
              core: widget.core,
              confirmation: widget.confirmation,
              volumeKeys: widget.volumeKeys,
            )),
        // Provisional results come after the finishes (#7).
        HomeAction.results =>
          _outlined('RESULTS', () => ResultsScreen(core: widget.core, confirmation: widget.confirmation)),
      };

  Widget _big(String label, Widget Function() screen) => SizedBox(
        width: double.infinity,
        height: 96,
        child: ElevatedButton(onPressed: () => _open(screen), child: Text(label)),
      );

  Widget _outlined(String label, Widget Function() screen) => SizedBox(
        width: double.infinity,
        height: Bars.minTargetDp + 8,
        child: OutlinedButton(onPressed: () => _open(screen), child: Text(label)),
      );

  @override
  Widget build(BuildContext context) {
    final actions = homeActions(widget.role);
    return Scaffold(
      // A home has nothing to type into. Back from FLEETS the keyboard is
      // still up while it lays out, and on a 320 x 640 phone the buttons did
      // not fit in what it left (#25, PR #94's emulator job).
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: FillOrScroll(
          children: [
            const SizedBox.shrink(),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // One line each, shrunk to fit: wrapped at 200% text, these
                // took the room the buttons need on a short phone (#25).
                Semantics(
                  header: true,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(roleName(widget.role), style: Theme.of(context).textTheme.headlineMedium),
                  ),
                ),
                const SizedBox(height: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: FutureBuilder<int>(
                    future: _count,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) return const Text('The log on this phone could not be read');
                      final n = snapshot.data;
                      if (n == null) return const Text('Reading the log…');
                      return Text('$n ${n == 1 ? 'event' : 'events'} on this phone');
                    },
                  ),
                ),
                const SizedBox(height: 16),
                // Away from the thumb's path to the role's own buttons below,
                // and undone at once, with no confirm dialog (#20 criterion 6).
                SizedBox(
                  width: double.infinity,
                  height: Bars.minTargetDp + 8,
                  child: OutlinedButton(
                    key: const ValueKey('undo-role'),
                    onPressed: widget.onUndo,
                    child: const FitLabel('UNDO ROLE'),
                  ),
                ),
                if (widget.notLogged)
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      width: double.infinity,
                      color: SunlightTokens.danger,
                      padding: const EdgeInsets.all(16),
                      margin: const EdgeInsets.only(top: 12),
                      child: const Text('Not logged. Tap again.',
                          style: TextStyle(color: SunlightTokens.onDanger, fontSize: 22, fontWeight: FontWeight.w700)),
                    ),
                  ),
              ],
            ),
            if (actions.isEmpty) ...[
              Text('No actions for this role yet.',
                  textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox.shrink(),
            ] else
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(height: 16),
                    _button(actions[i]),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}
