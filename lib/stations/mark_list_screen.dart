import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../roles/race_area.dart';
import '../shore/shore_status.dart';
import '../ui/bars.dart';
import '../ui/fit_label.dart';
import '../ui/sunlight.dart';
import 'station_screen.dart';

/// What a colour or shape chip says.
String looksName(String id) => id[0].toUpperCase() + id.substring(1);

/// The custom mark list editor (#78): a PRO names the marks the standard set
/// does not have, each with an optional colour and shape from fixed sets
/// (owner decision at pickup), and sends them to the mark boats on this
/// phone's race area. The editor opens on the list in force, so a mark left
/// as it was keeps its id and a boat stationed there stays valid (owner
/// decision at pickup); only a new mark gets a new id.
///
/// SEND LIST appends the whole list as one `mark_list.sent`, confirmed by one
/// buzz and one tone. UNDO LIST appends a `mark_list.undo` naming the list in
/// force, at once and with no confirm dialog, and the race area returns to
/// the list before it. Set-up, done before racing, as FLEETS is: no race-time
/// action here.
class MarkListScreen extends StatefulWidget {
  const MarkListScreen({super.key, required this.core, required this.confirmation, required this.course});

  final CoreClient core;
  final ConfirmationService confirmation;

  /// The course id of the race area the list is for.
  final String course;

  @override
  State<MarkListScreen> createState() => _MarkListScreenState();
}

class _MarkListScreenState extends State<MarkListScreen> {
  final _lists = <EventEnvelope>[];
  final _draft = <CustomMark>[];
  final _name = TextEditingController();
  String? _colour;
  String? _shape;
  String? _problem;
  bool _loaded = false;
  bool _busy = false;

  EventEnvelope? get _inForce => currentMarkListEvent(_lists, widget.course);
  List<CustomMark> get _sent => currentMarkList(_lists, widget.course);

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() => _problem = null));
    _read();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Reads every phone's lists, since another PRO's for this race area
  /// arrives by pull, and resets the draft to the list in force.
  Future<void> _read() async {
    try {
      final events = await widget.core.readAll();
      if (!mounted) return;
      setState(() {
        _lists
          ..clear()
          ..addAll(events.where((e) => MarkListKinds.all.contains(e.kind)));
        _draft
          ..clear()
          ..addAll(_sent);
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _problem = 'The log on this phone could not be read');
    }
  }

  void _add() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    if (_draft.any((m) => m.name.toLowerCase() == name.toLowerCase()) ||
        StandardMarks.all.any((m) => markName(m).toLowerCase() == name.toLowerCase())) {
      setState(() => _problem = '$name is already a mark');
      return;
    }
    setState(() {
      _draft.add(CustomMark(id: newCustomMarkId(), name: name, colour: _colour, shape: _shape));
      _name.clear();
      _colour = null;
      _shape = null;
      _problem = null;
    });
  }

  Future<void> _log(NewEvent event) async {
    if (_busy) return; // A second tap while the first is in flight is the same tap.
    _busy = true;
    try {
      final stored = await widget.confirmation.confirm(() => widget.core.append(event));
      if (!mounted) return;
      setState(() {
        _lists.add(stored);
        _draft
          ..clear()
          ..addAll(_sent);
        _problem = null;
      });
    } catch (_) {
      if (mounted) setState(() => _problem = 'Not logged. Tap again.');
    } finally {
      _busy = false;
    }
  }

  bool get _changed {
    final sent = _sent;
    if (sent.length != _draft.length) return true;
    for (var i = 0; i < sent.length; i++) {
      if (sent[i] != _draft[i]) return true;
    }
    return false;
  }

  /// A colour or shape, two to a row, filled when chosen; a second tap clears.
  Widget _chips(List<String> ids, String? chosen, String keyPrefix, ValueChanged<String?> pick) {
    Widget chip(String id) {
      final on = id == chosen;
      final child = Semantics(
        label: on ? '${looksName(id)}, chosen' : looksName(id),
        excludeSemantics: true,
        child: FitLabel(looksName(id).toUpperCase()),
      );
      void tap() => pick(on ? null : id);
      return SizedBox(
        height: Bars.minTargetDp + 8,
        child: on
            ? FilledButton(key: ValueKey('$keyPrefix-$id'), onPressed: tap, child: child)
            : OutlinedButton(key: ValueKey('$keyPrefix-$id'), onPressed: tap, child: child),
      );
    }

    return Column(
      children: [
        for (var i = 0; i < ids.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Expanded(child: chip(ids[i])),
                const SizedBox(width: 12),
                Expanded(child: i + 1 < ids.length ? chip(ids[i + 1]) : const SizedBox.shrink()),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final sent = _sent;
    final inForce = _inForce;
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
        title: RaceAreaTitle(
          title: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text('Custom marks', style: theme.titleLarge),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Bars.screenGutterDp),
          children: [
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
            if (!_loaded && _problem == null) const Text('Reading the log…'),
            if (_loaded)
              Text(
                sent.isEmpty
                    ? 'No list sent yet. Mark boats here see the standard set.'
                    : 'Sent: ${sent.length} custom ${sent.length == 1 ? 'mark' : 'marks'}',
                key: const ValueKey('mark-list-status'),
                style: theme.titleMedium,
              ),
            const SizedBox(height: 12),
            for (final m in _draft)
              Padding(
                key: ValueKey('mark-row-${m.id}'),
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text([m.name, ?markLooks(m)].join(' · '), style: theme.bodyLarge),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      height: Bars.minTargetDp,
                      child: OutlinedButton(
                        key: ValueKey('mark-remove-${m.id}'),
                        onPressed: () => setState(() => _draft.removeWhere((d) => d.id == m.id)),
                        child: Semantics(
                            label: 'Remove ${m.name}', excludeSemantics: true, child: const FitLabel('REMOVE')),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('mark-name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(fontSize: 22),
              decoration: const InputDecoration(
                labelText: 'Mark name',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 22),
              ),
              onSubmitted: (_) => _add(),
            ),
            const SizedBox(height: 12),
            Text('Colour (optional)', style: theme.titleSmall),
            const SizedBox(height: 8),
            _chips(MarkColours.all, _colour, 'mark-colour', (c) => setState(() => _colour = c)),
            Text('Shape (optional)', style: theme.titleSmall),
            const SizedBox(height: 8),
            _chips(MarkShapes.all, _shape, 'mark-shape', (s) => setState(() => _shape = s)),
            SizedBox(
              width: double.infinity,
              height: Bars.minTargetDp + 8,
              child: OutlinedButton(
                key: const ValueKey('mark-add'),
                onPressed: _loaded && _name.text.trim().isNotEmpty ? _add : null,
                child: const FitLabel('ADD MARK'),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: Bars.minTargetDp + 8,
              child: FilledButton(
                key: const ValueKey('mark-send'),
                onPressed: _loaded && _draft.isNotEmpty && _changed
                    ? () => _log(MarkListEvents.send(course: widget.course, marks: [..._draft]))
                    : null,
                child: const FitLabel('SEND LIST'),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: Bars.minTargetDp + 8,
              child: OutlinedButton(
                key: const ValueKey('mark-undo'),
                onPressed: inForce == null ? null : () => _log(MarkListEvents.undo(inForce.ulid)),
                child: const FitLabel('UNDO LIST'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
