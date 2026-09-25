-- 20260925000100_race_areas.sql
-- pro-companion #58, groom decision G31: the race area between event and fleet. An event runs one
-- or more race areas and every fleet races on exactly one, so a course PRO's authority (G29, G38)
-- can be scoped to the fleets on its race area. Stories say "race area" for this entity and "course
-- layout" for marks; the table keeps the name it was filed under, course.
--
-- It lands before #40's event log holds a row (G31). Every statement is re-runnable against the
-- schema this file creates.

-- Table ---------------------------------------------------------------------------------------------

create table if not exists public.course (
  id       uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.event(id),
  name     text not null check (length(btrim(name)) between 1 and 60),
  unique (event_id, name),
  -- The target of fleet's (course_id, event_id) key below: id alone is already unique, but a
  -- foreign key must name a unique constraint over exactly the columns it references.
  unique (id, event_id)
);
comment on table public.course is
  'A race area of an event (groom decision G31). Every fleet races on one. Created only through '
  'create_course(), by the owner''s tooling (G27) and never by a phone. Its caller may fix the id, so '
  'the default is only a default.';

alter table public.course enable row level security;

-- Fleet moves onto a race area ----------------------------------------------------------------------
-- Every fleet already stored goes to one default race area of its event, created here. Only events
-- with a fleet to move get one, so this is a no-op once every fleet has a race area; an event with
-- no fleet gets its race areas from the owner's tooling like any new event.

alter table public.fleet add column if not exists course_id uuid;

insert into public.course (event_id, name)
select distinct f.event_id, 'Main'
from public.fleet f
where f.course_id is null
on conflict (event_id, name) do nothing;

update public.fleet f
   set course_id = c.id
  from public.course c
 where f.course_id is null
   and c.event_id = f.event_id
   and c.name = 'Main';

alter table public.fleet alter column course_id set not null;

-- The race area must belong to the fleet's own event. A key over both columns holds that for every
-- role, service_role included, where an insert policy would hold it only for the clients it names.
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'fleet_course_same_event_fkey'
                   and conrelid = 'public.fleet'::regclass) then
    alter table public.fleet
      add constraint fleet_course_same_event_fkey
      foreign key (course_id, event_id) references public.course (id, event_id);
  end if;
end;
$$;

comment on column public.fleet.course_id is
  'The race area this fleet races on (#58). It must be a race area of the fleet''s own event, which '
  'fleet_course_same_event_fkey enforces.';

-- Grants --------------------------------------------------------------------------------------------
-- The same shape as the spine: take back Supabase's default grants on the new table, then grant
-- column lists. A client reads race areas and never writes one. A phone adding a fleet names its
-- race area, and needs to read it back (a RETURNING is a read).

revoke all on public.course from public, anon, authenticated;
grant select (id, event_id, name) on public.course to authenticated;

grant select (course_id) on public.fleet to authenticated;
grant insert (course_id) on public.fleet to authenticated;

-- Policies ------------------------------------------------------------------------------------------

drop policy if exists course_select_admitted on public.course;
create policy course_select_admitted on public.course
  for select to authenticated
  using (public.is_admitted_to_event(event_id));

-- Functions -----------------------------------------------------------------------------------------

-- A race area on an event. service_role only: the owner's tooling (G27) and CI, never a phone.
-- p_id lets the caller fix the id, as create_event's does.
create or replace function public.create_course(p_event uuid, p_name text, p_id uuid default null)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.course (id, event_id, name)
  values (coalesce(p_id, gen_random_uuid()), p_event, btrim(p_name))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.create_course(uuid, text, uuid) from public, anon, authenticated;
grant  execute on function public.create_course(uuid, text, uuid) to service_role;

-- The race area a fleet races on, so every later policy that scopes by race area (G29, G38) keys
-- through one function. Security definer like the admission helpers, so a policy can call it without
-- the caller holding a grant on fleet. It answers only for a fleet id the caller already holds, and
-- answers with an id, never a name.
create or replace function public.fleet_course(p_fleet uuid)
returns uuid
language sql stable security definer
set search_path = ''
as $$
  select f.course_id from public.fleet f where f.id = p_fleet;
$$;
revoke execute on function public.fleet_course(uuid) from public, anon;
grant  execute on function public.fleet_course(uuid) to authenticated;
