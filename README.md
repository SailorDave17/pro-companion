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

Credentials: `.env.example` names what the app and CI read; values live in a git-ignored
`.env.local` and in the repository's Actions secrets. `test/no_secrets_in_tree_test.dart` refuses
any credential-shaped string in the tracked tree.
