import 'package:pro_companion_core/core.dart';

/// The roles the picker offers on one phone (#20). Course PRO arrives with
/// #74's race areas and the scorer with its own home (held), so each joins
/// the picker with that story. #77 later narrows the pick to the role a phone
/// was admitted as.
const pickableRoles = [Roles.overallPro, Roles.recorder, Roles.markBoat, Roles.safety];

/// What [role] is called on screen. On one phone the PRO is the overall PRO
/// (#20's amendment, groom decision G28).
String roleName(String role) => switch (role) {
      Roles.overallPro => 'PRO',
      Roles.coursePro => 'Course PRO',
      Roles.recorder => 'Recorder',
      Roles.markBoat => 'Mark boat',
      Roles.safety => 'Safety',
      Roles.scorer => 'Scorer',
      _ => role,
    };

/// The screens a role home opens.
enum HomeAction { fleets, sequence, finishes, results }

/// What [role]'s home offers: that role's job and nothing else (#20
/// criterion 3, groom decision G29).
///
/// - The PRO runs the day: fleets, the start sequence, finishes and results.
/// - The recorder writes line finishes, and names its own fleets when its
///   phone works alone (owner decision 2026-10-06).
/// - The mark boat's station, roundings and finish-here arrive with #26, #54
///   and #30, and safety's actions with milestone 3, so their homes hold no
///   action yet. Neither has line-finish or start controls.
List<HomeAction> homeActions(String role) => switch (role) {
      Roles.overallPro => const [HomeAction.fleets, HomeAction.sequence, HomeAction.finishes, HomeAction.results],
      Roles.recorder => const [HomeAction.fleets, HomeAction.finishes],
      _ => const [],
    };
