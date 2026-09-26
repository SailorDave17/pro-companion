-- 20260925000600_sign_in_mode.sql
-- pro-companion #5, groom decisions G39 and G27: a club chooses how its committee phones sign in, and
-- admission holds each new phone to that choice.
--
-- - club.sign_in_mode is device_handoff, named_volunteers or both. Every club starts at both, which is
--   how admission behaved before this file, so no club changes behaviour when it lands.
-- - set_sign_in_mode(club, mode) switches it and answers with the mode it replaced. service_role only:
--   the owner script's sign-in-mode subcommand (G27), never a phone.
-- - admit_device reads the path a phone signed in by from its token. An anonymous sign-in is the
--   device-handoff path, and a named account, signed in by magic link, is the named-volunteers path.
--   A new admission on a path the club's mode excludes is refused. A phone already admitted gets its
--   admission back whatever the mode, so switching the mode never touches an admitted phone.
-- - Only a named volunteer's admission names a person. A device-handoff phone passes from hand to
--   hand, so its admission is tied to the event, club, role and race area and never to a person. A
--   person it names is refused rather than recorded as a guess.
--
-- The mode gates admission and nothing else. append_event and every policy read the admission, so an
-- admitted phone keeps writing whatever the mode becomes. Revoking one is the revoke subcommand's (#72).
--
-- A new file, never an edit of an applied one. Every statement is re-runnable against the schema this
-- file creates.

-- The club's sign-in mode ----------------------------------------------------------------------------

alter table public.club add column if not exists sign_in_mode text not null default 'both';

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'club_sign_in_mode_check'
                   and conrelid = 'public.club'::regclass) then
    alter table public.club
      add constraint club_sign_in_mode_check
      check (sign_in_mode in ('device_handoff', 'named_volunteers', 'both'));
  end if;
end;
$$;

comment on column public.club.sign_in_mode is
  'How the club''s committee phones sign in (#5, groom decision G39): device_handoff (an anonymous '
  'sign-in presenting a role''s code), named_volunteers (a named account, signed in by magic link, '
  'presenting a role''s code) or both. admit_device refuses a new admission on a path the mode '
  'excludes and never touches an admitted phone. Set by the owner script through set_sign_in_mode() '
  '(G27).';

-- Granted like every other column of club: it says how the club signs in, and nothing about who. A
-- phone's select('*') on club keeps working.
grant select (sign_in_mode) on public.club to authenticated;

comment on column public.committee_device.person is
  'The person a named volunteer''s admission names, as free text. Null on every device-handoff '
  'admission, which admit_device ties to the event, club, role and race area and never to a person '
  '(#5).';

-- Switching it ---------------------------------------------------------------------------------------
-- service_role only, like the owner's other functions. The mode's check refuses a value that is not
-- one of the three, and the answer is the mode it replaced, so the script can say what changed.

create or replace function public.set_sign_in_mode(p_club uuid, p_mode text)
returns text
language plpgsql security definer
set search_path = ''
as $$
declare
  v_before text;
begin
  select c.sign_in_mode into v_before from public.club c where c.id = p_club for update;
  if not found then
    raise exception 'set_sign_in_mode: no such club' using errcode = 'P0002';
  end if;
  update public.club set sign_in_mode = p_mode where id = p_club;
  return v_before;
end;
$$;
revoke execute on function public.set_sign_in_mode(uuid, text) from public, anon, authenticated;
grant  execute on function public.set_sign_in_mode(uuid, text) to service_role;

comment on function public.set_sign_in_mode(uuid, text) is
  'Switches a club''s sign-in mode (#5, G39) and answers with the mode it replaced. service_role only: '
  'the owner script''s sign-in-mode subcommand (G27).';

-- Admission ------------------------------------------------------------------------------------------
-- #65's function, with the club's mode and the person rule added. The order is deliberate:
--
-- 1. The code is judged first, with one answer for everything unrecognised, so a caller holding no
--    code learns nothing about a club's mode.
-- 2. A phone already admitted to the event gets its admission back, or is refused as revoked, before
--    the mode is read. That is what leaves admitted phones untouched by a switch.
-- 3. A new admission's path must be one the mode names. The path is read from the token's
--    is_anonymous claim, and anything but an explicit true or false is neither path, so a
--    single-path mode refuses it.
-- 4. A person is named only on the named-volunteers path.
--
-- create or replace keeps #65's grants: execute for authenticated, none for anon or public.

create or replace function public.admit_device(
  p_event uuid, p_admission_code text, p_person text default null)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_path    text;
  v_club    uuid;
  v_mode    text;
  v_role    text;
  v_course  uuid;
  v_person  text := nullif(btrim(p_person), '');
  v_id      uuid;
  v_revoked timestamptz;
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

  select d.id, d.revoked_at into v_id, v_revoked
  from public.committee_device d where d.event_id = p_event and d.auth_uid = v_uid;

  if v_id is not null then
    if v_revoked is not null then
      raise exception 'admit_device: this device was revoked from the event' using errcode = '42501';
    end if;
    return v_id;
  end if;

  v_path := case auth.jwt() ->> 'is_anonymous'
              when 'true'  then 'device_handoff'
              when 'false' then 'named_volunteers'
            end;

  if v_mode is distinct from 'both' and v_path is distinct from v_mode then
    raise exception 'admit_device: the club''s sign-in mode does not admit this sign-in'
      using errcode = '42501',
            detail  = format('sign_in_mode=%s path=%s', v_mode, coalesce(v_path, 'unknown'));
  end if;

  if v_person is not null and v_path is distinct from 'named_volunteers' then
    raise exception 'admit_device: only a named volunteer''s admission names a person'
      using errcode = '22023';
  end if;

  insert into public.committee_device (event_id, club_id, course_id, auth_uid, role, person)
  values (p_event, v_club, v_course, v_uid, v_role, v_person)
  returning id into v_id;
  return v_id;
end;
$$;

comment on function public.admit_device(uuid, text, text) is
  'Admits the signed-in phone to an event under the role, and for a bound role the race area, of the '
  'code it presents (#65). A new admission must come by a path the club''s sign-in mode names: an '
  'anonymous sign-in for device_handoff, a named account for named_volunteers (#5, G39). Only a named '
  'volunteer''s admission names a person. A phone already admitted gets its admission back.';
