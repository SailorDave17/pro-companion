import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../log/log_screen.dart' show refusalReasonText;
import '../ui/bars.dart';
import '../ui/clock.dart';
import '../ui/sunlight.dart';

/// What has reached shore (#66): each phone's own upload state, at a glance
/// on every race-time screen and in full one tap away, so a committee member
/// knows what the rest of the committee and the shore can see.
///
/// It reads the core only ([CoreClient.uploadStatus], [CoreClient.pullStatus])
/// and never learns how sync works (ADR 006). It writes nothing, and nothing
/// waits on it: an append never reads it.

/// One reading of the two statuses, taken together.
class ShoreReading {
  const ShoreReading(this.upload, this.pull);

  final UploadStatus upload;
  final PullStatus pull;

  int get waiting => upload.pending;
  int get refused => upload.refused.length;

  /// Events that stay on this phone and never upload: written before it was
  /// ever admitted (#6), or under an admission since revoked (#53). They are
  /// not waiting, so they never hold back the all-on-shore state (owner
  /// decision on #66); the full view lists them.
  int get kept => upload.neverAdmitted + upload.held;

  /// The last successful upload: when the server last accepted one of this
  /// phone's events (owner decision on #66).
  int? get lastUpload => upload.lastAcceptedAt;

  /// When a pull last read every race day this phone may read (#64).
  int? get lastPull => pull.lastPulledAt;

  /// The later of [lastUpload] and [lastPull]: the last time the shore
  /// answered this phone, or null when it never has.
  int? get lastSync => switch ((lastUpload, lastPull)) {
        (null, final p) => p,
        (final u, null) => u,
        (final u!, final p!) => math.max(u, p),
      };

  /// Offline when sync's latest run, upload or pull, could not reach the
  /// server (owner decision on #66: read from the core, not the phone's
  /// network). Before sync's first run it is not offline, only not synced.
  bool get offline {
    final up = upload.lastRun;
    final down = pull.lastRun;
    final latest = up == null
        ? down?.state
        : down == null
            ? up.state
            : (down.at >= up.at ? down.state : up.state);
    return latest == UploadRunState.unreachable;
  }

  /// Nothing waits and nothing was refused, and the shore holds at least one
  /// of this phone's events.
  bool get allOnShore => waiting == 0 && refused == 0 && upload.accepted > 0;

  // UploadStatus has no equality of its own; its wire form is plain data.
  @override
  bool operator ==(Object other) =>
      other is ShoreReading && jsonEncode(other.upload.toWire()) == jsonEncode(upload.toWire()) && other.pull == pull;

  @override
  int get hashCode => Object.hash(jsonEncode(upload.toWire()), pull);
}

/// Reads the core's two statuses for a [State], keeping the last good
/// reading: a read that fails after one that worked leaves what it showed.
mixin _ReadsShore<T extends StatefulWidget> on State<T> {
  CoreClient get core;

  ShoreReading? reading;
  bool unreadable = false;
  bool _busy = false;

  Future<void> readShore() async {
    if (_busy) return;
    _busy = true;
    try {
      final (upload, pull) = await (core.uploadStatus(), core.pullStatus()).wait;
      final next = ShoreReading(upload, pull);
      if (mounted && (next != reading || unreadable)) {
        setState(() {
          reading = next;
          unreadable = false;
        });
      }
    } catch (_) {
      if (mounted && reading == null) setState(() => unreadable = true);
    } finally {
      _busy = false;
    }
  }
}

/// The indicator's first line: offline first, then the counts, else the
/// all-on-shore state.
String shoreHeadline(ShoreReading r) {
  final parts = [
    if (r.offline) 'Offline',
    if (r.waiting > 0) '${r.waiting} waiting',
    if (r.refused > 0) '${r.refused} refused',
  ];
  if (parts.isNotEmpty) return parts.join(' · ');
  return r.allOnShore ? 'All on shore' : 'Nothing sent';
}

/// Each state has a shape of its own, so none is told from another by colour
/// alone (#66 criterion 2): the all-on-shore cloud carries a tick.
IconData shoreIcon(ShoreReading r) {
  if (r.offline) return Icons.cloud_off;
  if (r.refused > 0) return Icons.report;
  if (r.waiting > 0) return Icons.cloud_upload;
  if (r.allOnShore) return Icons.cloud_done;
  return Icons.cloud_queue;
}

/// How long ago [at] was, as of [now]: rounded down, in the largest unit.
String ageText(int at, int now) {
  final minutes = (now - at) ~/ 60000;
  if (minutes < 1) return 'just now';
  if (minutes < 60) return '$minutes min ago';
  final hours = minutes ~/ 60;
  if (hours < 24) return '$hours h ago';
  return '${hours ~/ 24} d ago';
}

/// The second line when offline: the age of the last sync (#66 criterion 3).
String lastSyncText(ShoreReading r, int now) {
  final last = r.lastSync;
  return last == null ? 'never synced' : 'last sync ${ageText(last, now)}';
}

/// The two times, in words: the home row's second line, and the full view.
String shoreTimesText(ShoreReading r, String Function(int) time) {
  if (r.lastUpload == null && r.lastPull == null) return 'Not synced yet';
  String at(int? t) => t == null ? 'never' : time(t);
  return 'Upload ${at(r.lastUpload)} · Pull ${at(r.lastPull)}';
}

/// What a screen reader says for the indicator: every part spelled out.
String spokenShore(ShoreReading r, int now) => [
      shoreHeadline(r),
      if (r.offline) lastSyncText(r, now),
      if (r.lastUpload == null && r.lastPull == null)
        'Not synced yet'
      else ...[
        'Last upload ${r.lastUpload == null ? 'never' : minuteText(r.lastUpload!)}',
        'Last pull ${r.lastPull == null ? 'never' : minuteText(r.lastPull!)}',
      ],
      'Shows what has reached shore',
    ].join('. ');

/// An event kind in words: `start.general_recall` is "Start general recall".
String kindText(String kind) {
  if (kind == UploadStatus.noKind) return 'Unreadable event';
  final words = kind.replaceAll('.', ' ').replaceAll('_', ' ');
  return words.isEmpty ? words : words[0].toUpperCase() + words.substring(1);
}

/// The indicator (#66): on every race-time screen's app bar, and as a full
/// row on each role's home ([wide]). A tap opens [ShoreStatusScreen].
///
/// It reads the core at once, then every [every] while its screen is the one
/// showing, and again as soon as its screen shows again: a screen under
/// another reads nothing.
class ShoreIndicator extends StatefulWidget {
  const ShoreIndicator({
    super.key,
    required this.core,
    this.wide = false,
    this.clock = systemClock,
    this.every = const Duration(seconds: 5),
  });

  final CoreClient core;

  /// A full-width row, for a role's home, rather than an app-bar chip.
  final bool wide;

  /// The phone's clock, which the age of the last sync is counted from.
  final int Function() clock;

  /// How often the core is asked.
  final Duration every;

  @override
  State<ShoreIndicator> createState() => _ShoreIndicatorState();
}

class _ShoreIndicatorState extends State<ShoreIndicator> with _ReadsShore {
  Timer? _timer;
  bool _current = true;

  @override
  CoreClient get core => widget.core;

  @override
  void initState() {
    super.initState();
    readShore();
    _timer = Timer.periodic(widget.every, (_) {
      if (_current) readShore();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    // Back on top, after a screen it opened was closed: what that screen
    // logged is read now, not at the next tick.
    if (current && !_current) readShore();
    _current = current;
  }

  @override
  void didUpdateWidget(ShoreIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.core != widget.core) readShore();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _open() => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ShoreStatusScreen(core: widget.core, clock: widget.clock),
      ));

  @override
  Widget build(BuildContext context) {
    final reading = this.reading;
    final now = widget.clock();
    final IconData icon;
    final String headline;
    final String detail;
    final String spoken;
    if (reading == null) {
      icon = unreadable ? Icons.help_outline : Icons.hourglass_empty;
      headline = unreadable ? 'Not read' : 'Reading…';
      detail = '';
      spoken = unreadable ? 'What reached shore could not be read' : 'Reading what reached shore';
    } else {
      icon = shoreIcon(reading);
      headline = shoreHeadline(reading);
      detail = reading.offline
          ? lastSyncText(reading, now)
          : widget.wide
              ? shoreTimesText(reading, minuteText)
              : '';
      spoken = spokenShore(reading, now);
    }
    final theme = Theme.of(context).textTheme;
    final visual = widget.wide
        ? _row(icon, headline, detail, theme)
        : _chip(
            icon,
            headline,
            switch (reading) {
              null => null,
              ShoreReading(offline: true) => Text(detail),
              _ => _times(reading),
            },
            theme);
    final button = OutlinedButton(
      key: ValueKey(widget.wide ? 'shore-row' : 'shore-indicator'),
      onPressed: _open,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size.square(Bars.minTargetDp),
      ),
      child: Semantics(label: spoken, excludeSemantics: true, child: visual),
    );
    if (widget.wide) {
      return SizedBox(width: double.infinity, height: Bars.minTargetDp + 8, child: button);
    }
    // A chip in the app bar: at most 40% of the screen's width, so the title
    // keeps the rest, and everything in it shrinks to fit rather than wrap.
    final maxWidth = math.max(Bars.minTargetDp, MediaQuery.sizeOf(context).width * 0.4);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, minHeight: Bars.minTargetDp, maxHeight: Bars.minTargetDp),
        child: button,
      ),
    );
  }

  /// The up and down times, HH:MM, each behind its arrow.
  Widget _times(ShoreReading r) {
    if (r.lastUpload == null && r.lastPull == null) return const Text('not synced');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.north, size: 14),
        Text(r.lastUpload == null ? '–' : minuteText(r.lastUpload!)),
        const SizedBox(width: 6),
        const Icon(Icons.south, size: 14),
        Text(r.lastPull == null ? '–' : minuteText(r.lastPull!)),
      ],
    );
  }

  Widget _chip(IconData icon, String headline, Widget? second, TextTheme theme) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, key: ValueKey('shore-icon-${icon.codePoint}')),
            const SizedBox(width: 6),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(headline, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w700)),
                if (second != null) DefaultTextStyle.merge(style: theme.bodySmall, child: second),
              ],
            ),
          ],
        ),
      );

  Widget _row(IconData icon, String headline, String detail, TextTheme theme) => Row(
        children: [
          Icon(icon, size: 32, key: ValueKey('shore-icon-${icon.codePoint}')),
          const SizedBox(width: 12),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(headline, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (detail.isNotEmpty) Text(detail, maxLines: 1, style: theme.bodyMedium),
                ],
              ),
            ),
          ),
          const Icon(Icons.chevron_right, size: 28),
        ],
      );
}

/// The full view behind the indicator (#66 criterion 5): what waits, by kind;
/// each refused event, with its kind and reason; what stays on the phone; and
/// the two times. A full screen, not a sheet: a modal on a race-time route
/// would steal the next tap, and the bar check refuses one. It reads the core
/// every [every] while open, and writes nothing.
class ShoreStatusScreen extends StatefulWidget {
  const ShoreStatusScreen({
    super.key,
    required this.core,
    this.clock = systemClock,
    this.every = const Duration(seconds: 5),
  });

  final CoreClient core;
  final int Function() clock;
  final Duration every;

  @override
  State<ShoreStatusScreen> createState() => _ShoreStatusScreenState();
}

class _ShoreStatusScreenState extends State<ShoreStatusScreen> with _ReadsShore {
  Timer? _timer;

  @override
  CoreClient get core => widget.core;

  @override
  void initState() {
    super.initState();
    readShore();
    _timer = Timer.periodic(widget.every, (_) => readShore());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = reading;
    final theme = Theme.of(context).textTheme;
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
          child: Text('Sent to shore', style: theme.titleLarge),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Bars.screenGutterDp),
          children: [
            if (unreadable) Text('What reached shore could not be read', style: theme.bodyLarge),
            if (r == null && !unreadable) const Text('Reading…'),
            if (r != null) ..._sections(r, theme),
          ],
        ),
      ),
    );
  }

  List<Widget> _sections(ShoreReading r, TextTheme theme) {
    final now = widget.clock();
    final waiting = r.upload.waitingByKind.entries.toList()
      ..sort((a, b) => b.value != a.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key));
    // What waits and what was refused come first, under one short line: at 200% text the times,
    // given first, filled more than the first screen on their own (measured, 953 dp of 819).
    return [
      _Line(
        key: const ValueKey('shore-summary'),
        icon: shoreIcon(r),
        title: shoreHeadline(r),
        lines: [if (r.offline) lastSyncText(r, now)],
      ),
      _heading('Waiting · ${r.waiting}', theme),
      if (waiting.isEmpty) _empty('Nothing waiting', theme),
      for (final e in waiting)
        _Line(key: ValueKey('waiting-${e.key}'), title: kindText(e.key), lines: ['${e.value} waiting']),
      _heading('Refused · ${r.refused}', theme),
      if (r.upload.refused.isEmpty) _empty('Nothing refused', theme),
      for (final f in r.upload.refused)
        _Line(
          key: ValueKey('refused-${f.ulid}'),
          icon: Icons.report,
          title: kindText(f.kind ?? UploadStatus.noKind),
          lines: [
            'Refused: ${refusalReasonText(f.reason)}',
            if (f.mayBeOnShore) 'It may be on shore all the same',
          ],
        ),
      if (r.kept > 0) ...[
        _heading('Kept on this phone · ${r.kept}', theme),
        if (r.upload.neverAdmitted > 0)
          _Line(
            key: const ValueKey('kept-never-admitted'),
            title: '${r.upload.neverAdmitted} before admission',
            lines: const ['Logged before this phone was admitted. They never upload.'],
          ),
        if (r.upload.held > 0)
          _Line(
            key: const ValueKey('kept-held'),
            title: '${r.upload.held} after removal',
            lines: const ['Logged under an admission since revoked. They are never sent.'],
          ),
      ],
      _heading('On shore · ${r.upload.accepted}', theme),
      _Line(
        key: const ValueKey('shore-times'),
        title: 'Last upload',
        lines: [r.lastUpload == null ? 'Never' : '${clockText(r.lastUpload!)}, ${ageText(r.lastUpload!, now)}'],
      ),
      _Line(
        key: const ValueKey('shore-pull'),
        title: 'Last pull',
        lines: [r.lastPull == null ? 'Never' : '${clockText(r.lastPull!)}, ${ageText(r.lastPull!, now)}'],
      ),
    ];
  }

  Widget _heading(String text, TextTheme theme) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Semantics(header: true, child: Text(text, style: theme.titleLarge)),
      );

  Widget _empty(String text, TextTheme theme) =>
      Padding(padding: const EdgeInsets.all(8), child: Text(text, style: theme.bodyLarge));
}

/// One row: its title, and the lines under it, read as one node.
class _Line extends StatelessWidget {
  const _Line({super.key, required this.title, required this.lines, this.icon});

  final String title;
  final List<String> lines;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: [title, ...lines].join('. '),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: SunlightTokens.disabled))),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) ...[Icon(icon, size: 32), const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // titleLarge, not titleMedium: the sunlight theme leaves titleMedium at 16 under
                  // bodyLarge's 22, so it drew smaller than the line under it (#67's render).
                  Text(title, style: theme.titleLarge),
                  for (final line in lines)
                    Text(line, style: theme.bodyLarge?.copyWith(color: SunlightTokens.mutedText)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
