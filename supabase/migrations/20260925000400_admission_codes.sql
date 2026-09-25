-- 20260925000400_admission_codes.sql
-- pro-companion #65, groom decisions G26 and G38: a phone is admitted to exactly the role, and for a
-- bound role the race area, that its admission code grants. Anyone holding one code cannot make
-- themselves PRO, because the phone no longer names its role.
--
-- - Each event-wide role (overall_pro, scorer, safety) has one code per event, and each bound role
--   (course_pro, recorder, mark_boat) one code per race area (docs/roles.md). The owner script
--   issues them through issue_admission_code(). A code is stored only as a hash, in admission_code,
--   which no client role can read.
-- - admit_device(event, code, person) looks the code up and copies its role and race area onto the
--   admission. The caller supplies no role.
-- - #39's single event code no longer admits. event.admission_code_hash is dropped, and so are the
--   two functions that read it.
-- - A phone bound to a race area adds fleets only on that race area. An event-wide phone adds them
--   on any race area of its event.
--
-- A new file, never an edit of an applied one. Every statement is re-runnable against the schema
-- this file creates. It drops a column and two functions, so a live apply waits for the owner.

-- #39's code goes, with both functions that read it -------------------------------------------------
-- A plpgsql body resolves its columns when it is called, not when a column is dropped. So the
-- readers are dropped by name here rather than left to fail at their next call
-- (cairn: a-dropped-table-does-not-drop-its-readers). The signatures change as well, and
-- create or replace cannot change a function's arguments.

drop function if exists public.admit_device(uuid, text, text, text);
drop function if exists public.create_event(uuid, text, date, text, uuid);
alter table public.event drop column if exists admission_code_hash;

comment on table public.event is
  'One race day (or regatta day) a committee runs. A phone may supply the id (offline-first), so the '
  'default is only a default. Its admission codes are in admission_code (#65), one per role and race '
  'area.';

-- Admission codes -------------------------------------------------------------------------------------

create table if not exists public.admission_code (
  id        uuid primary key default gen_random_uuid(),
  event_id  uuid not null references public.event(id),
  role      text not null
            check (role in ('overall_pro', 'course_pro', 'recorder', 'mark_boat', 'safety', 'scorer')),
  course_id uuid,
  code_hash text not null,
  issued_at timestamptz not null default now(),
  -- One code for each event-wide role of an event, and for each bound role on each race area.
  constraint admission_code_one_per_slot unique nulls not distinct (event_id, role, course_id),
  -- So a code an event holds answers with exactly one role and race area.
  constraint admission_code_hash_per_event unique (event_id, code_hash),
  constraint admission_code_course_same_event_fkey
    foreign key (course_id, event_id) references public.course (id, event_id),
  constraint admission_code_race_area_check
    check ((role in ('course_pro', 'recorder', 'mark_boat')) = (course_id is not null))
);
comment on table public.admission_code is
  'The codes that admit a phone to an event (#65; groom decisions G26 and G38). One per event-wide '
  'role, and one per race area for each bound role. code_hash is the sha256 of the code; the code '
  'itself is printed once by the owner script and never stored. No client role can read this table. '
  'Written only through issue_admission_code().';

alter table public.admission_code enable row level security;

-- No grant and no policy for any client role. A select('*') fails loudly rather than returning
-- nothing, and admit_device() reads the table as its owner.
revoke all on public.admission_code from public, anon, authenticated;

-- An admission carries its race area ------------------------------------------------------------------
-- A bound-role admission made before this file has no race area, and adding the check below fails
-- on it. That is deliberate: the file refuses rather than guess a race area, and the admission is
-- revoked or re-admitted first. The live project held no admission when this was written.

alter table public.committee_device add column if not exists course_id uuid;

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'committee_device_course_same_event_fkey'
                   and conrelid = 'public.committee_device'::regclass) then
    alter table public.committee_device
      add constraint committee_device_course_same_event_fkey
      foreign key (course_id, event_id) references public.course (id, event_id);
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'committee_device_race_area_check'
                   and conrelid = 'public.committee_device'::regclass) then
    alter table public.committee_device
      add constraint committee_device_race_area_check
      check ((role in ('course_pro', 'recorder', 'mark_boat')) = (course_id is not null));
  end if;
end;
$$;

comment on column public.committee_device.course_id is
  'The race area a bound role (course_pro, recorder, mark_boat) works on, copied from the admission '
  'code (#65, G38). Null for an event-wide role. committee_device_race_area_check holds the two '
  'together.';

grant select (course_id) on public.committee_device to authenticated;

-- Functions -------------------------------------------------------------------------------------------

-- An event, with no code of its own. service_role only, as before; its codes come from
-- issue_admission_code().
create or replace function public.create_event(
  p_club uuid, p_name text, p_race_day date, p_id uuid default null)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.event (id, club_id, name, race_day)
  values (coalesce(p_id, gen_random_uuid()), p_club, btrim(p_name), p_race_day)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.create_event(uuid, text, date, uuid) from public, anon, authenticated;
grant  execute on function public.create_event(uuid, text, date, uuid) to service_role;

-- One admission code, hashed at rest. service_role only: the owner script (G27) and CI, never a
-- phone. p_course names the race area of a bound role and is null for an event-wide one; the table's
-- constraints refuse any other combination, a race area of another event, and a second code for one
-- slot.
create or replace function public.issue_admission_code(
  p_event uuid, p_role text, p_code text, p_course uuid default null)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if length(coalesce(p_code, '')) < 6 then
    raise exception 'issue_admission_code: an admission code must be at least 6 characters'
      using errcode = '22023';
  end if;
  insert into public.admission_code (event_id, role, course_id, code_hash)
  values (p_event, p_role, p_course, encode(extensions.digest(p_code, 'sha256'), 'hex'))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.issue_admission_code(uuid, text, text, uuid) from public, anon, authenticated;
grant  execute on function public.issue_admission_code(uuid, text, text, uuid) to service_role;

-- Admission: the signed-in phone presents a code of the event, and becomes a committee device of
-- that event and club, under the role and race area the code was issued for. One message for no
-- such event, a code of another event and an unknown code, so the function is not an oracle for any
-- of them. A phone already admitted gets its admission back unchanged, whatever code it presents:
-- changing role is #70's. A revoked phone is refused.
create or replace function public.admit_device(
  p_event uuid, p_admission_code text, p_person text default null)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_club    uuid;
  v_role    text;
  v_course  uuid;
  v_id      uuid;
  v_revoked timestamptz;
begin
  if v_uid is null then
    raise exception 'admit_device: no signed-in caller' using errcode = '28000';
  end if;

  select e.club_id, c.role, c.course_id into v_club, v_role, v_course
  from public.admission_code c
  join public.event e on e.id = c.event_id
  where c.event_id = p_event
    and c.code_hash = encode(extensions.digest(coalesce(p_admission_code, ''), 'sha256'), 'hex');

  if v_club is null then
    raise exception 'admit_device: event or admission code not recognised' using errcode = '28000';
  end if;

  select d.id, d.revoked_at into v_id, v_revoked
  from public.committee_device d where d.event_id = p_event and d.auth_uid = v_uid;

  if v_id is not null then
    if v_revoked is not null then
      raise exception 'admit_device: this device was revoked from the event' using errcode = '42501';
    end if;
    return v_id;
  end if;

  insert into public.committee_device (event_id, club_id, course_id, auth_uid, role, person)
  values (p_event, v_club, v_course, v_uid, v_role, nullif(btrim(p_person), ''))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.admit_device(uuid, text, text) from public, anon;
grant  execute on function public.admit_device(uuid, text, text) to authenticated;

-- Whether the caller may work on a race area of an event: admitted to the event, not revoked, and
-- either event-wide or bound to that race area. Security definer like the other admission helpers.
create or replace function public.is_admitted_to_race_area(p_event uuid, p_course uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.committee_device d
    where d.auth_uid = auth.uid()
      and d.event_id = p_event
      and d.revoked_at is null
      and (d.course_id is null or d.course_id = p_course)
  );
$$;
revoke execute on function public.is_admitted_to_race_area(uuid, uuid) from public, anon;
grant  execute on function public.is_admitted_to_race_area(uuid, uuid) to authenticated;

-- Policies --------------------------------------------------------------------------------------------
-- A fleet a phone adds races on a race area that phone works on. fleet_course_same_event_fkey already
-- holds the race area to the fleet's event.

drop policy if exists fleet_insert_admitted on public.fleet;
create policy fleet_insert_admitted on public.fleet
  for insert to authenticated
  with check (public.is_admitted_to_race_area(event_id, course_id));
