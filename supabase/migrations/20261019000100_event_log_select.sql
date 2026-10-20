-- 20261019000100_event_log_select.sql
-- pro-companion #50: a phone reads its own event's log, and nothing else. This is the read half the
-- pull (#64) needs. #40 left the log with no client grant and no policy, so no phone could read it.
--
-- - A phone admitted to an event reads that event's rows. A phone admitted only to another event,
--   in this club or another, reads none of them.
-- - A phone never admitted reads no rows, whichever way it signed in (anonymously for device
--   handoff, or by magic link as a named volunteer).
-- - A revoked phone reads none of the event's rows. A phone whose role changed (#70) reads on
--   through its new admission.
-- - The anon key alone reads nothing: anon holds no grant, so it is refused (owner decision at
--   pickup, 2026-10-19).
--
-- Event-scoped, not race-area-scoped: no decision narrows reading, and the overall PRO needs every
-- race area. The policy reuses the spine's helper, which since #70 counts the phone's active,
-- unrevoked admission only, and only while no admission of the phone in the event is revoked.
--
-- Nothing here writes. append_event (#48) stays the one client write path, and the append-only
-- triggers (#40) still refuse every change, so a phone holding select on the log gains no other
-- privilege on it.
--
-- A new file, never an edit of an applied one. Every statement is re-runnable against the schema
-- this file creates.

-- Grant ---------------------------------------------------------------------------------------------
-- A column list, the spine's shape. Every column is granted today, so select=* works. A column a
-- later story adds (#73's admission column) is withheld until that story grants it, so a wildcard
-- read fails loudly rather than leaking or silently narrowing.

grant select (ulid, event_id, device_ts, device_id, seq, person, role, gps, source, kind,
              payload_version, payload, corrects_ulid, prev_hash, canonical, received_at)
  on public.event_log to authenticated;

-- Policy --------------------------------------------------------------------------------------------

drop policy if exists event_log_select_admitted on public.event_log;
create policy event_log_select_admitted on public.event_log
  for select to authenticated
  using (public.is_admitted_to_event(event_id));

comment on policy event_log_select_admitted on public.event_log is
  'A phone reads the log of an event it is admitted to, and no other (#50). The admission is the '
  'phone''s active one, not revoked, with no revoked admission in the event (is_admitted_to_event, '
  'since #70).';
