import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../ui/bars.dart';
import '../ui/sunlight.dart';

/// Provisional results (#7): every fleet's standings, scored on this phone
/// from its own log by the #2 engine, so the water knows the podium with no
/// signal. Nothing here reaches the network: the scoring is the core's
/// [provisionalResults], and the only write is the discard count, appended
/// to the phone's log like any other event.
///
/// Opened from the role home after racing, so it is not a race-time route. It
/// is still held to the bar, because it is reachable from the role home.
class ResultsScreen extends StatefulWidget {
  const ResultsScreen({super.key, required this.core, required this.confirmation});

  final CoreClient core;
  final ConfirmationService confirmation;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  final _events = <EventEnvelope>[];
  bool _loaded = false;
  String? _problem;

  /// A discard count on its way to the log.
  bool _saving = false;

  /// The fleet whose discard count failed to save, shown beside its stepper.
  ({String? fleet})? _notSaved;

  @override
  void initState() {
    super.initState();
    widget.core.readAll().then(
      (events) {
        if (!mounted) return;
        setState(() {
          _events.addAll(events);
          _loaded = true;
        });
      },
      onError: (Object _) {
        if (mounted) setState(() => _problem = 'The log on this phone could not be read');
      },
    );
  }

  Future<void> _setDiscards(String? fleet, int count) async {
    // One change at a time. A second tap before the first is logged would be
    // worked out from the count the first replaces, and confirmed twice for
    // one step.
    if (_saving) return;
    _saving = true;
    try {
      final stored = await widget.confirmation.confirm(
        () => widget.core.append(ResultsEvents.discards(fleet: fleet, count: count)),
      );
      if (!mounted) return;
      setState(() {
        _events.add(stored);
        _notSaved = null;
      });
    } catch (_) {
      // Beside the stepper that was tapped, which is on screen, rather than
      // at the top of a list that may be scrolled past it.
      if (mounted) setState(() => _notSaved = (fleet: fleet));
    } finally {
      _saving = false;
    }
  }

  /// The fleets to show, in the order they were named, or the day's one
  /// unnamed fleet. Finishes logged before any fleet was named get a section
  /// of their own rather than vanishing.
  List<({String? id, String? name})> _sections() {
    final named = fleets(_events);
    if (named.isEmpty) return const [(id: null, name: null)];
    return [
      for (final f in named) (id: f.id, name: f.name),
      if (finishOrder(_events, fleet: null).isNotEmpty) (id: null, name: 'No fleet'),
    ];
  }

  @override
  Widget build(BuildContext context) {
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
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text('Provisional results', style: Theme.of(context).textTheme.titleLarge),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Bars.screenGutterDp),
          children: [
            if (_problem != null) _Banner(_problem!),
            if (!_loaded && _problem == null) const Text('Reading the log…'),
            if (_loaded)
              for (final s in _sections())
                _FleetResults(
                  key: ValueKey('results-${s.id}'),
                  name: s.name,
                  results: () => provisionalResults(_events, fleet: s.id),
                  onDiscards: (count) => _setDiscards(s.id, count),
                  notSaved: _notSaved != null && _notSaved!.fleet == s.id,
                ),
          ],
        ),
      ),
    );
  }
}

/// One fleet's standings: a line per boat with her series points, and each
/// race's points under it.
class _FleetResults extends StatelessWidget {
  const _FleetResults({
    super.key,
    required this.name,
    required this.results,
    required this.onDiscards,
    required this.notSaved,
  });

  /// Null on a single-fleet day, where the fleet needs no heading.
  final String? name;
  final ProvisionalResults Function() results;
  final ValueChanged<int> onDiscards;

  /// This fleet's last discard change failed to save.
  final bool notSaved;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final ProvisionalResults r;
    try {
      r = results();
    } catch (e) {
      // The engine refuses a record it cannot score. Say so for this fleet
      // rather than lose the whole screen.
      return _section(theme, [_Banner('These results could not be scored: $e')]);
    }

    if (r.duplicates.isNotEmpty) {
      return _section(theme, [
        for (final d in r.duplicates)
          _Banner(
            'Sail ${d.sail} is on two finishes in race ${d.race}. Fix the sail number on the finish screen, or, '
            'if a gun was missed, log it on the sequence screen with the time it really went.',
          ),
      ]);
    }
    if (r.standings.isEmpty) return _section(theme, [Text('No finishes yet.', style: theme.bodyLarge)]);

    final unnamed = r.unnamed.length;
    return _section(theme, [
      Text('${r.races} ${r.races == 1 ? 'race' : 'races'} · provisional', style: theme.bodyLarge),
      if (unnamed > 0)
        _Warning(
          '$unnamed ${unnamed == 1 ? 'finish has' : 'finishes have'} no sail number, so these standings are '
          'incomplete. Name them on the finish screen.',
        ),
      for (final b in r.betweenRaces)
        _Warning(
          '${r.unnamed.containsKey(b.boat) ? 'A missed finish with no sail number' : 'Sail ${b.boat}'} was placed '
          'between race ${b.race - 1} and race ${b.race}, so she is scored in race ${b.race}. If she finished '
          'race ${b.race - 1}, these standings are wrong.',
        ),
      if (r.races > 1)
        _Discards(
          fleetKey: '${r.fleet}',
          count: r.discards,
          max: r.races - 1,
          onChanged: onDiscards,
          notSaved: notSaved,
        ),
      const SizedBox(height: 8),
      for (final s in r.standings)
        _StandingRow(
          standing: s,
          unnamed: r.unnamed[s.boat],
          betweenRaces: {
            for (final b in r.betweenRaces)
              if (b.boat == s.boat) b.race,
          },
        ),
    ]);
  }

  Widget _section(TextTheme theme, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (name != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Semantics(header: true, child: Text(name!, style: theme.titleLarge)),
          ),
        ...children,
      ],
    ),
  );
}

class _Discards extends StatelessWidget {
  const _Discards({
    required this.fleetKey,
    required this.count,
    required this.max,
    required this.onChanged,
    required this.notSaved,
  });

  final String fleetKey;
  final int count;
  final int max;
  final ValueChanged<int> onChanged;
  final bool notSaved;

  @override
  Widget build(BuildContext context) {
    // Outlined buttons, not icon buttons: the theme holds these to the
    // sunlight tokens, so one with nothing to do is still readable in sun.
    // The icon's label names each for a screen reader; the tooltip is for
    // sight only, or it joins the node of the standings around it.
    Widget step(String key, String tooltip, IconData icon, VoidCallback? onPressed) => Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: OutlinedButton(
        key: ValueKey('discards-$key-$fleetKey'),
        style: OutlinedButton.styleFrom(fixedSize: const Size.square(Bars.minTargetDp), padding: EdgeInsets.zero),
        onPressed: onPressed,
        child: Icon(icon, size: 32, semanticLabel: tooltip),
      ),
    );
    return Padding(
      key: ValueKey('discards-$fleetKey'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  count == 0 ? 'No discards' : 'Discards: $count',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              step('less', 'One discard fewer', Icons.remove, count > 0 ? () => onChanged(count - 1) : null),
              const SizedBox(width: 8),
              step('more', 'One discard more', Icons.add, count < max ? () => onChanged(count + 1) : null),
            ],
          ),
          if (notSaved) const Padding(padding: EdgeInsets.only(top: 8), child: _Banner('Not saved. Tap again.')),
        ],
      ),
    );
  }
}

/// A caveat on a fleet's standings, in the page's own grey.
class _Warning extends StatelessWidget {
  const _Warning(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.all(12),
    color: SunlightTokens.surface,
    child: Text(
      message,
      style: Theme.of(
        context,
      ).textTheme.bodyLarge?.copyWith(color: SunlightTokens.onSurface, fontWeight: FontWeight.w700),
    ),
  );
}

class _StandingRow extends StatelessWidget {
  const _StandingRow({required this.standing, required this.unnamed, required this.betweenRaces});

  final Standing standing;

  /// Where she finished, when she is a finish with no sail number.
  final UnnamedFinish? unnamed;

  /// The races (from 1) where she is a missed finish placed between two.
  final Set<int> betweenRaces;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final bold = theme.bodyLarge?.copyWith(fontWeight: FontWeight.w700);
    final u = unnamed;
    // One node per boat for a screen reader, read with what each number
    // means: the brackets that mark a discard are not spoken.
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: spokenStanding(standing, u, betweenRaces: betweenRaces),
      child: Container(
        key: ValueKey('standing-${standing.boat}'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: SunlightTokens.disabled)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 56, child: Text('${standing.rank}', style: bold)),
                Expanded(
                  child: Text(
                    u == null ? standing.boat : 'No sail # · race ${u.race}, #${u.place}',
                    style: u == null ? bold : bold?.copyWith(fontStyle: FontStyle.italic),
                  ),
                ),
                Text(pointsText(standing.netTenths), style: bold),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 56, top: 2),
              child: Wrap(
                spacing: 16,
                children: [
                  for (var i = 0; i < standing.races.length; i++)
                    Text(
                      'R${i + 1} ${raceScoreText(standing.races[i])}'
                      '${betweenRaces.contains(i + 1) ? ' · between races' : ''}',
                      style: theme.bodyLarge?.copyWith(color: SunlightTokens.mutedText),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A boat's line as a screen reader says it: "Rank 1, sail 1204, 2 points.
/// Race 1, 1. Race 2, 2, discarded. Race 3, 1."
String spokenStanding(Standing s, UnnamedFinish? unnamed, {Set<int> betweenRaces = const {}}) {
  final who = unnamed == null ? 'sail ${s.boat}' : 'no sail number, race ${unnamed.race} place ${unnamed.place}';
  final net = '${pointsText(s.netTenths)} ${s.netTenths == 10 ? 'point' : 'points'}';
  return [
    'Rank ${s.rank}, $who, $net.',
    for (var i = 0; i < s.races.length; i++)
      'Race ${i + 1}, ${s.races[i].code == null ? '' : '${s.races[i].code!.label} '}${pointsText(s.races[i].tenths)}'
          '${s.races[i].excluded ? ', discarded' : ''}${betweenRaces.contains(i + 1) ? ', placed between races' : ''}.',
  ].join(' ');
}

/// Points as results print them: whole points bare, tenths after a point.
String pointsText(int tenths) => tenths % 10 == 0 ? '${tenths ~/ 10}' : '${tenths ~/ 10}.${tenths % 10}';

/// One race's score as results print it: the code before the points, and an
/// excluded score in brackets (A2.1).
String raceScoreText(RaceScore s) {
  final text = '${s.code == null ? '' : '${s.code!.label} '}${pointsText(s.tenths)}';
  return s.excluded ? '($text)' : text;
}

class _Banner extends StatelessWidget {
  const _Banner(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      width: double.infinity,
      color: SunlightTokens.danger,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 12),
      child: Text(
        message,
        style: const TextStyle(color: SunlightTokens.onDanger, fontSize: 22, fontWeight: FontWeight.w700),
      ),
    ),
  );
}
