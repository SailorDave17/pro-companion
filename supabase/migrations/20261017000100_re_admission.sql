-- 20261017000100_re_admission.sql
-- pro-companion #70, groom decision G44: a phone changes role by presenting another role's code. The
-- new admission supersedes the old one, and both rows stay, so the record keeps which role wrote
-- what.
--
-- - #39's unique (event_id, auth_uid) becomes uniqueness over active rows only. A superseded row
--   names its successor in superseded_by. No row is deleted.
-- - admit_device: a phone presenting its active admission's own slot (role and race area) gets that
--   admission back, as before. A code for any other slot supersedes it with a new row. A phone
--   holding any revoked admission in the event is refused, whatever code it presents.
-- - The admission helpers count a phone's active row only, and only while no admission of the phone
--   in that event is revoked.
--
-- Owner decisions at pickup (2026-10-17, on #70):
-- - The slot is role plus race area, so a recorder moving from Alpha to Bravo supersedes.
-- - A role change is a new admission, so it is held to the club's sign-in mode (#5).
-- - On a role change a named volunteer's person is the name given, else the superseded row's name.
-- - Any revoked admission revokes the phone in that event: admit_device, the helpers, and
--   append_event, which already counted any revoked row.
-- - Switching back to an earlier role is another role change: a new row, never a reactivated one.
--
-- How the event log treats events written under a superseded admission is #73's (G46). Nothing here
-- writes to the log.
--
-- A new file, never an edit of an applied one. Every statement is re-runnable against the schema
-- this file creates. It drops #39's unique constraint, so a live apply waits for the owner.

-- The supersede columns -----------------------------------------------------------------------------
-- The successor is written before it exists: admit_device marks the old row, then inserts the new one
-- under the id it named. So the key is checked at commit (deferrable initially deferred). The
-- partial unique index below cannot be deferred, which is why the old row is marked first.

alter table public.committee_device add column if not exists superseded_by uuid;
alter table public.committee_device add column if not exists superseded_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'committee_device_superseded_by_fkey'
                   and conrelid = 'public.committee_device'::regclass) then
    alter table public.committee_device
      add constraint committee_device_superseded_by_fkey
      foreign key (superseded_by) references public.committee_device (id)
      deferrable initially deferred;
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'committee_device_supersede_check'
                   and conrelid = 'public.committee_device'::regclass) then
    alter table public.committee_device
      add constraint committee_device_supersede_check
      check ((superseded_by is null) = (superseded_at is null) and superseded_by is distinct from id);
  end if;
end;
$$;

comment on column public.committee_device.superseded_by is
  'The admission that replaced this one when the phone presented another role''s code (#70, G44). '
  'Null on the phone''s active admission. A superseded row stays, so the log can say which role wrote '
  'an event.';
comment on column public.committee_device.superseded_at is
  'When this admission was superseded (#70). Null exactly when superseded_by is.';

-- One active admission per phone and event ----------------------------------------------------------
-- #39's constraint took the name Postgres gives an unnamed unique on (event_id, auth_uid).

alter table public.committee_device drop constraint if exists committee_device_event_id_auth_uid_key;

create unique index if not exists committee_device_one_active_per_event
  on public.committee_device (event_id, auth_uid)
  where superseded_by is null;

comment on table public.committee_device is
  'A phone admitted to an event under a role. auth_uid is the Supabase Auth user the phone signed in '
  'as: anonymous for the device-handoff path, a named volunteer for the magic-link path (#5). '
  'club_id is denormalised so every policy is one lookup. A phone holds one active admission per '
  'event; a role change supersedes it with a new row (#70), and the superseded row stays. A revoked '
  'row stays too: the log it attributed events to is append-only.';

-- A phone reads its own rows, superseded ones included, through committee_device_select_own.
grant select (superseded_by, superseded_at) on public.committee_device to authenticated;

-- The admission helpers -----------------------------------------------------------------------------
-- The phone's active row, not revoked, and no revoked admission of the phone in that event.

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
      and d.superseded_by is null
      and d.revoked_at is null
      and not exists (select 1 from public.committee_device r
                      where r.auth_uid = d.auth_uid
                        and r.event_id = d.event_id
                        and r.revoked_at is not null)
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
      and d.superseded_by is null
      and d.revoked_at is null
      and not exists (select 1 from public.committee_device r
                      where r.auth_uid = d.auth_uid
                        and r.event_id = d.event_id
                        and r.revoked_at is not null)
  );
$$;

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
      and d.superseded_by is null
      and d.revoked_at is null
      and (d.course_id is null or d.course_id = p_course)
      and not exists (select 1 from public.committee_device r
                      where r.auth_uid = d.auth_uid
                        and r.event_id = d.event_id
                        and r.revoked_at is not null)
  );
$$;

-- Admission ------------------------------------------------------------------------------------------
-- #5's function, with the role change added. The order is deliberate:
--
-- 1. The code is judged first, with one answer for everything unrecognised.
-- 2. A phone holding any revoked admission in the event is refused (criterion 4).
-- 3. A phone presenting its active admission's own slot gets that admission back, before the mode is
--    read, so a mode switch never touches it (criterion 3, and #5's rule).
-- 4. Anything else is a new admission, a first one or a role change, and is held to the club's mode
--    and the person rule.
-- 5. A role change marks the active row superseded, naming the new row's id, then inserts the new
--    row under that id (criterion 2). The active row is locked first, so two role changes at once
--    cannot both supersede it.
-- 6. A call that overlaps another admission of the same phone looks again once. Under READ
--    COMMITTED, a call waiting on the lock rechecks the row it waited for, finds it superseded, and
--    cannot see the successor the other call committed. Its insert then meets the one-active index.
--    The second look is a new statement, so it sees the successor and answers as if the call had
--    come after: the successor's id for the same slot, a supersede of it for another. Without it the
--    phone got a bare 23505 (found by #70's review, reproduced in two sessions).
--
-- create or replace keeps #65's grants: execute for authenticated, none for anon or public.

create or replace function public.admit_device(
  p_event uuid, p_admission_code text, p_person text default null)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid        uuid := auth.uid();
  v_path       text;
  v_club       uuid;
  v_mode       text;
  v_role       text;
  v_course     uuid;
  v_person     text;
  v_active     uuid;
  v_act_role   text;
  v_act_course uuid;
  v_act_person text;
  v_id         uuid;
  v_constraint text;
begin
  if v_uid is null then
    raise exception 'admit_device: no signed-in caller' using errcode = '28000';
  end if;

  select e.club_id, cl.sign_in_mode, c.role, c.course_id into v_club, v_mode, v_role, v_course
  from public.admission_code c
  join public.event e on e.id = c.event_id
  join public.club cl on cl.id = e.club_id
  where c.event_id = p_event
    and c.code_hash = encode(extensions.digest(coalesce(p_admission_code, ''), 'sha256'), 'hex');

  if v_club is null then
    raise exception 'admit_device: event or admission code not recognised' using errcode = '28000';
  end if;

  if exists (select 1 from public.committee_device d
             where d.event_id = p_event and d.auth_uid = v_uid and d.revoked_at is not null) then
    raise exception 'admit_device: this device was revoked from the event' using errcode = '42501';
  end if;

  v_path := case auth.jwt() ->> 'is_anonymous'
              when 'true'  then 'device_handoff'
              when 'false' then 'named_volunteers'
            end;

  for v_attempt in 1..2 loop
    begin
      v_person := nullif(btrim(p_person), '');

      select d.id, d.role, d.course_id, d.person into v_active, v_act_role, v_act_course, v_act_person
      from public.committee_device d
      where d.event_id = p_event and d.auth_uid = v_uid and d.superseded_by is null
      for update;

      if v_active is not null and v_act_role = v_role and v_act_course is not distinct from v_course then
        return v_active;
      end if;

      if v_mode is distinct from 'both' and v_path is distinct from v_mode then
        raise exception 'admit_device: the club''s sign-in mode does not admit this sign-in'
          using errcode = '42501',
                detail  = format('sign_in_mode=%s path=%s', v_mode, coalesce(v_path, 'unknown'));
      end if;

      if v_person is not null and v_path is distinct from 'named_volunteers' then
        raise exception 'admit_device: only a named volunteer''s admission names a person'
          using errcode = '22023';
      end if;

      v_id := gen_random_uuid();

      if v_active is not null then
        if v_path = 'named_volunteers' then
          v_person := coalesce(v_person, v_act_person);
        end if;
        update public.committee_device
           set superseded_by = v_id, superseded_at = now()
         where id = v_active;
      end if;

      insert into public.committee_device (id, event_id, club_id, course_id, auth_uid, role, person)
      values (v_id, p_event, v_club, v_course, v_uid, v_role, v_person);
      return v_id;
    exception
      when unique_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint is distinct from 'committee_device_one_active_per_event' or v_attempt = 2 then
          raise;
        end if;
        -- Another call admitted this phone after this one looked. Look again (step 6).
    end;
  end loop;
end;
$$;

comment on function public.admit_device(uuid, text, text) is
  'Admits the signed-in phone to an event under the role, and for a bound role the race area, of the '
  'code it presents (#65). A phone presenting its active admission''s own role and race area gets it '
  'back. Another code supersedes it with a new row (#70, G44). A new or changed admission must come '
  'by a path the club''s sign-in mode names (#5, G39), and only a named volunteer''s admission names '
  'a person. A phone holding any revoked admission in the event is refused.';
