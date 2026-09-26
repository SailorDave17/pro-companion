-- pgTAP tests for race areas (#58, groom decision G31): the course table between event and fleet,
-- create_course(), fleet_course(), and the key holding a fleet's race area to the fleet's own event.
-- Run with `supabase test db` against the local stack; the whole file is one transaction and rolls
-- back.
--
-- Roles are switched the way PostgREST switches them, as in committee_spine_test.sql. What these
-- tests cannot show is the migration moving fleets that already existed (criterion 2): a reset
-- applies it to an empty database. That was run by seeding fleets at the previous version and
-- applying the file on top; the PR for #58 records the read-back.

begin;
create extension if not exists pgtap with schema extensions;
select plan(32);

-- Fixed ids so the file needs no client-side variables.
-- clubs:   …c01 Hoover, …c02 Other
-- events:  …e01 Hoover's club night, …e03 Hoover's second day, …e02 the other club's regatta
-- courses: …ca01 e01 Alpha, …ca02 e01 Bravo, …ca03 e03 Alpha, …cb01 e02 Alpha
-- codes:   e01's overall PRO (gull-1234), e02's scorer (tern-5678)
-- devices: …aa01 admitted to e01, …aa02 admitted to e02, …aa03 admitted to nothing. Both admitted
--          phones are event-wide, so the fleet tests below are about the race area's key alone.
--          A phone bound to one race area (#65) is admission_code_test.sql's.
-- fleets:  …f101 on e01's Alpha, …f102 on e01's Bravo

-- 1–5. The table, its RLS, and fleet's key onto it.
select has_table('public', 'course', 'the course (race area) table exists');
select columns_are('public', 'course', array['id', 'event_id', 'name'],
                   'a race area is an id, its event and a name');
select ok((select relrowsecurity from pg_class where oid = 'public.course'::regclass), 'course has RLS enabled');
select col_not_null('public', 'fleet', 'course_id', 'every fleet names its race area');
select fk_ok('public', 'fleet', array['course_id', 'event_id'], 'public', 'course', array['id', 'event_id'],
             'a fleet''s race area is keyed to the fleet''s own event');

-- Fixture: two clubs and three events (service context: table owner, RLS bypassed).
insert into public.club (id, name) values
  ('00000000-0000-0000-0000-000000000c01', 'Hoover (fixture)'),
  ('00000000-0000-0000-0000-000000000c02', 'Other (fixture)');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Club night', date '2026-09-27',
                           '00000000-0000-0000-0000-000000000e01');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Second day', date '2026-09-28',
                           '00000000-0000-0000-0000-000000000e03');
select public.create_event('00000000-0000-0000-0000-000000000c02', 'Their regatta', date '2026-09-27',
                           '00000000-0000-0000-0000-000000000e02');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'overall_pro', 'gull-1234');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e02', 'scorer', 'tern-5678');

-- 6–10. create_course as the owner's tooling calls it: service_role.
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select lives_ok($$select public.create_course('00000000-0000-0000-0000-000000000e01', 'Alpha',
                                              '00000000-0000-0000-0000-00000000ca01')$$,
                'service_role creates a race area');
reset role;
select is((select count(*) from public.course
           where id = '00000000-0000-0000-0000-00000000ca01'
             and event_id = '00000000-0000-0000-0000-000000000e01' and name = 'Alpha'),
          1::bigint, 'the race area is on the event it was created for');
set local role service_role;
select throws_ok($$select public.create_course('00000000-0000-0000-0000-000000000e01', 'Alpha')$$,
                 '23505', 'duplicate key value violates unique constraint "course_event_id_name_key"',
                 'a second race area of the same name on one event is refused');
select lives_ok($$select public.create_course('00000000-0000-0000-0000-000000000e03', 'Alpha',
                                              '00000000-0000-0000-0000-00000000ca03')$$,
                'the same name on another event is a race area of its own');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Bravo', '00000000-0000-0000-0000-00000000ca02');
select public.create_course('00000000-0000-0000-0000-000000000e02', 'Alpha', '00000000-0000-0000-0000-00000000cb01');
select is((select count(*) from pg_proc where proname = 'create_course'), 1::bigint,
          'create_course has one signature, so no overload can shadow it');

-- 11–12. No client creates a race area.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa01","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.create_course('00000000-0000-0000-0000-000000000e01', 'Charlie')$$,
                 '42501', null, 'a phone cannot create a race area');
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$select public.create_course('00000000-0000-0000-0000-000000000e01', 'Charlie')$$,
                 '42501', null, 'anon cannot create a race area');

-- Admit device A to e01 and device B to the other club's e02.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa01","role":"authenticated","is_anonymous":true}', true);
select public.admit_device('00000000-0000-0000-0000-000000000e01', 'gull-1234');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa02","role":"authenticated","is_anonymous":true}', true);
select public.admit_device('00000000-0000-0000-0000-000000000e02', 'tern-5678');

-- 13–18. Who reads race areas: only a phone admitted to their event.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa03","role":"authenticated","is_anonymous":true}', true);
select is((select count(*) from public.course), 0::bigint, 'a phone admitted to no event sees no race area');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa01","role":"authenticated","is_anonymous":true}', true);
select is((select count(*) from public.course), 2::bigint, 'an admitted phone sees its own event''s race areas');
select is((select count(*) from public.course where event_id = '00000000-0000-0000-0000-000000000e03'), 0::bigint,
          'it sees none on another event of its own club');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa02","role":"authenticated","is_anonymous":true}', true);
select is((select count(*) from public.course where event_id = '00000000-0000-0000-0000-000000000e02'), 1::bigint,
          'a phone on another club''s event sees that event''s race area (positive control)');
select is((select count(*) from public.course where event_id <> '00000000-0000-0000-0000-000000000e02'), 0::bigint,
          'and none of this club''s race areas');

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$select id from public.course$$, '42501', null, 'anon reads no race area');

-- 19–23. No client writes a race area, even one admitted to its event. The refusal has two layers,
-- no write grant and no write policy, and either alone refuses with the same code, so 22 and 23 hold
-- each layer from the catalog.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa01","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$insert into public.course (event_id, name) values ('00000000-0000-0000-0000-000000000e01', 'Charlie')$$,
                 '42501', null, 'an admitted phone cannot insert a race area');
select throws_ok($$update public.course set name = 'Renamed'$$, '42501', null,
                 'an admitted phone cannot rename a race area');
select throws_ok($$delete from public.course$$, '42501', null, 'an admitted phone cannot delete a race area');
reset role;
select ok(has_any_column_privilege('authenticated', 'public.fleet', 'INSERT')
          and not has_table_privilege('authenticated', 'public.course', 'INSERT, UPDATE, DELETE, TRUNCATE')
          and not has_any_column_privilege('authenticated', 'public.course', 'INSERT, UPDATE')
          and not has_table_privilege('anon', 'public.course', 'INSERT, UPDATE, DELETE, TRUNCATE')
          and not has_any_column_privilege('anon', 'public.course', 'INSERT, UPDATE'),
          'no client role holds a write privilege on course (fleet''s insert grant is the control)');
select is((select count(*) from pg_policy where polrelid = 'public.course'::regclass and polcmd <> 'r'), 0::bigint,
          'course has no write policy');

-- 24–28. A fleet goes on a race area of its own event and nowhere else.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa01","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$insert into public.fleet (id, event_id, course_id, name)
                  values ('00000000-0000-0000-0000-00000000f101', '00000000-0000-0000-0000-000000000e01',
                          '00000000-0000-0000-0000-00000000ca01', 'Lasers')$$,
                'an admitted phone adds a fleet on a race area of its event');
insert into public.fleet (id, event_id, course_id, name)
  values ('00000000-0000-0000-0000-00000000f102', '00000000-0000-0000-0000-000000000e01',
          '00000000-0000-0000-0000-00000000ca02', '420s');
select is((select course_id from public.fleet where id = '00000000-0000-0000-0000-00000000f101'),
          '00000000-0000-0000-0000-00000000ca01'::uuid, 'and reads back the race area it races on');
select throws_ok($$insert into public.fleet (event_id, course_id, name)
                   values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca03', 'Sneak')$$,
                 '23503', 'insert or update on table "fleet" violates foreign key constraint "fleet_course_same_event_fkey"',
                 'a race area of another event of the same club is refused');
select throws_ok($$insert into public.fleet (event_id, course_id, name)
                   values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000cb01', 'Sneak')$$,
                 '23503', 'insert or update on table "fleet" violates foreign key constraint "fleet_course_same_event_fkey"',
                 'another club''s race area is refused');
select throws_ok($$insert into public.fleet (event_id, name) values ('00000000-0000-0000-0000-000000000e01', 'Nowhere')$$,
                 '23502', 'null value in column "course_id" of relation "fleet" violates not-null constraint',
                 'a fleet naming no race area is refused');

-- 29–32. fleet_course resolves a fleet to its race area, for the policies that key through it. The
-- two fleets are on different race areas of one event, so an answer read off the event fails one.
select is(array[public.fleet_course('00000000-0000-0000-0000-00000000f101'),
                public.fleet_course('00000000-0000-0000-0000-00000000f102')],
          array['00000000-0000-0000-0000-00000000ca01', '00000000-0000-0000-0000-00000000ca02']::uuid[],
          'fleet_course resolves each fleet to its own race area');
select is(public.fleet_course('00000000-0000-0000-0000-0000000000ff'), null::uuid,
          'an unknown fleet resolves to no race area');
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$select public.fleet_course('00000000-0000-0000-0000-00000000f101')$$, '42501', null,
                 'anon cannot call fleet_course');
reset role;
select ok((select prosecdef and proconfig = array['search_path=""']
           from pg_proc where oid = 'public.fleet_course(uuid)'::regprocedure),
          'fleet_course is security definer with an empty search_path');

select * from finish();
rollback;
