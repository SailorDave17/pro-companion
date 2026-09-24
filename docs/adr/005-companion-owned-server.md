# ADR 005 — The companion owns its server side: a separate Supabase project

- Status: proposed 2026-09-23 (owner chose the shape at a gate; this text awaits approval on its PR)
- Builds on: pro-companion ADR 001 (offline-first phones syncing to Supabase), burgee ADR 002
  (Supabase as the data layer — kept), burgee ADR 004 (the repo split)
- Supersedes: groom decisions G6 and G16 on #12; amends G7, and the server half of G12, G13 and G18
- Scope of record: `cairn/memory/projects/pro-companion-scope-2026-08-14.md` (2026-09-23 section);
  field scan `cairn/memory/reference/supabase-org-billing-and-firebase-as-alternative-2026-09-23.md`

## Context

The 2026-09-23 delta groom routed the companion's server half to burgee: the general event log
"beside burgee#7's tables", role enforcement on that table, the storage bucket, the club record,
and the public views — ten held stories, under groom decisions G6, G7 and G16. Every one of them
depended on burgee's race-day schema (burgee#6) and magic-link sign-in with club roles (burgee#9),
and burgee has no `supabase/` directory and no migrations yet.

So the standalone claim held only for milestone 1. The charter calls the companion
standalone-capable, and G7 had already narrowed "standalone" to "no burgee account needed" while
keeping "the same Supabase". Past the first on-water test, every multi-phone story waited on
foundations in a repo this one does not control. The owner's words, the same day: *"pro-companion
should be able to operate stand alone, especially in the beginning stages."*

## Options considered

- **Server half in burgee's project** (the groom's routing) — one project, one schema, burgee's
  scorer and public pages read their own tables. Rejected: the dependency runs against the product's
  standalone claim, and burgee's foundations are unbuilt, so the companion's pilot would be gated on
  another repo's sequencing.
- **Same Supabase project, companion-owned schema** — a `committee` schema whose migrations live in
  pro-companion and are applied only by pro-companion tooling; burgee's public pages read plain
  views; about $10/month more than the groom's routing. **Recommended by the session** on cost and on
  same-database reads. **Rejected by the owner**: two repos migrating one database is shared
  ownership with extra steps, and the Supabase CLI keeps one migration history per database.
- **Separate Supabase project — chosen.** Full ownership, clean boundary, one extra Micro instance.
  The organisation shape was decided in the same exchange: a **second organisation under the
  owner's existing Supabase account, on Pro from day one**, holding burgee's project and the
  companion's. Tender and Taskr stay free in the existing organisation. Two variants were priced
  and set aside: upgrading the existing organisation (its Nano projects would be billed at the Micro
  rate — about $10/month more for the same result), and a new account under a new email (a clean
  identity, but the free allowance it would buy is not a pilot plan, and the second-org shape gives
  the same ownership boundary under one login).
- **Firebase** — Firestore, Auth, Storage and Functions on Blaze. Scanned 2026-09-23 against the
  vendor's own pages: near-zero cost at pilot volume, anonymous sign-in with custom claims (the
  role-in-the-credential design of held story H31), create-only rules, a server `time` field for
  receipt-time enforcement, realtime fan-out for free. Set aside for the pilot: burgee is Postgres, so
  re-derivation and the public pages would need a **cross-vendor** bridge; Functions and Storage need
  Blaze, which has no global spend cap; an idempotent retry is a refusal rather than a no-op; claims
  propagate only on token refresh; email-link sign-in on Flutter carries the Dynamic Links scar
  (shutdown 2025-08-25, the FlutterFire fix closed 2026-06-10); export needs Blaze and lands in a
  proprietary format; and cairn holds no Firebase experience at all. The dated findings are in the
  scan note above.

## Decision

1. **pro-companion owns `supabase/`** — CLI config, migrations, policies and database functions —
   for everything the phones sync to: the admission spine (club, event, fleet, committee device —
   #39), the general event log (#40), the local-stack test harness (#41), and, when their stories
   are filed, shore-side chain verification, role enforcement, the storage bucket, club
   provisioning, and the derived views for released results and running order.
2. **Auth is this project's Supabase Auth.** Anonymous sign-in for the device-handoff path, magic
   link for named volunteers (both paths of #5), roles granted by an admission function and carried
   per H31. burgee membership never gates a companion phone. The club and fleet rows carry a
   **nullable burgee id** so a burgee-run club maps onto its burgee records later; nothing waits for
   that mapping.
3. **burgee is a reader, and one writer, through a published boundary.** Released results and the
   running order are exposed as derived views readable by burgee's server with a key scoped to
   those views — never raw events, GPS, notes or names. The ClubSpot web importer (G18) appends an
   entries-imported event through an insert function. Whether burgee reads over PostgREST or the
   companion pushes by webhook is picked at the start of the first public-page story (held H42),
   with burgee#13's 60-second public bar as the test.
4. **Shared artefacts keep their directions.** Scoring vectors: burgee → companion, vendored with
   a drift check (#2, #17 — unchanged). Chain and rounding fixtures: companion → burgee (held H87 —
   unchanged). The synthetic ClubSpot fixture (held H72) moves its canonical home to the companion.
5. **Cost.** A Micro instance, about $10/month, in a Pro organisation shared with burgee's project:
   about $35/month for both. With Vercel Pro the stack lands near **$55 against the charter's $50
   line**, accepted by the owner. The free tier was rejected for this project: a free project pauses
   after a week idle, keeps no backups, and the account's free allowance is already full.

## Consequences

- **Milestone 1 is unchanged.** It has no server. The three foundation stories are filed as the
  milestone-2 seed (owner decision, over keeping them held).
- **Ten held stories are re-routed** in the groom run record: H28 → #40, H75 → #39 (widened to
  every club — it is the tenancy spine now), H27 → #41 (own migrations, no burgee vendoring); H29,
  H32, H53 and H72 move to pro-companion; H42, H43, H46 and H74 stay in burgee and cross the
  boundary in point 3; H30 and H31 lose their burgee#9 dependency; H33 depends on #40; H37 becomes
  a burgee-integration story. The estimate split moves from 112.5 / 17 to about 120.5 in
  pro-companion, 7.5 in burgee (four stories) and 1.5 in race-timer.
- **#2, #4, #5, #6, #7 and #8 are re-parented** from burgee epic #2 to #12. burgee#2 keeps #35 and
  #38, its web-side stories.
- **ADR 001 is amended**: "Supabase" in it means this project, and its append-only reference points
  at #40's policies rather than burgee#7.
- **Two Postgres projects now hold overlapping club, event and fleet models.** The nullable burgee
  ids are the seam. Double entry across it is the failure to watch for.
- **Owner-only prerequisites**: create the organisation and the project, store the project ref and
  anon key as Actions secrets (#39's external criterion). Until then #39 is blocked and nothing on
  the server path starts — **not** by borrowing burgee's project as a stopgap, which recreates the
  dependency this ADR removes.

## Kill conditions

- If burgee's re-derivation or public pages cannot meet the 60-second bar reading across projects,
  revisit the **same-project, companion-owned schema** option — the ownership stands; the boundary
  mechanism is what moves.
- If the racing organisation's Supabase bill exceeds the accepted $5 overrun, or the club/event
  seam forces double entry at a real club, reopen this ADR. Firebase is the recorded alternative and
  its numbers are dated 2026-09-23 — re-scan before choosing it.
- If #39's prerequisites are still missing when milestone 2 is due to start, that is a blocker to
  surface, not a reason to start the server work elsewhere.
