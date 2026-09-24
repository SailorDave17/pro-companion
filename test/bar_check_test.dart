import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/ui/race_time.dart';
import 'package:pro_companion/ui/sunlight.dart';

import 'support/bar_check.dart';

/// #4 criterion 2: the bar-check helper catches each kind of violation, each
/// proven by a planted one, and passes a screen that meets the bar. The
/// control matters as much as the plants - a helper that failed everything
/// would pass every planted test.
void main() {
  const ids = {'finish'};

  /// A role home with one big button, opening one race-time screen.
  Widget miniApp(
    NavigatorObserver observer, {
    required Widget Function(BuildContext) screen,
    ThemeData? screenTheme,
  }) =>
      MaterialApp(
        theme: sunlightTheme(),
        navigatorObservers: [observer],
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  height: 96,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (c) => screenTheme == null ? screen(c) : Theme(data: screenTheme, child: screen(c)),
                    )),
                    child: const Text('OPEN'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Widget fullWidthFinish({VoidCallback? onPressed}) => Padding(
        padding: const EdgeInsets.all(16),
        child: RaceTimeAction(
          id: 'finish',
          primary: true,
          child: SizedBox(
            width: double.infinity,
            height: 120,
            child: FilledButton(onPressed: onPressed ?? () {}, child: const Text('FINISH')),
          ),
        ),
      );

  Widget screen(List<Widget> children) => Scaffold(
        body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: children)),
      );

  testWidgets('control: a screen that meets the bar passes', (tester) async {
    final v = await barCheck(tester, (o) => miniApp(o, screen: (_) => screen([fullWidthFinish()])),
        actionIds: ids);
    expect(v, isEmpty);
  });

  testWidgets('a target below 64dp fails', (tester) async {
    // 56dp: above Android's own 48dp, so only a 64dp bar catches it.
    final v = await barCheck(
      tester,
      (o) => miniApp(o,
          screen: (_) => screen([
                fullWidthFinish(),
                SizedBox(
                  width: 56,
                  height: 56,
                  child: IconButton(
                    onPressed: () {},
                    style: IconButton.styleFrom(minimumSize: const Size.square(56), maximumSize: const Size.square(56)),
                    icon: const Icon(Icons.add),
                  ),
                ),
              ])),
      actionIds: ids,
    );
    expect(v, contains(contains('target below 64')));
  });

  testWidgets('a button label that is clipped or breaks a word fails', (tester) async {
    final v = await barCheck(
      tester,
      (o) => miniApp(o,
          screen: (_) => screen([
                fullWidthFinish(),
                SizedBox(
                  width: 96,
                  height: 64,
                  child: OutlinedButton(
                    onPressed: () {},
                    style: const ButtonStyle(textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 28))),
                    child: const Text('Cancel'),
                  ),
                ),
              ])),
      actionIds: ids,
    );
    expect(v, contains(contains('"Cancel" breaks a word')));
  });

  testWidgets('a primary action narrower than full width fails', (tester) async {
    final v = await barCheck(
      tester,
      (o) => miniApp(o,
          screen: (_) => screen([
                RaceTimeAction(
                  id: 'finish',
                  primary: true,
                  child: SizedBox(width: 200, height: 120, child: FilledButton(onPressed: () {}, child: const Text('FINISH'))),
                ),
              ])),
      actionIds: ids,
    );
    expect(v, contains(contains('narrower than the full width')));
  });

  testWidgets('an action reachable only by swipe fails', (tester) async {
    final v = await barCheck(
      tester,
      (o) => miniApp(o,
          screen: (_) => screen([
                fullWidthFinish(),
                Dismissible(
                  key: const ValueKey('row'),
                  onDismissed: (_) {},
                  child: const SizedBox(height: 80, child: Center(child: Text('swipe to undo'))),
                ),
              ])),
      actionIds: ids,
    );
    expect(v, contains(contains('Dismissible')));
  });

  testWidgets('a drag handler hiding an action fails', (tester) async {
    final v = await barCheck(
      tester,
      (o) => miniApp(o,
          screen: (_) => screen([
                fullWidthFinish(),
                GestureDetector(onHorizontalDragEnd: (_) {}, child: const SizedBox(height: 80, child: Text('swipe'))),
              ])),
      actionIds: ids,
    );
    expect(v, contains(contains('drag handlers')));
  });

  testWidgets('a route missing the sunlight tokens fails', (tester) async {
    final v = await barCheck(
      tester,
      (o) => miniApp(o, screen: (_) => screen([fullWidthFinish()]), screenTheme: ThemeData.light()),
      actionIds: ids,
    );
    expect(v, contains(contains('sunlight tokens')));
  });

  testWidgets('a race-time action more than 2 taps from the role home fails', (tester) async {
    final v = await barCheck(
      tester,
      (o) => miniApp(o,
          screen: (context) => screen([
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 96,
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => screen([fullWidthFinish()]))),
                      child: const Text('DEEPER'),
                    ),
                  ),
                ),
              ])),
      actionIds: ids,
    );
    expect(v, contains(contains('"finish" needs 3 taps from the role home; the limit is 2')));
  });

  testWidgets('an item correction may take one tap more, and only an item correction', (tester) async {
    Widget itemScreen({required bool itemScoped}) => StatefulBuilder(builder: (context, setState) {
          return _ExpandingRow(itemScoped: itemScoped);
        });
    final ok = await barCheck(
      tester,
      (o) => miniApp(o, screen: (_) => screen([fullWidthFinish(), itemScreen(itemScoped: true)])),
      actionIds: {'finish', 'fix'},
    );
    expect(ok, isEmpty, reason: 'an item correction 3 taps deep is within its allowance');
    final bad = await barCheck(
      tester,
      (o) => miniApp(o, screen: (_) => screen([fullWidthFinish(), itemScreen(itemScoped: false)])),
      actionIds: {'finish', 'fix'},
    );
    expect(bad, contains(contains('"fix" needs 3 taps')));
  });

  testWidgets('a dialog on a race-time route fails', (tester) async {
    final v = await barCheck(
      tester,
      (o) => miniApp(o,
          screen: (context) => screen([
                fullWidthFinish(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const AlertDialog(content: Text('Are you sure?')),
                  ),
                ),
              ])),
      actionIds: ids,
    );
    expect(v, contains(contains('opened a DialogRoute')));
  });

  testWidgets('a confirm prompt drawn inline, with no route, fails too', (tester) async {
    // Only the dialog-type scan can see this: nothing is pushed, so the
    // route observer has nothing to report.
    final v = await barCheck(
      tester,
      (o) => miniApp(o,
          screen: (_) => screen([
                fullWidthFinish(),
                const SizedBox(height: 200, child: AlertDialog(content: Text('Log this finish?'))),
              ])),
      actionIds: ids,
    );
    expect(v, contains(contains('a AlertDialog is showing')));
  });
}

/// A row that, once tapped, reveals a "fix" action - an item correction.
class _ExpandingRow extends StatefulWidget {
  const _ExpandingRow({required this.itemScoped});
  final bool itemScoped;

  @override
  State<_ExpandingRow> createState() => _ExpandingRowState();
}

class _ExpandingRowState extends State<_ExpandingRow> {
  bool open = false;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          SizedBox(
            width: double.infinity,
            height: 72,
            child: OutlinedButton(onPressed: () => setState(() => open = true), child: const Text('row 1')),
          ),
          if (open)
            RaceTimeAction(
              id: 'fix',
              itemScoped: widget.itemScoped,
              child: SizedBox(
                width: 160,
                height: 72,
                child: ElevatedButton(onPressed: () {}, child: const Text('Fix')),
              ),
            ),
        ]),
      );
}
