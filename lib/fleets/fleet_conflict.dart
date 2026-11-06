import 'package:pro_companion_core/core.dart';

/// What a screen says of a fleet whose name another race area also has
/// (#76 criterion 4), or null when [fleet] has no such conflict. Names the
/// other race areas from [areas] where the phone keeps them.
String? fleetConflictNote(FleetMerge merge, String fleet, String name, List<RaceArea> areas) {
  if (!merge.conflicted(fleet)) return null;
  final others = [
    for (final c in merge.conflictingCourses(fleet))
      if (areas.where((a) => a.id == c).firstOrNull case final RaceArea a) a.name,
  ]..sort();
  return others.isEmpty
      ? 'Another race area also has a fleet named $name'
      : '${others.join(' and ')} also ${others.length == 1 ? 'has' : 'have'} a fleet named $name';
}

/// The name of the race area [fleet]'s definition names, from [areas], or
/// null when it names none or the phone does not keep it.
String? fleetAreaName(Iterable<EventEnvelope> events, String fleet, List<RaceArea> areas) {
  final defined = events.where((e) => e.ulid == fleet && e.kind == FleetKinds.defined).firstOrNull;
  final course = defined?.payload[coursePayloadKey];
  return course is String ? areas.where((a) => a.id == course).firstOrNull?.name : null;
}
