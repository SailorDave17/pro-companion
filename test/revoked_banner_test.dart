import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/revocation/revoked_banner.dart';
import 'package:pro_companion/ui/bars.dart';
import 'package:pro_companion/ui/race_time.dart';
import 'package:pro_companion/ui/sunlight.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';
import 'support/roles.dart';

/// #53: a phone whose admission was revoked says so above every screen, names the race day, and
/// goes on logging. Sync learns of the revocation in the core (packages/sync); the UI reads it
/// only through CoreClient.revocation, which the fake core answers with what a test sets.
void main() {
  const day = 'b3c7e9a1-2d4f-4b6a-8c0e-1f2a3b4c5d6e';
  const named = Revocation(eventId: day, eventName: 'Fall Series Day 2', at: 1000);
  const unnamed = Revocation(eventId: day, at: 1000);

  late int now;
  late FakeCore core;
  late FakeConfirmationDevice device;

  setUp(() {
    now = DateTime(2026, 10, 25, 14, 30).millisecondsSinceEpoch;
    core = withRole(FakeCore(clock: () => now += 1000));
    device = FakeConfirmationDevice();
  });

  final banner = find.byKey(const ValueKey('revoked-banner'));
  final finishButton = find.widgetWithText(FilledButton, 'FINISH');

  Future<void> openApp(WidgetTester tester, {double textScale = 1}) async {
    setPhoneSize(tester);
    // A status bar, so the banner's place under it is what a phone shows.
    tester.view.padding = const FakeViewPadding(top: 24 * 2.625);
    tester.view.viewPadding = const FakeViewPadding(top: 24 * 2.625);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await tester.pumpWidget(
      MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: ProCompanionApp(core: core, confirmation: ConfirmationService(device)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The paragraph a banner line is drawn with.
  RenderParagraph paragraph(WidgetTester tester, String line) => tester.renderObject<RenderParagraph>(find.text(line));

  Future<List<EventEnvelope>> finishes(WidgetTester tester) async => [
    for (final e in (await tester.runAsync(core.readOwn))!)
      if (e.kind == FinishKinds.finish) e,
  ];

  group('criterion 1: a revoked phone shows a banner naming the race day', () {
    testWidgets('control: with the admission standing there is no banner, and the home starts under '
        'the status bar as before', (tester) async {
      await openApp(tester);
      expect(banner, findsNothing);
      expect(find.textContaining('Removed from'), findsNothing);
      expect(core.calls['revocation'], 1, reason: 'the banner asked, and was told nothing is revoked');
      expect(tester.getTopLeft(find.byType(Scaffold)).dy, 0);
      expect(
        MediaQuery.paddingOf(tester.element(find.byType(Scaffold))).top,
        24,
        reason: 'control: the screen keeps the status bar inset as before',
      );
    });

    testWidgets('on the home, from the first read: the race day by name, and what it means', (tester) async {
      core.revocationValue = named;
      await openApp(tester);
      expect(banner, findsOneWidget);
      expect(find.text('Removed from Fall Series Day 2'), findsOneWidget);
      expect(find.text(RevokedBanner.detail), findsOneWidget);
      expect(
        tester.widget<Material>(find.descendant(of: banner, matching: find.byType(Material))).color,
        SunlightTokens.danger,
      );
      expect(tester.getTopLeft(banner).dy, 0, reason: 'at the top of the screen');
      expect(
        tester.getTopLeft(find.byType(Scaffold)).dy,
        tester.getBottomLeft(banner).dy,
        reason: 'the screen starts under it, nothing hidden behind it',
      );
      expect(
        tester.getTopLeft(find.text('Removed from Fall Series Day 2')).dy,
        greaterThanOrEqualTo(24),
        reason: 'its text clears the status bar',
      );
      expect(
        MediaQuery.paddingOf(tester.element(find.byType(Scaffold))).top,
        0,
        reason: 'the banner took the status bar, so the screen does not leave room for it again',
      );
    });

    testWidgets('a race day sync never learned the name of is named plainly', (tester) async {
      core.revocationValue = unnamed;
      await openApp(tester);
      expect(find.text('Removed from this race day'), findsOneWidget);
    });

    testWidgets('on whatever screen is open, within one read, and that screen stays open', (tester) async {
      await openApp(tester);
      await tester.tap(find.text('FINISHES'));
      await tester.pumpAndSettle();
      expect(finishButton, findsOneWidget);
      expect(banner, findsNothing, reason: 'control');

      core.revocationValue = named; // as sync records the refusal, mid-race
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(banner, findsOneWidget);
      expect(finishButton, findsOneWidget, reason: 'still on FINISHES: the screen kept its place');
      expect(find.text('Removed from Fall Series Day 2'), findsOneWidget);
    });

    testWidgets('goes once the phone holds an admission that stands, and a failed read changes nothing', (
      tester,
    ) async {
      core.revocationValue = named;
      await openApp(tester);
      expect(banner, findsOneWidget);

      core.failWith = const CoreException('failed', 'the core is busy');
      await tester.pump(const Duration(seconds: 5));
      expect(banner, findsOneWidget, reason: 'a failed read is not a revocation lifted');

      core.failWith = null;
      core.revocationValue = null;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(banner, findsNothing);
    });

    testWidgets('is announced: one live region a screen reader reads as it appears', (tester) async {
      final semantics = tester.ensureSemantics();
      core.revocationValue = named;
      await openApp(tester);
      final node = tester.getSemantics(banner);
      expect(node.flagsCollection.isLiveRegion, isTrue);
      expect(node.label, contains('Removed from Fall Series Day 2'));
      expect(node.label, contains(RevokedBanner.detail));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse, reason: 'nothing to tap');
      semantics.dispose();
    });

    testWidgets('the status-bar icons turn light over the banner, after a screen had made them dark', (tester) async {
      // The review of #53: an AppBar on white leaves the icons dark, about 2:1 over the red.
      await openApp(tester);
      await tester.tap(find.text('FINISHES'));
      await tester.pumpAndSettle();
      expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.dark, reason: 'control');
      core.revocationValue = named;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.light);
    });

    testWidgets('its text is drawn white on the danger red, held to the contrast bar', (tester) async {
      // The background alone was pinned until the review of #53: red text on the red passed.
      core.revocationValue = named;
      await openApp(tester);
      final plate = tester.widget<Material>(find.descendant(of: banner, matching: find.byType(Material))).color!;
      for (final line in [RevokedBanner.title(named), RevokedBanner.detail]) {
        final color = paragraph(tester, line).text.style!.color!;
        expect(color, SunlightTokens.onDanger, reason: line);
        expect(contrastRatio(color, plate), greaterThanOrEqualTo(Bars.minTextContrast), reason: line);
      }
    });
  });

  // The widget-test font draws every glyph one em wide, so the names below are chosen by their
  // length to land in each regime: at 22 px a 379 dp line holds 17 glyphs.
  group('long names and large text: one line each, shrunk to fit, never below a floor, then cut', () {
    Future<void> openOn(WidgetTester tester, Size size, double scale, Revocation r) async {
      tester.view.physicalSize = size * 2.625;
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      core.revocationValue = r;
      await tester.pumpWidget(
        MediaQuery.withClampedTextScaling(
          minScaleFactor: scale,
          maxScaleFactor: scale,
          child: ProCompanionApp(core: core, confirmation: ConfirmationService(device)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a line that fits is drawn whole at the phone\'s text size', (tester) async {
      const short = Revocation(eventId: day, eventName: 'R2', at: 1000); // 15 glyphs
      await openOn(tester, const Size(411, 891), 1, short);
      final title = paragraph(tester, RevokedBanner.title(short));
      expect(title.text.style!.fontSize, 22);
      expect(title.didExceedMaxLines, isFalse);
    });

    testWidgets('a line a little too long is shrunk to fit, whole, and stays above the floor', (tester) async {
      const near = Revocation(eventId: day, eventName: 'Day 22', at: 1000); // 19 glyphs: 418 px at 22
      await openOn(tester, const Size(411, 891), 1, near);
      final title = paragraph(tester, RevokedBanner.title(near));
      expect(title.text.style!.fontSize, inExclusiveRange(RevokedBanner.minFontSize, 22));
      expect(title.didExceedMaxLines, isFalse, reason: 'shrunk, not cut');
    });

    testWidgets('a shrunk line is drawn whole whatever the letter spacing, which does not shrink with the font', (
      tester,
    ) async {
      // On the emulator one scaling step left the detail "…Hand it i…" at 200%: Material's
      // letter spacing is a fixed number of pixels. The test font has none, so set a wide one.
      setPhoneSize(tester);
      const near = Revocation(eventId: day, eventName: 'Day 22', at: 1000); // 19 glyphs
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(textTheme: const TextTheme(bodyMedium: TextStyle(letterSpacing: 2))),
          home: const Scaffold(body: RevokedBanner(revocation: near)),
        ),
      );
      final title = paragraph(tester, RevokedBanner.title(near));
      expect(title.text.style!.letterSpacing, 2, reason: 'control: the spacing reached the banner');
      expect(title.text.style!.fontSize, inExclusiveRange(RevokedBanner.minFontSize, 22));
      expect(title.didExceedMaxLines, isFalse, reason: 'shrunk until it fits, not cut');
    });

    // CI's emulator, and the bar's reference phone.
    for (final size in const [Size(320, 640), Size(411, 891)]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('a long name at ${(scale * 100).round()}% text on a ${size.width.round()} dp phone is drawn at '
            'the floor, cut with an ellipsis, read whole, and takes at most a quarter of the screen', (tester) async {
          final semantics = tester.ensureSemantics();
          const long = Revocation(eventId: day, eventName: 'Hoover Sailing Club Fall Series Day 2', at: 1000);
          await openOn(tester, size, scale, long);
          final box = tester.getRect(banner);
          for (final line in [RevokedBanner.title(long), RevokedBanner.detail]) {
            final p = paragraph(tester, line);
            expect(p.text.style!.fontSize, greaterThanOrEqualTo(RevokedBanner.minFontSize), reason: line);
            expect(p.overflow, TextOverflow.ellipsis, reason: line);
            final drawn = tester.getRect(find.text(line));
            expect(drawn.left, greaterThanOrEqualTo(box.left + Bars.screenGutterDp - 0.5), reason: line);
            expect(drawn.right, lessThanOrEqualTo(box.right - Bars.screenGutterDp + 0.5), reason: '$line: $drawn');
          }
          expect(paragraph(tester, RevokedBanner.title(long)).didExceedMaxLines, isTrue, reason: 'cut at the floor');
          expect(tester.getSemantics(banner).label, contains('Hoover Sailing Club Fall Series Day 2'));
          expect(box.height, lessThanOrEqualTo(size.height / 4), reason: 'the screen below keeps its room');
          semantics.dispose();
        });
      }
    }
  });

  group('criterion 2: capture is never blocked', () {
    testWidgets('with the banner up, a FINISH tap logs, buzzes and shows, and nothing asks first', (tester) async {
      core.revocationValue = named;
      await openApp(tester);
      await tester.tap(find.text('FINISHES'));
      await tester.pumpAndSettle();
      expect(banner, findsOneWidget);

      for (var i = 1; i <= 3; i++) {
        await tester.tap(finishButton);
        await tester.pumpAndSettle();
        expect(await finishes(tester), hasLength(i));
      }
      expect(device.vibrations, 3, reason: 'each tap confirmed as committed, as on any phone');
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Finishes · 3'), findsOneWidget);
    });
  });

  group('criterion 4: the bar-check helper passes with the banner up', () {
    /// The app the bar checks explore: the PRO's day with its gun and a full finish list (#4's
    /// fixture), so every PRO action exists to be reached, a single-fleet day with no fleet switch,
    /// and the banner up. One builder, so each check and its own banner assertion see one app.
    Widget Function(NavigatorObserver) revokedDayApp(double scale) => (observer) {
      var t = DateTime(2026, 10, 25, 14, 30).millisecondsSinceEpoch;
      final seeded = withRole(FakeCore(clock: () => t += 1000))..revocationValue = named;
      seeded.seed([
        EventEnvelope(
          ulid: '01J8START0000000000000000G',
          deviceTs: t += 1000,
          deviceId: seeded.deviceIdValue,
          seq: 1,
          source: 'manual',
          kind: StartKinds.start,
          payloadVersion: 1,
          payload: const {'fleet': null},
        ),
        for (var i = 0; i < 12; i++)
          EventEnvelope(
            ulid: '01J8${'${i + 1}'.padLeft(22, '0')}',
            deviceTs: t += 1000,
            deviceId: seeded.deviceIdValue,
            seq: i + 2,
            source: 'tap',
            kind: FinishKinds.finish,
            payloadVersion: 1,
            payload: const {},
          ),
      ]);
      return MediaQuery.withClampedTextScaling(
        minScaleFactor: scale,
        maxScaleFactor: scale,
        child: ProCompanionApp(
          core: seeded,
          confirmation: ConfirmationService(FakeConfirmationDevice()),
          navigatorObservers: [observer],
        ),
      );
    };

    for (final scale in [1.0, 2.0]) {
      testWidgets('from the PRO home, every screen within two taps, at ${(scale * 100).round()}% text', (tester) async {
        final app = revokedDayApp(scale);
        final violations = await barCheck(tester, app, actionIds: proRaceTimeActionIds.difference({'fleet-switch'}));
        expect(violations, isEmpty, reason: violations.join('\n'));
        // The check's own app has the banner up. Without it, this check would be finish_screen_test's
        // bannerless one again, and pass (the review of #53).
        await tester.pumpWidget(app(NavigatorObserver()));
        await tester.pumpAndSettle();
        expect(banner, findsOneWidget);
      });
    }

    testWidgets('the banner is drawn hit-testable above every pushed screen', (tester) async {
      core.revocationValue = named;
      await openApp(tester);
      for (final screen in ['FINISHES', 'SEQUENCE', 'RESULTS', 'FLEETS']) {
        await tester.tap(find.text(screen));
        await tester.pumpAndSettle();
        expect(banner.hitTestable(), findsOneWidget, reason: screen);
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
      }
    });
  });
}
