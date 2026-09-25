import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../ui/bars.dart';
import '../ui/sunlight.dart';

/// Naming the day's fleets (#18 criterion 1): a name, and a class if the PRO
/// wants one. Each fleet is a `fleet.defined` event. The first fleet a phone
/// defines is also selected, so the next finish already carries a fleet.
///
/// This is set-up, done before racing, so it is not a race-time route. It is
/// still held to the bar, because it is reachable from the role home.
class FleetsScreen extends StatefulWidget {
  const FleetsScreen({super.key, required this.core, required this.confirmation});

  final CoreClient core;
  final ConfirmationService confirmation;

  @override
  State<FleetsScreen> createState() => _FleetsScreenState();
}

class _FleetsScreenState extends State<FleetsScreen> {
  final _events = <EventEnvelope>[];
  final _name = TextEditingController();
  final _klass = TextEditingController();
  String? _deviceId;
  String? _problem;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() => _problem = null));
    Future.wait([widget.core.readAll(), widget.core.deviceId()]).then((r) {
      if (!mounted) return;
      setState(() {
        _events.addAll((r[0] as List<EventEnvelope>).where((e) => FleetKinds.all.contains(e.kind)));
        _deviceId = r[1] as String;
        _loaded = true;
      });
    }, onError: (Object _) {
      if (mounted) setState(() => _problem = 'The log on this phone could not be read');
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _klass.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    if (fleets(_events).any((f) => f.name.toLowerCase() == name.toLowerCase())) {
      setState(() => _problem = '$name is already a fleet');
      return;
    }
    final firstForThisPhone = _deviceId != null && selectedFleet(_events, _deviceId!) == null;
    try {
      final added = await widget.confirmation.confirm(() async {
        final defined = await widget.core.append(FleetEvents.define(name, klass: _klass.text));
        return [
          defined,
          if (firstForThisPhone) await widget.core.append(FleetEvents.select(defined.ulid)),
        ];
      });
      if (!mounted) return;
      setState(() {
        _events.addAll(added);
        _name.clear();
        _klass.clear();
        _problem = null;
      });
    } catch (_) {
      // The definition may have committed and the selection not; show what
      // the log actually holds rather than what this screen assumed.
      List<EventEnvelope>? events;
      try {
        events = await widget.core.readAll();
      } catch (_) {
        events = null; // Keep what is shown; the message still says it failed.
      }
      if (!mounted) return;
      setState(() {
        if (events != null) {
          _events
            ..clear()
            ..addAll(events.where((e) => FleetKinds.all.contains(e.kind)));
        }
        _problem = 'Not saved. Tap again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = fleets(_events);
    final current = _deviceId == null ? null : selectedFleet(_events, _deviceId!);
    final text = Theme.of(context).textTheme.bodyLarge;

    InputDecoration field(String label) => InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
        );

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        leadingWidth: 80,
        leading: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: IconButton(
            tooltip: 'Back',
            iconSize: 32,
            style: IconButton.styleFrom(minimumSize: const Size.square(Bars.minTargetDp)),
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        title: Text('Fleets', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Bars.screenGutterDp),
          children: [
            if (!_loaded && _problem == null) const Text('Reading the log…'),
            if (_loaded && all.isEmpty) Text('No fleets yet. Name the first one below.', style: text),
            for (final f in all)
              Container(
                key: ValueKey('fleet-${f.id}'),
                constraints: const BoxConstraints(minHeight: Bars.minTargetDp),
                alignment: Alignment.centerLeft,
                child: Text(
                  [f.name, if (f.klass != null) f.klass!, if (f.id == current) 'finishing now'].join(' · '),
                  style: text?.copyWith(fontWeight: f.id == current ? FontWeight.w700 : null),
                ),
              ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('fleet-name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(fontSize: 22),
              decoration: field('Fleet name'),
              onSubmitted: (_) => _add(),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('fleet-class'),
              controller: _klass,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(fontSize: 22),
              decoration: field('Class (optional)'),
              onSubmitted: (_) => _add(),
            ),
            const SizedBox(height: 12),
            if (_problem != null)
              Semantics(
                liveRegion: true,
                child: Container(
                  width: double.infinity,
                  color: SunlightTokens.danger,
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Text(_problem!,
                      style: const TextStyle(color: SunlightTokens.onDanger, fontSize: 22, fontWeight: FontWeight.w700)),
                ),
              ),
            SizedBox(
              width: double.infinity,
              height: Bars.minTargetDp + 8,
              child: FilledButton(
                key: const ValueKey('fleet-add'),
                onPressed: _loaded && _name.text.trim().isNotEmpty ? _add : null,
                child: const FittedBox(fit: BoxFit.scaleDown, child: Text('ADD FLEET', maxLines: 1)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
