import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../shore/shore_status.dart';
import '../ui/bars.dart';
import '../ui/fit_label.dart';
import '../ui/sunlight.dart';

/// The race area this phone works on (#74), for every screen's header. It
/// sits above the navigator (`MaterialApp.builder`), so a screen pushed from
/// a screen the home pushed still sees it. The role home sets it once it has
/// read the race area, and clears it when it goes. Null on a phone never
/// admitted, which has one implicit race area and shows none.
class RaceAreaFrame extends StatefulWidget {
  const RaceAreaFrame({super.key, required this.child});

  final Widget child;

  /// The frame's race area, for the home to set. Null where there is no frame,
  /// as in a widget test that pumps one screen alone.
  static ValueNotifier<RaceArea?>? notifierOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_RaceAreaScope>()?.notifier;

  /// The race area to show in [context]'s header, rebuilding it when it moves.
  static RaceArea? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_RaceAreaScope>()?.notifier?.value;

  @override
  State<RaceAreaFrame> createState() => _RaceAreaFrameState();
}

class _RaceAreaFrameState extends State<RaceAreaFrame> {
  final _area = ValueNotifier<RaceArea?>(null);

  @override
  void dispose() {
    _area.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _RaceAreaScope(notifier: _area, child: widget.child);
}

class _RaceAreaScope extends InheritedNotifier<ValueNotifier<RaceArea?>> {
  const _RaceAreaScope({required super.notifier, required super.child});
}

/// What a header says of race area [area].
String raceAreaLine(RaceArea area) => 'Race area · ${area.name}';

/// One line naming a race area, in a header's narrow title slot. It is drawn
/// at the phone's text size when it fits, shrunk when it does not, and never
/// below [minFontSize]: there it is cut with an ellipsis, and a screen reader
/// still reads it whole. Shrunk with no floor, as a `FittedBox` does, "Race
/// area · Charlie inner trapezoid" drew about 13 px tall on the emulator at
/// 100% and 200% text alike (#74's render; #53 measured the same on its
/// banner and chose this floor).
class RaceAreaText extends StatelessWidget {
  const RaceAreaText(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  static const minFontSize = 16.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
        final base = DefaultTextStyle.of(context).style.merge(style);
        final full = base.copyWith(fontSize: MediaQuery.textScalerOf(context).scale(base.fontSize ?? 14));
        Size sizeAt(double fontSize) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: full.copyWith(fontSize: fontSize)),
            textDirection: Directionality.of(context),
            maxLines: 1,
          )..layout();
          final size = painter.size;
          painter.dispose();
          return size;
        }

        // Letter spacing does not scale, so each step measures again (#53).
        final (roomW, roomH) = (constraints.maxWidth - 0.5, constraints.maxHeight);
        var fontSize = full.fontSize!;
        var at = sizeAt(fontSize);
        for (var step = 0; (at.width > roomW || at.height > roomH) && fontSize > minFontSize && step < 8; step++) {
          final shrink = [if (at.width > roomW) roomW / at.width, if (at.height > roomH) roomH / at.height]
              .reduce((a, b) => a < b ? a : b);
          fontSize = (fontSize * shrink).clamp(minFontSize, fontSize);
          at = sizeAt(fontSize);
        }
        return Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          textScaler: TextScaler.noScaling,
          style: full.copyWith(fontSize: fontSize),
        );
      });
}

/// A screen's header [title], with the race area under it once the phone
/// works on one (#74 criterion 1). Each line shrinks to fit on its own, so a
/// long race-area name never shrinks the title (the shared `FittedBox` #33
/// measured). Unchanged where there is no race area to show.
class RaceAreaTitle extends StatelessWidget {
  const RaceAreaTitle({super.key, required this.title});

  final Widget title;

  @override
  Widget build(BuildContext context) {
    final area = RaceAreaFrame.of(context);
    if (area == null) return title;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          flex: 3,
          child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: title),
        ),
        Flexible(
          flex: 2,
          child: RaceAreaText(raceAreaLine(area),
              key: const ValueKey('race-area-header'), style: Theme.of(context).textTheme.titleSmall!),
        ),
      ],
    );
  }
}

/// The race-area picker (#74 criterion 2), for a phone admitted with an
/// event-wide role: the race day's race areas as sync kept them, fetched once
/// with signal. One tap on one logs this phone's pick and returns home. A full
/// screen, never a sheet or a menu, as the station picker is. The race areas
/// never move: the one in force is filled in its own row.
///
/// Set-up, not a race-time action: a pick is made before racing, as a role
/// pick is. Pops with the stored pick, or with nothing for Back or for the
/// race area the phone is already on, which logs nothing.
class RaceAreaScreen extends StatefulWidget {
  const RaceAreaScreen({
    super.key,
    required this.core,
    required this.confirmation,
    required this.areas,
    required this.current,
  });

  final CoreClient core;
  final ConfirmationService confirmation;

  /// The race day's race areas, by name.
  final List<RaceArea> areas;

  /// The course id of the race area in force, or null when there is none.
  final String? current;

  @override
  State<RaceAreaScreen> createState() => _RaceAreaScreenState();
}

class _RaceAreaScreenState extends State<RaceAreaScreen> {
  bool _busy = false;
  bool _notLogged = false;

  Future<void> _pick(RaceArea area) async {
    if (_busy) return; // A second tap while the first is in flight is the same tap.
    if (area.id == widget.current) {
      Navigator.of(context).pop();
      return;
    }
    _busy = true;
    try {
      final stored = await widget.confirmation.confirm(() => widget.core.append(RaceAreaEvents.select(area.id)));
      if (mounted) Navigator.of(context).pop(stored);
    } catch (_) {
      if (mounted) setState(() => _notLogged = true);
    } finally {
      _busy = false;
    }
  }

  Widget _area(RaceArea area) {
    final current = area.id == widget.current;
    // The race area in force is drawn as a fill alone, so it is said too.
    final child = Semantics(
      label: current ? '${area.name}, current race area' : area.name,
      excludeSemantics: true,
      child: FitLabel(area.name.toUpperCase()),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        width: double.infinity,
        height: Bars.minTargetDp + 8,
        child: current
            ? FilledButton(key: ValueKey('race-area-${area.id}'), onPressed: () => _pick(area), child: child)
            : OutlinedButton(key: ValueKey('race-area-${area.id}'), onPressed: () => _pick(area), child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.areas.where((a) => a.id == widget.current).firstOrNull;
    final text = Theme.of(context).textTheme.bodyLarge;
    return Scaffold(
      // Nothing here is typed.
      resizeToAvoidBottomInset: false,
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
        title: RaceAreaText(current == null ? 'Race area · none yet' : raceAreaLine(current),
            style: Theme.of(context).textTheme.titleLarge!),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Bars.screenGutterDp),
          children: [
            if (_notLogged)
              Semantics(
                liveRegion: true,
                child: Container(
                  width: double.infinity,
                  color: SunlightTokens.danger,
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 12),
                  child: const Text('Not logged. Tap again.',
                      style: TextStyle(color: SunlightTokens.onDanger, fontSize: 22, fontWeight: FontWeight.w700)),
                ),
              ),
            if (widget.areas.isEmpty)
              Text('No race areas on this phone yet. They arrive with signal.',
                  key: const ValueKey('race-areas-none'), style: text),
            for (final a in widget.areas) _area(a),
          ],
        ),
      ),
    );
  }
}
