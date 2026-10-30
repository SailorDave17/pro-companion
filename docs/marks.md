# Marks — the standard set a mark boat's station names

- **Status: groom decision G11's first half (#26, owner, 2026-10-08).** A fixed standard set that
  works offline on one phone. The ids below are fixed here, once: roundings (#54), a finish at a mark
  (#30) and the course module key on them, and burgee will read them in the log. **Never rename one.**
  An event a phone stored keeps the id it was written with.
- **Defined in code** as `StandardMarks` in `packages/core/lib/src/stations.dart`.
  `packages/core/test/stations_test.dart` pins each id, and `test/marks_doc_test.dart` fails if this
  table and the code disagree.
- **Not yet:** the custom mark list a PRO sends for an unusual course (G11's second half), which is
  its own story.

## The set

In the order the station picker shows them, two to a row.

| Mark | Stored as | Shown as |
|---|---|---|
| Mark 1 | `mark_1` | MARK 1 |
| Mark 2 | `mark_2` | MARK 2 |
| Mark 3 | `mark_3` | MARK 3 |
| Mark 4 | `mark_4` | MARK 4 |
| Windward | `windward` | WINDWARD |
| Leeward | `leeward` | LEEWARD |
| Gate left | `gate_left` | GATE LEFT |
| Gate right | `gate_right` | GATE RIGHT |
| Offset | `offset` | OFFSET |

`mark_1` to `mark_4` carry a `mark_` prefix, so no id reads as a number or a place (owner's choice,
2026-10-08).

## How a phone's events carry its mark

- **A station is self-declared (G49).** A mark boat picks it on its own phone (the mark-boat home's
  STATION, then the mark: 2 taps), with no server and no PRO. Nothing checks that the boat is there.
- The pick is a `station.selected` event with `payload.mark`. UNDO STATION on the home appends a
  `station.undo` naming the pick in `corrects_ulid`, and the phone returns to the station before it,
  or to none.
- **The core stamps the station into every event the phone appends** while it has one, as
  `payload.mark`, unless the event names a mark of its own (owner's choice, 2026-10-08). A
  `"mark": null` counts as its own, meaning "at no mark". So a rounding or a finish-here carries the
  station with no work of its own, and so does every other event a stationed phone writes, set-up
  ones included.
- A station belongs to the role pick it was made under. A new role pick, or UNDO ROLE, starts the
  phone with no station.
- Gate left and gate right are as the PRO's briefing names them. The phone records the volunteer's
  word for which is which.

## Finishing at a mark (#30)

When the course is shortened, the mark boat's station becomes a fleet's finish. Owner's choices at
pickup, 2026-10-14.

- **The mark-boat home's FINISH AT MARK** opens the finish-at-mark screen. It is off until the phone
  has a station, because that station is the mark the finishes are taken at.
- **A shortened course is a `course.shortened` event** naming `payload.fleet`, or null on a
  single-fleet day. The phone's station is stamped as its mark. On the screen, the fleet row makes
  the mark a fleet's finish with one tap. A single-fleet day shows one FINISH HERE button instead.
  So the mark becomes a finish in 2 taps from the home. A tap on a fleet already finishing here only
  shows it, and logs nothing.
- **A finish there is a `finish.at_mark` event**, with the fleet, the stamped mark and the phone's
  device id. It is its own kind, so the line's finish order and provisional results never count it.
  A sail number (`finish.sail`) and an undo (`finish.undo`) name it as they name a line finish.
- **UNDO LAST** takes back the fleet's last finish here. With no finish since the shortened course,
  it takes back the shortened course itself, as a `course.undo` naming it in `corrects_ulid`.
- **Which fleets finish here belongs to the phone**, as its station does. It is this phone's
  `course.shortened` events at this mark that are not undone. Another phone's, arriving by sync,
  never switches it.
- **The screen shows the time of day, and elapsed time as "pending reconciliation".** Elapsed time
  needs the gun, which another phone logs, and a clock reference across phones (G10). The clock
  reference exists since #55: a `clock.offset` event, the phone's clock against satellite time,
  which the core appends itself just before the phone's first finish here in each race whose gun it
  knows of, or once per fleet per day while it knows none (ADR 001, "Two clocks"). Today a mark
  phone knows no gun: its home fires none and sync is not started in the app (#113), so it is once
  per fleet per day, with another after the phone's clock is set.
- **The core times a finish here across phones since #69**, for scoring and export to read; nothing
  reads it yet. `CoreClient.raceTimes()` gives every fleet race the phone holds. A finish at the
  line or at a mark, taken on another phone than the gun's, is timed from the race's gun through
  both phones' offsets. One taken on the gun's own phone is timed on that phone's clock, unless the
  clock was set between the two.
  - A race is flagged `unreconciled` where any finish could not be timed: across two phones, one
    with no offset or none measured; or no gun held (`no_gun`, owner decision at #69's pickup).
  - It is flagged `two_finish_sources` where more than one phone took its finishes. Every phone's
    are kept, and none is matched to another's (scope constraint 11).
  - A finish's race is the latest of the fleet's guns that day that it came after. That is read in
    satellite time where both phones have an offset measured, and on the raw clocks otherwise. A
    later gun the raw clocks put after the finish cannot be ruled out by them, so its flags pass to
    the finish, which is then not timed (#69's review).
  - **Provisional results split races by another rule until #160.** `racesOf` (#7) reads the raw
    clocks only and has no local-date rule, so a finish logged on a later date than the fleet's last
    gun is in that gun's race there, and in its own date's race of the day here.
  - A finish's sail number is its latest by device time, as everywhere a finish is named, so one
    corrected after the phone's clock was set back reads the older name until #161.
- **Not yet:** a second shortened course for the same fleet at the same mark later in the day logs
  nothing new, because the first is still in force. The phone has no race boundary to end it.

## Roundings (#54)

The mark boat taps each boat as she rounds its station. Owner's choices at pickup, 2026-10-27.

- **The mark-boat home's ROUNDINGS** opens the rounding screen. Like FINISH AT MARK, it is off until
  the phone has a station.
- **A rounding is a `rounding` event** naming `payload.fleet` (null on a single-fleet day) and
  `payload.sail`, null for a boat the operator could not identify. The core stamps the station as
  `payload.mark`, and two more keys:
  - `payload.race`: the gun the fleet's race began with, as the phone knows the guns, or null when it
    knows none. The same rule as a clock offset's race (ADR 001, "Two clocks").
  - `payload.lap`: one more than this phone's roundings of that boat, at this mark, for this fleet,
    in that race, not undone. So the count runs from the gun, else from the start of the day. **Until
    a mark-boat phone learns the guns (#113), a second race on the same day counts on from the
    first.** An unidentified boat's lap is null.
- **A sail number named later, or corrected, is a `rounding.sail`** naming the rounding in
  `corrects_ulid`, with `payload.sail`; the latest wins, and the rounding itself is never edited.
  **UNDO LAST is a `rounding.undo`** naming the rounding, with no confirm.
- **The boats offered are this phone's own**: every sail number each fleet logged on this phone
  today, in roundings and finishes at a mark, in the order each last rounded. On a day of several
  fleets each fleet is a section of the grid, and a tap logs the boat with her own fleet, so a known
  boat is ROUNDINGS, then her number: 2 taps from the home, whichever fleet the row shows. The row
  picks the fleet for the list, UNKNOWN and NEW BOAT. The grid is frozen while the screen is open,
  and a boat typed with NEW BOAT joins the end of her fleet's section.
- **The fleets are the PRO's.** The rounding screen reads the day's fleet definitions from every
  phone, pulled down by sync, beside its own events (owner decision on #54's review, 2026-10-27). A
  mark-boat phone names none of its own, so without them a day of several fleets would log every
  rounding with no fleet. Until sync runs in the app (#113), it sees only fleets it named itself.
- **A log that cannot be read** shows that and RETRY, and nothing to log into: an empty grid would
  read as no boats yet.
- A rounding brings its race's clock offset just before it, as a finish does (#55), so a gate's two
  phones can be compared.

## The running order (#68)

RUNNING ORDER, on the PRO's, the recorder's and the mark boat's homes (owner decision at pickup),
lists each fleet's boats as far round as every phone's roundings say, re-read every 5 s. It reads
all the phones' events on purpose, as the committee log does. The rule is `runningOrders` in
`packages/core/lib/src/roundings.dart`, and `fixtures/rounding/` holds its vectors and states it in
full; pro-companion is canonical for them and burgee vendors them.

- **The log has no course**, so a boat's roundings in the race are how far round she is: more is
  ahead. Boats level on that are in the order they rounded their latest mark.
- **On one phone, boats level are in the order it logged them**, so a clock set on that phone
  changes nothing. **Across phones** (a gate's two mark boats), each rounding is read in satellite
  time through its phone's clock offset. Where either has none measured, the order is on the phones'
  own clocks and the screen says so, below the order.
- **A mark a phone is stationed at today, with no rounding of the fleet in the race, is named as
  waiting**, above the order it qualifies, so the order is never read as current at a mark it has
  not heard from. Yesterday's station is no mark today.
- Roundings that name no fleet on a day that defines fleets (a mark-boat phone before sync brings it
  the PRO's fleets) show as their own order, "No fleet named", last, and only while it holds a
  rounding in its race.
