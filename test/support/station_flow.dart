import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion_core/core.dart';

/// A mark boat's phone sets its station and takes it back, from the role
/// picker, holding nothing else: no admission, no fleets, nothing from a PRO
/// (#26 criterion 3). Shared by the host test (test/station_test.dart) and the
/// on-device one (integration_test/offline_results_flow.dart), so both prove
/// one flow.
///
/// Between the two it appends a rounding straight to [core], as #54 will: the
/// station it carries is criterion 4's, on whichever core this runs against.
///
/// Expects [core] to hold nothing yet, so the app opens on the role picker.
/// Leaves the mark boat's home open with no station.
Future<void> markBoatStationFlow(WidgetTester tester, CoreClient core) async {
  Future<void> tap(Finder f) async {
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  String status() => tester.widget<Text>(find.byKey(const ValueKey('station-status'))).data!;

  await tap(find.byKey(ValueKey('pick-${Roles.markBoat}')));
  expect(status(), 'No station yet', reason: "the mark boat's home");
  await tap(find.text('STATION'));
  await tap(find.byKey(const ValueKey('station-${StandardMarks.gateLeft}')));
  expect(status(), 'Station: Gate left');

  final rounding = (await tester.runAsync(() => core.append(const NewEvent(kind: 'rounding', source: 'tap'))))!;
  expect(markOf(rounding), StandardMarks.gateLeft, reason: 'criterion 4: a later event carries the station');

  await tap(find.byKey(const ValueKey('undo-station')));
  expect(status(), 'No station yet');

  final all = (await tester.runAsync(core.readAll))!;
  expect([for (final e in all) e.kind], [RoleKinds.assigned, StationKinds.selected, 'rounding', StationKinds.undo]);
  expect(all[1].payload, {'mark': StandardMarks.gateLeft});
  expect(all[3].correctsUlid, all[1].ulid);
  expect(await tester.runAsync(core.admissionId), isNull, reason: 'never admitted to any server');
}
