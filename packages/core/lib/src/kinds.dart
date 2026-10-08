import 'finishes.dart';
import 'fleets.dart';
import 'results.dart';
import 'roles.dart';
import 'starts.dart';
import 'stations.dart';

/// Every event kind the core writes, in one place (#6). Each feature keeps its
/// own `*Kinds` class; this is their union, so a test that must cover every
/// kind the log can hold reads it from here rather than from a hand list.
/// `test/kinds_test.dart` scans `lib/src` and fails when a `*Kinds` class holds
/// a kind this set does not.
abstract final class EventKinds {
  static const all = {
    ...FinishKinds.all,
    ...FleetKinds.all,
    ...StartKinds.all,
    ...ResultsKinds.all,
    ...RoleKinds.all,
    ...StationKinds.all,
  };
}
