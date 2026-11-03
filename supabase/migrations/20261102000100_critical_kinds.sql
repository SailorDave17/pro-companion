-- 20261102000100_critical_kinds.sql
-- pro-companion #75, groom decisions G24, G29 and G30: the server refuses a critical event kind
-- outside its writer's role and race area, so the log's authority is enforced, not just recorded.
--
-- - The map is data: public.critical_kind names, for each critical kind, the roles that may write
--   it and where (docs/roles.md, "The critical kinds"; test/critical_kinds_doc_test.dart holds the
--   two equal). A kind the map does not name is open to any admitted role.
-- - public.critical_correction names the corrections judged as the event they correct, and where
--   each names it: a sail number and an undo of a finish follow that finish, line or at-mark.
-- - public.critical_kind_refusal judges one text, and append_event calls it after #73's admission
--   checks and before the insert. One policy in one function.
--
-- Owner decisions at pickup (2026-11-02), from a premise of the story that was not true yet: the
-- server holds none of the phones' fleets. A phone's fleet id is the ULID of its fleet.defined
-- event, public.fleet.id is a uuid, and no phone writes public.fleet. So:
-- 1. A fleet is held once its fleet.defined is in the race day's log, and a critical event naming
--    one that is not gets a retryable error (SQLSTATE PCW01), which rolls back and keeps no refusal
--    record; sync retries it, as it always read an unknown fleet (packages/sync). Its race area is,
--    in order: the course its fleet.defined names in payload.course (#74 adds it); the race area of
--    the admission that defined it (a bound role's); else none, and only the role is checked (the
--    gap #74 closes: an event-wide phone's fleet on a day with several race areas). The pickup's
--    third step, the race day's only race area, is left out: on such a day every bound phone is on
--    that race area, so it could never change a verdict.
-- 2. A critical event with no fleet is a single-fleet day's, checked by role only, except a kind
--    with an event-wide reach (a postponement or abandonment): with no fleet it is the whole day's,
--    and the overall PRO's alone.
-- 3. Kinds are families: every start.* kind (#33's start.sequence_start and start.signal included),
--    a line finish (finish, finish.missed), course.shortened, and finish.at_mark. A correction
--    follows what it corrects, read from the log; until that event is on the server it is retried
--    like an unheld fleet.
--
-- Owner decisions at the review (2026-11-02), on two holes the review found in the rules above:
-- 5. start.undo, start.time_corrected, start.ocs_cleared and course.undo carry no fleet on any day,
--    only corrects_ulid, so rule 2 checked them by role alone and a course PRO could take back or
--    retime another race area's gun. They are corrections too, and a chain is followed to the first
--    event that is not one: an undo of a time correction is judged as the start.
-- 6. A correction whose target the server refused, or an event whose fleet's fleet.defined it
--    refused, waited on PCW01 for good, since a refused event never reaches the log. It is refused
--    with the reason its target got. not_admitted is not final (the phone sends that event again,
--    and it may be accepted), so a correction of one still waits. revoked, passed on, would have
--    sync mark the correcting phone's own admission revoked, so it is passed on as
--    admission_mismatch.
-- 4. results.released and race.abandoned, which no phone writes yet, are named now, so the rule is
--    in force when one first does.
--
-- A new file, never an edit of an applied one. Every statement is re-runnable against the schema
-- this file creates. It replaces event_refusal_reason_check, the one drop here: the constraint, not
-- a row.

-- The map -------------------------------------------------------------------------------------------
-- reach: race_area, the fleets on the race area the writer's admission binds; any, a fleet on any
-- race area; event, any race area and also with no fleet, for the whole race day.

create table if not exists public.critical_kind (
  kind  text not null,
  role  text not null check (role in ('overall_pro', 'course_pro', 'recorder', 'mark_boat', 'safety', 'scorer')),
  reach text not null check (reach in ('race_area', 'any', 'event')),
  primary key (kind, role)
);

comment on table public.critical_kind is
  'The critical kinds (G24, G29, G30, #75): each row lets one role write one kind, on its race area '
  '(race_area), any race area (any) or also for the whole race day with no fleet (event). A kind '
  'with no row is open to any admitted role; a role with no row for a critical kind is refused it. '
  'docs/roles.md holds the same map, and test/critical_kinds_doc_test.dart holds the two equal.';

create table if not exists public.critical_correction (
  kind   text primary key,
  target text not null check (target in ('corrects_ulid', 'payload.finish'))
);

comment on table public.critical_correction is
  'Corrections judged as the event they correct (#75): its kind and its fleet, read from the log '
  'under the ULID found at target, and through it to the first event that is not a correction. '
  'Until that event is on the server the correction is retried; if the server finally refused it, '
  'the correction is refused with its reason.';

-- Read only by append_event, as their owner. No client or service role reads or writes either.
alter table public.critical_kind       enable row level security;
alter table public.critical_correction enable row level security;
revoke all on public.critical_kind, public.critical_correction from public, anon, authenticated, service_role;

insert into public.critical_kind (kind, role, reach) values
  -- Start and sequence events: the PROs'.
  ('start',                  'overall_pro', 'any'),   ('start',                  'course_pro', 'race_area'),
  ('start.postponement',     'overall_pro', 'event'), ('start.postponement',     'course_pro', 'race_area'),
  ('start.general_recall',   'overall_pro', 'any'),   ('start.general_recall',   'course_pro', 'race_area'),
  ('start.individual_recall','overall_pro', 'any'),   ('start.individual_recall','course_pro', 'race_area'),
  ('start.ocs',              'overall_pro', 'any'),   ('start.ocs',              'course_pro', 'race_area'),
  ('start.sequence_start',   'overall_pro', 'any'),   ('start.sequence_start',   'course_pro', 'race_area'),
  ('start.signal',           'overall_pro', 'any'),   ('start.signal',           'course_pro', 'race_area'),
  ('race.abandoned',         'overall_pro', 'event'), ('race.abandoned',         'course_pro', 'race_area'),
  -- Line finishes: the PROs' and the recorder's.
  ('finish',                 'overall_pro', 'any'),   ('finish',                 'course_pro', 'race_area'),
  ('finish',                 'recorder',    'race_area'),
  ('finish.missed',          'overall_pro', 'any'),   ('finish.missed',          'course_pro', 'race_area'),
  ('finish.missed',          'recorder',    'race_area'),
  -- A shortened course: the PROs' and the mark boat's. A finish at a mark: the mark boat's.
  ('course.shortened',       'overall_pro', 'any'),   ('course.shortened',       'course_pro', 'race_area'),
  ('course.shortened',       'mark_boat',   'race_area'),
  ('finish.at_mark',         'overall_pro', 'any'),   ('finish.at_mark',         'mark_boat',  'race_area'),
  -- The release of results: the fleet's PRO and the scorer (G30).
  ('results.released',       'overall_pro', 'any'),   ('results.released',       'course_pro', 'race_area'),
  ('results.released',       'scorer',      'any')
on conflict (kind, role) do nothing;

-- None of these carries a fleet of its own (decision 5); each is judged as the event it names.
insert into public.critical_correction (kind, target) values
  ('finish.sail',          'payload.finish'),
  ('finish.undo',          'corrects_ulid'),
  ('start.undo',           'corrects_ulid'),
  ('start.time_corrected', 'corrects_ulid'),
  ('start.ocs_cleared',    'corrects_ulid'),
  ('course.undo',          'corrects_ulid')
on conflict (kind) do nothing;

-- The two new reason categories --------------------------------------------------------------------

alter table public.event_refusal drop constraint if exists event_refusal_reason_check;
alter table public.event_refusal
  add constraint event_refusal_reason_check
  check (reason in ('not_admitted', 'revoked', 'inconsistent_canonical', 'ulid_conflict',
                    'admission_mismatch', 'role_mismatch', 'admission_superseded',
                    'kind_not_permitted', 'race_area_mismatch'));

comment on column public.event_refusal.reason is
  'Why it was refused: not_admitted, revoked, inconsistent_canonical (the text cannot be stored as '
  'an event), ulid_conflict (another event is stored under its ULID), admission_mismatch (the text '
  'names an admission that is not the caller''s on this race day, #73), role_mismatch (the text''s '
  'role is not the admission''s, #73), admission_superseded (written under a superseded admission '
  'past its role-change marker, #73, G46), kind_not_permitted (a critical kind its role may not '
  'write, #75) or race_area_mismatch (a critical kind for a fleet off its race area, or for the '
  'whole race day, #75).';

-- The policy ----------------------------------------------------------------------------------------
-- Null when the text may be stored, a refusal reason when it may not, and PCW01 raised when it
-- cannot be judged yet because the fleet, or the event a correction names, is not on the server
-- and was not finally refused there. PCW01 is outside class 22, 23502 and 23505, so append_event
-- never turns it into a refusal record, and it is never append_event_refused, which sync keeps as
-- final.

-- The reason the server finally refused the event stored under p_ulid on race day p_event, as a
-- correction naming it, or an event naming it as its fleet, is refused with (decision 6); null when
-- it holds no final refusal of it. A refused text need not be JSON, so it is matched by its ULID
-- first and parsed in a block of its own.
create or replace function public.critical_kind_refused_target(p_event uuid, p_ulid text)
returns text
language plpgsql stable
set search_path = ''
as $$
declare
  r        record;
  v_reason text;
begin
  if p_ulid is null then
    return null;
  end if;
  for r in select f.canonical, f.reason from public.event_refusal f
           where f.event_id = p_event and strpos(f.canonical, '"ulid":"' || p_ulid || '"') > 0
           order by f.refused_at, f.id
  loop
    v_reason := null;
    begin
      if (r.canonical::jsonb ->> 'ulid') = p_ulid then
        v_reason := r.reason;
      end if;
    exception when data_exception then
      v_reason := null;
    end;
    if v_reason = 'revoked' then
      return 'admission_mismatch';
    elsif v_reason is not null and v_reason <> 'not_admitted' then
      return v_reason;
    end if;
  end loop;
  return null;
end;
$$;

revoke execute on function public.critical_kind_refused_target(uuid, text)
  from public, anon, authenticated, service_role;

comment on function public.critical_kind_refused_target(uuid, text) is
  'The final refusal reason of the event under a ULID on a race day (#75), for critical_kind_refusal: '
  'not_admitted is not final, and revoked is passed on as admission_mismatch. Callable only by its '
  'owner.';

create or replace function public.critical_kind_refusal(p_event uuid, p_text jsonb, p_role text, p_course uuid)
returns text
language plpgsql stable
set search_path = ''
as $$
declare
  v_kind    text := p_text ->> 'kind';
  v_fleet   text := p_text -> 'payload' ->> 'fleet';
  v_event   jsonb := p_text;
  v_place   text;
  v_target  text;
  v_hops    integer := 0;
  v_refused text;
  v_reach   text;
  v_area    uuid;
begin
  -- A correction is judged as the event it names, and a correction of a correction as the one that
  -- names in turn, down to the first that is not one: that event's kind and fleet.
  loop
    select c.target into v_place from public.critical_correction c where c.kind = v_kind;
    exit when not found;
    v_hops := v_hops + 1;
    if v_hops > 8 then
      -- Deeper than anything the core writes: refused rather than followed.
      return 'kind_not_permitted';
    end if;
    v_target := case v_place when 'corrects_ulid' then v_event ->> 'corrects_ulid'
                             else v_event -> 'payload' ->> 'finish' end;
    select t.canonical::jsonb into v_event
    from public.event_log t where t.event_id = p_event and t.ulid = v_target;
    if not found then
      v_refused := public.critical_kind_refused_target(p_event, v_target);
      if v_refused is not null then
        return v_refused;
      end if;
      raise exception 'append_event: % corrects an event the server does not hold yet', p_text ->> 'kind'
        using errcode = 'PCW01',
              hint = 'Retry: it is accepted or refused once the event it corrects is on the server.';
    end if;
    v_kind := v_event ->> 'kind';
    v_fleet := v_event -> 'payload' ->> 'fleet';
  end loop;

  if not exists (select 1 from public.critical_kind k where k.kind = v_kind) then
    return null;
  end if;
  select k.reach into v_reach from public.critical_kind k where k.kind = v_kind and k.role = p_role;
  if v_reach is null then
    return 'kind_not_permitted';
  end if;

  if v_fleet is null then
    -- The whole race day's postponement or abandonment, or a single-fleet day's event.
    if v_reach <> 'event'
       and exists (select 1 from public.critical_kind k where k.kind = v_kind and k.reach = 'event') then
      return 'race_area_mismatch';
    end if;
    return null;
  end if;

  -- The fleet, as the race day's log defines it, and the race area it races on.
  select coalesce(
           (select c.id from public.course c where c.event_id = p_event and c.id::text = f.payload ->> 'course'),
           d.course_id)
    into v_area
  from public.event_log f
  left join public.committee_device d on d.id = f.admission_id
  where f.event_id = p_event and f.ulid = v_fleet and f.kind = 'fleet.defined';
  if not found then
    v_refused := public.critical_kind_refused_target(p_event, v_fleet);
    if v_refused is not null then
      return v_refused;
    end if;
    raise exception 'append_event: fleet % is not on the server yet', v_fleet
      using errcode = 'PCW01',
            hint = 'Retry: it is judged once the fleet''s fleet.defined is in the race day''s log.';
  end if;

  if v_reach = 'race_area' and v_area is not null and v_area is distinct from p_course then
    return 'race_area_mismatch';
  end if;
  return null;
end;
$$;

revoke execute on function public.critical_kind_refusal(uuid, jsonb, text, uuid)
  from public, anon, authenticated, service_role;

comment on function public.critical_kind_refusal(uuid, jsonb, text, uuid) is
  'append_event''s critical-kind check (#75): null to store the text, kind_not_permitted or '
  'race_area_mismatch to refuse it (or the final reason its fleet, or the event it corrects, was '
  'refused with), PCW01 raised to have it retried while that fleet or event is not on the server. '
  'A correction is judged as the event it names, through a chain. Callable only by its owner, which '
  'append_event runs as.';

-- append_event --------------------------------------------------------------------------------------
-- #73's function, with #75's check after the admission, role and marker are judged and before the
-- insert. create or replace keeps #48's grants: execute for authenticated, none for anon,
-- service_role or public.

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
      else
        -- #75: a critical kind only from a role, and on a race area, its admission allows. A text
        -- it cannot judge yet raises PCW01, which rolls the call back and keeps no record.
        v_reason := public.critical_kind_refusal(p_event, v_json, v_admission.role, v_admission.course_id);
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
  'under a superseded admission its seq at or below the device''s admission.superseded marker (G46). '
  'Since #75 a critical kind must be one its role may write, on its race area (critical_kind_refusal); '
  'one whose fleet, or corrected event, is not on the server yet raises PCW01 to be retried.';
