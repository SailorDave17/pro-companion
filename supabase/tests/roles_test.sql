-- pgTAP tests for the committee's six roles (#57, groom decision G28). Run with `supabase test db`
-- against the local stack; the whole file is one transaction and rolls back.
--
-- What these tests cannot show is the migration moving existing pro admissions to overall_pro
-- (criterion 2): a reset applies it to a database with no admissions. That was run by seeding
-- admissions at the previous version and applying the file on top; the PR for #57 records it.

begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

-- 1–2. One check holds the role to a set, and it allows exactly G28's six. A check listing 'scorer'
-- is a role-set check: #39's listed it too, and #65's race-area check names only the three bound
-- roles.
select is((select array_agg(conname order by conname) from pg_constraint
           where conrelid = 'public.committee_device'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%''scorer''%'),
          array['committee_device_role_g28_check']::name[],
          'one check constrains the role, and #39''s is gone');
select is((select array_agg(m[1] order by m[1])
           from regexp_matches((select pg_get_constraintdef(oid) from pg_constraint
                                where conname = 'committee_device_role_g28_check'),
                               '''([a-z_]+)''', 'g') as m),
          array['course_pro', 'mark_boat', 'overall_pro', 'recorder', 'safety', 'scorer'],
          'the check allows exactly the six roles of G28');

-- Fixture: a club, an event, a race area and a code for each role (service context: table owner,
-- RLS bypassed). Since #65 the code grants the role.
insert into public.club (id, name) values ('00000000-0000-0000-0000-000000000c01', 'Hoover (fixture)');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Club night', date '2026-09-27',
                           '00000000-0000-0000-0000-000000000e01');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Main', '00000000-0000-0000-0000-00000000ca01');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'overall_pro', 'opro-1234');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'course_pro', 'cpro-1234',
                                   '00000000-0000-0000-0000-00000000ca01');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'recorder', 'reco-1234',
                                   '00000000-0000-0000-0000-00000000ca01');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'mark_boat', 'mark-1234',
                                   '00000000-0000-0000-0000-00000000ca01');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'safety', 'safe-1234');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'scorer', 'scor-1234');

-- 3–8. A phone is admitted under each of the six roles, one phone per role.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000ab01","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'opro-1234')$$,
                'a phone is admitted as overall_pro');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000ab02","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'cpro-1234')$$,
                'a phone is admitted as course_pro');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000ab03","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'reco-1234')$$,
                'a phone is admitted as recorder');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000ab04","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'mark-1234')$$,
                'a phone is admitted as mark_boat');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000ab05","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'safe-1234')$$,
                'a phone is admitted as safety');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000ab06","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'scor-1234')$$,
                'a phone is admitted as scorer');

-- 9. Each admission carries the role it was granted.
reset role;
select is((select array_agg(role order by role) from public.committee_device
           where event_id = '00000000-0000-0000-0000-000000000e01'),
          array['course_pro', 'mark_boat', 'overall_pro', 'recorder', 'safety', 'scorer'],
          'the six admissions carry the six roles');

-- 10–11. #39's pro and the signal boat's own role are refused by the check. Since #65 a phone
-- cannot name a role, so the rows go in as the table owner, where nothing but a check can refuse
-- them. Neither names a race area, which the race-area check allows for a role it does not bind.
-- One phone each, so 11 does not depend on what 10 did.
select throws_ok($$insert into public.committee_device (event_id, club_id, auth_uid, role)
                   values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01',
                           '00000000-0000-0000-0000-00000000ab07', 'pro')$$,
                 '23514', 'new row for relation "committee_device" violates check constraint "committee_device_role_g28_check"',
                 'pro is no longer a role');
select throws_ok($$insert into public.committee_device (event_id, club_id, auth_uid, role)
                   values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01',
                           '00000000-0000-0000-0000-00000000ab08', 'signal_boat')$$,
                 '23514', 'new row for relation "committee_device" violates check constraint "committee_device_role_g28_check"',
                 'signal_boat is not a role: the signal boat is the PRO');

select * from finish();
rollback;
