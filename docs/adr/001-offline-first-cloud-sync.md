# ADR 001 — Offline-first phones syncing to Supabase over any connection

- Status: proposed 2026-09-23 (owner chose the shape; this text awaits approval)
- Builds on: burgee ADR 004 (Flutter, Android-first), burgee ADR 002 (Supabase)
- Scope of record: `cairn/memory/projects/pro-companion-scope-2026-08-14.md`, decisions 1, 2, 7, 8
- Amended 2026-09-23 by pro-companion ADR 005: "Supabase" throughout this ADR means **the
  companion's own Supabase project**, not burgee's. The server-side rules described below (row-level
  security, append-only, who may write) land in pro-companion's `supabase/` migrations (#39, #40),
  and burgee reads derived views across that boundary. The architecture — local core, one sync
  path, no phone-to-phone link — is unchanged.
- Amended 2026-09-26 by pro-companion #49 (groom decision G44): every event's envelope also carries
  `admission_id`, the admission its phone held when it wrote the event. See "Who can write to an
  event's log".
- Amended 2026-10-14 by pro-companion #31: the core stamps every event's `gps` from the phone's last
  fix, with the fix's age in `age_ms`, and when there is none, says why in the new envelope field
  `gps_reason`. See "Located and attributed" below.
- Amended 2026-10-26 by pro-companion #55 (groom decision G10): as a phone joins a race, the core
  appends a `clock.offset` event recording its clock against satellite time, and a `clock.changed`
  event when the phone's clock is set. The envelope is unchanged. See "Two clocks" below.
- Amended 2026-10-27 by pro-companion #54 and #68: a phone's first rounding in a race joins it too,
  so the running order can put two phones' roundings at a gate side by side in satellite time. The
  envelope is unchanged. See "Two clocks" below.
- Amended 2026-10-29 by pro-companion #69: the core times each finish from its race's gun on
  another phone, per fleet race, for scoring and export, and flags a race it could not time or that
  two phones took finishes for. Nothing is stored. See "Two clocks" below.

## Context

The pilot serves the whole committee on several phones at once (decision 1): signal boat, recorder,
mark boats, safety. Race officers told the owner the closest competitor, SailAlign, is "unusable",
and one of the three reasons was **unreliable: it needs signal**.

The owner asked whether a front-end/back-end approach would be more reliable for an app with this
much going on. The system already has one — the Flutter app is the front end, Supabase is the back
end — so the real question is **where the source of truth lives while the boat has no signal.**

## Options considered

- **Thin client, server does it all** — the classic split. Simplest to reason about on shore; the
  app stops the moment signal drops, which is the failure officers reported. Contradicts the
  charter's offline-first constraint. Rejected.
- **On-water hub** — the signal-boat phone as a local server, other phones joining it directly
  over Nearby Connections / Wi-Fi Direct with no cell. Recommended in the first draft of this ADR.
  **Rejected by the owner: "Wi-Fi Direct is a losing bet."** It adds a second sync path, a
  single point of failure on the signal boat, and radio range that plausibly does not reach a
  windward mark anyway.
- **Peer mesh** — every phone syncs with every other. Rejected earlier on pilot risk; the owner's
  reasoning against the hub applies to it with more force.
- **Offline-first phones syncing to Supabase over any connection** — chosen.

## Decision

Two tiers, and the first never waits on the second:

1. **Local core on every phone.** The app is split internally: the UI layer, and a core that owns
   the local database, the append-only event log, the domain rules and the sync engine. **The UI
   never calls the network.** Every action writes to the local core, which answers within the
   ~100 ms bar. A phone with no connection runs its whole role — finishes, roundings, the log, the
   clocks — indefinitely.
2. **Supabase is the meeting point.** Each phone syncs with Supabase whenever it has **any**
   internet connection — cell, or Wi-Fi such as a club or boat hotspot. There is no phone-to-phone
   link: committee phones see each other's events **through the cloud**, so they see each other
   exactly as far as they have signal. Sync runs in the background, both directions, and resumes on
   its own when signal returns.

**Why this holds together: the log only ever grows.** Every event carries a client-generated ULID,
a device timestamp and a device id. Merging is a union keyed by ULID; order is device timestamp
with device id as the tiebreak (the rule pro-companion#6 already specifies), and one phone's own
events in the same millisecond keep the order it logged them, its sequence number (#145, 2026-10-26:
a ULID's random tail had inverted them). Nothing is edited, so
nothing conflicts — an undo is a new correction event, per decision 8. The same event uploaded
twice is harmless.

### Who can write to an event's log

A phone writes to an event only under the club's chosen auth path (pro-companion#5: a race-day
device session or a named volunteer account). Every event is stamped with the device id and, where
known, the person — so the log says who recorded what. Supabase's row-level security refuses writes
outside the device's club and event, and refuses any UPDATE or DELETE on log rows (#40 — this said
burgee#7 until ADR 005 moved the table into the companion's project on 2026-09-23). A
phone that was never admitted to the event cannot put anything into its log, online or later.

**Amended 2026-09-26 (#49, groom decision G44): every event also carries the admission it was
written under.** The envelope field `admission_id` holds the id of the phone's committee_device row,
which `admit_device` returns and the local core caches. It is null on a phone never admitted, as in
single-phone use. The phone stamps it inside the event's canonical text, so the chain's hash covers
it (`docs/event-chain.md`). The server cannot stamp it on insert: an event written offline under
one admission and uploaded after a re-admission would get the wrong one. So attribution keys on the
admission, which carries the role and race area, not on the auth identity. A re-admission changes
the admission on later events only, and the device's chain continues across it. The server's check
that an event names its writer's admission is #73.

### The race-timer link

Decision 2: race-timer signals, the companion logs. race-timer runs on the same phone and today
exposes **no interface to other apps** (its service is driven by internal intents only). So the
link is work on both sides:

- **The contract:** race-timer emits each sequence event — sequence start, each signal, postponement,
  individual and general recall, the start gun — with its own timestamp; the companion's local core
  records each as a log event with `source = race-timer`, never a hand-typed time.
- **The mechanism** (an Android broadcast, a bound service, or a content provider) is picked by a
  spike, because it must deliver while the companion is in the background and the screen is off.
- **Fallback when race-timer is not installed or not running:** the PRO taps gun times by hand
  into the companion, marked `source = manual`, so a protest committee can tell the two apart.

### A log that can prove it was not altered

"Protest-grade" is made concrete by four properties, each testable:

- **Append-only everywhere** — enforced in the local store and again by the database.
- **Chained per device** — each event carries a hash of the device's previous event, so a removed or
  altered event breaks the chain visibly, on the phone and on shore.
- **Two clocks** — the device timestamp is kept verbatim, and the server's receipt time is stored
  separately; neither overwrites the other (the clock-skew rule in pro-companion#6). *Amended
  2026-10-26 (#55):* phones' clocks disagree, so a finish on a mark boat cannot be timed against the
  signal boat's gun from the two device timestamps alone. Each phone therefore records its clock's
  **offset from satellite time** (satellite minus device) in a `clock.offset` event, which the core
  appends itself just before the phone's gun, and before its first finish, at the line or at a mark,
  in each race. *Amended 2026-10-27 (#54, #68):* and before its first rounding, since the running
  order puts two phones' roundings at a gate side by side, in satellite time where both phones have
  an offset measured, and flagged as on their own clocks where either has none. Roundings on one
  phone are put in the order that phone logged them, so a clock set on it changes nothing there. That race is the fleet's latest gun the phone knows of, its own or pulled from
  another phone, when that gun went that day; with none known, it is the fleet's race of the day
  (owner decision on #55). The satellite time comes only from a GPS-provider fix, the one provider
  whose time Android guarantees is the constellation's. The event carries the offset, its
  uncertainty (null when the phone states none) and the fix's age, or a `reason` when there is
  none: the four `gps_reason` values, `no_gps_time`, or `clock_changed` after the phone's clock was
  set. When the phone reports its clock set, the core also appends a **`clock.changed`** event
  (owner decision at #55's review), so a race counts as joined only by an offset recorded after it,
  and the log says the clock moved. A race joined only by offsets that could not be measured is
  joined again once the phone has satellite time. Device timestamps still stay verbatim: an elapsed
  time across two phones, or across a clock set on one, reads each reading through its own phone's
  latest offset, and is flagged, never computed from the raw clocks, when either has none.
  *Amended 2026-10-29 (#69):* the core reads that per fleet race for scoring and export
  (`CoreClient.raceTimes()`), worked out each time it is asked and never stored. A finish's race is
  the latest of the fleet's guns that day that it came after, compared in satellite time where both
  phones have an offset measured and on the raw clocks otherwise. A race is flagged unreconciled
  where any finish could not be timed, including when no gun is held, and as having two finish
  sources where two phones took finishes. Both phones' finishes are kept, and neither is matched to
  the other.
- **Located and attributed** — each event carries GPS position where available, the device id,
  the person and (amended 2026-09-26, #49) the admission it was written under, so it answers *who,
  when, where* without anyone's memory. *Amended 2026-10-14 (#31):* the core stamps the position,
  never the caller. `gps` holds latitude, longitude, accuracy and `age_ms`, the fix's true age when
  the event was written: 30 s or less is current, and an older fix is still carried, with its age.
  With no fix, `gps` is null and `gps_reason` says why (`no_permission`, `location_off`, `no_fix`,
  `no_source`). An append never waits on GPS.

## Consequences

- **The committee is only as connected as its signal.** With no signal on the water, every phone
  still works alone and nothing is lost, but phones do not see each other's entries until they
  reconnect. This is the honest difference from SailAlign: it stops without signal; the companion
  keeps working and catches up.
- **Far marks: live if cell, else catch up** (owner decision 2026-09-23). Mark roundings reach shore
  live wherever the mark boat has cell and sync on return otherwise. No range-extender hardware in
  the pilot.
- **Role handoff depends on signal.** A replacement phone takes over a role and pulls that role's
  log from Supabase; with no signal it starts from what it holds, and the two logs merge cleanly
  when either phone reconnects.
- **Visible sync status matters more, not less** — every phone shows what has reached shore and what
  is waiting, because that is now the only way a committee knows what the others can see.
- **One sync path**, not three. The local core is still the largest piece of engineering in the
  pilot and every race-time story sits on it, so it is built first behind a narrow interface.
- **iOS later is easier.** Cloud sync is platform-neutral, so nothing here is Android-only except the
  race-timer link, which is Android-only because race-timer is.
- **Decision 8's "phone-to-phone sync, no cell" is withdrawn** by this ADR.

## Kill conditions

- If the local core cannot meet the 100 ms bar on the club phone with a full day's events, its
  storage choice is reopened — not the architecture.
- If a full race day on real water shows sync missing or duplicating any event after reconnection,
  the sync engine is not done, whatever its tests say (pro-companion#8 measures this).
- If the race-timer link cannot deliver events with the companion in the background and the screen
  off, the fallback is manual gun-time entry, and decision 3 (the companion absorbs race-timer's cue
  path) moves up from horizon.
- If committees at the pilot need to see each other's entries mid-race where there is no cell, this
  ADR's rejection of an on-water link is the thing to revisit — with the range measured, not assumed.
