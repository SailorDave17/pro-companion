import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_companion_core/core.dart';

import '../ui/bars.dart';
import '../ui/sunlight.dart';

/// Puts the revoked banner (#53) above every screen, from the app shell, so
/// a volunteer logging on FINISHES sees it as soon as it is true. It reads
/// [CoreClient.revocation] at once and then every [every], since sync learns
/// of a revocation in the core, from the refusal of a tap's upload, and tells
/// nobody.
///
/// It blocks nothing. The screens under it work as before, and what they log
/// stays on the phone. With no revocation there is no banner and nothing
/// moves. A banner that appears mid-race leaves the open screen open, and
/// moves everything on it down by the banner's height, once: a tap aimed at a
/// top-anchored target at that moment lands on the row above. The owner
/// accepted that at #53's review, since it happens once per phone per race
/// day, and only on a phone whose taps no longer count.
class RevokedFrame extends StatefulWidget {
  const RevokedFrame({super.key, required this.core, required this.child, this.every = const Duration(seconds: 5)});

  final CoreClient core;

  /// The app's navigator: every screen.
  final Widget child;

  /// How often the core is asked.
  final Duration every;

  @override
  State<RevokedFrame> createState() => _RevokedFrameState();
}

class _RevokedFrameState extends State<RevokedFrame> {
  Revocation? _revocation;
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
      final revocation = await widget.core.revocation();
      if (mounted && revocation != _revocation) setState(() => _revocation = revocation);
    } catch (_) {
      // A read that failed changes nothing: the banner stays as last read.
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
    final revocation = _revocation;
    final media = MediaQuery.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Always two children, so the screens below never move in the tree. A move
        // would not close them either: WidgetsApp keys its Navigator globally, so
        // it is reparented with its routes (measured on #53: a frame that moved
        // the Navigator when the banner came left FINISHES open).
        revocation == null
            ? const SizedBox.shrink()
            : RevokedBanner(revocation: revocation, topInset: media.padding.top),
        Expanded(
          // A semantics container of its own, so a BlockSemantics in a route
          // drops only what that route paints over, never the banner.
          child: Semantics(
            container: true,
            child: MediaQuery(
              // The banner takes the status bar's inset, so the screen below starts under it.
              data: revocation == null ? media : media.removePadding(removeTop: true),
              child: widget.child,
            ),
          ),
        ),
      ],
    );
  }
}

/// The banner itself: which race day removed this phone, and what that means
/// for the volunteer holding it. It has nothing to tap.
class RevokedBanner extends StatelessWidget {
  const RevokedBanner({super.key, required this.revocation, this.topInset = 0});

  final Revocation revocation;

  /// The status bar's height, which the banner sits under.
  final double topInset;

  /// The first line: the race day by name, or plainly when sync never read
  /// its name.
  static String title(Revocation r) => 'Removed from ${r.eventName ?? 'this race day'}';

  static const detail = 'Taps stay on this phone, unsent. Hand it in.';

  /// The smallest font size a line is drawn at, whatever the phone's text
  /// size. A line that would need to be smaller is drawn at this size and cut
  /// with an ellipsis instead; a screen reader still reads it whole (owner's
  /// choice at #53's review). Shrunk with no floor, a 69-character title drew
  /// 15 dp tall on the emulator, and 200% text gained nothing.
  static const minFontSize = 16.0;

  @override
  Widget build(BuildContext context) {
    // One node, both lines in it, announced as it appears.
    return MergeSemantics(
      key: const ValueKey('revoked-banner'),
      child: Semantics(
        liveRegion: true,
        // Light status-bar icons over the red: a screen's AppBar left them
        // dark, about 2:1 against it (the review of #53).
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: Material(
            color: SunlightTokens.danger,
            child: Padding(
              padding: EdgeInsets.fromLTRB(Bars.screenGutterDp, 8 + topInset, Bars.screenGutterDp, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _line(title(revocation), const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  _line(detail, const TextStyle(fontSize: 18)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// One line, never wrapped: at 200% text, wrapped lines took the room the
  /// PRO home's SEQUENCE and FINISHES need, and pushed them below the fold
  /// (the bar check, #53), as the home's own headings did on #25. It is
  /// drawn at the phone's text size when it fits, shrunk to fit when it does
  /// not, and cut at [minFontSize] when even that does not fit.
  static Widget _line(String text, TextStyle style) => LayoutBuilder(
    builder: (context, constraints) {
      final full = DefaultTextStyle.of(context).style
          .merge(style)
          .copyWith(color: SunlightTokens.onDanger, fontSize: MediaQuery.textScalerOf(context).scale(style.fontSize!));
      double widthAt(double size) {
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: full.copyWith(fontSize: size),
          ),
          textDirection: Directionality.of(context),
          maxLines: 1,
        )..layout();
        final width = painter.width;
        painter.dispose();
        return width;
      }

      // Width is not linear in font size: letter spacing stays the same
      // number of pixels at any size. Scaling once by the overflow left
      // "Hand it in." cut at 200% on the emulator, so each step measures again,
      // down to the floor. Half a pixel spare keeps rounding from cutting a
      // line that fits.
      final room = constraints.maxWidth - 0.5;
      var size = full.fontSize!;
      for (var width = widthAt(size), step = 0; width > room && size > minFontSize && step < 6; step++) {
        size = math.max(minFontSize, size * room / width);
        width = widthAt(size);
      }
      return Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        textScaler: TextScaler.noScaling,
        style: full.copyWith(fontSize: size),
      );
    },
  );
}
