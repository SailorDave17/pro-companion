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
enum HomeAction { fleets, sequence, finishes, results, log, station, roundings, finishAtMark, runningOrder }

/// What [role]'s home offers: that role's job and nothing else (#20
/// criterion 3, groom decision G29).
///
/// - The PRO runs the day: fleets, the start sequence, finishes and results,
///   and the committee log, where the other phones' logs are checked (#67;
///   on the PRO's home only, owner decision at its pickup).
/// - The recorder writes line finishes, and names its own fleets when its
///   phone works alone (owner decision 2026-10-06).
/// - The mark boat sets its station (#26), taps each boat rounding it (#54),
///   and finishes a shortened course there (#30). It has no line-finish or
///   start controls.
/// - Safety's actions arrive with milestone 3, so its home holds none yet.
///
/// The PRO, the recorder and the mark boat each end with the running order
/// (#68), which follows the race from every phone's roundings (owner decision
/// at #68's pickup: on every role's home, not the PRO's alone).
List<HomeAction> homeActions(String role) => switch (role) {
      Roles.overallPro => const [
          HomeAction.fleets,
          HomeAction.sequence,
          HomeAction.finishes,
          HomeAction.results,
          HomeAction.log,
          HomeAction.runningOrder,
        ],
      Roles.recorder => const [HomeAction.fleets, HomeAction.finishes, HomeAction.runningOrder],
      Roles.markBoat => const [
          HomeAction.station,
          HomeAction.roundings,
          HomeAction.finishAtMark,
          HomeAction.runningOrder,
        ],
      _ => const [],
    };
