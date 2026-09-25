-- pgTAP tests for admission by role code (#65, groom decisions G26 and G38): the admission_code
-- table, issue_admission_code(), admit_device(event, code, person), the race-area binding on
-- committee_device, and the fleet insert policy that holds a bound phone to its race area. Run with
-- `supabase test db` against the local stack; the whole file is one transaction and rolls back.
--
-- Roles are switched the way PostgREST switches them, as in committee_spine_test.sql. Codes are
-- issued as service_role, the role the owner script calls with. Every refusal gets its own phone:
-- admit_device returns an existing admission without inserting, so a shared phone would make one
-- refusal depend on another.
--
-- What these tests cannot show is a code #39 printed being presented after the migration
-- (criterion 6): a reset applies every file to an empty database, so no #39 event exists here. 6
-- and 7 hold the column and every reader of it gone. The PR for #65 records the run that seeded an
-- event and its code at the previous version and presented the code after applying this file.

begin;
create extension if not exists pgtap with schema extensions;
select plan(53);

-- Fixed ids so the file needs no client-side variables.
-- clubs:   …c01 Hoover, …c02 Other
-- events:  …e01 Hoover's club night, …e02 the other club's regatta
-- courses: …ca01 e01 Alpha, …ca02 e01 Bravo, …cb01 e02 Alpha
-- phones:  …ad01–ad09 one per e01 code, in the order issued below; …ad10–ad14 refused;
--          …ad20–ad22 rows inserted by the table owner

-- 1–5. The code table holds a hash and nothing a client can read.
select has_table('public', 'admission_code', 'the admission_code table exists');
select columns_are('public', 'admission_code', array['id', 'event_id', 'role', 'course_id', 'code_hash', 'issued_at'],
                   'a code is kept as its event, role, race area and hash, never as the code');
select ok((select relrowsecurity from pg_class where oid = 'public.admission_code'::regclass),
          'admission_code has RLS enabled');
select ok(has_any_column_privilege('authenticated', 'public.course', 'SELECT')
          and not has_table_privilege('authenticated', 'public.admission_code', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
          and not has_any_column_privilege('authenticated', 'public.admission_code', 'SELECT, INSERT, UPDATE, REFERENCES')
          and not has_table_privilege('anon', 'public.admission_code', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
          and not has_any_column_privilege('anon', 'public.admission_code', 'SELECT, INSERT, UPDATE, REFERENCES'),
          'no client role holds any privilege on admission_code (course''s select grant is the control)');
select is((select count(*) from pg_policy where polrelid = 'public.admission_code'::regclass), 0::bigint,
          'admission_code has no policy for any role');

-- 6–7. Criterion 6: #39's single event code is gone, and nothing is left reading it.
select hasnt_column('public', 'event', 'admission_code_hash', 'the event no longer holds #39''s code');
select is((select count(*) from pg_proc
           where pronamespace = 'public'::regnamespace and prosrc like '%admission_code_hash%'), 0::bigint,
          'no function body reads the dropped column');

-- 8–10. Criteria 2 and 5: one admit_device, and the caller cannot name a role to it.
select is(array(select pg_get_function_identity_arguments(oid) from pg_proc
                where pronamespace = 'public'::regnamespace and proname = 'admit_device'),
          array['p_event uuid, p_admission_code text, p_person text'],
          'admit_device has one signature, and it takes no role');
select is(array(select pg_get_function_identity_arguments(oid) from pg_proc
                where pronamespace = 'public'::regnamespace and proname = 'create_event'),
          array['p_club uuid, p_name text, p_race_day date, p_id uuid'],
          'create_event has one signature, and it takes no code');
select is(array(select proname::text from pg_proc
                where pronamespace = 'public'::regnamespace
                  and proname in ('admit_device', 'create_event', 'issue_admission_code', 'is_admitted_to_race_area')
                  and not (prosecdef and proconfig = array['search_path=""'])),
          array[]::text[],
          'the four functions are security definer with an empty search_path');

-- Fixture: two clubs, two events, three race areas (service context: table owner, RLS bypassed).
insert into public.club (id, name) values
  ('00000000-0000-0000-0000-000000000c01', 'Hoover (fixture)'),
  ('00000000-0000-0000-0000-000000000c02', 'Other (fixture)');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Club night', date '2026-09-27',
                           '00000000-0000-0000-0000-000000000e01');
select public.create_event('00000000-0000-0000-0000-000000000c02', 'Their regatta', date '2026-09-27',
                           '00000000-0000-0000-0000-000000000e02');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Alpha', '00000000-0000-0000-0000-00000000ca01');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Bravo', '00000000-0000-0000-0000-00000000ca02');
select public.create_course('00000000-0000-0000-0000-000000000e02', 'Alpha', '00000000-0000-0000-0000-00000000cb01');

-- e01's nine codes, as the owner script issues them: one per event-wide role, one per race area
-- for each bound role. e02 gets one, for criterion 3.
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'overall_pro', 'OPRO-E01A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'scorer',      'SCOR-E01A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'safety',      'SAFE-E01A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'course_pro',  'CPRO-ALFA', '00000000-0000-0000-0000-00000000ca01');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'recorder',    'RECO-ALFA', '00000000-0000-0000-0000-00000000ca01');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'mark_boat',   'MARK-ALFA', '00000000-0000-0000-0000-00000000ca01');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'course_pro',  'CPRO-BRAV', '00000000-0000-0000-0000-00000000ca02');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'recorder',    'RECO-BRAV', '00000000-0000-0000-0000-00000000ca02');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'mark_boat',   'MARK-BRAV', '00000000-0000-0000-0000-00000000ca02');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e02', 'recorder',    'RECO-E02A', '00000000-0000-0000-0000-00000000cb01');

-- 11–17. Criteria 1 and 4 on the code table. Each code but 16's is new, and 16's slot is free (every
-- slot of e01 is taken, so it is on e02), so only the named rule can refuse each.
select throws_ok($$select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'recorder', 'XXXX-0001')$$,
                 '23514', 'new row for relation "admission_code" violates check constraint "admission_code_race_area_check"',
                 'a code for a bound role names a race area');
select throws_ok($$select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'scorer', 'XXXX-0002',
                                                      '00000000-0000-0000-0000-00000000ca01')$$,
                 '23514', 'new row for relation "admission_code" violates check constraint "admission_code_race_area_check"',
                 'a code for an event-wide role names none');
select throws_ok($$select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'overall_pro', 'XXXX-0003')$$,
                 '23505', 'duplicate key value violates unique constraint "admission_code_one_per_slot"',
                 'an event has one code for an event-wide role');
select throws_ok($$select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'recorder', 'XXXX-0004',
                                                      '00000000-0000-0000-0000-00000000ca01')$$,
                 '23505', 'duplicate key value violates unique constraint "admission_code_one_per_slot"',
                 'a race area has one code for each bound role');
select throws_ok($$select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'recorder', 'XXXX-0005',
                                                      '00000000-0000-0000-0000-00000000cb01')$$,
                 '23503', 'insert or update on table "admission_code" violates foreign key constraint "admission_code_course_same_event_fkey"',
                 'a code''s race area is one of its own event''s');
select throws_ok($$select public.issue_admission_code('00000000-0000-0000-0000-000000000e02', 'overall_pro', 'RECO-E02A')$$,
                 '23505', 'duplicate key value violates unique constraint "admission_code_hash_per_event"',
                 'one code cannot stand for two slots of an event');
-- 17 asks for the row by its hash rather than reading the slot's one code, so a mutation letting 13's
-- second code in cannot abort the file here (it did, once, when this read the slot).
reset role;
select ok(exists(select 1 from public.admission_code
                 where event_id = '00000000-0000-0000-0000-000000000e01' and role = 'overall_pro'
                   and course_id is null
                   and code_hash = encode(extensions.digest('OPRO-E01A', 'sha256'), 'hex')),
          'a code is stored as its sha256');

-- 18–19. No client issues a code.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000ad01","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'overall_pro', 'MINE-0001')$$,
                 '42501', null, 'a phone cannot issue itself a code');
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'overall_pro', 'MINE-0002')$$,
                 '42501', null, 'anon cannot issue a code');

-- 20–28. Nine phones present e01's nine codes, one each. ad05 is a named volunteer and calls with
-- named arguments, as PostgREST does.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad01","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'OPRO-E01A')$$,
                'a phone presents the overall PRO''s code');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad02","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'SCOR-E01A')$$,
                'a phone presents the scorer''s code');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad03","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'SAFE-E01A')$$,
                'a phone presents the safety boat''s code');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad04","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'CPRO-ALFA')$$,
                'a phone presents Alpha''s course PRO code');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad05","role":"authenticated","is_anonymous":false}', true);
select lives_ok($$select public.admit_device(p_event => '00000000-0000-0000-0000-000000000e01',
                                             p_admission_code => 'RECO-ALFA', p_person => 'Jo Volunteer')$$,
                'a named volunteer presents Alpha''s recorder code');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad06","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'MARK-ALFA')$$,
                'a phone presents Alpha''s mark boat code');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad07","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'CPRO-BRAV')$$,
                'a phone presents Bravo''s course PRO code');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad08","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'RECO-BRAV')$$,
                'a phone presents Bravo''s recorder code');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad09","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'MARK-BRAV')$$,
                'a phone presents Bravo''s mark boat code');

-- 29. Criterion 2: each admission carries exactly its code's role and race area. Both race areas
-- carry all three bound roles, so an answer read off the role alone, or off the first race area,
-- fails.
reset role;
select is(array(select right(d.auth_uid::text, 4) || ' ' || d.role || ' ' || coalesce(c.name, 'event-wide')
                from public.committee_device d
                left join public.course c on c.id = d.course_id
                where d.event_id = '00000000-0000-0000-0000-000000000e01'
                order by d.auth_uid),
          array['ad01 overall_pro event-wide', 'ad02 scorer event-wide', 'ad03 safety event-wide',
                'ad04 course_pro Alpha', 'ad05 recorder Alpha', 'ad06 mark_boat Alpha',
                'ad07 course_pro Bravo', 'ad08 recorder Bravo', 'ad09 mark_boat Bravo'],
          'each phone is admitted to exactly the role and race area of the code it presented');

-- 30–31. A bound phone reads its own race area back; a named volunteer's person is kept.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad05","role":"authenticated","is_anonymous":false}', true);
select is((select course_id from public.committee_device), '00000000-0000-0000-0000-00000000ca01'::uuid,
          'a bound phone reads the race area it was admitted to');
select is((select person from public.committee_device), 'Jo Volunteer', 'the person it named is on its admission');

-- 32–33. Holding a second code changes nothing: the recorder presenting the overall PRO's code gets
-- its own admission back, still recorder. Changing role is #70's.
select is(public.admit_device('00000000-0000-0000-0000-000000000e01', 'OPRO-E01A'),
          (select id from public.committee_device),
          'a phone already admitted gets its own admission back');
select is((select role || ' ' || course_id::text from public.committee_device),
          'recorder 00000000-0000-0000-0000-00000000ca01',
          'and it is still the recorder on its race area');

-- 34. No client reads a code, even a phone admitted as overall PRO.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad01","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select code_hash from public.admission_code$$, '42501', null,
                 'an admitted overall PRO cannot read the codes');

-- 35–40. Criterion 3: a code of another event, an unknown code and no event are refused alike, with
-- #39's error, and none creates a row. 39 is criterion 5's behavioural half: a caller naming a role
-- finds no function to call.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad10","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'RECO-E02A')$$,
                 '28000', 'admit_device: event or admission code not recognised', 'a code of another event is refused');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad11","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'NOPE-NOPE')$$,
                 '28000', 'admit_device: event or admission code not recognised', 'an unknown code is refused alike');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad12","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-0000000000ff', 'RECO-ALFA')$$,
                 '28000', 'admit_device: event or admission code not recognised', 'an unknown event is refused alike');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad13","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.admit_device(null, 'RECO-ALFA')$$,
                 '28000', 'admit_device: event or admission code not recognised', 'no event is refused alike');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad14","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.admit_device(p_event => '00000000-0000-0000-0000-000000000e01', p_role => 'overall_pro',
                                              p_admission_code => 'RECO-ALFA')$$,
                 '42883', null, 'a caller naming a role finds no admit_device to call');
reset role;
select is((select count(*) from public.committee_device
           where auth_uid in ('00000000-0000-0000-0000-00000000ad10', '00000000-0000-0000-0000-00000000ad11',
                              '00000000-0000-0000-0000-00000000ad12', '00000000-0000-0000-0000-00000000ad13',
                              '00000000-0000-0000-0000-00000000ad14')),
          0::bigint, 'no refused presentation created a row');

-- 41–43. Criterion 4 on committee_device, inserting as the table owner so nothing but the
-- constraint can refuse. 43's race area is another event's.
select throws_ok($$insert into public.committee_device (event_id, club_id, auth_uid, role)
                   values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01',
                           '00000000-0000-0000-0000-00000000ad20', 'recorder')$$,
                 '23514', 'new row for relation "committee_device" violates check constraint "committee_device_race_area_check"',
                 'a bound-role admission with no race area is refused');
select throws_ok($$insert into public.committee_device (event_id, club_id, course_id, auth_uid, role)
                   values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01',
                           '00000000-0000-0000-0000-00000000ca01', '00000000-0000-0000-0000-00000000ad21', 'scorer')$$,
                 '23514', 'new row for relation "committee_device" violates check constraint "committee_device_race_area_check"',
                 'an event-wide admission with a race area is refused');
select throws_ok($$insert into public.committee_device (event_id, club_id, course_id, auth_uid, role)
                   values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01',
                           '00000000-0000-0000-0000-00000000cb01', '00000000-0000-0000-0000-00000000ad22', 'recorder')$$,
                 '23503', 'insert or update on table "committee_device" violates foreign key constraint "committee_device_course_same_event_fkey"',
                 'an admission''s race area is one of its own event''s');

-- 44–46. The two binding checks name the same three roles (G38), and the code table allows exactly
-- G28's six, as committee_device does (roles_test.sql).
select is((select array_agg(m[1] order by m[1])
           from regexp_matches((select pg_get_constraintdef(oid) from pg_constraint
                                where conname = 'committee_device_race_area_check'), '''([a-z_]+)''', 'g') as m),
          array['course_pro', 'mark_boat', 'recorder'],
          'committee_device binds exactly course_pro, recorder and mark_boat to a race area');
select is((select array_agg(m[1] order by m[1])
           from regexp_matches((select pg_get_constraintdef(oid) from pg_constraint
                                where conname = 'admission_code_race_area_check'), '''([a-z_]+)''', 'g') as m),
          array['course_pro', 'mark_boat', 'recorder'],
          'admission_code binds the same three');
select is((select array_agg(m[1] order by m[1])
           from regexp_matches((select pg_get_constraintdef(oid) from pg_constraint
                                where conname = 'admission_code_role_check'), '''([a-z_]+)''', 'g') as m),
          array['course_pro', 'mark_boat', 'overall_pro', 'recorder', 'safety', 'scorer'],
          'admission_code allows exactly the six roles of G28');

-- 47–52. Criterion 7: a bound phone adds fleets on its race area and no other; an event-wide phone
-- adds them on any race area of its event.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad05","role":"authenticated","is_anonymous":false}', true);
select lives_ok($$insert into public.fleet (event_id, course_id, name)
                  values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca01', 'Lasers')$$,
                'the recorder on Alpha adds a fleet on Alpha');
select throws_ok($$insert into public.fleet (event_id, course_id, name)
                   values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca02', 'Sneak')$$,
                 '42501', 'new row violates row-level security policy for table "fleet"',
                 'the recorder on Alpha cannot add one on Bravo');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad07","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$insert into public.fleet (event_id, course_id, name)
                  values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca02', 'Toppers')$$,
                'the course PRO on Bravo adds a fleet on Bravo');
select throws_ok($$insert into public.fleet (event_id, course_id, name)
                   values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca01', 'Sneak')$$,
                 '42501', 'new row violates row-level security policy for table "fleet"',
                 'and cannot add one on Alpha');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000ad01","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$insert into public.fleet (event_id, course_id, name)
                  values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca01', 'Optis')$$,
                'the overall PRO adds a fleet on Alpha');
select lives_ok($$insert into public.fleet (event_id, course_id, name)
                  values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca02', '420s')$$,
                'and on Bravo');

-- 53. What the phones added: four fleets, each on the race area it named.
reset role;
select is(array(select f.name || ' ' || c.name from public.fleet f join public.course c on c.id = f.course_id
                where f.event_id = '00000000-0000-0000-0000-000000000e01' order by f.name),
          array['420s Bravo', 'Lasers Alpha', 'Optis Alpha', 'Toppers Bravo'],
          'the four fleets the phones could add, and nothing refused');

select * from finish();
rollback;
