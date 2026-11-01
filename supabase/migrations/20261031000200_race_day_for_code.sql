-- #71: the race day a role's admission code is for, so a phone's join screen needs one thing typed
-- (owner decision at pickup, 2026-10-31).
--
-- admit_device(event, code, person) takes the race day as well as the code, and the owner script
-- prints an eight-character code beside a UUID nobody types on a wet phone. The phone cannot read
-- admission_code (no client role holds any privilege on it, #65), so this definer function answers
-- the one question the phone has: which race day this code was issued for. It is not a gate:
-- admit_device still judges the code, the phone and the club's sign-in mode, in that order, and a
-- code issued to two race days is answered with the same refusal as an unknown one, since the
-- phone cannot choose between them. The message is admit_device's own, so the function is no more
-- of an oracle than the admission it precedes.
--
-- A new file, never an edit of an applied one. Every statement is re-runnable.

-- The lookup is by hash alone. admission_code_hash_per_event (event_id, code_hash) cannot serve it.
create index if not exists admission_code_hash_idx on public.admission_code (code_hash);

create or replace function public.race_day_for_code(p_admission_code text)
returns uuid
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_event uuid;
  v_n     integer;
begin
  if auth.uid() is null then
    raise exception 'race_day_for_code: no signed-in caller' using errcode = '28000';
  end if;

  select count(distinct c.event_id), min(c.event_id::text)::uuid into v_n, v_event
  from public.admission_code c
  where c.code_hash = encode(extensions.digest(coalesce(p_admission_code, ''), 'sha256'), 'hex');

  if v_n <> 1 then
    raise exception 'admit_device: event or admission code not recognised' using errcode = '28000';
  end if;
  return v_event;
end;
$$;

comment on function public.race_day_for_code(text) is
  'The race day (event) the admission code was issued for (#71), so the phone''s join screen asks for '
  'the code alone and then calls admit_device(event, code). Refuses with admit_device''s own message '
  'when the code was issued to no race day or to more than one. Signed-in callers only; it judges '
  'nothing else.';

revoke execute on function public.race_day_for_code(text) from public, anon;
grant  execute on function public.race_day_for_code(text) to authenticated, service_role;
