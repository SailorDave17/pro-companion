import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import 'confirmation.dart';
import 'core_bootstrap.dart';
import 'finish/finish_screen.dart';
import 'ui/bars.dart';
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
  });

  /// The only way UI code reaches the log (ADR 001, ADR 003).
  final CoreClient core;

  /// The buzz and beep every logged race-time action gets.
  final ConfirmationService confirmation;
  final List<NavigatorObserver> navigatorObservers;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PRO Companion',
      theme: sunlightTheme(),
      navigatorObservers: navigatorObservers,
      home: HomeScreen(core: core, confirmation: confirmation),
    );
  }
}

/// The app's home. Stands in for the PRO's role home until #20 adds role
/// homes; the finish screen is one tap from here.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.core, required this.confirmation});

  final CoreClient core;
  final ConfirmationService confirmation;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<int> _count = widget.core.count();

  Future<void> _openFinishes() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FinishScreen(core: widget.core, confirmation: widget.confirmation),
    ));
    if (mounted) {
      setState(() {
        _count = widget.core.count();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Bars.screenGutterDp),
          child: Column(
            children: [
              const Spacer(),
              Text('PRO Companion', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              FutureBuilder<int>(
                future: _count,
                builder: (context, snapshot) {
                  if (snapshot.hasError) return const Text('The log on this phone could not be read');
                  final n = snapshot.data;
                  if (n == null) return const Text('Reading the log…');
                  return Text('$n ${n == 1 ? 'event' : 'events'} on this phone');
                },
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 96,
                child: ElevatedButton(onPressed: _openFinishes, child: const Text('FINISHES')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
