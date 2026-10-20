-- pgTAP tests for the refusal stub (#60, groom decision G41): a phone admitted to a race day reads
-- the device, sequence, hash and reason of each event refused there, and nothing else of the record.
-- Run with `supabase test db` against the local stack; the whole file is one transaction and rolls
-- back. #48's record itself, and that no role can change it, is append_event_test.sql's.
--
-- Roles are switched the way PostgREST switches them, as in committee_spine_test.sql. Every phone's
-- read goes through pg_temp.stubs or pg_temp.attempt, which answer what the phone saw or its
-- refusal, so a mutation that makes a read raise fails its own test and does not abort the file.
--
-- Pickup decision (owner, 2026-10-19, on #60): the stub is a column grant on the record, not a view.

begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

-- Fixed ids so the file needs no client-side variables.
-- clubs:   …c01 Hoover, …c02 Other
-- events:  …e01 Hoover's club night, …e03 Hoover's second day, …e02 the other club's regatta
-- refused: on e01, device …6001's seq 5 (hash a1…) and an unparseable text (hash a2…); on e03,
--          device …6003's seq 2 (hash a3…); on e02, device …6004's seq 9 (hash a4…)
-- phones:  …6101 safety on e01; …6102 scorer on e02; …6104 signed in anonymously, never admitted;
--          …6106 scorer on e01, then revoked

-- 1–3. The read layers, held from the catalog: the stub's five columns for phones and nothing for
-- anon, and one policy, select only, for authenticated, through the admission helper.
select is(array(select a.attname::text from pg_attribute a
                where a.attrelid = 'public.event_refusal'::regclass and a.attnum > 0 and not a.attisdropped
                  and has_column_privilege('authenticated', 'public.event_refusal', a.attname, 'SELECT')
                order by a.attnum),
          array['event_id', 'event_hash', 'device_id', 'seq', 'reason'],
          'a phone may select the stub''s columns only: no canonical text, caller, time or record id');
select ok(not has_table_privilege('anon', 'public.event_refusal', 'SELECT')
          and not has_any_column_privilege('anon', 'public.event_refusal', 'SELECT'),
          'anon may select no column of the refusals');
select is(array(select p.polname::text || ' ' || p.polcmd::text || ' to '
                       || array_to_string(array(select r.rolname::text from pg_roles r
                                                where r.oid = any(p.polroles) order by r.rolname), ',')
                       || ' using ' || coalesce(pg_get_expr(p.polqual, p.polrelid), '(none)')
                from pg_policy p where p.polrelid = 'public.event_refusal'::regclass order by p.polname),
          array['event_refusal_stub_select_admitted r to authenticated using is_admitted_to_event(event_id)'],
          'the refusals have one policy: select, for phones, on the event they are admitted to');

-- Fixture (table owner, RLS bypassed): two clubs, three events, four refusals. The texts carry a
-- person, GPS and a payload, which no phone may read.
insert into public.club (id, name) values
  ('00000000-0000-0000-0000-000000000c01', 'Hoover (fixture)'),
  ('00000000-0000-0000-0000-000000000c02', 'Other (fixture)');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Club night', date '2026-10-19',
                           '00000000-0000-0000-0000-000000000e01');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Second day', date '2026-10-20',
                           '00000000-0000-0000-0000-000000000e03');
select public.create_event('00000000-0000-0000-0000-000000000c02', 'Their regatta', date '2026-10-19',
                           '00000000-0000-0000-0000-000000000e02');
insert into public.event_refusal (event_id, canonical, event_hash, device_id, seq, reason, auth_uid) values
  ('00000000-0000-0000-0000-000000000e01',
   '{"device_id":"01J8Z0D0000000000000006001","gps":{"accuracy_m":4,"lat":33.4,"lon":-86.8},"kind":"finish","payload":{"sail":"12345"},"person":"Dana (fixture)","seq":5,"ulid":"01J80000000000000000006001"}',
   'a1' || repeat('0', 62), '01J8Z0D0000000000000006001', 5, 'ulid_conflict', '00000000-0000-0000-0000-00000000f001'),
  ('00000000-0000-0000-0000-000000000e01', 'not json at all',
   'a2' || repeat('0', 62), null, null, 'inconsistent_canonical', '00000000-0000-0000-0000-00000000f001'),
  ('00000000-0000-0000-0000-000000000e03',
   '{"device_id":"01J8Z0D0000000000000006003","kind":"note","payload":{"text":"e03"},"seq":2,"ulid":"01J80000000000000000006003"}',
   'a3' || repeat('0', 62), '01J8Z0D0000000000000006003', 2, 'not_admitted', '00000000-0000-0000-0000-00000000f003'),
  ('00000000-0000-0000-0000-000000000e02',
   '{"device_id":"01J8Z0D0000000000000006004","kind":"note","payload":{"text":"e02"},"seq":9,"ulid":"01J80000000000000000006004"}',
   'a4' || repeat('0', 62), '01J8Z0D0000000000000006004', 9, 'revoked', '00000000-0000-0000-0000-00000000f004');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'safety', 'SAFE-E01A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'scorer', 'SCOR-E01A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e02', 'scorer', 'SCOR-E02A');
reset role;

-- The stubs the calling role sees, each as device (last four) # seq, hash (first two) and reason @
-- race day (last three), in race day, device and sequence order, or 'none', or the refusal. A null
-- device or seq shows as '?'.
create function pg_temp.stubs() returns text
language plpgsql as $$
declare
  v_seen text;
begin
  select coalesce(string_agg(coalesce(right(r.device_id, 4), '?') || '#' || coalesce(r.seq::text, '?') || ' '
                             || left(r.event_hash, 2) || ' ' || r.reason || '@' || right(r.event_id::text, 3),
                             ',' order by r.event_id, r.device_id, r.seq), 'none')
    into v_seen
  from public.event_refusal r;
  return v_seen;
exception when others then
  return 'refused ' || sqlstate || ': ' || sqlerrm;
end;
$$;
grant execute on function pg_temp.stubs() to authenticated, anon;

-- Runs a statement as the calling role and answers 'ran', or its refusal.
create function pg_temp.attempt(p_sql text) returns text
language plpgsql as $$
begin
  execute p_sql;
  return 'ran';
exception when others then
  return 'refused ' || sqlstate || ': ' || sqlerrm;
end;
$$;
grant execute on function pg_temp.attempt(text) to authenticated;

-- Signs a phone in, the way PostgREST sets the claims for its token.
create function pg_temp.as_phone(p_uid text) returns void
language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated', 'is_anonymous', true)::text, true);
$$;
grant execute on function pg_temp.as_phone(text) to authenticated;

create temp table adm (k text primary key, v uuid);
grant select, insert on adm to authenticated, service_role;

-- Admissions.
set local role authenticated;
select pg_temp.as_phone('00000000-0000-0000-0000-000000006101');
select public.admit_device('00000000-0000-0000-0000-000000000e01', 'SAFE-E01A');
select pg_temp.as_phone('00000000-0000-0000-0000-000000006102');
select public.admit_device('00000000-0000-0000-0000-000000000e02', 'SCOR-E02A');
select pg_temp.as_phone('00000000-0000-0000-0000-000000006106');
insert into adm values ('6106', public.admit_device('00000000-0000-0000-0000-000000000e01', 'SCOR-E01A'));

-- 4–6. Criterion 1: a phone admitted to e01 reads e01's stubs, the unparseable one included, and
-- none of e03 (same club) or e02. It cannot read the text, so no payload, GPS or person, and it
-- cannot read who sent it.
select pg_temp.as_phone('00000000-0000-0000-0000-000000006101');
select is(pg_temp.stubs(), '6001#5 a1 ulid_conflict@e01,?#? a2 inconsistent_canonical@e01',
          'a phone admitted to e01 reads the device, seq, hash and reason of each refusal on e01, and no other');
select is(pg_temp.attempt('select canonical from public.event_refusal'),
          'refused 42501: permission denied for table event_refusal',
          'it cannot read a refused event''s text, and so no payload, GPS or person');
select is(pg_temp.attempt('select auth_uid from public.event_refusal'),
          'refused 42501: permission denied for table event_refusal',
          'nor which signed-in user sent it');

-- 7–9. Criterion 2: a phone of another club reads only its own race day's stubs; a phone never
-- admitted reads none; the anon key alone is refused, as on the log (#50).
select pg_temp.as_phone('00000000-0000-0000-0000-000000006102');
select is(pg_temp.stubs(), '6004#9 a4 revoked@e02', 'a phone of the other club reads its own event''s stubs, and none of Hoover''s');
select pg_temp.as_phone('00000000-0000-0000-0000-000000006104');
select is(pg_temp.stubs(), 'none', 'a phone signed in and never admitted reads no stubs');
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select is(pg_temp.stubs(), 'refused 42501: permission denied for table event_refusal',
          'the anon key alone is refused, not shown the stubs');

-- 10–12. Criterion 2: a revoked phone reads no stubs. 10 is its control: the same phone read them
-- before it was revoked.
set local role authenticated;
select pg_temp.as_phone('00000000-0000-0000-0000-000000006106');
select is(pg_temp.stubs(), '6001#5 a1 ulid_conflict@e01,?#? a2 inconsistent_canonical@e01',
          'before it is revoked, the phone reads e01''s stubs');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select lives_ok(format('select public.revoke_device(%L)', (select v from adm where k = '6106')),
                'the owner''s tooling revokes the phone');
set local role authenticated;
select pg_temp.as_phone('00000000-0000-0000-0000-000000006106');
select is(pg_temp.stubs(), 'none', 'a revoked phone reads no stubs');

-- 13–14. Criterion 4: the stub is the record's own columns. No view or second table carries it, and
-- the only client-callable function whose body names the record is append_event, its one writer.
reset role;
select is(array(select v.view_schema::text || '.' || v.view_name::text from information_schema.view_table_usage v
                where v.table_schema = 'public' and v.table_name = 'event_refusal'),
          array[]::text[],
          'no view reads the refusal record');
select is(array(select p.proname::text from pg_proc p
                where p.pronamespace = 'public'::regnamespace and p.prosrc like '%event_refusal%'
                  and (has_function_privilege('authenticated', p.oid, 'execute')
                       or has_function_privilege('anon', p.oid, 'execute'))
                order by p.proname),
          array['append_event'],
          'append_event is the only function a client can call whose body names the record');

select * from finish();
rollback;
