import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import 'confirmation.dart';
import 'core_bootstrap.dart';
import 'finish/finish_screen.dart';
import 'fleets/fleets_screen.dart';
import 'results/results_screen.dart';
import 'sequence/sequence_screen.dart';
import 'ui/bars.dart';
import 'ui/clock.dart';
import 'ui/sunlight.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ProCompanionApp(
    core: await startCore(),
    confirmation: ConfirmationService(const PlatformConfirmationDevice()),
  ));
}

class ProCompanionApp extends StatelessWidget {
  const ProCompanionApp({
    super.key,
    required this.core,
    required this.confirmation,
    this.navigatorObservers = const [],
    this.clock = systemClock,
  });

  /// The only way UI code reaches the log (ADR 001, ADR 003).
  final CoreClient core;

  /// The buzz and beep every logged race-time action gets.
  final ConfirmationService confirmation;
  final List<NavigatorObserver> navigatorObservers;

  /// The phone's clock, which a gun's typed time is held to (#25).
  final int Function() clock;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PRO Companion',
      theme: sunlightTheme(),
      navigatorObservers: navigatorObservers,
      home: HomeScreen(core: core, confirmation: confirmation, clock: clock),
    );
  }
}

/// The app's home. Stands in for the PRO's role home until #20 adds role
/// homes; the sequence, finish and results screens are one tap from here.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.core, required this.confirmation, this.clock = systemClock});

  final CoreClient core;
  final ConfirmationService confirmation;
  final int Function() clock;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<int> _count = widget.core.count();

  Future<void> _open(Widget Function() screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen()));
    if (mounted) {
      setState(() {
        _count = widget.core.count();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Home has nothing to type into. Back from FLEETS the keyboard is still
      // up while home lays out, and on a 320 x 640 phone the three buttons did
      // not fit in what it left (#25, PR #94's emulator job).
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Bars.screenGutterDp),
          child: Column(
            children: [
              const Spacer(),
              // One line each, shrunk to fit: wrapped at 200% text, these took
              // the room the three buttons need on a short phone (#25).
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('PRO Companion', style: Theme.of(context).textTheme.titleLarge),
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
              const Spacer(),
              // Naming the day's fleets is set-up, done before racing (#18).
              SizedBox(
                width: double.infinity,
                height: Bars.minTargetDp + 8,
                child: OutlinedButton(
                  onPressed: () => _open(() => FleetsScreen(core: widget.core, confirmation: widget.confirmation)),
                  child: const Text('FLEETS'),
                ),
              ),
              const SizedBox(height: 16),
              // The start, then the finishes: the order a race runs in (#25).
              SizedBox(
                width: double.infinity,
                height: 96,
                child: ElevatedButton(
                  onPressed: () => _open(() => SequenceScreen(
                        core: widget.core,
                        confirmation: widget.confirmation,
                        clock: widget.clock,
                      )),
                  child: const Text('SEQUENCE'),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 96,
                child: ElevatedButton(
                  onPressed: () => _open(() => FinishScreen(core: widget.core, confirmation: widget.confirmation)),
                  child: const Text('FINISHES'),
                ),
              ),
              const SizedBox(height: 16),
              // Provisional results come after the finishes (#7).
              SizedBox(
                width: double.infinity,
                height: Bars.minTargetDp + 8,
                child: OutlinedButton(
                  onPressed: () => _open(() => ResultsScreen(core: widget.core, confirmation: widget.confirmation)),
                  child: const Text('RESULTS'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
