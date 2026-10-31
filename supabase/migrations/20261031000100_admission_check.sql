-- 20261031000100_admission_check.sql
-- pro-companion #73, groom decisions G44 and G46: the server accepts an event only under the
-- admission, role and race day its phone actually holds, so the attribution on the record is the
-- database's, not the app's. #49 made every phone stamp admission_id inside the canonical text;
-- this file is the check on it.
--
-- - The log gains admission_id, generated from the text like every other envelope column, and the
--   phones may read it (#50's column list grows by one).
-- - append_event judges the text's admission after the caller and before the insert:
--   1. A byte-identical re-send of a stored event is still a no-op, judged before anything else, so
--      a rule added later never turns a retry into a refusal.
--   2. The admission named must be one of the caller's rows on this race day: active or superseded.
--      It may also be another user's admission of this race day, when that user holds no revoked
--      admission here and the chain of successors from the named row ends in an admission of the
--      slot (role and race area) the caller's active admission holds. That is the device-handoff
--      link (owner decisions at pickup and at the review, 2026-10-31, from the conflict #6 raised):
--      a phone that lost its session signs in as a new user and is admitted again with the slot's
--      code, and the events it logged before the loss still name the admission they were written
--      under, including those before a role change it made before the loss. The link is the code,
--      not the device. A user holds one active admission per race day and a role change supersedes
--      within it, so the chain ends in that user's active row, and no recursion is needed. Anything
--      else, a null admission included, is refused as admission_mismatch.
--   3. The text's role must be the admission's role. A different role, or none, is refused as
--      role_mismatch. The text is never rewritten: rewriting breaks the hash the phone computed.
--   4. Under a superseded admission (#70), an event is accepted up to the phone's role-change marker
--      and refused past it (G46). The marker is the device's event of kind admission.superseded
--      written under the old admission; an event under that admission whose seq is above the
--      marker's is refused as admission_superseded. With no marker stored yet the event is
--      accepted: a phone uploads in sequence order, so the marker lands before anything written
--      after it. The marker's payload is the phone's (#71); the server reads only its kind and seq.
--   5. Then the text is inserted, and #48's inconsistent_canonical and ulid_conflict apply as before.
--   A refusal is kept and answered exactly as #48 does.
-- - Why a live committee_device lookup, not a JWT claim: a claim would need the access-token hook,
--   changes only when the token is refreshed, and cannot differ per event for one anonymous user,
--   where the lookup reads the rows as they are, superseded and revoked ones included, on every
--   call (README, "The event log, and the events it refuses").
--
-- A new file, never an edit of an applied one. Every statement is re-runnable against the schema
-- this file creates. It replaces event_refusal_reason_check, which is the one drop here: the
-- constraint, not a row.

-- The admission column ----------------------------------------------------------------------------
-- Generated from the text like the rest (#40), so it cannot disagree with it. Its type is uuid: the
-- core refuses to stamp anything else (#49), and a text naming something else is refused as
-- admission_mismatch before the cast is ever reached.

alter table public.event_log
  add column if not exists admission_id uuid
    generated always as ((canonical::jsonb ->> 'admission_id')::uuid) stored;

comment on column public.event_log.admission_id is
  'The admission the event was written under, read from the text (#49, #73): the phone''s '
  'committee_device row. Never null on a row append_event stored, since it refuses a text naming '
  'none, and a phone never uploads an event from before its first admission; null only on a row '
  'the table owner inserted, as test fixtures are. append_event holds it to the caller''s rows, so '
  'the attribution is the database''s.';

-- The role-change marker lookup: one device's markers under one admission on one race day.
create index if not exists event_log_marker_idx
  on public.event_log (event_id, device_id, admission_id)
  where kind = 'admission.superseded';

-- #50's column list grows by the new column, so a phone's select=* keeps working.
grant select (admission_id) on public.event_log to authenticated;

-- The three new reason categories ---------------------------------------------------------------------
-- #48 said #73 adds its categories by replacing the check in a new file.

alter table public.event_refusal drop constraint if exists event_refusal_reason_check;
alter table public.event_refusal
  add constraint event_refusal_reason_check
  check (reason in ('not_admitted', 'revoked', 'inconsistent_canonical', 'ulid_conflict',
                    'admission_mismatch', 'role_mismatch', 'admission_superseded'));

comment on column public.event_refusal.reason is
  'Why it was refused: not_admitted, revoked, inconsistent_canonical (the text cannot be stored as '
  'an event), ulid_conflict (another event is stored under its ULID), admission_mismatch (the text '
  'names an admission that is not the caller''s on this race day, #73), role_mismatch (the text''s '
  'role is not the admission''s, #73) or admission_superseded (written under a superseded admission '
  'past its role-change marker, #73, G46). #75 adds its own.';

-- append_event --------------------------------------------------------------------------------------
-- #48's function with the admission judged between the caller and the insert. The order:
--
-- 1. revoked, then not_admitted, as #48 judges the caller.
-- 2. A byte-identical re-send of a stored event answers accepted with duplicate true, before any
--    judgement of the text.
-- 3. A text that parses as a JSON object is judged on its admission, role and marker, as the header
--    says. A text that does not parse is left to the insert, which refuses it as inconsistent.
-- 4. The insert, with #48's inconsistent_canonical and ulid_conflict.
--
-- create or replace keeps #48's grants: execute for authenticated, none for anon, service_role or
-- public.

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
  v_named      uuid;
  v_admission  public.committee_device%rowtype;
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

  -- The text as JSON, where it parses to an object; null otherwise. seq where it is an integer.
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
    -- The admission as a uuid, so the lookup below takes committee_device's primary key; a text
    -- that is not one names no admission, and is refused as admission_mismatch.
    begin
      v_named := (v_json ->> 'admission_id')::uuid;
    exception when data_exception then
      v_named := null;
    end;
  else
    v_json := null;
  end if;

  if v_revoked then
    v_reason := 'revoked';
  elsif not v_active then
    v_reason := 'not_admitted';
  elsif v_json is not null and exists (select 1 from public.event_log l
                                       where l.ulid = v_json ->> 'ulid'
                                         and l.event_id = p_event
                                         and l.canonical = p_canonical) then
    -- A re-send of a stored event, byte for byte: a no-op whatever the rules below say now.
    return jsonb_build_object('outcome', 'accepted', 'duplicate', true, 'hash', v_hash);
  else
    if v_json is not null then
      -- The admission named: the caller's own row on this race day, or another user's row of it
      -- when that user holds no revoked admission here and the row's chain of successors ends
      -- (in that user's active row, h) in the slot the caller's active admission (c) holds: the
      -- device-handoff link.
      select d.* into v_admission
      from public.committee_device d
      where d.id = v_named
        and d.event_id = p_event
        and (d.auth_uid = v_uid
             or (not exists (select 1 from public.committee_device r
                             where r.auth_uid = d.auth_uid
                               and r.event_id = p_event
                               and r.revoked_at is not null)
                 and exists (select 1
                             from public.committee_device h
                             join public.committee_device c
                               on c.auth_uid = v_uid
                              and c.event_id = p_event
                              and c.superseded_by is null
                             where h.auth_uid = d.auth_uid
                               and h.event_id = p_event
                               and h.superseded_by is null
                               and h.role = c.role
                               and h.course_id is not distinct from c.course_id)));
      if v_admission.id is null then
        v_reason := 'admission_mismatch';
      elsif (v_json ->> 'role') is distinct from v_admission.role then
        v_reason := 'role_mismatch';
      elsif v_admission.superseded_by is not null
            and exists (select 1 from public.event_log m
                        where m.event_id = p_event
                          and m.device_id = v_json ->> 'device_id'
                          and m.admission_id = v_admission.id
                          and m.kind = 'admission.superseded'
                          and m.seq < v_seq) then
        v_reason := 'admission_superseded';
      end if;
    end if;

    if v_reason is null then
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
  end if;

  -- Refused. Kept only when the caller holds a committee_device row in the event's club (G43).
  if v_in_club then
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
  'event_refusal when the caller holds a committee_device row in the club (G43). Since #73 the '
  'text''s admission must be the caller''s on the race day, or another unrevoked user''s whose '
  'successors end in the slot the caller''s active admission holds; its role the admission''s; and '
  'under a superseded admission its seq at or below the device''s admission.superseded marker (G46).';
