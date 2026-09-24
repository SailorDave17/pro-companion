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

Credentials: `.env.example` names what the app and CI read; values live in a git-ignored
`.env.local` and in the repository's Actions secrets. `test/no_secrets_in_tree_test.dart` refuses
any credential-shaped string in the tracked tree.
