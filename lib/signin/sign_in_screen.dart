import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pro_companion_core/core.dart';

import '../confirmation.dart';
import '../join/join_screen.dart';
import '../ui/bars.dart';
import '../ui/fit_label.dart';
import '../ui/sunlight.dart';

/// The sign-in screen (#104): a named volunteer signs the phone in by their
/// email's magic link, so their own account holds the phone's admission
/// (groom decision G39), rather than an anonymous sign-in.
///
/// Three steps, each its own state:
/// - the address, and SEND LINK ([CoreClient.requestSignInLink]); once the
///   server has taken it, the screen says to open the link on this phone,
///   since only this phone holds the request's verifier;
/// - the link, handed in by the role gate when it opens the app
///   ([opening], or later on [links]), exchanged for the volunteer's session
///   ([CoreClient.completeSignInLink]);
/// - signed in: ENTER ROLE CODE opens the join screen (#71), whose `join`
///   now admits the phone under the volunteer's account. Its role pick comes
///   back through here to the role gate, which opens that role's home.
///
/// Every answer is told apart by the core's code, never its text. Set-up, not
/// a race-time route, so no race-time action is registered; it is held to the
/// bar because the picker reaches it in one tap.
class SignInScreen extends StatefulWidget {
  const SignInScreen({
    super.key,
    required this.core,
    required this.confirmation,
    this.links = const Stream.empty(),
    this.opening,
  });

  final CoreClient core;
  final ConfirmationService confirmation;

  /// The magic links that open the app while this screen shows.
  final Stream<SignInLink> links;

  /// The link that opened the app, or this screen, when one did.
  final SignInLink? opening;

  static const needsSignal = 'Sign-in needs signal. Try again when the phone has signal.';
  static const noServer = 'This build has no server to sign in through.';
  static const alreadySignedIn = 'This phone is already signed in. Enter the code the PRO gave you.';
  static const badLink = 'That link could not sign you in. Ask for a new one.';
  static const expiredLink = 'That link has expired. Ask for a new one.';

  /// What the screen says once the link is on its way to [email].
  static String sentTo(String email) => 'We sent a link to $email. Open it on this phone.';

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  StreamSubscription<SignInLink>? _links;

  /// The address the newest link went to, once the server took the request.
  String? _sentTo;

  /// The account the phone is signed in as, once a link signed it in, or
  /// true in [_alreadySignedIn] for a phone that already held a session.
  String? _signedInAs;
  bool _alreadySignedIn = false;

  /// A link kept for want of signal, opened again on TRY AGAIN.
  SignInLink? _keptLink;

  /// The sentence on the danger banner.
  String? _problem;

  /// A request or a link is on its way: a second tap is the same tap.
  /// [_opening] says it is a link.
  bool _busy = false;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _email.addListener(() => setState(() {}));
    _links = widget.links.listen(_open);
    final opening = widget.opening;
    if (opening != null) scheduleMicrotask(() => _open(opening));
  }

  @override
  void dispose() {
    _links?.cancel();
    _email.dispose();
    super.dispose();
  }

  bool get _signedIn => _signedInAs != null || _alreadySignedIn;

  Future<void> _send() async {
    final email = _email.text.trim();
    if (email.isEmpty || _busy || _signedIn) return;
    _busy = true;
    setState(() => _problem = null);
    try {
      await widget.core.requestSignInLink(email);
      if (mounted) setState(() => _sentTo = email);
    } on CoreException catch (e) {
      if (mounted) setState(() => _fail(e));
    } catch (_) {
      if (mounted) setState(() => _problem = 'Could not send a link. Tap SEND LINK to try again.');
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  /// Opens [link]: an error the server's verify step sent is said plainly,
  /// and a code is exchanged for the volunteer's session.
  Future<void> _open(SignInLink link) async {
    if (_busy || _signedIn || !mounted) return;
    final code = link.code;
    if (code == null) {
      setState(() => _problem = link.errorCode == 'otp_expired' ? SignInScreen.expiredLink : SignInScreen.badLink);
      return;
    }
    _busy = true;
    setState(() {
      _opening = true;
      _problem = null;
      _keptLink = null;
    });
    try {
      final email = await widget.core.completeSignInLink(code);
      if (mounted) setState(() => _signedInAs = email);
    } on CoreException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.code == SignInCodes.noSignal) _keptLink = link;
        _fail(e);
      });
    } catch (_) {
      if (mounted) setState(() => _problem = SignInScreen.badLink);
    } finally {
      _busy = false;
      _opening = false;
      if (mounted) setState(() {});
    }
  }

  void _fail(CoreException e) {
    switch (e.code) {
      case SignInCodes.signedIn:
        _alreadySignedIn = true;
        _problem = null;
      case SignInCodes.refused:
        _problem = e.message;
      case SignInCodes.noSignal:
        _problem = SignInScreen.needsSignal;
      case SignInCodes.noServer:
        _problem = SignInScreen.noServer;
      default:
        _problem = 'Could not sign in. ${e.message}';
    }
  }

  /// ENTER ROLE CODE: the join screen admits the phone under the session it
  /// now holds, and its role pick is handed back to the role gate.
  Future<void> _enterCode() async {
    final result = await Navigator.of(context).push<Object?>(MaterialPageRoute(
      builder: (_) => JoinScreen(core: widget.core, confirmation: widget.confirmation),
    ));
    if (mounted && result is EventEnvelope) Navigator.of(context).pop(result);
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

  Widget _action(String label, {required Key key, required VoidCallback? onPressed, bool filled = true, double? height}) =>
      SizedBox(
        width: double.infinity,
        height: height ?? Bars.minTargetDp + 8,
        child: filled
            ? FilledButton(key: key, onPressed: onPressed, child: FitLabel(label))
            : OutlinedButton(key: key, onPressed: onPressed, child: FitLabel(label)),
      );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
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
        title: Text('Sign in by email', style: text.titleLarge),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Bars.screenGutterDp),
          children: _signedIn ? _signedInView(text) : _entry(text),
        ),
      ),
    );
  }

  /// Before sign-in: the address, SEND LINK, and what the last attempt said.
  List<Widget> _entry(TextTheme text) {
    final sentTo = _sentTo;
    return [
      Text('Enter your email address. We will send you a link to sign in on this phone.', style: text.bodyLarge),
      const SizedBox(height: 16),
      TextField(
        key: const ValueKey('sign-in-email'),
        controller: _email,
        enabled: !_busy,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.email],
        textInputAction: TextInputAction.send,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        decoration: const InputDecoration(
          labelText: 'Email address',
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 22),
        ),
        onSubmitted: (_) => _send(),
      ),
      const SizedBox(height: 12),
      if (sentTo != null && _problem == null)
        _banner(SignInScreen.sentTo(sentTo),
            key: const ValueKey('link-sent'), color: SunlightTokens.surface, onColor: SunlightTokens.onSurface),
      if (_problem != null)
        _banner(_problem!, key: const ValueKey('sign-in-problem'), color: SunlightTokens.danger, onColor: SunlightTokens.onDanger),
      if (_keptLink != null) ...[
        _action('TRY AGAIN', key: const ValueKey('try-link-again'), onPressed: _busy ? null : () => _open(_keptLink!)),
        const SizedBox(height: 12),
      ],
      _action(
        _busy ? (_opening ? 'SIGNING IN…' : 'SENDING…') : (sentTo == null ? 'SEND LINK' : 'SEND A NEW LINK'),
        key: const ValueKey('send-link'),
        filled: sentTo == null,
        onPressed: _email.text.trim().isEmpty || _busy ? null : _send,
      ),
    ];
  }

  /// Signed in: who as, and one tap to the join screen for the role's code.
  List<Widget> _signedInView(TextTheme text) {
    final email = _signedInAs;
    return [
      if (email != null) ...[
        Semantics(header: true, child: Text('Signed in as', style: text.titleLarge)),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(email, key: const ValueKey('signed-in-as'), style: text.headlineSmall),
        ),
        const SizedBox(height: 16),
        Text('Now enter the code the PRO gave you.', style: text.bodyLarge),
      ] else
        _banner(SignInScreen.alreadySignedIn,
            key: const ValueKey('already-signed-in'), color: SunlightTokens.surface, onColor: SunlightTokens.onSurface),
      const SizedBox(height: 24),
      _action('ENTER ROLE CODE', key: const ValueKey('enter-role-code'), onPressed: _enterCode, height: 96),
    ];
  }
}
