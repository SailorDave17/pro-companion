-- 20260925000500_append_event.sql
-- pro-companion #48, groom decisions G37, G43 and G45: every event a phone sends goes through one
-- function, append_event, and an event it refuses from a committee phone of the club is kept, with
-- its exact bytes, apart from the log.
--
-- - append_event(event, canonical) is the only client path into event_log. An accepted event is
--   stored exactly as #40 defines it, and a byte-identical re-send is still a no-op.
-- - A refusal is answered as an error the phone can tell from a transient failure: HTTP 422, with
--   code append_event_refused and the reason category in details. It is returned, not raised,
--   because raising would roll the refusal record back with the event.
-- - A refused event is kept in event_refusal when the caller holds any committee_device row in the
--   event's club (G43). A stranger's event is refused and not kept.
-- - Only service_role and the owner's tooling read event_refusal. It is append-only for every role,
--   like the log (owner decision on #48), so it is retained as long as the event's log (G45).
--
-- The reason categories here are not_admitted, revoked, inconsistent_canonical and ulid_conflict
-- (owner decision on #48: a different body under a stored ULID is kept as its own category). The
-- admission-mismatch (#73) and critical-kind (#75) stories add theirs inside the same function.
--
-- A new file, never an edit of an applied one. Every statement is re-runnable against the schema
-- this file creates.

-- The refusal record ---------------------------------------------------------------------------------
-- device_id and seq are read from the text where it parses, and are null where it does not, since
-- the text of an inconsistent event may be anything. canonical is the bytes exactly as sent, and
-- event_hash is their SHA-256, the refused event's hash in the chain (docs/event-chain.md). One
-- record per event and hash, so a refused event re-sent leaves one record.

create table if not exists public.event_refusal (
  id          uuid        primary key default gen_random_uuid(),
  event_id    uuid        not null references public.event(id),
  canonical   text        not null,
  event_hash  text        not null,
  device_id   text,
  seq         bigint,
  reason      text        not null,
  auth_uid    uuid        not null,
  refused_at  timestamptz not null default now(),
  constraint event_refusal_once unique (event_id, event_hash),
  constraint event_refusal_reason_check
    check (reason in ('not_admitted', 'revoked', 'inconsistent_canonical', 'ulid_conflict'))
);

comment on table public.event_refusal is
  'Every event append_event refused from a caller holding a committee_device row in the event''s '
  'club (#48; groom decisions G37 and G43), kept apart from event_log with its exact bytes. Full '
  'payloads, GPS, names and notes included, so only service_role and the owner''s tooling read it. '
  'Append-only for every role, and retained as long as the event''s log (G45).';
comment on column public.event_refusal.canonical is
  'The refused event''s text exactly as the phone sent it, whether or not it parses.';
comment on column public.event_refusal.event_hash is
  'The SHA-256 of canonical''s UTF-8 bytes, 64 lowercase hex characters: the refused event''s hash '
  'in its device''s chain (docs/event-chain.md).';
comment on column public.event_refusal.device_id is
  'The envelope''s device_id, read from the text; null where the text does not parse.';
comment on column public.event_refusal.seq is
  'The envelope''s seq, read from the text; null where the text does not parse or seq is not an '
  'integer.';
comment on column public.event_refusal.reason is
  'Why it was refused: not_admitted, revoked, inconsistent_canonical (the text cannot be stored as '
  'an event) or ulid_conflict (another event is stored under its ULID). #73 and #75 add theirs.';
comment on column public.event_refusal.auth_uid is
  'The Supabase Auth user that called append_event.';
comment on column public.event_refusal.refused_at is
  'The server''s time of the refusal.';

alter table public.event_refusal enable row level security;

-- Grants --------------------------------------------------------------------------------------------
-- No client role holds any privilege, and there is no policy. service_role reads it and never writes
-- it; append_event writes it as the table owner.

revoke all on public.event_refusal from public, anon, authenticated, service_role;
grant select on public.event_refusal to service_role;

-- Append-only, for every role (owner decision on #48, as #40 decided for the log) --------------------
-- Per statement and ENABLE ALWAYS, like the log's. A purge of an event's log disables these in the
-- same file as the log's, which is what "retained as long as the event's log" means (G45).

create or replace function public.event_refusal_refuse_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'event_refusal is append-only: % refused', tg_op;
end;
$$;

drop trigger if exists event_refusal_no_update on public.event_refusal;
create trigger event_refusal_no_update
  before update on public.event_refusal
  for each statement execute function public.event_refusal_refuse_change();

drop trigger if exists event_refusal_no_delete on public.event_refusal;
create trigger event_refusal_no_delete
  before delete on public.event_refusal
  for each statement execute function public.event_refusal_refuse_change();

drop trigger if exists event_refusal_no_truncate on public.event_refusal;
create trigger event_refusal_no_truncate
  before truncate on public.event_refusal
  for each statement execute function public.event_refusal_refuse_change();

alter table public.event_refusal enable always trigger event_refusal_no_update;
alter table public.event_refusal enable always trigger event_refusal_no_delete;
alter table public.event_refusal enable always trigger event_refusal_no_truncate;

revoke execute on function public.event_refusal_refuse_change() from public, anon, authenticated;

-- The log has no direct client insert ----------------------------------------------------------------
-- #40 already revoked it. Stated again here because this file makes append_event the only path.

revoke insert on public.event_log from public, anon, authenticated, service_role;

-- append_event ----------------------------------------------------------------------------------------
-- The phone sends the race day and the event's canonical text. The caller is judged first, then the
-- text:
--
-- 1. A caller holding a revoked committee_device row in the event is refused as revoked.
-- 2. A caller holding no active row in the event is refused as not_admitted. So are a caller of
--    another club, a caller signed in as nobody and an event that does not exist, with one answer
--    for all three, so the function is not an oracle for which events exist.
-- 3. Otherwise the text is inserted into the log as the table owner, the one role that can.
--    - A re-send identical to the stored row inserts nothing (#40's insert trigger), and answers
--      accepted with duplicate true.
--    - A text that cannot fill the log's columns is refused as inconsistent_canonical: not JSON, a
--      required field missing, a value of the wrong type, or an escaped U+0000.
--    - A different text under a stored ULID is refused as ulid_conflict, by the log's primary key.
--
-- Any other error is raised as it is. It was not a judgement on the event, so it is neither
-- recorded nor answered as a refusal, and the phone retries it.

create or replace function public.append_event(p_event uuid, p_canonical text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid        uuid := auth.uid();
  v_club       uuid;
  v_in_club    boolean;
  v_revoked    boolean;
  v_active     boolean;
  v_hash       text;
  v_reason     text;
  v_ulid       text;
  v_constraint text;
  v_json       jsonb;
  v_seq        bigint;
begin
  if p_canonical is null then
    raise exception 'append_event: no canonical text' using errcode = '22004';
  end if;
  v_hash := encode(sha256(convert_to(p_canonical, 'UTF8')), 'hex');

  select e.club_id into v_club from public.event e where e.id = p_event;

  select count(*) > 0,
         coalesce(bool_or(d.event_id = p_event and d.revoked_at is not null), false),
         coalesce(bool_or(d.event_id = p_event and d.revoked_at is null), false)
    into v_in_club, v_revoked, v_active
  from public.committee_device d
  where d.auth_uid = v_uid and d.club_id = v_club;

  if v_revoked then
    v_reason := 'revoked';
  elsif not v_active then
    v_reason := 'not_admitted';
  else
    begin
      insert into public.event_log (event_id, canonical) values (p_event, p_canonical)
      returning ulid into v_ulid;
      return jsonb_build_object('outcome', 'accepted', 'duplicate', v_ulid is null, 'hash', v_hash);
    exception
      when unique_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint is distinct from 'event_log_pkey' then
          raise;
        end if;
        v_reason := 'ulid_conflict';
      when data_exception or not_null_violation then
        v_reason := 'inconsistent_canonical';
    end;
  end if;

  -- Refused. Kept only when the caller holds a committee_device row in the event's club (G43).
  if v_in_club then
    begin
      v_json := p_canonical::jsonb;
    exception when data_exception then
      v_json := null;
    end;
    if jsonb_typeof(v_json) = 'object' then
      begin
        v_seq := (v_json ->> 'seq')::bigint;
      exception when data_exception then
        v_seq := null;
      end;
    else
      v_json := null;
    end if;

    insert into public.event_refusal (event_id, canonical, event_hash, device_id, seq, reason, auth_uid)
    values (p_event, p_canonical, v_hash, v_json ->> 'device_id', v_seq, v_reason, v_uid)
    on conflict (event_id, event_hash) do nothing;
  end if;

  -- PostgREST answers with this status and commits, so the record stays (measured on #48).
  perform set_config('response.status', '422', true);
  return jsonb_build_object(
    'outcome', 'refused',
    'reason',  v_reason,
    'hash',    v_hash,
    'code',    'append_event_refused',
    'message', 'append_event refused the event: ' || v_reason,
    'details', v_reason);
end;
$$;

comment on function public.append_event(uuid, text) is
  'The only client path into event_log (#48). Stores an accepted event, and answers a refusal with '
  'HTTP 422, code append_event_refused and the reason in details, keeping the refused event in '
  'event_refusal when the caller holds a committee_device row in the club (G43).';

revoke execute on function public.append_event(uuid, text) from public, anon, service_role;
grant  execute on function public.append_event(uuid, text) to authenticated;
