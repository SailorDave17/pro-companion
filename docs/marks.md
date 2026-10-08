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
