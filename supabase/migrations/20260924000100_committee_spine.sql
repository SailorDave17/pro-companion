-- 20260924000100_committee_spine.sql
-- pro-companion ADR 005, story #39: the companion's own tenancy spine — club, event, fleet and
-- the phones admitted to an event. The general event log (#40) hangs off this.
--
-- Every statement is re-runnable against the schema it creates. That is deliberate: the route that
-- applies this to the live project (POST /v1/projects/{ref}/database/query) never writes the CLI's
-- migration registry, so a later `supabase db push` will offer this file again
-- (cairn: supabase-management-api-tokens-2026-08-31).

create extension if not exists pgcrypto with schema extensions;

-- Tables ------------------------------------------------------------------------------------------

create table if not exists public.club (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (length(btrim(name)) between 1 and 120),
  standalone     boolean not null default true,
  burgee_club_id uuid,
  created_at     timestamptz not null default now()
);
comment on table public.club is
  'A club whose committee runs race days on the companion. standalone = no burgee account or project '
  'behind it (scope decision 7 / groom decision G7 under ADR 005); burgee_club_id is the seam to a '
  'burgee-run club, mapped later and required by nothing here.';

create table if not exists public.event (
  id                  uuid primary key default gen_random_uuid(),
  club_id             uuid not null references public.club(id),
  name                text not null check (length(btrim(name)) between 1 and 120),
  race_day            date not null,
  admission_code_hash text not null,
  created_at          timestamptz not null default now()
);
create index if not exists event_club_id_idx on public.event (club_id);
comment on table public.event is
  'One race day (or regatta day) a committee runs. A phone may supply the id (offline-first), so the '
  'default is only a default. admission_code_hash is the sha256 of the code a phone presents to '
  'admit_device(); it is never granted to a client role.';

create table if not exists public.fleet (
  id              uuid primary key default gen_random_uuid(),
  event_id        uuid not null references public.event(id),
  name            text not null check (length(btrim(name)) between 1 and 60),
  burgee_fleet_id uuid,
  unique (event_id, name)
);
comment on table public.fleet is
  'A fleet racing on an event (#18 keys every race-time event to one). burgee_fleet_id is the seam to '
  'a burgee fleet, filled by the integration story, required by nothing here.';

create table if not exists public.committee_device (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.event(id),
  club_id     uuid not null references public.club(id),
  auth_uid    uuid not null,
  role        text not null check (role in ('pro', 'recorder', 'mark_boat', 'safety', 'scorer')),
  person      text,
  admitted_at timestamptz not null default now(),
  revoked_at  timestamptz,
  unique (event_id, auth_uid)
);
create index if not exists committee_device_auth_uid_idx on public.committee_device (auth_uid);
comment on table public.committee_device is
  'A phone admitted to an event under a role. auth_uid is the Supabase Auth user the phone signed in '
  'as — anonymous for the device-handoff path, a named volunteer for the magic-link path (#5). '
  'club_id is denormalised so every policy is one lookup. A revoked row stays: the log it attributed '
  'events to is append-only.';

alter table public.club             enable row level security;
alter table public.event            enable row level security;
alter table public.fleet            enable row level security;
alter table public.committee_device enable row level security;

-- Grants --------------------------------------------------------------------------------------------
-- Supabase grants anon and authenticated everything on a new public table by default. Take it back
-- and grant explicit column lists; admission_code_hash and auth_uid are withheld from every client
-- role, so a select('*') on those tables fails loudly rather than leaking them
-- (cairn: supabase-rls-column-grants-2026-08-06).

revoke all on public.club, public.event, public.fleet, public.committee_device
  from public, anon, authenticated;

grant select (id, name, standalone, burgee_club_id, created_at)        on public.club             to authenticated;
grant select (id, club_id, name, race_day, created_at)                 on public.event            to authenticated;
grant select (id, event_id, name, burgee_fleet_id)                     on public.fleet            to authenticated;
grant insert (id, event_id, name)                                      on public.fleet            to authenticated;
grant select (id, event_id, club_id, role, person, admitted_at, revoked_at)
                                                                       on public.committee_device to authenticated;

-- Helpers -------------------------------------------------------------------------------------------
-- Security definer so a policy can consult committee_device without the caller holding a broader
-- grant on it; search_path pinned and every name qualified, per the Supabase advisor.

create or replace function public.is_admitted_to_club(p_club uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.committee_device d
    where d.auth_uid = auth.uid()
      and d.club_id = p_club
      and d.revoked_at is null
  );
$$;

create or replace function public.is_admitted_to_event(p_event uuid)
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
  );
$$;

revoke execute on function public.is_admitted_to_club(uuid)  from public, anon;
revoke execute on function public.is_admitted_to_event(uuid) from public, anon;
grant  execute on function public.is_admitted_to_club(uuid)  to authenticated;
grant  execute on function public.is_admitted_to_event(uuid) to authenticated;

-- Policies ------------------------------------------------------------------------------------------
-- Reads are scoped by admission; the only client write here is a fleet row (a PRO defining fleets by
-- hand offline, #18). Clubs, events and admissions are written only through the functions below.

drop policy if exists club_select_admitted on public.club;
create policy club_select_admitted on public.club
  for select to authenticated
  using (public.is_admitted_to_club(id));

drop policy if exists event_select_admitted on public.event;
create policy event_select_admitted on public.event
  for select to authenticated
  using (public.is_admitted_to_club(club_id));

drop policy if exists fleet_select_admitted on public.fleet;
create policy fleet_select_admitted on public.fleet
  for select to authenticated
  using (public.is_admitted_to_event(event_id));

drop policy if exists fleet_insert_admitted on public.fleet;
create policy fleet_insert_admitted on public.fleet
  for insert to authenticated
  with check (public.is_admitted_to_event(event_id));

drop policy if exists committee_device_select_own on public.committee_device;
create policy committee_device_select_own on public.committee_device
  for select to authenticated
  using (auth_uid = auth.uid());

-- Functions -----------------------------------------------------------------------------------------

-- Provisioning: a club record and nothing else — no user account, no membership (G7). Callable by
-- service_role only: the owner's tooling and CI, never a phone.
create or replace function public.provision_club(p_name text, p_standalone boolean default true)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.club (name, standalone)
  values (btrim(p_name), coalesce(p_standalone, true))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.provision_club(text, boolean) from public, anon, authenticated;
grant  execute on function public.provision_club(text, boolean) to service_role;

-- An event with its admission code, hashed at rest. service_role only for now; the story that lets a
-- PRO start a race day from the phone (held H76) widens this to admitted devices.
create or replace function public.create_event(
  p_club uuid, p_name text, p_race_day date, p_admission_code text, p_id uuid default null)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if length(coalesce(p_admission_code, '')) < 6 then
    raise exception 'create_event: admission code must be at least 6 characters' using errcode = '22023';
  end if;
  insert into public.event (id, club_id, name, race_day, admission_code_hash)
  values (coalesce(p_id, gen_random_uuid()), p_club, btrim(p_name), p_race_day,
          encode(extensions.digest(p_admission_code, 'sha256'), 'hex'))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.create_event(uuid, text, date, text, uuid) from public, anon, authenticated;
grant  execute on function public.create_event(uuid, text, date, text, uuid) to service_role;

-- Admission: the signed-in phone presents the event's code and a role, and becomes a committee
-- device of that event and club. One message for "no such event" and "wrong code", so the function
-- is not an oracle for either. A revoked device is refused rather than re-admitted; how a role is
-- re-granted is #5's.
create or replace function public.admit_device(
  p_event uuid, p_role text, p_admission_code text, p_person text default null)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_club    uuid;
  v_hash    text;
  v_id      uuid;
  v_revoked timestamptz;
begin
  if v_uid is null then
    raise exception 'admit_device: no signed-in caller' using errcode = '28000';
  end if;

  select e.club_id, e.admission_code_hash into v_club, v_hash
  from public.event e where e.id = p_event;

  if v_club is null
     or v_hash is distinct from encode(extensions.digest(coalesce(p_admission_code, ''), 'sha256'), 'hex') then
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

  insert into public.committee_device (event_id, club_id, auth_uid, role, person)
  values (p_event, v_club, v_uid, p_role, nullif(btrim(p_person), ''))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.admit_device(uuid, text, text, text) from public, anon;
grant  execute on function public.admit_device(uuid, text, text, text) to authenticated;

-- Revocation: marks the row; the device's next write is refused by every policy above. service_role
-- only until the admission and handoff story (held H30) decides who revokes from a phone.
create or replace function public.revoke_device(p_device uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.committee_device
     set revoked_at = coalesce(revoked_at, now())
   where id = p_device;
  if not found then
    raise exception 'revoke_device: no such device' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.revoke_device(uuid) from public, anon, authenticated;
grant  execute on function public.revoke_device(uuid) to service_role;
