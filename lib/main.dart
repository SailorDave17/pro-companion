import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import 'core_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ProCompanionApp(core: await startCore()));
}

class ProCompanionApp extends StatelessWidget {
  const ProCompanionApp({super.key, required this.core});

  /// The only way UI code reaches the log (ADR 001, ADR 003).
  final CoreClient core;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PRO Companion',
      home: HomeScreen(core: core),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.core});

  final CoreClient core;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final Future<int> _count = widget.core.count();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('PRO Companion'),
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
          ],
        ),
      ),
    );
  }
}
