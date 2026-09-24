import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/ui/bars.dart';
import 'package:pro_companion/ui/race_time.dart';
import 'package:pro_companion/ui/sunlight.dart';

/// The shared bar-check helper (#4 criterion 2): holds a flow of screens to
/// the wet-hands bar (groom decision G3, docs/usability-bars.md).
///
/// It explores the app the way a thumb would. From the role home it taps
/// every tappable thing, then every tappable thing on each screen that
/// opens, up to [Bars.maxTapsFromRoleHome] taps deep, rebuilding the app fresh
/// for every path. On every screen it reaches, it checks:
///
///   * every interactive target is at least [Bars.minTargetDp] both ways
///     (Flutter's MinimumTapTargetGuideline at 64dp. Its blind spot: it skips
///     a target touching the screen edge or a scrollable's edge);
///   * no button's label is clipped or breaks a word - run it at 200% text
///     as well as 100% to mean anything;
///   * every primary race-time action spans the screen but for the gutters;
///   * no action hides behind a swipe (Dismissible, Draggable, drag handlers);
///   * the screen renders in the sunlight tokens;
///   * no dialog, sheet or menu was opened (a PopupRoute), and none is showing.
///
/// Across the whole exploration it checks that every race-time action in
/// [actionIds] can be reached within the tap limit, its own tap included. An
/// item's own corrections may take one tap more, to select the item (owner
/// decision 2026-09-24).
///
/// [buildApp] must return a fresh app, with a fresh fake core, every call.
/// Returns the violations found; an empty list is a pass.
Future<List<String>> barCheck(
  WidgetTester tester,
  Widget Function(NavigatorObserver observer) buildApp, {
  Set<String> actionIds = raceTimeActionIds,
  int maxTaps = Bars.maxTapsFromRoleHome,
}) async {
  setPhoneSize(tester);
  final semantics = tester.ensureSemantics();
  final violations = <String>{};
  final reachedAt = <String, int>{}; // action id -> fewest taps to see it
  final itemScoped = <String>{};

  Future<void> build(List<int> path, _PopupObserver observer) async {
    await tester.pumpWidget(const SizedBox.shrink()); // a fresh Navigator every time
    await tester.pumpWidget(KeyedSubtree(key: UniqueKey(), child: buildApp(observer)));
    await tester.pumpAndSettle();
    for (final i in path) {
      final targets = _tappable(tester);
      tester.semantics.tap(targets.at(i));
      await tester.pumpAndSettle();
    }
  }

  Future<void> visit(List<int> path) async {
    final observer = _PopupObserver();
    await build(path, observer);
    final where = path.isEmpty ? 'role home' : 'after taps $path';

    for (final popup in observer.popups) {
      violations.add('$where: opened a ${popup.runtimeType} - no dialog, sheet or confirm prompt on a race-time route');
    }
    for (final type in const [AlertDialog, Dialog, SimpleDialog, BottomSheet]) {
      if (find.byType(type).evaluate().isNotEmpty) violations.add('$where: a $type is showing');
    }

    final targets = await const MinimumTapTargetGuideline(
      size: Size.square(Bars.minTargetDp),
      link: 'docs/usability-bars.md',
    ).evaluate(tester);
    if (!targets.passed) violations.add('$where: target below ${Bars.minTargetDp}dp - ${targets.reason}');
    for (final clipped in clippedLabels(tester)) {
      violations.add('$where: $clipped');
    }

    final screenWidth = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    for (final element in find.byType(RaceTimeAction).hitTestable().evaluate()) {
      final action = element.widget as RaceTimeAction;
      final seen = reachedAt[action.id];
      if (seen == null || path.length < seen) reachedAt[action.id] = path.length;
      if (action.itemScoped) itemScoped.add(action.id);
      if (action.primary) {
        final width = tester.getSize(find.byElementPredicate((e) => e == element)).width;
        final needed = screenWidth - 2 * Bars.screenGutterDp;
        if (width < needed - 0.5) {
          violations.add('$where: primary action "${action.id}" is ${width.toStringAsFixed(1)}dp wide, '
              'narrower than the full width ${needed.toStringAsFixed(1)}dp');
        }
      }
    }

    if (find.byType(Dismissible).evaluate().isNotEmpty) violations.add('$where: a Dismissible - an action behind a swipe');
    if (find.byWidgetPredicate((w) => w is Draggable || w is LongPressDraggable).evaluate().isNotEmpty) {
      violations.add('$where: a Draggable - an action behind a drag');
    }
    final swipers = find.byWidgetPredicate((w) =>
        w is GestureDetector &&
        (w.onHorizontalDragEnd != null ||
            w.onHorizontalDragUpdate != null ||
            w.onVerticalDragEnd != null ||
            w.onVerticalDragUpdate != null ||
            w.onPanEnd != null ||
            w.onPanUpdate != null));
    if (swipers.evaluate().isNotEmpty) violations.add('$where: a GestureDetector with drag handlers - an action behind a swipe');

    final scaffolds = find.byType(Scaffold).hitTestable().evaluate();
    if (scaffolds.isEmpty) {
      violations.add('$where: no Scaffold on screen to check the theme of');
    } else if (!usesSunlightTokens(Theme.of(scaffolds.last))) {
      violations.add('$where: the screen does not render in the sunlight tokens');
    }

    if (path.length < maxTaps) {
      final count = _tappable(tester).evaluate().length;
      for (var i = 0; i < count; i++) {
        await visit([...path, i]);
      }
    }
  }

  await visit(const []);

  for (final id in actionIds) {
    final allowed = maxTaps - 1 + (itemScoped.contains(id) ? 1 : 0);
    final reached = reachedAt[id];
    if (reached == null) {
      violations.add('race-time action "$id" was not reached within $maxTaps taps of the role home');
    } else if (reached > allowed) {
      violations.add('race-time action "$id" needs ${reached + 1} taps from the role home; the limit is '
          '${allowed + 1}${itemScoped.contains(id) ? ' for an item correction' : ''}');
    }
  }

  semantics.dispose();
  await tester.pumpWidget(const SizedBox.shrink());
  return violations.toList();
}

/// Labels on buttons that do not fit: a word broken across lines ("Canc/el")
/// or text taller than its button (clipped). Found by rendering the finish
/// screen at 200% text, where every other check passed (#4).
List<String> clippedLabels(WidgetTester tester) {
  final found = <String>[];
  for (final button in find.byWidgetPredicate((w) => w is ButtonStyleButton).hitTestable().evaluate()) {
    void visit(RenderObject r) {
      if (r is RenderParagraph) {
        final text = r.text.toPlainText();
        final width = r.size.width;
        if (r.getMinIntrinsicWidth(double.infinity) > width + 0.5) {
          found.add('"$text" breaks a word: its longest word needs '
              '${r.getMinIntrinsicWidth(double.infinity).toStringAsFixed(0)}dp of ${width.toStringAsFixed(0)}dp');
        } else if (r.getMaxIntrinsicHeight(width) > r.size.height + 0.5) {
          found.add('"$text" is clipped: it needs ${r.getMaxIntrinsicHeight(width).toStringAsFixed(0)}dp '
              'of height and has ${r.size.height.toStringAsFixed(0)}dp');
        }
        return;
      }
      r.visitChildren(visit);
    }

    button.renderObject!.visitChildren(visit);
  }
  return found;
}

/// A mid-size Android phone: 411 x 891 dp.
void setPhoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

SemanticsFinder _tappable(WidgetTester tester) => find.semantics.byPredicate(
      (node) =>
          !node.isMergedIntoParent &&
          node.getSemanticsData().hasAction(SemanticsAction.tap) &&
          !node.getSemanticsData().flagsCollection.isHidden,
      describeMatch: (_) => 'tappable semantics node',
    );

class _PopupObserver extends NavigatorObserver {
  final popups = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) popups.add(route);
  }
}
