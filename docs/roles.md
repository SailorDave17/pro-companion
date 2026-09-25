# Committee roles — who a phone is admitted as

- **Status: groom decisions G28 and G38 (owner, 2026-09-24).** The server holds the six roles below.
  The check on `committee_device.role` (`supabase/migrations/20260925000200_six_committee_roles.sql`,
  #57) refuses any other, and #39's `pro` became `overall_pro`. `supabase/tests/roles_test.sql` fails
  if the check allows a different set. `test/roles_doc_test.dart` fails if this table changes.
- **Decided, not yet enforced:** the race-area binding and the critical kinds. A phone is bound to its
  race area at admission from #65, which also gives each role its own admission code (G26). Until
  then a phone names its role when it is admitted. The server refuses a critical kind outside the
  writer's role and race area from #75.

## The roles

| Role | Stored as | Where it works | Critical kinds it may write (G24, G29, G30) |
|---|---|---|---|
| Overall PRO | `overall_pro` | **Event-wide** | All of them on any race area, plus event-wide postpone and abandon |
| Course PRO | `course_pro` | **One race area** | All of them, for the fleets on its race area |
| Recorder | `recorder` | **One race area** | Line finishes |
| Mark boat | `mark_boat` | **One race area** | A shortened course, and finishes at its station |
| Safety | `safety` | **Event-wide** | None |
| Scorer | `scorer` | **Event-wide** | The release of provisional results |

The critical kinds are line finishes, start and sequence events, a shortened course and the release
of results (G24). Every other kind is open to any admitted role.

## What the table does not say

- **The signal boat is the PRO (G28).** There is no signal-boat role. The owner first chose a
  separate one, then answered that the signal boat is the PRO.
- **One overall PRO, and one course PRO per race area (G28).** Admission does not enforce it. A
  phone warns when another active device writes as the same PRO (G48, #80).
- **A day with no scorer is scored by the PRO (G28).** The scorer is a phone role, not a shore one.
- **A mark boat's station is self-declared (G49).** It is recorded, not enforced (#26).
