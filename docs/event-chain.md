# The event chain — how each phone's log shows an altered or removed event

- **Status: #28.** The phone's core writes and verifies it (`packages/core/lib/src/chain.dart`,
  `EventStore.append`). The companion's shore verifier (#62) and burgee reproduce it, and all three
  are held to the vectors in `fixtures/chain/`. **Since #67** a verifier also reads refusal stubs,
  and a phone shows every other phone's chain (`packages/core/lib/src/chain_status.dart`).
- **Decisions (owner, 2026-09-25):** the canonical form is RFC 8785, and a broken chain names its
  break point, not the altered event.

## What is hashed: the canonical text

An event is hashed as its **canonical text**: the [RFC 8785](https://www.rfc-editor.org/rfc/rfc8785)
JSON Canonicalization Scheme applied to its wire form. The wire form is the ADR 001 envelope,
`EventEnvelope.toWire()`, with every field present even when null, plus any field a newer core
wrote. Since #49 that includes `admission_id`, the admission the event was written under, so the
hash covers it too. Since #31 it includes where the phone was: `gps` with the fix's `age_ms`, or
`gps_reason` saying why there is no fix.

RFC 8785 fixes every choice JSON leaves open:

- Object members are sorted by key, keys compared as UTF-16 code units. There is no whitespace.
- Strings escape only `"`, `\` and the control characters U+0000 to U+001F, as `\b \t \n \f \r`
  where one exists and `\u00hh` (lowercase) otherwise. Everything else is written as-is, in UTF-8.
- Numbers are written as ECMAScript's `Number.prototype.toString` writes them. So `5.0` is `5`,
  `-0` is `0`, `1e21` is `1e+21` and `1e-7` stays `1e-7`. An integer past 2^53 - 1, a non-finite
  number and a lone surrogate are refused, not written.

**The canonical text is what is stored and what travels.** The phone's store keeps it as the row's
body, #40 keeps it beside the typed columns, and the phone sends it through #48's `append_event`.
**A verifier hashes the text it was given and never a re-serialisation of it.** A newer core may add
envelope fields an older one would write as missing. Re-serialising would then change the text, and
the hash with it, on an event nobody touched. `admission_id` (#49) is the first such field: an event
written before #49 has none, and a newer core that read it into an envelope and wrote it back would
add `"admission_id":null` and change its hash. `gps_reason` (#31) is the second, in the same way.

## The hash and the link

- **The hash** of an event is the SHA-256 of its canonical text's UTF-8 bytes, written as 64
  lowercase hex characters.
- **The link:** each event's `prev_hash` is the hash of the same device's previous event, the one
  with the sequence number one lower.
- **Genesis:** a device's first event (`seq` 1) carries 64 zeros as its `prev_hash`.

A device is an install. A phone handed to another volunteer mid-race keeps its device id and its
chain. A replacement phone is a new device, with its own chain from genesis. The chain is per
device, not per admission: a re-admission (#49) changes the `admission_id` the device's later events
carry, and the chain continues across it.

## Verdicts

A verifier takes one device's events, in any order, and reads them by sequence number, then by
ULID. That second key only decides which event is named when two hold one number. The verdict is
the first of these that applies:

| Verdict | When |
|---|---|
| **broken** at event E | E has no `prev_hash`; or E's number is above 1 and its `prev_hash` is genesis; or E is seq 1 and its `prev_hash` is not genesis; or the event before E holds the same number (a fork); or E follows its predecessor P by exactly one and E's `prev_hash` is not P's hash; or E follows P across missing numbers and E's `prev_hash` **is** P's hash |
| **gapped** | any number from 1 up to the highest present is missing, and every link that can be checked holds |
| **intact** | every number from 1 is present and every link holds |

- **Why a link across a gap that matches is broken.** In a genuine chain, E links to the event just
  before it, which this verifier has not seen. A link straight to P means the events between them
  were removed and E was re-linked.
- **Why a missing number alone is not broken.** Far marks routinely hold partial chains while they
  catch up (#28 grounding constraint 5), so a gap must not read as tampering.

**A broken verdict names the break point**: the first event, E, whose recorded link fails. When E
follows an event P, it names P as well (`after_seq`). The chain cannot say which of the two
changed. When one byte of P's payload is altered, P's hash changes and E's link stops holding, so
the verdict is *broken at E, after P*, and P may be the altered one.

## Refusal stubs in the chain (#67)

An event the server refused is not in the log, so its number would read as a gap. A phone admitted
to the race day reads a **stub** of it instead (#60, groom decision G41): the device, the number,
the reason, and the refused event's hash, which is the SHA-256 of the exact text the server
refused, the same hash the chain takes. A verifier given stubs reads each one in its event's place:

- **A stub fills its number with its hash.** The event after it is checked against that hash, as
  against any event, so a refusal is never a gap, and a stub whose hash is not the refused event's
  breaks the chain at the event after it. A stub has no previous hash, so its own link cannot be
  checked.
- **A stub whose hash is an event's held at its number is that event**, refused, and is read once.
  A phone holds its own refused events and pulls their stubs back.
- **A stub of another text at a held number is a fork**, as two events at one number are: broken
  at that number, named by the held event. Two stubs of two texts at one number are a fork too,
  with no text to name it by.
- At one number a stub is read before an event, so a fork between the two is named by the event.

`verifyChain(texts, refusals: …)` implements this. The shore verifier (#62) reproduces it. The
vectors carry no stubs yet; #62 adds them with its verifier (owner decision at #67's pickup).

## What a phone shows (#67)

The committee log, from LOG on the PRO's home, shows each other phone's log as **one status**, the
worst that applies, with the rest as lines under it (owner decision at #67's pickup):

| Status | When | Its lines |
|---|---|---|
| **Altered** | the chain is broken | the first bad event and its time, and the event before it |
| **Catching up** | a number is missing between the lowest and the highest held | how many are missing, and the last event verified unbroken from the lowest |
| **Refused at N** | a stub is held, and every link holds | the numbers verified |
| **Verified** | every number from the lowest held to the highest is held, and every link holds | the numbers verified |

Every refusal is listed as its own line, with its reason, whatever the status.

- **Numbers below the lowest held are not missing.** A phone's first events, logged before it was
  admitted, never reach shore (#64), so a count from 1 would read every phone as catching up for
  good. Verified means verified from the lowest number held.
- **Each race day is verified on its own**, from that race day's events and stubs. A device's stint
  on a race day this phone cannot read never reaches it, and across race days it would be a hole
  that never fills. The link from one race day's last event to the next one's first is not checked.
- **Its limit:** a device that leaves a race day and comes back to it later in the same day shows a
  hole there for the race day in between. It reads as catching up, never as altered.
- **This phone's own chain** is verified against every stub naming it, and shows only when it is
  broken: as a banner above the rows, naming its first bad event.
- Each row names its phone by the role and station its latest event carries, and the end of its
  device id.

## What the chain cannot show

- **An altered last event.** Nothing links to it yet, so it shows only once another event follows
  it, or against a copy already on shore.
- **A rewritten tail.** Someone who alters an event and then rewrites every link after it, on the
  one phone, leaves a consistent chain. It shows against the shore copy, which holds the original
  links (#62).
- **Events written before #28.** They carry no `prev_hash`, so their chain verifies as broken from
  its first event. The pilot's field test (#8) has not run, so no committee's log predates the chain.

## The vectors

`fixtures/chain/` holds one JSON file per case. The set covers:

- intact, a gap in the middle and a missing start;
- an altered payload byte, a removal re-linked in the middle and at the start, a first link that
  is not genesis, and a fork;
- a handoff to a new device.

Each file lists every event's hash and canonical text, then the expected verdict for each device.
Expected verdicts are written by hand from this document. `fixtures/chain/README.md` states the
format and the direction of the set.
