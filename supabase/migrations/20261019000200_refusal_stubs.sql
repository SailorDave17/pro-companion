-- 20261019000200_refusal_stubs.sql
-- pro-companion #60, groom decision G41: a phone admitted to a race day reads a content-free stub of
-- each event refused on that race day, so it can show another phone's chain as "refused at N" and
-- keep verifying past it.
--
-- The stub is five columns of #48's refusal record: the race day, the device, the sequence, the
-- refused event's hash and the reason category. The rest stays service_role's only (G37): the
-- event's text (payload, GPS, person, notes), the Auth user that sent it, the time and the record's
-- id. The phone already shares the race day's log, and the stub says only where a device's chain was
-- refused and why.
--
-- - A phone admitted to the race day reads its stubs. A phone of another race day, in this club or
--   another, a phone never admitted and a revoked phone read none.
-- - The anon key alone holds no grant and is refused, as on the log (#50).
-- - The stub is a column grant on the record itself, not a second table or a view (owner decision at
--   pickup, 2026-10-19), so there is one write path, append_event (#48), and the record stays
--   append-only for every role.
--
-- A new file, never an edit of an applied one. Every statement is re-runnable against the schema
-- this file creates.

-- Grant ---------------------------------------------------------------------------------------------
-- The stub's columns only. A phone selecting any other column, select=* included, is refused, and so
-- is a filter or an order on one (supabase-rls-column-grants).

grant select (event_id, device_id, seq, event_hash, reason) on public.event_refusal to authenticated;

-- Policy --------------------------------------------------------------------------------------------

drop policy if exists event_refusal_stub_select_admitted on public.event_refusal;
create policy event_refusal_stub_select_admitted on public.event_refusal
  for select to authenticated
  using (public.is_admitted_to_event(event_id));

comment on policy event_refusal_stub_select_admitted on public.event_refusal is
  'A phone reads the refusal stubs of an event it is admitted to, and no other (#60, G41). The '
  'columns it may read are the stub''s only: event_id, device_id, seq, event_hash and reason.';

comment on table public.event_refusal is
  'Every event append_event refused from a caller holding a committee_device row in the event''s '
  'club (#48; groom decisions G37 and G43), kept apart from event_log with its exact bytes. Full '
  'payloads, GPS, names and notes included, so only service_role and the owner''s tooling read the '
  'whole record. A phone admitted to the event reads its stub only: event_id, device_id, seq, '
  'event_hash and reason (#60, G41). Append-only for every role, and retained as long as the '
  'event''s log (G45).';
