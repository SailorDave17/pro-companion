-- pgTAP tests for changing role by re-admission (#70, groom decision G44): uniqueness over active
-- admissions only, admit_device superseding a phone's admission when it presents another slot's code,
-- the revoked-phone refusal across all of a phone's admissions, and the admission helpers counting the
-- active row only. Run with `supabase test db` against the local stack; the whole file is one
-- transaction and rolls back.
--
-- Roles are switched the way PostgREST switches them, as in committee_spine_test.sql. Every phone a
-- test reads again holds its own fixed id, and every refusal gets its own phone: a refused act a
-- mutation lets through really happens, so it must not change a row another test reads.
--
-- admit_device answers with an id it generates, so each answer is kept in the temp table ans and
-- compared from there. Every call goes through pg_temp.answer, so a mutation that makes one raise
-- fails its own tests and does not abort the file.
--
-- Pickup decisions (owner, 2026-10-17, on #70) these tests hold: the slot is role plus race area; a
-- role change is held to the club's sign-in mode; a named volunteer's person carries over unless a
-- new one is given; any revoked admission revokes the phone in that event; switching back is a new
-- row.
--
-- Criterion 1's "no existing row is deleted" is shown against seeded rows, which a reset cannot
-- hold: the PR for #70 records the run that stopped at 20260925000600, seeded admissions, applied this
-- file and counted them. Criterion 6 is the mutation round in that PR.

begin;
create extension if not exists pgtap with schema extensions;
select plan(47);

-- Fixed ids so the file needs no client-side variables.
-- clubs:   …c01 Hoover (mode both); …c02 Other, switched to device_handoff for 40–42
-- events:  …e01 Hoover's club night, …e02 the other club's regatta
-- courses: …ca01 e01 Alpha, …ca02 e01 Bravo
-- phones:  …7001 recorder → mark boat → recorder again; …7002 named recorder Alpha → Bravo;
--          …7003 named scorer → overall PRO naming a new person; …7004 revoked, then presents;
--          …7005 scorer → overall PRO, then its superseded row revoked; …7006 recorder Alpha →
--          Bravo; …7007 overall PRO → recorder Alpha; …7008 refused for naming a person;
--          …7010 named scorer of e02; …7011, …7012, …7016 rows inserted by the table owner;
--          …7015 named scorer, then a token that does not say its path

-- 1–7. Criterion 1: #39's unique is gone, and one active admission per phone and event replaces it.
select is((select count(*) from pg_constraint
           where conrelid = 'public.committee_device'::regclass
             and conname = 'committee_device_event_id_auth_uid_key'), 0::bigint,
          '#39''s unique (event_id, auth_uid) is gone');
-- 2 reads the index by to_regclass, which answers null for a missing index where a ::regclass cast
-- would abort the file.
select is(pg_get_indexdef(to_regclass('public.committee_device_one_active_per_event')),
          'CREATE UNIQUE INDEX committee_device_one_active_per_event ON public.committee_device USING btree (event_id, auth_uid) WHERE (superseded_by IS NULL)',
          'a phone holds one active (not superseded) admission per event');
select has_column('public', 'committee_device', 'superseded_by', 'an admission names the one that replaced it');
select has_column('public', 'committee_device', 'superseded_at', 'and when it was replaced');
select ok(has_column_privilege('authenticated', 'public.committee_device', 'superseded_by', 'SELECT')
          and has_column_privilege('authenticated', 'public.committee_device', 'superseded_at', 'SELECT'),
          'a phone can read the supersede columns of its own rows');
select is(array(select p.oid::regprocedure::text from pg_proc p
                where p.oid in ('public.admit_device(uuid, text, text)'::regprocedure,
                                'public.is_admitted_to_club(uuid)'::regprocedure,
                                'public.is_admitted_to_event(uuid)'::regprocedure,
                                'public.is_admitted_to_race_area(uuid, uuid)'::regprocedure)
                  and not coalesce(p.prosecdef and p.proconfig = array['search_path=""'], false)),
          array[]::text[],
          'the four functions are security definer with an empty search_path');
-- 6's coalesce matters: a function with no SET clause has a null proconfig, and without it the
-- predicate is null, the row drops out and the check passes.
select is((select condeferrable::text || ' ' || condeferred::text from pg_constraint
           where conrelid = 'public.committee_device'::regclass
             and conname = 'committee_device_superseded_by_fkey'), 'true true',
          'the successor key is checked at commit, so the old row can name the new one first');

-- Fixture (table owner, RLS bypassed).
insert into public.club (id, name) values
  ('00000000-0000-0000-0000-000000000c01', 'Hoover (fixture)'),
  ('00000000-0000-0000-0000-000000000c02', 'Other (fixture)');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Club night', date '2026-10-17',
                           '00000000-0000-0000-0000-000000000e01');
select public.create_event('00000000-0000-0000-0000-000000000c02', 'Their regatta', date '2026-10-17',
                           '00000000-0000-0000-0000-000000000e02');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Alpha', '00000000-0000-0000-0000-00000000ca01');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Bravo', '00000000-0000-0000-0000-00000000ca02');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'overall_pro', 'OPRO-E01A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'scorer',      'SCOR-E01A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'recorder',    'RECO-ALFA', '00000000-0000-0000-0000-00000000ca01');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'mark_boat',   'MARK-ALFA', '00000000-0000-0000-0000-00000000ca01');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'recorder',    'RECO-BRAV', '00000000-0000-0000-0000-00000000ca02');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e02', 'scorer',      'SCOR-E02A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e02', 'overall_pro', 'OPRO-E02A');
reset role;

-- A call's answer as text, or its refusal, as in sign_in_path_test.sql.
create function pg_temp.answer(p_call text) returns text
language plpgsql as $$
declare
  v_answer text;
begin
  execute p_call into v_answer;
  return v_answer;
exception when others then
  return 'refused ' || sqlstate || ': ' || sqlerrm;
end;
$$;
grant execute on function pg_temp.answer(text) to authenticated;

create temp table ans (k text primary key, v text);
grant select, insert on ans to authenticated, service_role;

create function pg_temp.is_uuid(p text) returns boolean
language sql immutable as $$
  select p ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$$;

-- 8–9. The rule is the partial index, read from the table owner's side, which no function stands in
-- front of.
select throws_ok($$insert into public.committee_device (event_id, club_id, auth_uid, role) values
                     ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01',
                      '00000000-0000-0000-0000-000000007011', 'scorer'),
                     ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01',
                      '00000000-0000-0000-0000-000000007011', 'safety')$$,
                 '23505', 'duplicate key value violates unique constraint "committee_device_one_active_per_event"',
                 'two active admissions of one phone in one event are refused');
select lives_ok($$insert into public.committee_device (id, event_id, club_id, auth_uid, role, superseded_by, superseded_at) values
                    ('00000000-0000-0000-0000-0000000d7121', '00000000-0000-0000-0000-000000000e01',
                     '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-000000007012', 'scorer',
                     '00000000-0000-0000-0000-0000000d7122', now()),
                    ('00000000-0000-0000-0000-0000000d7122', '00000000-0000-0000-0000-000000000e01',
                     '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-000000007012', 'safety',
                     null, null)$$,
                'a superseded admission and its active successor stand side by side');

-- The phones present their codes. Each answer is kept for the tests below.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007001","role":"authenticated","is_anonymous":true}', true);
insert into ans values ('7001 first',  pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'RECO-ALFA')$$));
insert into ans values ('7001 change', pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'MARK-ALFA')$$));
insert into ans values ('7001 again',  pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'MARK-ALFA')$$));
reset role;
insert into ans values ('7001 rows after again',
  (select count(*)::text from public.committee_device where auth_uid = '00000000-0000-0000-0000-000000007001'));
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007001","role":"authenticated","is_anonymous":true}', true);
insert into ans values ('7001 back',   pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'RECO-ALFA')$$));

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007002","role":"authenticated","is_anonymous":false}', true);
insert into ans values ('7002 first',  pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'RECO-ALFA', 'Jo')$$));
insert into ans values ('7002 change', pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'RECO-BRAV')$$));

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007003","role":"authenticated","is_anonymous":false}', true);
insert into ans values ('7003 first',  pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'SCOR-E01A', 'Ann')$$));
insert into ans values ('7003 change', pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'OPRO-E01A', 'Ann B')$$));

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007004","role":"authenticated","is_anonymous":true}', true);
insert into ans values ('7004 first',  pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'SCOR-E01A')$$));
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007005","role":"authenticated","is_anonymous":true}', true);
insert into ans values ('7005 first',  pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'SCOR-E01A')$$));
insert into ans values ('7005 change', pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'OPRO-E01A')$$));
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007006","role":"authenticated","is_anonymous":true}', true);
insert into ans values ('7006 first',  pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'RECO-ALFA')$$));
insert into ans values ('7006 change', pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'RECO-BRAV')$$));
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007007","role":"authenticated","is_anonymous":true}', true);
insert into ans values ('7007 first',  pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'OPRO-E01A')$$));
insert into ans values ('7007 change', pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'RECO-ALFA')$$));
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007008","role":"authenticated","is_anonymous":true}', true);
insert into ans values ('7008 first',  pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'SCOR-E01A')$$));

-- Revocations, as the owner's tooling makes them: 7004's only admission, and 7005's superseded one.
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.revoke_device((select v from ans where k = '7004 first')::uuid)
  where pg_temp.is_uuid((select v from ans where k = '7004 first'));
select public.revoke_device((select v from ans where k = '7005 first')::uuid)
  where pg_temp.is_uuid((select v from ans where k = '7005 first'));
reset role;

-- 10–19. Criteria 2 and 3, and switching back, on one phone.
select ok(pg_temp.is_uuid((select v from ans where k = '7001 first')), 'a phone is admitted as recorder on Alpha');
select ok(pg_temp.is_uuid((select v from ans where k = '7001 change'))
          and (select v from ans where k = '7001 change') <> (select v from ans where k = '7001 first'),
          'another role''s code answers with a new admission');
select ok(exists(select 1 from public.committee_device
                 where id::text = (select v from ans where k = '7001 change')
                   and role = 'mark_boat' and course_id = '00000000-0000-0000-0000-00000000ca01'),
          'the new admission carries the new code''s role and race area');
select ok(exists(select 1 from public.committee_device
                 where id::text = (select v from ans where k = '7001 first')
                   and role = 'recorder'
                   and superseded_by::text = (select v from ans where k = '7001 change')
                   and superseded_at is not null),
          'the old admission stays, marked superseded by the new one');
-- 14 asks for an id as well: two refusals with one message would otherwise compare equal.
select ok(pg_temp.is_uuid((select v from ans where k = '7001 again'))
          and (select v from ans where k = '7001 again') = (select v from ans where k = '7001 change'),
          'criterion 3: the same code again answers with the active admission');
select is((select v from ans where k = '7001 rows after again'), '2',
          'and adds no row');
select ok(pg_temp.is_uuid((select v from ans where k = '7001 back'))
          and (select v from ans where k = '7001 back')
              not in ((select v from ans where k = '7001 first'), (select v from ans where k = '7001 change')),
          'switching back to recorder is a new admission, not the first one reactivated');
select ok((select superseded_by::text from public.committee_device
           where id::text = (select v from ans where k = '7001 change')) = (select v from ans where k = '7001 back')
          and (select superseded_by::text from public.committee_device
               where id::text = (select v from ans where k = '7001 first')) = (select v from ans where k = '7001 change'),
          'the successor chain runs first → mark boat → recorder again');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007001","role":"authenticated","is_anonymous":true}', true);
select is(array(select role || ' ' || (superseded_by is null)::text from public.committee_device
                order by role, superseded_by is null),
          array['mark_boat false', 'recorder false', 'recorder true'],
          'the phone reads all three of its admissions, superseded ones included');
reset role;
select is((select count(*) from public.committee_device
           where auth_uid = '00000000-0000-0000-0000-000000007001' and superseded_by is null), 1::bigint,
          'and exactly one of them is active');

-- 20–22. The slot is role plus race area, and a named volunteer's person carries over.
select ok((select v from ans where k = '7002 change') <> (select v from ans where k = '7002 first')
          and exists(select 1 from public.committee_device
                     where id::text = (select v from ans where k = '7002 change')
                       and role = 'recorder' and course_id = '00000000-0000-0000-0000-00000000ca02'
                       and superseded_by is null)
          and exists(select 1 from public.committee_device
                     where id::text = (select v from ans where k = '7002 first')
                       and superseded_by::text = (select v from ans where k = '7002 change')),
          'a recorder presenting another race area''s recorder code moves there, superseding the old area');
select is((select person from public.committee_device where id::text = (select v from ans where k = '7002 change')),
          'Jo', 'a named volunteer who names nobody keeps the name of the admission it replaced');
select is(array(select person from public.committee_device
                where auth_uid = '00000000-0000-0000-0000-000000007003' order by superseded_by is null),
          array['Ann', 'Ann B'], 'a name given on a role change goes on the new admission, and the old keeps its own');

-- 23–24. The person rule holds on a role change, and a refused change changes nothing.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007008","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'OPRO-E01A', 'Pat')$$,
                 '22023', 'admit_device: only a named volunteer''s admission names a person',
                 'a device-handoff phone naming a person on a role change is refused');
reset role;
select is(array(select role || ' ' || (superseded_by is null)::text from public.committee_device
                where auth_uid = '00000000-0000-0000-0000-000000007008'),
          array['scorer true'], 'and it is still the scorer, with no row added');

-- 25–27. Criterion 4: a phone holding any revoked admission in the event is refused, whatever code.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007004","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'OPRO-E01A')$$,
                 '42501', 'admit_device: this device was revoked from the event',
                 'a revoked phone presenting another role''s code is refused');
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'SCOR-E01A')$$,
                 '42501', 'admit_device: this device was revoked from the event',
                 'and so is one presenting its own code');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007005","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'OPRO-E01A')$$,
                 '42501', 'admit_device: this device was revoked from the event',
                 'a phone whose superseded admission was revoked is refused, even its active code');

-- 28–32. Criterion 5 and the revocation decision: the helpers count the active row only, and only
-- while no admission of the phone in the event is revoked.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007001","role":"authenticated","is_anonymous":true}', true);
select ok(public.is_admitted_to_event('00000000-0000-0000-0000-000000000e01'), 'a phone that changed role is admitted to its event');
select ok(public.is_admitted_to_club('00000000-0000-0000-0000-000000000c01'), 'and to its club');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007005","role":"authenticated","is_anonymous":true}', true);
select ok(not public.is_admitted_to_event('00000000-0000-0000-0000-000000000e01'),
          'a phone whose superseded admission was revoked is not admitted to the event');
select ok(not public.is_admitted_to_club('00000000-0000-0000-0000-000000000c01'), 'nor to the club');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007004","role":"authenticated","is_anonymous":true}', true);
select ok(not public.is_admitted_to_event('00000000-0000-0000-0000-000000000e01'), 'a revoked phone is not admitted (control)');

-- 33–39. Criterion 5's fleet insert: the superseded role grants nothing.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007006","role":"authenticated","is_anonymous":true}', true);
select ok(not public.is_admitted_to_race_area('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca01'),
          'a recorder moved to Bravo is no longer admitted to Alpha');
select ok(public.is_admitted_to_race_area('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca02'),
          'and is admitted to Bravo');
select throws_ok($$insert into public.fleet (event_id, course_id, name) values
                     ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca01', 'R7006 Alpha')$$,
                 '42501', null, 'its fleet insert on Alpha, which only the superseded admission allowed, is refused');
select lives_ok($$insert into public.fleet (event_id, course_id, name) values
                    ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca02', 'R7006 Bravo')$$,
                'its fleet insert on Bravo is accepted');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007007","role":"authenticated","is_anonymous":true}', true);
select ok(not public.is_admitted_to_race_area('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca02'),
          'an overall PRO that became Alpha''s recorder is no longer admitted to Bravo');
select throws_ok($$insert into public.fleet (event_id, course_id, name) values
                     ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca02', 'R7007 Bravo')$$,
                 '42501', null, 'its fleet insert on Bravo, which its superseded event-wide role allowed, is refused');
select ok(public.is_admitted_to_race_area('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca01'),
          'and it is admitted to Alpha');

-- 40–42. A role change is a new admission, so the club's sign-in mode holds it. The same code again
-- is not, so a switch never touches it.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007010","role":"authenticated","is_anonymous":false}', true);
insert into ans values ('7010 first', pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e02', 'SCOR-E02A')$$));
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.set_sign_in_mode('00000000-0000-0000-0000-000000000c02', 'device_handoff');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007010","role":"authenticated","is_anonymous":false}', true);
insert into ans values ('7010 again', pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e02', 'SCOR-E02A')$$));
select ok(pg_temp.is_uuid((select v from ans where k = '7010 again'))
          and (select v from ans where k = '7010 again') = (select v from ans where k = '7010 first'),
          'at device_handoff, a named account presenting its own code still gets its admission back');
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e02', 'OPRO-E02A')$$,
                 '42501', 'admit_device: the club''s sign-in mode does not admit this sign-in',
                 'but its role change is refused, because the mode excludes its path');
reset role;
select is(array(select role || ' ' || (superseded_by is null)::text from public.committee_device
                where auth_uid = '00000000-0000-0000-0000-000000007010'),
          array['scorer true'], 'and it is still the scorer, with no row added');

-- 43. The person carries over on the named path only. In mode both, a token that does not say which
-- path it came by is admitted, and a named volunteer's name must not follow it onto the new row.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007015","role":"authenticated","is_anonymous":false}', true);
insert into ans values ('7015 first',  pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'SCOR-E01A', 'Lee')$$));
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007015","role":"authenticated"}', true);
insert into ans values ('7015 change', pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'OPRO-E01A')$$));
reset role;
select is(array(select person from public.committee_device
                where auth_uid = '00000000-0000-0000-0000-000000007015' order by superseded_by is null),
          array['Lee', null]::text[],
          'a role change on a token that does not say its path carries no name onto the new admission');

-- 44–46. The event and club helpers count the active row only. Every state admit_device makes ends a
-- superseded row's chain in an active row of the same event, so only the table owner can make the
-- state that tells the filter apart: a superseded e01 row whose successor is the phone's admission
-- to e02, another club's event.
insert into public.committee_device (id, event_id, club_id, auth_uid, role, superseded_by, superseded_at) values
  ('00000000-0000-0000-0000-0000000d7161', '00000000-0000-0000-0000-000000000e01',
   '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-000000007016', 'scorer',
   '00000000-0000-0000-0000-0000000d7162', now()),
  ('00000000-0000-0000-0000-0000000d7162', '00000000-0000-0000-0000-000000000e02',
   '00000000-0000-0000-0000-000000000c02', '00000000-0000-0000-0000-000000007016', 'scorer',
   null, null);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007016","role":"authenticated","is_anonymous":true}', true);
select ok(not public.is_admitted_to_event('00000000-0000-0000-0000-000000000e01'),
          'a phone whose only e01 admission is superseded is not admitted to e01');
select ok(not public.is_admitted_to_club('00000000-0000-0000-0000-000000000c01'),
          'nor to e01''s club');
select ok(public.is_admitted_to_event('00000000-0000-0000-0000-000000000e02')
          and public.is_admitted_to_club('00000000-0000-0000-0000-000000000c02'),
          'and is admitted where its active admission is (control)');
reset role;

-- 47. Every successor named in the file exists. The key is deferred to commit, which this file never
-- reaches, so it is checked here.
select lives_ok($$set constraints committee_device_superseded_by_fkey immediate$$,
                'every superseded admission names an admission that exists');

select * from finish();
rollback;
