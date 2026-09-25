-- 20260925000300_event_log.sql
-- pro-companion #40 (held H28, re-homed by ADR 005): the general event log. Every event any
-- committee phone logs, of every kind, is kept here exactly as sent and never edited.
--
-- The row is the event's canonical text (RFC 8785, docs/event-chain.md), and every ADR 001 envelope
-- column is generated from that text. So the typed columns cannot disagree with the text: an insert
-- supplies an event id and the text, and a value for any typed column is refused. A verifier hashes
-- the stored text, never a re-serialisation of the columns.
--
-- No client role can write here. The client insert path is #48's append_event, and the select
-- policy is #50's. The admission column is #73's.
--
-- Every statement is re-runnable against the schema this file creates.

-- Table ---------------------------------------------------------------------------------------------
-- A JSON null in the text is SQL NULL in its typed column, for the jsonb columns as for the text
-- ones. So a required field that is missing or null is refused by its not-null constraint. A text
-- that is not JSON, or a seq, device_ts or payload_version that is not an integer, is refused by the
-- cast. Postgres's jsonb cannot hold U+0000, so an event whose text escapes one (\u0000) is refused
-- too. The constraint holds the columns to the text. It does not check that the text is itself in
-- RFC 8785 form.

create table if not exists public.event_log (
  ulid            text        generated always as (canonical::jsonb ->> 'ulid') stored primary key,
  event_id        uuid        not null references public.event(id),
  device_ts       bigint      generated always as ((canonical::jsonb ->> 'device_ts')::bigint) stored not null,
  device_id       text        generated always as (canonical::jsonb ->> 'device_id') stored not null,
  seq             bigint      generated always as ((canonical::jsonb ->> 'seq')::bigint) stored not null,
  person          text        generated always as (canonical::jsonb ->> 'person') stored,
  role            text        generated always as (canonical::jsonb ->> 'role') stored,
  gps             jsonb       generated always as (nullif(canonical::jsonb -> 'gps', 'null'::jsonb)) stored,
  source          text        generated always as (canonical::jsonb ->> 'source') stored not null,
  kind            text        generated always as (canonical::jsonb ->> 'kind') stored not null,
  payload_version integer     generated always as ((canonical::jsonb ->> 'payload_version')::integer) stored not null,
  payload         jsonb       generated always as (nullif(canonical::jsonb -> 'payload', 'null'::jsonb)) stored not null,
  corrects_ulid   text        generated always as (canonical::jsonb ->> 'corrects_ulid') stored,
  prev_hash       text        generated always as (canonical::jsonb ->> 'prev_hash') stored,
  canonical       text        not null,
  received_at     timestamptz not null default now()
);
create index if not exists event_log_event_device_seq_idx on public.event_log (event_id, device_id, seq);

comment on table public.event_log is
  'Every committee event of every kind, append-only (#40; ADR 001). The row is the event''s canonical '
  'text, and the ADR 001 envelope columns are generated from it. No role may update, delete or '
  'truncate a row. A re-sent event is a no-op, and a different event under a stored ULID is refused. '
  'Clients write only through #48''s append_event.';
comment on column public.event_log.canonical is
  'The event''s RFC 8785 canonical text exactly as the phone sent it (docs/event-chain.md). Its '
  'SHA-256 is the event''s hash. Text, not jsonb: jsonb reorders keys and normalises numbers, so a '
  'shore recompute would never match the phone''s hash.';
comment on column public.event_log.event_id is
  'The race day whose log this is. The canonical text carries no event, so the writer names it.';
comment on column public.event_log.received_at is
  'The server''s receipt time, set by the database on insert. A value the writer supplies is '
  'ignored. device_ts is the phone''s own clock, kept verbatim (ADR 001: two clocks).';

alter table public.event_log enable row level security;

-- Grants --------------------------------------------------------------------------------------------
-- No client role holds any privilege here, and there is no policy. service_role and the owner's
-- tooling read the log and never write it.

revoke all on public.event_log from public, anon, authenticated, service_role;
grant select on public.event_log to service_role;

-- Insert: receipt time, and a re-sent event ------------------------------------------------------------
-- A phone retries an upload it never saw acknowledged, so the same event can arrive twice, and at
-- once. A re-send identical to the stored row (same text, same event) is a no-op. Anything else
-- under a stored ULID is refused by the primary key (owner decision 2026-09-25): a retry is
-- byte-identical, and a different body is an altered event that must not vanish silently. The
-- advisory lock makes two concurrent identical inserts one row and one no-op, not a duplicate-key
-- error. Generated columns are not yet computed in a BEFORE trigger, so the ULID is read from the
-- text.

create or replace function public.event_log_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_ulid text;
begin
  new.received_at := now();
  v_ulid := new.canonical::jsonb ->> 'ulid';
  if v_ulid is not null then
    perform pg_advisory_xact_lock(hashtextextended('public.event_log:' || v_ulid, 0));
    if exists (select 1 from public.event_log l
               where l.ulid = v_ulid and l.canonical = new.canonical and l.event_id = new.event_id) then
      return null;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists event_log_before_insert on public.event_log;
create trigger event_log_before_insert
  before insert on public.event_log
  for each row execute function public.event_log_before_insert();

-- Append-only, for every role (owner decision 2026-09-25) --------------------------------------------
-- The phone's store refuses UPDATE and DELETE whatever issued them (#24), and this refuses them
-- again on the server (ADR 001: append-only everywhere). Per statement, so an update or delete
-- matching no row is refused too. ENABLE ALWAYS, so session_replication_role = replica does not
-- skip them. The table owner can still disable a trigger; a data migration or purge that has to
-- do that says so in its own file.

create or replace function public.event_log_refuse_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'event_log is append-only: % refused', tg_op;
end;
$$;

drop trigger if exists event_log_no_update on public.event_log;
create trigger event_log_no_update
  before update on public.event_log
  for each statement execute function public.event_log_refuse_change();

drop trigger if exists event_log_no_delete on public.event_log;
create trigger event_log_no_delete
  before delete on public.event_log
  for each statement execute function public.event_log_refuse_change();

drop trigger if exists event_log_no_truncate on public.event_log;
create trigger event_log_no_truncate
  before truncate on public.event_log
  for each statement execute function public.event_log_refuse_change();

alter table public.event_log enable always trigger event_log_no_update;
alter table public.event_log enable always trigger event_log_no_delete;
alter table public.event_log enable always trigger event_log_no_truncate;

revoke execute on function public.event_log_before_insert()  from public, anon, authenticated;
revoke execute on function public.event_log_refuse_change()  from public, anon, authenticated;
