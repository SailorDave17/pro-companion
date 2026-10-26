import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../roles/roles.dart';
import '../stations/station_screen.dart';
import '../ui/bars.dart';
import '../ui/clock.dart';
import '../ui/sunlight.dart';

/// The committee log (#67): how each other committee phone's log reads on
/// this phone, as sync has pulled it down (#64), so a gap from lost signal is
/// never mistaken for an altered record. And a banner when this phone's own
/// chain is broken.
///
/// The core verifies the chains ([CoreClient.chainStatus]); this screen reads
/// that every [every], so a pull that fills a gap while it is open moves the
/// row. It shows nothing else of the other phones' events, and writes
/// nothing.
///
/// Opened from the PRO's home, so it is not a race-time route. It is still
/// held to the bar, because it is reachable from the role home.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key, required this.core, this.every = const Duration(seconds: 5)});

  final CoreClient core;

  /// How often the core is asked.
  final Duration every;

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  ChainStatus? _status;
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
      final status = await widget.core.chainStatus();
      if (mounted && (status != _status || _unreadable)) {
        setState(() {
          _status = status;
          _unreadable = false;
        });
      }
    } catch (_) {
      // A read that fails after one that worked leaves what it showed.
      if (mounted && _status == null) setState(() => _unreadable = true);
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
    final status = _status;
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
          child: Text('Committee log', style: theme.titleLarge),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Bars.screenGutterDp),
          children: [
            if (status?.ownBreak case final own?) _OwnChainBroken(own),
            if (_unreadable) const _Banner(['The log on this phone could not be read']),
            if (status == null && !_unreadable) const Text('Reading the log…'),
            if (status != null && status.devices.isEmpty)
              Text("No other phone's events on this phone yet.", style: theme.bodyLarge),
            if (status != null)
              for (final day in _byRaceDay(status.devices)) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Semantics(
                    header: true,
                    child: Text(day.first.raceDayName ?? 'Unnamed race day', style: theme.titleLarge),
                  ),
                ),
                for (final d in day) _DeviceRow(key: ValueKey('chain-${d.eventId}-${d.deviceId}'), chain: d),
                const SizedBox(height: 16),
              ],
          ],
        ),
      ),
    );
  }
}

/// [devices] in runs of one race day each, in the core's order.
List<List<DeviceChain>> _byRaceDay(List<DeviceChain> devices) {
  final days = <List<DeviceChain>>[];
  for (final d in devices) {
    if (days.isEmpty || days.last.first.eventId != d.eventId) days.add([]);
    days.last.add(d);
  }
  return days;
}

/// What a row's status says, its first line: the worst that applies.
String chainStateText(DeviceChain d) => switch (d.state) {
      DeviceChainStates.altered => 'Altered',
      DeviceChainStates.catchingUp => 'Catching up',
      DeviceChainStates.refused => 'Refused at ${[for (final r in d.refusals) r.seq].join(', ')}',
      DeviceChainStates.verified => 'Verified',
      _ => d.state,
    };

/// Each status has a shape of its own, so none is told from another by
/// colour alone (#67 criterion 6).
IconData chainStateIcon(String state) => switch (state) {
      DeviceChainStates.altered => Icons.warning,
      DeviceChainStates.catchingUp => Icons.hourglass_bottom,
      DeviceChainStates.refused => Icons.block,
      _ => Icons.check_circle,
    };

/// Which phone a row is: the role and station its latest event carries, and
/// the end of its device id, since two phones may hold one role.
String chainPhoneText(DeviceChain d) {
  final id = d.deviceId.length > 4 ? d.deviceId.substring(d.deviceId.length - 4) : d.deviceId;
  final role = d.role;
  final mark = d.mark;
  if (role == null) return 'Phone …$id';
  return '${roleName(role)}${mark == null ? '' : ' at ${markName(mark)}'} · phone …$id';
}

/// A refusal's category in words (append_event's reasons, #48).
String refusalReasonText(String reason) => switch (reason) {
      'not_admitted' => 'not admitted',
      'revoked' => 'revoked',
      'inconsistent_canonical' => 'inconsistent text',
      'ulid_conflict' => 'another text under its ULID',
      _ => reason,
    };

String _event(ChainPoint p) =>
    p.deviceTs == null ? 'event ${p.seq} (refused)' : 'event ${p.seq}, logged ${clockText(p.deviceTs!)}';

/// What a broken chain's lines say: its first bad event, and the one before
/// it, which may be the one changed instead (docs/event-chain.md).
List<String> _breakLines(ChainBreak b) => [
      'First bad event: ${_event(b.at)}',
      if (b.afterSeq != null) 'Event ${b.afterSeq}, before it, may be the one changed',
    ];

/// The lines under a row's status: what the status rests on, and every
/// refusal whatever the status.
List<String> chainDetailLines(DeviceChain d) {
  final b = d.breakAt;
  final v = d.lastVerified;
  final range = d.first == d.last ? 'Event ${d.first}' : 'Events ${d.first} to ${d.last}';
  return [
    if (d.state == DeviceChainStates.altered && b != null) ..._breakLines(b),
    if (d.state == DeviceChainStates.catchingUp) ...[
      '${d.missing} ${d.missing == 1 ? 'event' : 'events'} missing',
      if (v != null) 'Verified to ${_event(v)}',
    ],
    if (d.state == DeviceChainStates.refused || d.state == DeviceChainStates.verified) '$range, every link holds',
    for (final r in d.refusals) 'Event ${r.seq} refused: ${refusalReasonText(r.reason)}',
  ];
}

/// A row as a screen reader says it: its status, its phone, then each line.
String spokenChain(DeviceChain d) => [chainStateText(d), chainPhoneText(d), ...chainDetailLines(d)].join('. ');

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({super.key, required this.chain});

  final DeviceChain chain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final altered = chain.state == DeviceChainStates.altered;
    final fg = altered ? SunlightTokens.onDanger : SunlightTokens.text;
    final muted = altered ? SunlightTokens.onDanger : SunlightTokens.mutedText;
    // One node per phone for a screen reader, read with what each line means.
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: spokenChain(chain),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: altered ? SunlightTokens.danger : SunlightTokens.background,
          border: const Border(bottom: BorderSide(color: SunlightTokens.disabled)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(chainStateIcon(chain.state), size: 32, color: fg, key: ValueKey('chain-icon-${chain.state}')),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The status is what the row is for, so it is the largest line. At the theme's
                  // titleMedium it drew smaller than the phone's name (the emulator render, #67).
                  Text(chainStateText(chain), style: theme.titleLarge?.copyWith(color: fg)),
                  Text(chainPhoneText(chain), style: theme.bodyLarge?.copyWith(color: fg, fontWeight: FontWeight.w700)),
                  for (final line in chainDetailLines(chain)) Text(line, style: theme.bodyLarge?.copyWith(color: muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// This phone's own chain is broken (#67 criterion 5): what the phone itself
/// holds was changed after it was written.
class _OwnChainBroken extends StatelessWidget {
  const _OwnChainBroken(this.at);

  final ChainBreak at;

  @override
  Widget build(BuildContext context) =>
      _Banner(["This phone's log has been altered", ..._breakLines(at)], key: const ValueKey('own-chain-broken'));
}

class _Banner extends StatelessWidget {
  const _Banner(this.lines, {super.key});

  final List<String> lines;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Container(
          width: double.infinity,
          color: SunlightTokens.danger,
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning, size: 32, color: SunlightTokens.onDanger),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < lines.length; i++)
                      Text(
                        lines[i],
                        style: TextStyle(
                          color: SunlightTokens.onDanger,
                          fontSize: i == 0 ? 22 : 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}
