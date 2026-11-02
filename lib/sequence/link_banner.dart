import 'package:flutter/material.dart';

import '../ui/sunlight.dart';

/// Says the race-timer link is not active (#33 criterion 9): nothing has come
/// from race-timer for ten minutes, so a gun has to be tapped. It comes and
/// goes every race day, so it has a fixed height, which the start card gives
/// up while it shows, and nothing on the screen moves under a thumb when it
/// does (owner decision on #33). It is information, not an error, so it is not
/// the danger colour, which means "Not logged". An icon carries it as well as
/// the shading, and there is nothing to tap.
class LinkBanner extends StatelessWidget {
  const LinkBanner({super.key});

  static const height = 32.0;
  static const text = 'race-timer link not active';

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: text,
      excludeSemantics: true,
      child: Container(
        key: const ValueKey('link-banner'),
        height: height,
        width: double.infinity,
        color: SunlightTokens.surface,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        // One line at any text size: wrapped, it would take the card's room.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link_off, size: 20, color: SunlightTokens.onSurface),
              const SizedBox(width: 8),
              const Text(text,
                  maxLines: 1,
                  style: TextStyle(color: SunlightTokens.onSurface, fontSize: 18, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}
