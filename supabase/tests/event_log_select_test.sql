-- pgTAP tests for reading the event log (#50): a phone reads the log of the event it is admitted to
-- and nothing else. Run with `supabase test db` against the local stack; the whole file is one
-- transaction and rolls back.
--
-- Roles are switched the way PostgREST switches them, as in committee_spine_test.sql. Every phone's
-- read goes through pg_temp.visible, which answers what the phone saw, or its refusal, so a mutation
-- that makes a read raise fails its own test and does not abort the file.
--
-- Pickup decision (owner, 2026-10-19, on #50): criterion 2's "anonymous" is a phone signed in
-- anonymously (the device-handoff path) and never admitted. It reads no rows. The anon key alone holds
-- no grant and is refused, as it was before #50.

begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

-- Fixed ids so the file needs no client-side variables.
-- clubs:   …c01 Hoover, …c02 Other
-- events:  …e01 Hoover's club night, …e03 Hoover's second day, …e02 the other club's regatta
-- log:     01J8…5001 and 5002 on e01, 5003 on e03, 5004 on e02
-- phones:  …5101 safety on e01; …5102 scorer on e02; …5104 signed in anonymously, never admitted;
--          …5105 signed in by name, never admitted; …5106 scorer on e01, then revoked;
--          …5107 overall PRO on e01, then re-admitted as scorer (#70)

-- 1–3. The read layers, held from the catalog: a select grant for phones and none for anon, and one
-- policy, select only, for authenticated, through the admission helper.
select is(array(select a.attname::text from pg_attribute a
                where a.attrelid = 'public.event_log'::regclass and a.attnum > 0 and not a.attisdropped
                  and not has_column_privilege('authenticated', 'public.event_log', a.attname, 'SELECT')
                order by a.attnum),
          array[]::text[],
          'a phone may select every column of the log');
select ok(not has_table_privilege('anon', 'public.event_log', 'SELECT')
          and not has_any_column_privilege('anon', 'public.event_log', 'SELECT'),
          'anon may select no column of the log');
select is(array(select p.polname::text || ' ' || p.polcmd::text || ' to '
                       || array_to_string(array(select r.rolname::text from pg_roles r
                                                where r.oid = any(p.polroles) order by r.rolname), ',')
                       || ' using ' || coalesce(pg_get_expr(p.polqual, p.polrelid), '(none)')
                from pg_policy p where p.polrelid = 'public.event_log'::regclass order by p.polname),
          array['event_log_select_admitted r to authenticated using is_admitted_to_event(event_id)'],
          'the log has one policy: select, for phones, on the event they are admitted to');

-- Fixture (table owner, RLS bypassed): two clubs, three events, four events in the log.
insert into public.club (id, name) values
  ('00000000-0000-0000-0000-000000000c01', 'Hoover (fixture)'),
  ('00000000-0000-0000-0000-000000000c02', 'Other (fixture)');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Club night', date '2026-10-19',
                           '00000000-0000-0000-0000-000000000e01');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Second day', date '2026-10-20',
                           '00000000-0000-0000-0000-000000000e03');
select public.create_event('00000000-0000-0000-0000-000000000c02', 'Their regatta', date '2026-10-19',
                           '00000000-0000-0000-0000-000000000e02');
insert into public.event_log (event_id, canonical) values
  ('00000000-0000-0000-0000-000000000e01', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000005001","device_ts":1729339201000,"gps":null,"kind":"note","payload":{"text":"e01 first"},"payload_version":1,"person":null,"prev_hash":null,"role":"overall_pro","seq":1,"source":"tap","ulid":"01J80000000000000000005001"}'),
  ('00000000-0000-0000-0000-000000000e01', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000005001","device_ts":1729339202000,"gps":null,"kind":"note","payload":{"text":"e01 second"},"payload_version":1,"person":null,"prev_hash":null,"role":"overall_pro","seq":2,"source":"tap","ulid":"01J80000000000000000005002"}'),
  ('00000000-0000-0000-0000-000000000e03', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000005003","device_ts":1729425601000,"gps":null,"kind":"note","payload":{"text":"e03"},"payload_version":1,"person":null,"prev_hash":null,"role":"overall_pro","seq":1,"source":"tap","ulid":"01J80000000000000000005003"}'),
  ('00000000-0000-0000-0000-000000000e02', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000005004","device_ts":1729339203000,"gps":null,"kind":"note","payload":{"text":"e02"},"payload_version":1,"person":null,"prev_hash":null,"role":"scorer","seq":1,"source":"tap","ulid":"01J80000000000000000005004"}');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'overall_pro', 'OPRO-E01A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'scorer',      'SCOR-E01A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'safety',      'SAFE-E01A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e02', 'scorer',      'SCOR-E02A');
reset role;

-- What the calling role sees of the log: each row as the last four of its ULID @ the last three of
-- its event, in ULID order, or 'none', or the refusal.
create function pg_temp.visible() returns text
language plpgsql as $$
declare
  v_seen text;
begin
  select coalesce(string_agg(right(l.ulid, 4) || '@' || right(l.event_id::text, 3), ',' order by l.ulid), 'none')
    into v_seen
  from public.event_log l;
  return v_seen;
exception when others then
  return 'refused ' || sqlstate || ': ' || sqlerrm;
end;
$$;
grant execute on function pg_temp.visible() to authenticated, anon;

-- Signs a phone in, the way PostgREST sets the claims for its token.
create function pg_temp.as_phone(p_uid text, p_anonymous boolean) returns void
language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated', 'is_anonymous', p_anonymous)::text, true);
$$;
grant execute on function pg_temp.as_phone(text, boolean) to authenticated;

create temp table adm (k text primary key, v uuid);
grant select, insert on adm to authenticated, service_role;

-- Admissions.
set local role authenticated;
select pg_temp.as_phone('00000000-0000-0000-0000-000000005101', true);
select public.admit_device('00000000-0000-0000-0000-000000000e01', 'SAFE-E01A');
select pg_temp.as_phone('00000000-0000-0000-0000-000000005102', true);
select public.admit_device('00000000-0000-0000-0000-000000000e02', 'SCOR-E02A');
select pg_temp.as_phone('00000000-0000-0000-0000-000000005106', true);
insert into adm values ('5106', public.admit_device('00000000-0000-0000-0000-000000000e01', 'SCOR-E01A'));
select pg_temp.as_phone('00000000-0000-0000-0000-000000005107', true);
insert into adm values ('5107 first', public.admit_device('00000000-0000-0000-0000-000000000e01', 'OPRO-E01A'));
insert into adm values ('5107 second', public.admit_device('00000000-0000-0000-0000-000000000e01', 'SCOR-E01A'));

-- 4–5. Criterion 1: a phone reads its own event's log, and nothing of another event, in its club or
-- another club.
select pg_temp.as_phone('00000000-0000-0000-0000-000000005101', true);
select is(pg_temp.visible(), '5001@e01,5002@e01',
          'a phone admitted to e01 reads e01''s log, and none of e03 (same club) or e02 (another club)');
select pg_temp.as_phone('00000000-0000-0000-0000-000000005102', true);
select is(pg_temp.visible(), '5004@e02',
          'a phone of the other club reads its own event''s log, and none of Hoover''s');

-- 6–8. Criterion 2: a phone never admitted reads no rows, by either sign-in path, and the anon key
-- alone is refused (pickup decision).
select pg_temp.as_phone('00000000-0000-0000-0000-000000005104', true);
select is(pg_temp.visible(), 'none', 'a phone signed in anonymously and never admitted reads no rows');
select pg_temp.as_phone('00000000-0000-0000-0000-000000005105', false);
select is(pg_temp.visible(), 'none', 'a phone signed in by name and never admitted reads no rows');
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select is(pg_temp.visible(), 'refused 42501: permission denied for table event_log',
          'the anon key alone is refused, not shown the log');

-- 9–11. Criterion 3: a revoked phone reads no rows. 9 is its control: the same phone read the log
-- before it was revoked.
set local role authenticated;
select pg_temp.as_phone('00000000-0000-0000-0000-000000005106', true);
select is(pg_temp.visible(), '5001@e01,5002@e01', 'before it is revoked, the phone reads e01''s log');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select lives_ok(format('select public.revoke_device(%L)', (select v from adm where k = '5106')),
                'the owner''s tooling revokes the phone');
set local role authenticated;
select pg_temp.as_phone('00000000-0000-0000-0000-000000005106', true);
select is(pg_temp.visible(), 'none', 'a revoked phone reads no rows');

-- 12–13. A phone whose role changed (#70) reads on through its new admission. 12 is its control:
-- the first admission was superseded, not reused.
reset role;
select ok(exists(select 1 from public.committee_device d
                 where d.id = (select v from adm where k = '5107 first')
                   and d.superseded_by = (select v from adm where k = '5107 second')
                   and d.superseded_by is distinct from d.id),
          'the phone''s first admission was superseded by its second');
set local role authenticated;
select pg_temp.as_phone('00000000-0000-0000-0000-000000005107', true);
select is(pg_temp.visible(), '5001@e01,5002@e01', 'after a role change the phone still reads e01''s log');

reset role;
select * from finish();
rollback;
