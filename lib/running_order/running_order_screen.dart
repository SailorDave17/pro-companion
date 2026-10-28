import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../shore/shore_status.dart';
import '../stations/station_screen.dart';
import '../ui/bars.dart';
import '../ui/clock.dart';
import '../ui/sunlight.dart';

/// The running order (#68): each fleet's boats in the order they are round
/// the course, from every committee phone's roundings that sync has pulled
/// down (#64), so the committee follows the race live. Opened from the PRO's,
/// the recorder's and the mark boat's homes (owner decision at pickup).
///
/// It reads [CoreClient.readAll] on purpose: it is built to show the
/// committee's view, as the committee log is (#67). It reads again every
/// [every], so roundings that arrive while it is open move the order
/// (criterion 2). It writes nothing.
///
/// A mark a phone is stationed at whose roundings have not arrived is named
/// as waiting, so the order is never read as current at a mark it has not
/// heard from (criterion 4).
class RunningOrderScreen extends StatefulWidget {
  const RunningOrderScreen({
    super.key,
    required this.core,
    this.clock = systemClock,
    this.every = const Duration(seconds: 5),
  });

  final CoreClient core;

  /// The phone's clock: the race is the one its date and guns say.
  final int Function() clock;

  /// How often the log is read again.
  final Duration every;

  @override
  State<RunningOrderScreen> createState() => _RunningOrderScreenState();
}

class _RunningOrderScreenState extends State<RunningOrderScreen> {
  List<EventEnvelope>? _events;
  bool _unreadable = false;
  Timer? _timer;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    _read();
    _timer = Timer.periodic(widget.every, (_) => _read());
  }

  Future<void> _read() async {
    if (_reading) return;
    _reading = true;
    try {
      final events = await widget.core.readAll();
      if (mounted) {
        setState(() {
          _events = events;
          _unreadable = false;
        });
      }
    } catch (_) {
      // A read that fails after one that worked leaves what it showed.
      if (mounted && _events == null) setState(() => _unreadable = true);
    } finally {
      _reading = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final events = _events;
    final theme = Theme.of(context).textTheme;
    final orders = events == null ? const <FleetRunningOrder>[] : runningOrders(events, now: widget.clock());
    final names = events == null ? const <String, String>{} : {for (final f in fleets(events)) f.id: f.name};
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        leadingWidth: 80,
        actions: [ShoreIndicator(core: widget.core)],
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
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text('Running order', style: theme.titleLarge),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Bars.screenGutterDp),
          children: [
            if (_unreadable) const _Note('The log on this phone could not be read', danger: true),
            if (events == null && !_unreadable) const Text('Reading the log…'),
            for (final o in orders)
              _FleetOrder(
                key: ValueKey('running-${o.fleet ?? 'none'}'),
                order: o,
                // A day of one fleet needs no heading; roundings that name no
                // fleet on a day of several do.
                title: o.fleet == null ? (names.isEmpty ? null : 'No fleet named') : names[o.fleet] ?? 'Fleet',
              ),
          ],
        ),
      ),
    );
  }
}

class _FleetOrder extends StatelessWidget {
  const _FleetOrder({super.key, required this.order, required this.title});

  final FleetRunningOrder order;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title case final String t)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              // A node of its own: left to merge, the heading took in every
              // note and line under it (the semantics tree, #68's audit).
              child: Semantics(header: true, container: true, child: Text(t, style: theme.titleLarge)),
            ),
          // Above the order it qualifies, and short: at 200% text a sentence
          // per mark filled the first screen and hid the order (emulator).
          if (order.waiting.isNotEmpty)
            _Note('Waiting for ${order.waiting.map(markName).join(', ')}', key: const ValueKey('waiting')),
          if (order.entries.isEmpty) Text('No roundings yet', style: theme.bodyLarge),
          for (var i = 0; i < order.entries.length; i++) _EntryRow(place: i + 1, entry: order.entries[i]),
          // Below the rows: it qualifies places, not whether the order is current.
          if (order.clocksUnmatched)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: _Note("Level at a gate: in each phone's own clock order"),
            ),
          if (order.unnamed > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Semantics(
                container: true,
                child: Text(
                  '${order.unnamed} ${order.unnamed == 1 ? 'rounding' : 'roundings'} not yet named',
                  style: theme.bodyLarge,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.place, required this.entry});

  final int place;
  final RunningEntry entry;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme.bodyLarge;
    final mark = entry.mark == null ? 'a mark' : markName(entry.mark!);
    final time = clockText(entry.last.deviceTs);
    final rounded = '${entry.roundings} ${entry.roundings == 1 ? 'mark' : 'marks'}';
    // Each row its own screen-reader node, as the results rows are (#7): left
    // to merge, a fleet's rows read as one with its heading.
    return Semantics(
      key: ValueKey('running-entry-${entry.sail}'),
      container: true,
      label: '$place, sail ${entry.sail}, last rounded $mark at $time, $rounded rounded',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            SizedBox(width: 48, child: _OneLine('$place', style: text?.copyWith(fontWeight: FontWeight.w700))),
            SizedBox(width: 96, child: _OneLine(entry.sail, style: text?.copyWith(fontWeight: FontWeight.w700))),
            // At 200% a four-digit number fills its column and ran into the
            // mark ("1033Gate left") on the emulator.
            const SizedBox(width: 8),
            Expanded(child: _OneLine('$mark · $time', style: text)),
          ],
        ),
      ),
    );
  }
}

/// [text] on one line, shrunk to fit its width rather than wrapped.
class _OneLine extends StatelessWidget {
  const _OneLine(this.text, {this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(text, maxLines: 1, softWrap: false, style: style),
      );
}

/// A line the committee must not miss: a mark still waiting, clocks not
/// matched, or a log that could not be read.
class _Note extends StatelessWidget {
  const _Note(this.text, {super.key, this.danger = false});

  final String text;
  final bool danger;

  @override
  // Its own node, so it is not read as part of the heading above it.
  Widget build(BuildContext context) => Semantics(
        container: true,
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          color: danger ? SunlightTokens.danger : SunlightTokens.surface,
          child: Text(
            text,
            style: TextStyle(
              color: danger ? SunlightTokens.onDanger : SunlightTokens.text,
              // No smaller than the rows it qualifies (bodyLarge, 22): a note
              // drawn smaller read as less important on #67's render.
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
}
