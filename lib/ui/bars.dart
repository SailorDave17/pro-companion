/// The wet-hands bar every race-time screen is held to (groom decision G3).
///
/// Ratified 2026-09-23 and pending confirmation or adjustment in amended #8's
/// on-water session. docs/usability-bars.md states the same numbers and says
/// why; a test holds the two together, so one cannot change alone.
abstract final class Bars {
  /// Smallest interactive target, in dp, both ways.
  static const double minTargetDp = 64;

  /// Smallest text-to-background contrast ratio (WCAG's AAA level).
  static const double minTextContrast = 7.0;

  /// A primary race-time action spans the screen but for this margin a side.
  static const double screenGutterDp = 16;

  /// Taps from the role home to any screen-level race-time action, the
  /// action's own tap included. An item's own corrections count from the
  /// item (owner decision 2026-09-24, #4).
  static const int maxTapsFromRoleHome = 2;
}
