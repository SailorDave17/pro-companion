import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../ui/bars.dart';
import '../ui/race_time.dart';
import '../ui/sunlight.dart';

/// Finish capture (#4): one big tap per boat, confirmed by a buzz and a beep,
/// with undo instead of confirm prompts. FINISH is anchored at the bottom and
/// never moves or gets covered; the order runs above it, newest nearest the
/// button (owner's layout, 2026-09-24).
class FinishScreen extends StatefulWidget {
  const FinishScreen({super.key, required this.core, required this.confirmation});

  final CoreClient core;
  final ConfirmationService confirmation;

  @override
  State<FinishScreen> createState() => _FinishScreenState();
}

class _FinishScreenState extends State<FinishScreen> {
  final _events = <EventEnvelope>[];
  final _scroll = ScrollController();
  bool _loaded = false;
  bool _failed = false;
  String? _expanded;
  String? _keypadFor;
  String _digits = '';

  @override
  void initState() {
    super.initState();
    widget.core.readAll().then((events) {
      if (!mounted) return;
      setState(() {
        _events.addAll(events.where((e) => FinishKinds.all.contains(e.kind)));
        _loaded = true;
      });
      _scrollToNewest();
    }, onError: (Object _) {
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Appends [event] and, once the core confirms it, shows it. A failed
  /// append shows "Not logged" and fires no confirmation. True when logged.
  Future<bool> _append(NewEvent event) async {
    try {
      final stored = await widget.confirmation.confirm(() => widget.core.append(event));
      if (!mounted) return true;
      setState(() {
        _events.add(stored);
        _failed = false;
      });
      if (event.kind == FinishKinds.finish) _scrollToNewest();
      return true;
    } catch (_) {
      if (mounted) setState(() => _failed = true);
      return false;
    }
  }

  /// Saves the typed sail number, then walks on to the next finish in the
  /// order that has none, so naming a fleet after the rush is type, Save,
  /// type, Save (design-bar, owner 2026-09-24). A failed save stays put with
  /// the digits, for the retry.
  Future<void> _saveSail() async {
    final target = _keypadFor;
    if (target == null || _digits.isEmpty) return;
    if (!await _append(FinishEvents.assignSail(target, _digits)) || !mounted) return;
    final order = finishOrder(_events);
    final at = order.indexWhere((e) => e.ulid == target);
    final next = order.skip(at + 1).where((e) => e.sail == null).firstOrNull;
    setState(() {
      _keypadFor = next?.ulid;
      _digits = '';
    });
  }

  void _scrollToNewest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final order = finishOrder(_events);
    final last = lastUndoable(_events);
    final lastPlace = last == null ? null : order.where((e) => e.ulid == last).firstOrNull?.place;
    final height = MediaQuery.sizeOf(context).height;

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
        title: Text('Finishes · ${order.length}', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: _keypadFor != null
                  ? _SailKeypad(
                      entry: order.where((e) => e.ulid == _keypadFor).firstOrNull,
                      digits: _digits,
                      onDigit: (d) => setState(() {
                        if (_digits.length < 7) _digits += d;
                      }),
                      onDelete: () => setState(() => _digits = _digits.isEmpty ? '' : _digits.substring(0, _digits.length - 1)),
                      onCancel: () => setState(() => _keypadFor = null),
                      onSave: _saveSail,
                    )
                  : !_loaded && !_failed
                      ? const Center(child: Text('Reading the log…'))
                      : ListView.builder(
                          controller: _scroll,
                          itemCount: order.length,
                          itemBuilder: (context, i) => _FinishRow(
                            entry: order[i],
                            expanded: _expanded == order[i].ulid,
                            onTapRow: () => setState(
                                () => _expanded = _expanded == order[i].ulid ? null : order[i].ulid),
                            onSail: () => setState(() {
                              _expanded = null;
                              _keypadFor = order[i].ulid;
                              _digits = order[i].sail ?? '';
                            }),
                            onMissedAbove: () {
                              setState(() => _expanded = null);
                              _append(FinishEvents.missed(
                                afterUlid: i == 0 ? null : order[i - 1].ulid,
                                beforeUlid: order[i].ulid,
                              ));
                            },
                            onUndo: () {
                              setState(() => _expanded = null);
                              _append(FinishEvents.undo(order[i].ulid));
                            },
                          ),
                        ),
            ),
            if (_failed)
              Semantics(
                liveRegion: true,
                child: Container(
                  width: double.infinity,
                  color: SunlightTokens.danger,
                  padding: const EdgeInsets.all(16),
                  child: const Text('Not logged. Tap again.',
                      style: TextStyle(color: SunlightTokens.onDanger, fontSize: 22, fontWeight: FontWeight.w700)),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, 8, Bars.screenGutterDp, 8),
              child: RaceTimeAction(
                id: 'undo-last',
                primary: true,
                child: SizedBox(
                  width: double.infinity,
                  height: Bars.minTargetDp,
                  child: ElevatedButton(
                    onPressed: last == null ? null : () => _append(FinishEvents.undo(last)),
                    child: _Label(last == null ? 'Nothing to undo' : 'UNDO LAST (#$lastPlace)'),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Bars.screenGutterDp, 0, Bars.screenGutterDp, Bars.screenGutterDp),
              child: RaceTimeAction(
                id: 'finish',
                primary: true,
                child: SizedBox(
                  width: double.infinity,
                  height: math.max(120, height * 0.3),
                  child: FilledButton(
                    onPressed: () => _append(FinishEvents.finish()),
                    style: FilledButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 44, fontWeight: FontWeight.w900, letterSpacing: 2),
                    ),
                    child: const _Label('FINISH'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A button label that shrinks to fit its button rather than wrap or clip.
/// At large text sizes a fixed-size control otherwise cuts its own label
/// ("Canc/el", "Sail" without its "#") - measured at 200% on the emulator.
class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1));
}

String _clock(int deviceTs) {
  final t = DateTime.fromMillisecondsSinceEpoch(deviceTs);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

class _FinishRow extends StatelessWidget {
  const _FinishRow({
    required this.entry,
    required this.expanded,
    required this.onTapRow,
    required this.onSail,
    required this.onMissedAbove,
    required this.onUndo,
  });

  final FinishEntry entry;
  final bool expanded;
  final VoidCallback onTapRow;
  final VoidCallback onSail;
  final VoidCallback onMissedAbove;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme.bodyLarge;
    return Container(
      color: expanded ? SunlightTokens.surface : null,
      padding: const EdgeInsets.symmetric(horizontal: Bars.screenGutterDp, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  key: ValueKey('row-${entry.ulid}'),
                  onTap: () {
                    final opening = !expanded;
                    onTapRow();
                    // The bottom row's actions open below the fold; bring them
                    // into view, or reaching them would take a swipe
                    // (measured on the emulator with a full list).
                    if (opening) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (context.mounted) {
                          Scrollable.ensureVisible(
                            context,
                            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
                            duration: const Duration(milliseconds: 150),
                          );
                        }
                      });
                    }
                  },
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: Bars.minTargetDp),
                    child: Row(
                      children: [
                        SizedBox(width: 56, child: Text('${entry.place}', style: text?.copyWith(fontWeight: FontWeight.w700))),
                        Expanded(
                          child: Text(
                            entry.missed ? 'missed · time unknown' : _clock(entry.deviceTs!),
                            style: entry.missed ? text?.copyWith(color: SunlightTokens.mutedText, fontStyle: FontStyle.italic) : text,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              RaceTimeAction(
                id: 'sail',
                child: SizedBox(
                  width: 132,
                  height: Bars.minTargetDp,
                  child: OutlinedButton(
                    key: ValueKey('sail-${entry.ulid}'),
                    onPressed: onSail,
                    child: _Label(entry.sail ?? 'Sail #'),
                  ),
                ),
              ),
            ],
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: RaceTimeAction(
                      id: 'missed-above',
                      itemScoped: true,
                      child: ElevatedButton(onPressed: onMissedAbove, child: const _Label('Missed above')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: RaceTimeAction(
                      id: 'undo-this',
                      itemScoped: true,
                      child: ElevatedButton(onPressed: onUndo, child: const _Label('Undo this')),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SailKeypad extends StatelessWidget {
  const _SailKeypad({
    required this.entry,
    required this.digits,
    required this.onDigit,
    required this.onDelete,
    required this.onCancel,
    required this.onSave,
  });

  final FinishEntry? entry;
  final String digits;
  final ValueChanged<String> onDigit;
  final VoidCallback onDelete;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final title = e == null ? 'Sail' : 'Sail for #${e.place} · ${e.missed ? 'missed' : _clock(e.deviceTs!)}';
    Widget key(String label, VoidCallback? onPressed, {Key? k}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: SizedBox(
              height: Bars.minTargetDp,
              child: OutlinedButton(
                key: k,
                onPressed: onPressed,
                style: const ButtonStyle(
                  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
                ),
                child: _Label(label),
              ),
            ),
          ),
        );
    return Container(
      color: SunlightTokens.surface,
      padding: const EdgeInsets.symmetric(horizontal: Bars.screenGutterDp - 4, vertical: 4),
      child: SingleChildScrollView(
        child: Column(
          children: [
            // A fixed-height header, so the keypad below it fits in the same
            // space at any text size and FINISH never has to move.
            SizedBox(
              height: Bars.minTargetDp + 8,
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: Theme.of(context).textTheme.bodyMedium),
                            Text(digits.isEmpty ? '—' : digits,
                                style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // "Close", not "Cancel": numbers saved on the way stay saved.
                  SizedBox(width: 140, child: Row(children: [key('Close', onCancel, k: const ValueKey('keypad-cancel'))])),
                ],
              ),
            ),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              Row(children: [for (final d in row) key(d, () => onDigit(d), k: ValueKey('key-$d'))]),
            Row(children: [
              key('⌫', onDelete, k: const ValueKey('key-del')),
              key('0', () => onDigit('0'), k: const ValueKey('key-0')),
              key('Save', digits.isEmpty ? null : onSave, k: const ValueKey('keypad-save')),
            ]),
          ],
        ),
      ),
    );
  }
}
