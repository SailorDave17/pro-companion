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

It refuses an event from a phone that is revoked or not admitted to that race day. It also refuses a
text that cannot be stored as an event, and a different event under a ULID already stored. A
refusal answers HTTP 422 with code `append_event_refused` and the reason in `details`. It is final,
where a transient failure is a network error or a 5xx, so the phone keeps a refused event and does
not send it again.

**The server keeps data it refused.** When the phone that sent a refused event holds any admission
in that club, active, superseded or revoked, the server keeps the event in `event_refusal`
(groom decision G37). It is kept with its exact bytes: the full payload, including GPS, names and
notes. A phone with no admission in the club leaves nothing behind (G43).

- **Only service_role and the owner's tooling can read the refusals.** No phone can read, write,
  change or delete one.
- **They are kept as long as the event's log, with no separate purge** (G45). Like the log, they
  cannot be updated or deleted by any role, the owner included.

### Tests against the local stack

Some Dart tests talk to the local stack through its API, as a phone or as the owner's tooling:
`test/local_stack_test.dart`, `test/append_event_test.dart`, `test/sign_in_path_test.dart`, and the
local-stack group in `test/owner_script_test.dart`. They skip unless `PRO_COMPANION_LOCAL_STACK=1`,
so with the stack started:

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
  `scripts/start_local_stack.sh`, resets it, and runs the whole suite with the variable set. So a
  migration that fails to apply fails the job, and a new local-stack test runs there with nothing
  to register.
  - The script starts only the four services the tests use: the database, auth, the REST API and
    its gateway.
  - It retries `supabase start` only when an image pull fails outright. That is the CLI's
    `failed to pull docker image`, printed after its own three tries, which both ECR and ghcr.io
    throttles cause on some days. Any other failure fails at once, a migration that fails to apply
    among them.
- **The stack allows 30 anonymous sign-ins an hour per IP** (`[auth.rate_limit]`), and each
  device-handoff phone is one. A full run signs in 16 of them, so a second full run within the hour
  can reach the limit; run one file at a time while working. A named volunteer's phone spends a
  token verification instead, which the stack also allows 30 of an hour. A full run spends 4.

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
  `sign_in_mode=named_volunteers path=device_handoff`. A phone already admitted gets its admission
  back whatever the mode, and goes on writing. Nothing is reinstalled.
- **The path is read from the phone's token.** Its `is_anonymous` claim is true on device handoff
  and false for a named account. A token without the claim is neither, so only `both` admits it.
- **A replacement phone** presents the same role's code and gets an admission of its own. The phone
  it replaces is not revoked.
- **The script prints the mode it reads back** after the switch, not the one it asked for, and fails
  when they differ. It finds its target and key as `provision` does.

Not built yet: the phone's sign-in screens (the code entry is #71), revoking a phone (#72), stamping
each event with the admission it was written under (#49, checked by the server in #73), sync after
a phone signs in again (#6), and magic-link mail and its redirect on the live project, which are
held for the pilot's sixth milestone.

Credentials: `.env.example` names what the app and CI read; values live in a git-ignored
`.env.local` and in the repository's Actions secrets. `test/no_secrets_in_tree_test.dart` refuses
any credential-shaped string in the tracked tree.
