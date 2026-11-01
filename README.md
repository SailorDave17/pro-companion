# pro-companion

App that can be used as standalone or with companion apps to make the pros life easier on race day.

The race committee's companion — the whole team, not just the PRO: role-scoped views for the
signal boat, recorder, mark boats and safety boats, an append-only protest-ready log (the US
Sailing paper forms, digitized), finish capture, GPS course setting (templates by fleet and
conditions, mark coordinates pushed to the mark boats), and live results to shore when a burgee
event sits behind it. Flutter, Android-first; iOS follows post-pilot. Start signals stay with
race-timer for the pilot — this app records them.

Scope of record: the tiered feature scope and the owner decisions behind it live in
`cairn/memory/projects/pro-companion-scope-2026-08-14.md`; the product charter is
`burgee/docs/charter.md` (this app is burgee's RC companion, ADR 004, standalone-capable by
design).

## Field builds

Phones on the water run a release APK signed with the owner's upload key, never a debug build.
The key lives outside the repo, and a release build without it stops and names what is missing.
How to make the key, point the build at it, check the signature and sideload the APK:
`docs/field-builds.md` (#23).

## Server side

The companion owns the server it syncs to — its own Supabase project, separate from burgee's
(ADR 005). Everything server-side lives under `supabase/`:

- `supabase/migrations/` — the schema, applied in filename order. Each file is re-runnable against
  the schema it creates.
- `supabase/tests/` — pgTAP tests of the policies and functions. They run as the roles PostgREST
  runs as, so what they prove is the database's answer.
- `supabase/config.toml` — the local stack. `npx supabase start`, then `npx supabase db reset` to
  apply the migrations and `npx supabase test db` to run the tests. Needs Docker.

### The event log, and the events it refuses

A phone sends every event through one function, `append_event(event, canonical text)`. No client
writes the log (`event_log`) any other way. The function stores an event the phone is admitted to
write, exactly as sent, and a re-send of a stored event is a no-op.

**A phone reads the log of the race day it is admitted to, and nothing else** (#50). A phone never
admitted, or revoked from that race day, reads no rows, and the anon key alone is refused. A phone
whose role changed reads on through its new admission.

It refuses an event from a phone that is revoked or not admitted to that race day. It also refuses a
text that cannot be stored as an event, and a different event under a ULID already stored. A
refusal answers HTTP 422 with code `append_event_refused` and the reason in `details`. It is final,
so the phone keeps a refused event and does not send it again. Every other failure is retried: a
network error, a 5xx, and any error whose code is not `append_event_refused`, since an error the
function raises can arrive as a 4xx (#6 keys on the code, never on the status).

**The server holds the text to the phone's admission** (#73; groom decisions G44 and G46). Every
event names the admission it was written under (`admission_id`, stamped by the core since #49, and a
generated column of the log since #73). `append_event` judges it after the caller and before the
insert, and never rewrites the text, which would break the hash the phone computed:

- **The admission named must be the caller's own on that race day**, active or superseded. It may
  also be another user's admission of the race day, when that user holds no revoked admission
  there and the chain of successors from the named admission ends in the slot (role and race
  area) the caller's active admission holds: the **device-handoff link**. A phone that lost its
  session signs in as a new user and is admitted again with the slot's code, and the events it
  logged before the loss still name the admission they were written under, those from before a
  role change it made before the loss included; the link is the code, not the device (owner
  decisions, 2026-10-31). A slot the caller held earlier that day and left does not count.
  Anything else, a null admission included, is refused as `admission_mismatch`. A phone admitted
  to two race days names each day's own admission on that day's events.
- **The text's role must be the admission's role.** A different role, or none, is refused as
  `role_mismatch`.
- **Under a superseded admission** (a role change, #70), events are accepted up to the phone's
  role-change marker and refused past it (G46) as `admission_superseded`. The marker is the device's
  event of kind `admission.superseded`, logged under the old admission; its own sequence number is
  the bound, and its payload is the phone's (#71 logs it before it stamps the new admission). With
  no marker stored, events under a superseded admission are accepted, since a phone uploads in
  sequence order and the marker lands before anything written after it.
- **A byte-identical re-send of a stored event is a no-op** before any of this is judged, so a rule
  added later never turns a retry into a refusal.

The three refusals are kept like the others, and a phone reads each as a stub.

**Why a live `committee_device` lookup, not a JWT claim.** A role claim would need the access-token
hook, and it changes only when the token is refreshed, so a role change or a revocation would hold
until the next refresh. It also cannot differ per event for one anonymous user, where a phone may
hold admissions on two race days, and a superseded one beside its active one. The lookup reads the
rows as they are on every call, superseded and revoked ones included, which is what the marker
rule and the handoff link need. Its cost is a few indexed reads of `committee_device` per append
(the named admission by its key, the rest by the user's index), and one of the marker index under
a superseded admission.

**The server keeps data it refused.** When the phone that sent a refused event holds any admission
in that club, active, superseded or revoked, the server keeps the event in `event_refusal`
(groom decision G37). It is kept with its exact bytes: the full payload, including GPS, names and
notes. A phone with no admission in the club leaves nothing behind (G43).

- **Only service_role and the owner's tooling can read a whole refusal.** A phone admitted to the
  race day reads its stub only (#60, G41): the device, the sequence, the refused event's hash and
  the reason, so it can show another phone's chain as refused at that point. No phone can read the
  text or who sent it, and none can write, change or delete a refusal.
- **They are kept as long as the event's log, with no separate purge** (G45). Like the log, they
  cannot be updated or deleted by any role, the owner included.

### Sync: the phone's own events, up to the log

`packages/sync` (#6, ADR 006) uploads each of the phone's own events through `append_event`,
exactly once, and keeps every outcome in the core's store beside the log. It is pure Dart, for the
headless core engine; the UI never imports it (`test/import_boundary_test.dart`).

- **Each event goes as its stored text, byte for byte**, to the race day its own admission belongs
  to. A re-send is harmless, so a lost answer is simply retried.
- **Accepted and refused are final**, kept in the core's append-only upload tables, and the UI reads
  them, with how the last run ended, through `CoreClient.uploadStatus()`. A refusal found after an
  earlier send's answer was lost is flagged as maybe already on shore.
- **Nothing is sent to a race day the signed-in user holds no admission to.** A lost session, or a
  new user not yet admitted, pauses sync rather than turning events into refusals. Events written
  before the phone was ever admitted stay on the phone.
- **A refusal for revocation is the last send under the user's admissions on that race day**
  (#53), since the server refuses the user's every event there once any of them is revoked. Their
  other events, and every tap after, stay on the phone unsent, counted as `held` in
  `uploadStatus()`. Each would only be refused again, and every refusal stays in `event_refusal`
  for good. One exception: an event whose earlier send may have landed goes once more, so its
  refusal is flagged as maybe on shore. Once every race day has revoked the phone, sync stops
  running on its own until a tap nudges it or the phone is admitted again. A revocation is never
  lifted: a phone revoked on a race day is refused there whatever code it presents.
- **A revoked phone says so above every screen** (#53): a banner naming the race day, from
  `CoreClient.revocation()`, which the UI reads every 5 s. Capture goes on under it. Each line is
  shrunk to fit and never drawn below 16 px; a name too long even then is cut with an ellipsis,
  and a screen reader still reads it whole. The race day's name comes from the pull, which reads it
  once while the phone may read it. Once revoked, the server shows the phone no race day of the
  club unless it holds another admission there. A phone revoked before it ever read the name says
  "this race day".
- **Each phone shows what has reached shore** (#66): a chip in every race-time screen's app bar,
  and a row at the foot of each role's home, read from `uploadStatus()` and `pullStatus()` every
  5 s while its screen shows. It gives the count waiting and refused, the times of the last
  accepted upload and the last full pull, or offline with the age of the last sync when sync's
  latest run could not reach the server. A tap opens a full screen listing what waits by kind,
  each refused event with its kind and reason, and what stays on the phone (before admission, or
  under a revoked admission), which never counts as waiting. It reads only, so no append waits on
  it.
- **It keeps trying on its own** while anything is waiting, backing off to 15 s between runs, with
  every request bounded at 10 s, so an upload starts within 30 s of signal returning.
- **The session lives in one file**, rewritten on every change, in a directory that must not be
  backed up (a restored copy is a refresh token many rotations old). Sync never signs anyone in by
  itself.
- **Its tests:** `dart test` in `packages/sync` against a scripted server (the real Supabase client,
  only the transport faked), and `test/sync_test.dart` against the local stack.

### Sync: the other phones' events, down to this one

The same engine also pulls (#64). Once the upload half has reached the server, it reads every race
day the phone is admitted to: the other committee phones' events, and the refusal stubs (#60).
With nothing left to upload, a started engine runs again every 15 s to pull, unless every race day
has revoked the phone (#53, above).

- **A pulled event is kept as the server holds it, byte for byte**, so its device's chain verifies
  on this phone as it does on its own. It never enters this phone's own chain. An event on shore
  that names this phone but was never written here is refused, because it would take the number
  the next tap needs.
- **The cursor is per race day and per device**, worked out from what is stored. A pull asks for
  exactly the numbers it does not hold: below the lowest held, above the highest held, and each
  missing range in between (up to eight named per device, then everything above). So an event that
  reaches shore late is still delivered, and nothing held is sent again. It counts from the
  device's lowest number held there, not from 1, since a phone's first events (its role pick,
  before it is admitted) never reach shore, and numbers a device logged on another race day are a
  hole here that costs one range. A refused number counts as held, from its stub. A pull cut off
  mid-page resumes from exactly what it stored.
- **A device not seen yet is asked for only when its id is a ULID**, and every value the server
  sent back is quoted when a later page's filter carries it. So a row whose ids hold PostgREST's
  reserved characters can neither be stored nor break the pull for the phones after it.
- **A new event goes up first.** A pull yields at its next page when an event is appended, and
  resumes from what it stored.
- **A revoked phone is refused by the phone itself**, from its own `committee_device.revoked_at`,
  because the server's RLS answers a revoked phone's read with no rows, not an error. Nothing
  already stored is touched.
- **The UI reads it through the core**: `CoreClient.pullStatus()` says when a pull last read
  everything, and `readAll()` includes the other phones' events. **Every screen reads
  `readOwn()`**, this phone's events only, so a pull changes no screen (owner decision on #64).
  A story that shows the committee's view reads `readAll()` on purpose.
- **The committee log shows how each other phone's log reads (#67)**, from LOG on the PRO's home:
  verified, catching up, refused at N, or altered, per race day it was pulled from, and a banner
  when this phone's own chain is broken. The core verifies the chains (`CoreClient.chainStatus()`),
  a refusal stub standing in for the event it refused, so the screen sees neither the text nor the
  stubs. `docs/event-chain.md`, "What a phone shows", states the rules.
- **Finishes are timed across phones (#69)**: `CoreClient.raceTimes()` gives each fleet race the
  phone holds. A finish taken on another phone than the gun's is timed from the gun through both
  phones' clock offsets (#55), and one on the gun's own phone on that phone's clock. The race is
  flagged `unreconciled` or `two_finish_sources`. It is there for scoring and export to read;
  nothing reads it yet, and no screen shows it. `docs/marks.md` states the rules.
- **Neither half is in the app yet.** Starting it from the core host, with the project's URL and key, is
  #113's. The host itself is #32's (ADR 003, `lib/core_host.dart`), the foreground service that
  keeps the core running with the app closed. Since #46 a release build may use the network: the main
  manifest requests `INTERNET` and `ACCESS_NETWORK_STATE`, held there by
  `test/main_manifest_test.dart` and, in the release APK, by `scripts/check_release_signing.sh`.

### Tests against the local stack

Some Dart tests talk to the local stack through its API, as a phone or as the owner's tooling:
`test/local_stack_test.dart`, `test/append_event_test.dart`, `test/sign_in_path_test.dart`,
`test/sync_test.dart`, `test/owner_revoke_test.dart`, and the local-stack group in
`test/owner_script_test.dart`. They skip unless `PRO_COMPANION_LOCAL_STACK=1`, so with the stack
started:

```
PRO_COMPANION_LOCAL_STACK=1 flutter test
```

- **`test/support/local_stack.dart` is the helper.** A test asks it for a race day and for phones:
  - The club, event, race areas and codes come from the owner's tooling (`scripts/owner.dart`).
  - A device-handoff phone signs in anonymously, through the stack's own auth.
  - A named volunteer's phone signs in by magic link (#5). A test cannot click an email link, so the
    helper creates the account and generates its link through the stack's admin API, with the
    secret key. The phone then verifies the link's token with the publishable key, the request the
    link makes when it opens.
  - Each phone is admitted by `admit_device` with one of the printed codes, and never by the
    secret key.
  - A row no client can write, like the event log's, is seeded as the table owner through `psql`
    in the database container.
- **CI runs them in the `local-stack` job.** It starts the stack from `supabase/migrations` with
  `scripts/start_local_stack.sh`, resets it, runs the pgTAP suite under `supabase/tests/` (#51),
  and then runs the whole suite with the variable set. So a migration that fails to apply fails
  the job, a failing pgTAP assertion fails it, and a new local-stack test or pgTAP file runs there
  with nothing to register.
  - pgTAP runs first, on the freshly reset database, because the Dart tests commit rows that the
    pgTAP files' whole-table counts would see. Locally, run `db reset` again after a
    `PRO_COMPANION_LOCAL_STACK=1` run, before `test db`.
  - It runs as `supabase test db --debug`, which makes the CLI run pg_prove `--verbose`, so the log
    shows every test, not just one verdict per file.
  - The script starts only the four services the tests use: the database, auth, the REST API and
    its gateway.
  - It retries `supabase start` only when an image pull fails outright. That is the CLI's
    `failed to pull docker image`, printed after its own three tries, which both ECR and ghcr.io
    throttles cause on some days. Any other failure fails at once, a migration that fails to apply
    among them.
- **The stack allows 30 anonymous sign-ins an hour per IP** (`[auth.rate_limit]`), and each
  device-handoff phone is one. A full run signs in 20 of them, so a second full run within the hour
  can reach the limit; run one file at a time while working. A named volunteer's phone spends a
  token verification instead, which the stack allows 30 of **per 5 minutes**. A full run spends 22,
  15 of them in `test/sync_test.dart`, so prove a mutation there with `--plain-name` on one case.

### Applying a migration to the live project

`scripts/migrate_live.dart` applies migrations to the live project and records each one. It sends
each file through the Management API's query route, together with its row in the Supabase CLI's
migration history (`supabase_migrations.schema_migrations`), **in one transaction and under the
file's own version**. So the live history always says which files are applied, and a file never
runs twice.

```
dart run scripts/migrate_live.dart                    # plan: applied, pending, remote-only (read-only)
dart run scripts/migrate_live.dart sql apply <v>      # print exactly what apply would send
dart run scripts/migrate_live.dart apply              # apply every pending file, oldest first
```

- **Token.** A Supabase personal access token, read from `SUPABASE_ACCESS_TOKEN` in your shell,
  otherwise from **`SUPPABASE_TOKEN`** (spelled with a double P) in the git-ignored `.env.local`. It
  is an account-wide credential; never commit it.
- **Owner go-ahead.** `apply` and `record` write to production. Run `plan` and `sql apply` first
  and apply only at the owner's go-ahead.
- **One new file per change, and never an edit of an applied one.** Name it
  `<14-digit version>_<snake_case>.sql`, later than every file before it. The history stores each
  file as committed, with LF line endings whatever the checkout, so an edited file would no longer
  match what ran.
- **No file may carry its own `begin;` or `commit;`.** Every file runs inside the script's
  transaction, so if a statement fails, nothing of that file runs and nothing is recorded.
- **Read the answer from the history, not the exit code.** `apply` reads the history back after each
  file and fails unless that file's version is the one new row.
- `record <version>` marks a file as already applied without running it. It exists for files
  applied by another route: `20260924000100` was applied through the query route before this
  script existed, and #44 recorded it.

Not `supabase db push`, which needs the database password, a second production credential. Not
the Management API's own migrations routes either: they record history under a version they choose,
so the live history would never match the file names. On the local stack the Supabase CLI writes the
same history table itself.

### Provisioning a race day

For the pilot a club admin acts through the owner's scripts (groom decision G27).
`scripts/owner.dart provision` does three things:

- It reuses the club of exactly that name, or provisions one when there is none.
- It creates the event and its race areas.
- It prints every id and the event's admission codes. There is one for each event-wide role
  (overall PRO, scorer, safety), and one per race area for each bound role (course PRO, recorder,
  mark boat). `docs/roles.md` says which role is which.

```
dart run scripts/owner.dart provision --club "Hoover Sailing Club" --event "Club night" \
    --date 2026-09-27 --race-area Alpha --race-area Bravo
```

- **Target.** With no `--project` it runs against the local stack, taking the stack's URL and
  secret key from `supabase status`. It reaches the live project only when you name it, with
  `--project pxywvqhdywgrysmwvbxy`. It then reads the project's secret key from
  `SUPABASE_SECRET_KEY`, in your shell or in the git-ignored `.env.local`.
- **The admission codes** are printed once and stored only as hashes. A code admits a phone as the
  role printed beside it, and for a bound role on its race area, so hand each one to the volunteer
  doing that job. The phone never names its role, so no code but the overall PRO's makes a phone
  overall PRO. The script never writes a code to a file.

### How a club's phones sign in

A club chooses how its committee phones sign in (groom decision G39). Both ways end in a role's
admission code, presented to `admit_device`:

- **Device handoff.** The phone signs in anonymously. Its admission is tied to the event, club, role
  and race area, and never to a person, because the phone passes from hand to hand. A
  device-handoff phone that names a person is refused.
- **Named volunteers.** The phone signs in by magic link as the volunteer's own account, so the
  account holds the admission. It may also name a person.

The club's `sign_in_mode` says which of the two admits a new phone: `device_handoff`,
`named_volunteers` or `both`. Every club starts at `both`. The owner switches it:

```
dart run scripts/owner.dart sign-in-mode --club "Hoover Sailing Club" --mode named_volunteers
```

- **A switch applies to phones admitted after it.** A phone on a path the mode excludes is refused
  with HTTP 403, code `42501`, and `details` naming the mode and the path it signed in by, such as
  `sign_in_mode=named_volunteers path=device_handoff`. A phone already admitted that presents its own
  code again gets its admission back whatever the mode, and goes on writing. Nothing is reinstalled.
- **A role change is a new admission** (#70). A phone presenting another role's code, or the same
  role's code for another race area, gets a new admission under that role. Its old admission is
  marked superseded (`superseded_by` names the new one) and kept, so the record still says which
  role wrote what. A role change is held to the mode like a first admission. A named volunteer keeps
  their name unless they give a new one. A phone holding any revoked admission in the event is
  refused, whatever code it presents.
- **The path is read from the phone's token.** Its `is_anonymous` claim is true on device handoff
  and false for a named account. A token without the claim is neither, so only `both` admits it.
- **A replacement phone** presents the same role's code and gets an admission of its own. The phone
  it replaces is not revoked.
- **The script prints the mode it reads back** after the switch, not the one it asked for, and fails
  when they differ. It finds its target and key as `provision` does.

**The phone's join screen** (#71) is where a device-handoff phone presents its code: JOIN WITH CODE
on the role picker, the code typed as the script prints it (`XXXX-XXXX`; the field upper-cases and
inserts the dash), then JOIN. The core does the rest through sync, in order: it signs the phone in
anonymously when it holds no session; asks `race_day_for_code(code)` which race day the code was
issued for, so the volunteer never sees an event id (the function is a definer, callable by any
signed-in phone, and refuses a code issued to no race day or to more than one with `admit_device`'s
own message); calls `admit_device(event, code)`; reads the role and race area granted from the
phone's own `committee_device` row; and caches the admission on the core, where a change of
admission first appends the role-change marker (`admission.superseded`, G46) under the admission
being left. The screen then shows the role and race area granted, and one tap logs the role pick and
opens that role's home. A code the server refuses is one plain sentence that names no role, race
area or event, and the code stays in the field. With no signal, the screen says admission needs
signal, keeps the code and sends it again every five seconds until the server answers. On a build
with no server wired to the core (before #113 starts sync in the core host) the screen says so.

### Revoking a phone

When a committee phone is lost, the owner takes it off the event (#72). Run with no `--device`,
`revoke` lists the event's admissions and changes nothing:

```
dart run scripts/owner.dart revoke --club "Hoover Sailing Club" --event "Club night" --date 2026-09-27
```

Each line gives the id of the sign-in holding the admission, the Auth user the phone signed in as,
then the admission's role, race area, person, admitted time and state: `active`, `superseded`,
`revoked`, or `superseded, revoked`. Run it again with that id to revoke the sign-in:

```
dart run scripts/owner.dart revoke --club "Hoover Sailing Club" --event "Club night" --date 2026-09-27 \
    --device <id>
```

- **The id is a sign-in, not a handset.**
  - A phone that changed role has one line for each admission, all under one id.
  - A device-handoff phone that lost its session has signed in again as a new id, so one phone can
    hold two. Revoke each.
  - **A named volunteer's id is their account**, on every phone signed in to it. Revoking it takes
    all of those phones off the event, a replacement included.
- **It keys on the sign-in, not the role.** Every active admission that sign-in holds in the event
  is marked through `revoke_device`. Another sign-in holding the same role's code is untouched, and
  so are this sign-in's admissions to other events.
- **Its next write to the event is refused**, and so is any code it presents. What it already wrote
  stays in the log. A revocation is never lifted, so a named volunteer rejoins the event only under
  another account, or by device handoff if the club allows it. A new sign-in with the role's code
  is a new admission: revoking a sign-in does not retire the code.
- **Revoking twice is safe.** The second run reports no change and exits 0. An id with no admission
  to this event exits 1 and changes nothing. If the connection fails, the script says the change
  may or may not have landed, and running it again is safe.
- **It names one event and one sign-in a run.** A flag given twice is refused, so with two phones
  lost, run it once for each.
- **The script reads the admissions back.** A role change it sees there fails the run, so run it
  again. One landing just after the read-back can leave an `active` line behind an exit 0. The
  server still refuses that sign-in, and another revoke clears the line.
- **Two events can share a club, name and date**, since `provision` run twice makes them. The script
  then refuses and prints their ids, and `--event-id <id>` names one in place of the three flags.
  It finds its target and key as `provision` does.

Not built yet: the phone's magic-link screen (#104; the code entry is #71's join screen, above),
starting sync in the app (#113, which also wires the join screen's call to sync in the core host),
and magic-link mail and its redirect on the live project, which are held for the pilot's sixth
milestone.

Credentials: `.env.example` names what the app and CI read; values live in a git-ignored
`.env.local` and in the repository's Actions secrets. `test/no_secrets_in_tree_test.dart` refuses
any credential-shaped string in the tracked tree.

## Reading burgee from CI

burgee is private, so CI reads it with a read-only deploy key (#17). The private half is the Actions
secret `BURGEE_DEPLOY_KEY`. The public half is registered on burgee alone, as the deploy key
"pro-companion CI read (#17)" without write access, and GitHub refuses a push made with it. The
`burgee-read` job checks out one file from burgee's default branch and prints its size and hash,
never its content, because this repository's CI logs are public. It is there for the drift check on
burgee's vendored copies of `fixtures/` (ADR 005, point 4). A Dependabot pull request skips the job,
since it gets no Actions secrets.

To replace the key:

1. `ssh-keygen -t ed25519 -N "" -f <file outside the repo>`.
2. `gh repo deploy-key add <file>.pub --repo SailorDave17/burgee --title "pro-companion CI read (#17)"`.
   Without `--allow-write` it is read-only.
3. `gh secret set BURGEE_DEPLOY_KEY -R SailorDave17/pro-companion < <file>`, then delete both files.
4. Delete the old key under burgee's Settings → Deploy keys.
