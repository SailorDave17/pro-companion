import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../roles/roles.dart';
import '../ui/bars.dart';
import '../ui/fit_label.dart';
import '../ui/sunlight.dart';

/// The join screen (#71): a volunteer handed a phone and a role's admission
/// code enters the code and lands on that role's home. The core does the
/// admitting ([CoreClient.join]: sign-in by device handoff, the race day from
/// the code, `admit_device`, the admission cached with its role-change marker)
/// and answers with what the code granted. This screen then shows the role
/// and race area granted, and one tap logs the role pick and opens the home
/// (owner decision at pickup, 2026-10-31: shown first, opened on a tap).
///
/// Three answers the screen tells apart by the core's code, never its text:
/// - a refusal (`join_refused`): one plain sentence, naming no role, race area
///   or event, and the code stays in the field to be corrected;
/// - no signal (`no_signal`): the code is kept and sent again every
///   [retryEvery] until the server answers, with no second entry;
/// - anything else: a sentence saying so, and JOIN tries again on a tap.
///
/// Set-up, not a race-time route, so no race-time action is registered; it is
/// still held to the bar because the picker reaches it in one tap.
class JoinScreen extends StatefulWidget {
  const JoinScreen({
    super.key,
    required this.core,
    required this.confirmation,
    this.retryEvery = const Duration(seconds: 5),
  });

  final CoreClient core;
  final ConfirmationService confirmation;

  /// How often a code kept for want of signal is sent again.
  final Duration retryEvery;

  /// What the field says while empty: the shape the owner script prints.
  static const codeHint = 'XXXX-XXXX';

  static const needsSignal = 'Admission needs signal. The code is kept and will be sent when the phone reconnects.';
  static const noServer = 'This build has no server to join through.';

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

/// Keeps the field to the code's shape: Crockford's letters and digits,
/// upper-cased as typed (the server hashes the code exactly as sent), a dash
/// after the first four so a wet thumb never hunts for one, nine characters
/// at most.
class CodeFormatter extends TextInputFormatter {
  const CodeFormatter();

  static String format(String raw) {
    final chars = raw.toUpperCase().replaceAll(RegExp('[^0-9A-Z]'), '');
    final kept = chars.length > 8 ? chars.substring(0, 8) : chars;
    return kept.length > 4 ? '${kept.substring(0, 4)}-${kept.substring(4)}' : kept;
  }

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final text = format(newValue.text);
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}

class _JoinScreenState extends State<JoinScreen> {
  final _code = TextEditingController();

  /// What the code granted, once the core admitted the phone.
  Admission? _granted;

  /// The sentence on the danger banner: a refusal, a failure, or no server.
  String? _problem;

  /// True while a code is kept for want of signal and sent again on [_retry].
  bool _waitingForSignal = false;
  Timer? _retry;

  /// A join or the pick is on its way: a second tap is the same tap.
  bool _busy = false;

  /// The pick that opens the home did not log.
  bool _notLogged = false;

  @override
  void initState() {
    super.initState();
    _code.addListener(() {
      // A new entry is a new attempt: a kept code's retry stops, a refusal's
      // sentence clears, and JOIN enables as soon as there is something to send.
      if (!_busy && (_waitingForSignal || _problem != null)) {
        _stopRetry();
        setState(() {
          _waitingForSignal = false;
          _problem = null;
        });
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _stopRetry();
    _code.dispose();
    super.dispose();
  }

  void _stopRetry() {
    _retry?.cancel();
    _retry = null;
  }

  void _startRetry() {
    _retry ??= Timer.periodic(widget.retryEvery, (_) {
      if (!_busy && _waitingForSignal && _code.text.isNotEmpty) _join();
    });
  }

  Future<void> _join() async {
    final code = _code.text.trim();
    if (code.isEmpty || _busy || _granted != null) return;
    _busy = true;
    setState(() => _problem = null);
    try {
      final granted = await widget.core.join(code);
      if (!mounted) return;
      _stopRetry();
      setState(() {
        _granted = granted;
        _waitingForSignal = false;
      });
    } on CoreException catch (e) {
      if (!mounted) return;
      setState(() {
        switch (e.code) {
          case JoinCodes.noSignal:
            _waitingForSignal = true;
            _startRetry();
          case JoinCodes.refused:
            _stopRetry();
            _waitingForSignal = false;
            _problem = e.message;
          case JoinCodes.noServer:
            _stopRetry();
            _waitingForSignal = false;
            _problem = JoinScreen.noServer;
          default:
            _stopRetry();
            _waitingForSignal = false;
            _problem = 'Could not join. ${e.message}';
        }
      });
    } catch (_) {
      if (!mounted) return;
      _stopRetry();
      setState(() {
        _waitingForSignal = false;
        _problem = 'Could not join. Tap JOIN to try again.';
      });
    } finally {
      _busy = false;
    }
  }

  /// Logs the role the code granted, with the buzz and beep a pick gets
  /// (#20), and hands the pick back to the role gate, which opens the home.
  Future<void> _open() async {
    final granted = _granted;
    if (granted == null || _busy) return;
    _busy = true;
    try {
      final stored = await widget.confirmation.confirm(() => widget.core.append(RoleEvents.assign(granted.role)));
      if (!mounted) return;
      Navigator.of(context).pop(stored);
    } catch (_) {
      if (mounted) setState(() => _notLogged = true);
    } finally {
      _busy = false;
    }
  }

  Widget _banner(String text, {required Color color, required Color onColor, Key? key}) => Semantics(
        liveRegion: true,
        child: Container(
          key: key,
          width: double.infinity,
          color: color,
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.only(bottom: 12),
          child: Text(text, style: TextStyle(color: onColor, fontSize: 22, fontWeight: FontWeight.w700)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final granted = _granted;
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
        title: Text('Join with a code', style: text.titleLarge),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Bars.screenGutterDp),
          children: granted == null ? _entry(text) : _grant(text, granted),
        ),
      ),
    );
  }

  /// Before admission: the code, JOIN, and what the last attempt said.
  List<Widget> _entry(TextTheme text) => [
        Text('Enter the code the PRO gave you.', style: text.bodyLarge),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('join-code'),
          controller: _code,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          keyboardType: TextInputType.visiblePassword,
          inputFormatters: const [CodeFormatter()],
          textInputAction: TextInputAction.done,
          style: const TextStyle(fontSize: 28, letterSpacing: 2, fontWeight: FontWeight.w700),
          decoration: const InputDecoration(
            labelText: 'Admission code',
            hintText: JoinScreen.codeHint,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 22),
          ),
          onSubmitted: (_) => _join(),
        ),
        const SizedBox(height: 12),
        if (_waitingForSignal)
          _banner(JoinScreen.needsSignal,
              key: const ValueKey('needs-signal'), color: SunlightTokens.surface, onColor: SunlightTokens.onSurface),
        if (_problem != null)
          _banner(_problem!, key: const ValueKey('join-problem'), color: SunlightTokens.danger, onColor: SunlightTokens.onDanger),
        SizedBox(
          width: double.infinity,
          height: Bars.minTargetDp + 8,
          child: FilledButton(
            key: const ValueKey('join'),
            onPressed: _code.text.trim().isEmpty || _busy ? null : _join,
            child: FitLabel(_busy ? 'JOINING…' : 'JOIN'),
          ),
        ),
      ];

  /// After admission: what the code granted, and one tap to open the home.
  List<Widget> _grant(TextTheme text, Admission granted) => [
        Semantics(
          header: true,
          child: Text('Admitted as', style: text.titleLarge),
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(roleName(granted.role), key: const ValueKey('granted-role'), style: text.headlineMedium),
        ),
        const SizedBox(height: 8),
        Text(
          granted.raceArea == null ? 'Whole event' : 'Race area: ${granted.raceArea}',
          key: const ValueKey('granted-race-area'),
          style: text.titleLarge,
        ),
        const SizedBox(height: 24),
        if (_notLogged)
          _banner('Not logged. Tap again.', color: SunlightTokens.danger, onColor: SunlightTokens.onDanger),
        SizedBox(
          width: double.infinity,
          height: 96,
          child: FilledButton(
            key: const ValueKey('open-home'),
            onPressed: _open,
            child: FitLabel('OPEN ${roleName(granted.role).toUpperCase()} HOME'),
          ),
        ),
      ];
}
