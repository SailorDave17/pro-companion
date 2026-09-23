# ADR 001 — Offline-first phones syncing to Supabase over any connection

- Status: proposed 2026-09-23 (owner chose the shape; this text awaits approval)
- Builds on: burgee ADR 004 (Flutter, Android-first), burgee ADR 002 (Supabase)
- Scope of record: `cairn/memory/projects/pro-companion-scope-2026-08-14.md`, decisions 1, 2, 7, 8

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
with device id as the tiebreak (the rule pro-companion#6 already specifies). Nothing is edited, so
nothing conflicts — an undo is a new correction event, per decision 8. The same event uploaded
twice is harmless.

### Who can write to an event's log

A phone writes to an event only under the club's chosen auth path (pro-companion#5: a race-day
device session or a named volunteer account). Every event is stamped with the device id and, where
known, the person — so the log says who recorded what. Supabase's row-level security refuses writes
outside the device's club and event, and refuses any UPDATE or DELETE on log rows (burgee#7). A
phone that was never admitted to the event cannot put anything into its log, online or later.

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
  separately; neither overwrites the other (the clock-skew rule in pro-companion#6).
- **Located and attributed** — each event carries GPS position where available, the device id and
  the person, so it answers *who, when, where* without anyone's memory.

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
