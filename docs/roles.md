# Committee roles — who a phone is admitted as

- **Status: groom decisions G28 and G38 (owner, 2026-09-24).** The server holds the six roles below.
  The check on `committee_device.role` (`supabase/migrations/20260925000200_six_committee_roles.sql`,
  #57) refuses any other, and #39's `pro` became `overall_pro`. `supabase/tests/roles_test.sql` fails
  if the check allows a different set. `test/roles_doc_test.dart` fails if this table changes.
- **The race-area binding is enforced from #65.** Each role has its own admission code (G26): one per
  event for an event-wide role, and one per race area for a bound role. A phone is admitted to
  exactly the role and race area of the code it presents, and never names its role.
  `committee_device_race_area_check` refuses a bound role with no race area, and an event-wide role
  with one. A phone bound to a race area adds fleets only on that race area.
  `supabase/tests/admission_code_test.sql` holds all of it.
- **A phone changes role by re-admission from #70** (G44). Presenting the code of another role, or of
  the same role on another race area, supersedes its admission with a new one. Both rows stay, and
  only the active one admits: a superseded role adds no fleet. `supabase/tests/re_admission_test.sql`
  holds it.
- **The critical kinds are enforced from #75.** `append_event` refuses a critical kind outside the
  writer's role (`kind_not_permitted`) or race area (`race_area_mismatch`), and keeps the refusal
  like any other. The map is "The critical kinds, kind by kind" below, and
  `test/critical_kinds_doc_test.dart` fails if the server's map differs from it.

## The roles

| Role | Stored as | Where it works | Critical kinds it may write (G24, G29, G30) |
|---|---|---|---|
| Overall PRO | `overall_pro` | **Event-wide** | All of them on any race area, plus event-wide postpone and abandon |
| Course PRO | `course_pro` | **One race area** | All of them but a finish at a mark, for the fleets on its race area |
| Recorder | `recorder` | **One race area** | Line finishes |
| Mark boat | `mark_boat` | **One race area** | A shortened course, and finishes at its station |
| Safety | `safety` | **Event-wide** | None |
| Scorer | `scorer` | **Event-wide** | The release of provisional results |

The critical kinds are line finishes, start and sequence events, a shortened course and the release
of results (G24), and with them a finish at a mark and an abandonment (G29). Every other kind is
open to any admitted role.

## The critical kinds, kind by kind

The server's map, `public.critical_kind` (#75). A cell says where that role may write the kind:

- **its race area**: for a fleet racing on the race area its admission binds;
- **any race area**: for a fleet on any race area;
- **any race area, or event-wide**: that, and also with no fleet at all, for the whole race day;
- **—**: never. The event is refused as `kind_not_permitted`.

A bound role writing for a fleet on another race area, or for the whole race day, is refused as
`race_area_mismatch`.

| Kind | Overall PRO | Course PRO | Recorder | Mark boat | Safety | Scorer |
|---|---|---|---|---|---|---|
| `start` | any race area | its race area | — | — | — | — |
| `start.postponement` | any race area, or event-wide | its race area | — | — | — | — |
| `start.general_recall` | any race area | its race area | — | — | — | — |
| `start.individual_recall` | any race area | its race area | — | — | — | — |
| `start.ocs` | any race area | its race area | — | — | — | — |
| `start.sequence_start` | any race area | its race area | — | — | — | — |
| `start.signal` | any race area | its race area | — | — | — | — |
| `race.abandoned` | any race area, or event-wide | its race area | — | — | — | — |
| `finish` | any race area | its race area | its race area | — | — | — |
| `finish.missed` | any race area | its race area | its race area | — | — | — |
| `course.shortened` | any race area | its race area | — | its race area | — | — |
| `finish.at_mark` | any race area | — | — | its race area | — | — |
| `results.released` | any race area | its race area | — | — | — | any race area |

`race.abandoned` and `results.released` are named before any phone writes them, so the rule is in
force when one first does. The story that adds either to the core uses these names.

Six corrections carry no fleet of their own. Each is judged as the event it corrects, with that
event's kind and fleet, so a mark boat can number and take back its own finishes at a mark, a
recorder its line finishes, and a course PRO can retime or take back only its own race area's
starts (`public.critical_correction`):

| Correction | Judged as | The event it names, read from |
|---|---|---|
| `finish.sail` | the finish it numbers | `payload.finish` |
| `finish.undo` | the finish it takes back | `corrects_ulid` |
| `start.undo` | the start event it takes back | `corrects_ulid` |
| `start.time_corrected` | the start it retimes | `corrects_ulid` |
| `start.ocs_cleared` | the OCS it clears | `corrects_ulid` |
| `course.undo` | the shortened course it takes back | `corrects_ulid` |

A correction of a correction is followed to the first event that is not one: an undo of a time
correction is judged as the start. An undo of the overall PRO's whole-day postponement is the
overall PRO's alone, as the postponement is.

A correction waits, with the retryable error below, until the event it names is on the server. If
the server refused that event, the correction is refused with the same reason. Two reasons are read
differently, because sync gives them a meaning of their own:

- a target refused `not_admitted` may still be accepted on a later send, so the correction keeps
  waiting;
- a target refused `revoked` passes on `admission_mismatch`, since `revoked` would mark the
  correcting phone itself revoked.

An event naming a fleet whose `fleet.defined` was refused is refused the same way.

### Which race area a fleet races on

A phone's fleet id is the ULID of the `fleet.defined` event that made it, so the server reads a fleet
from the race day's log, not from `public.fleet`, which no phone writes yet. A critical event naming
a fleet whose `fleet.defined` is not in the log yet, or a correction whose event is not, is refused
with a retryable error (SQLSTATE `PCW01`). That error keeps no refusal record, and sync sends the
event again on its next run. The fleet's race area is the first of:

1. the race area its `fleet.defined` names in `payload.course` (#74 puts it there);
2. the race area of the admission that defined it, when that role is bound to one;
3. none. Then only the role is checked. Since #74 that leaves two cases: a fleet defined before #74,
   and one an event-wide phone defined before picking a race area. On a day with one race area
   neither is a gap, since every bound phone is on that race area.

### Which race area a phone works on (#74)

- **A bound role** (course PRO, recorder, mark boat) works on the race area its admission names. Its
  phone shows that race area under every screen's title and offers no picker.
- **An event-wide role** (overall PRO, scorer, safety) picks one. RACE AREA on its home opens a
  picker of the race day's race areas, which sync reads once with signal (`course`, by `event_id`)
  and the phone keeps offline. A pick is a `race_area.selected` event naming the course id in
  `payload.course`, undone by `race_area.undo`. It holds under the admission and the role pick it
  was made under, as a station pick does. Neither kind is critical: a pick is set-up.
- **A phone never admitted** (single-phone use, milestone 1) has one implicit race area. It shows
  none and offers no picker, and its fleets name none.
- **The core stamps the course id** into every `fleet.defined` the phone appends while it works on a
  race area. A fleet naming a course of its own keeps it. FLEETS lists that race area's fleets and
  those that name none.

An event with no fleet belongs to a single-fleet day and is checked by role only. A postponement or
abandonment with no fleet is the exception: it is for the whole race day, and only the overall PRO
may write it. The six corrections above are not events with no fleet: they take the fleet of the
event they name.

## What the table does not say

- **The signal boat is the PRO (G28).** There is no signal-boat role. The owner first chose a
  separate one, then answered that the signal boat is the PRO.
- **One overall PRO, and one course PRO per race area (G28).** Admission does not enforce it. A
  phone warns when another active device writes as the same PRO (G48, #80).
- **A day with no scorer is scored by the PRO (G28).** The scorer is a phone role, not a shore one.
- **A mark boat's station is self-declared (G49).** It is recorded, not enforced (#26). The marks it
  can name, and how its events carry one, are in `docs/marks.md`.
