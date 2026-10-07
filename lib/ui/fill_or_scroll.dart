import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'bars.dart';

/// A screen's column, inside the screen gutter, that fills the screen with
/// [children] spread down it, equal space between each, and scrolls rather
/// than overflowing when they are taller than the screen. A role home or the
/// role picker with "Not logged" up overflowed a short phone (#20).
///
/// Each child is a group; a [SizedBox.shrink] at either end leaves a share of
/// the space there, as a [Spacer] would. It sizes by the children's real
/// layout, never their intrinsic height: a line shrunk to fit at 200% text
/// reports its unshrunk height, and measured that way the PRO's home came out
/// 25 dp taller than what it drew on a 320 x 640 phone.
///
/// The gutter is inside the scrollable, so no target touches its edge, where
/// the tap-target guideline skips one (docs/usability-bars.md).
class FillOrScroll extends StatelessWidget {
  const FillOrScroll({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.all(Bars.screenGutterDp),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: math.max(0, constraints.maxHeight - 2 * Bars.screenGutterDp)),
            child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: children),
          ),
        ),
      );
}
