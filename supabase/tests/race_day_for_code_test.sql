-- pgTAP tests for race_day_for_code (#71): the one lookup a phone's join screen makes before
-- admit_device, so a volunteer types the code alone. Run with `supabase test db` against the local
-- stack; the whole file is one transaction and rolls back.
--
-- Roles are switched the way PostgREST switches them, as in admission_code_test.sql. Codes are
-- issued as service_role. The fixture is admission_code_test.sql's, with a third event so that one
-- code can be issued to two race days.
--
-- What it holds: the function is a definer with an empty search_path, callable by a signed-in phone
-- and by nobody else; an unknown code, a null code and a code issued to two race days are refused
-- with admit_device's own message and code (28000), so the lookup is no more of an oracle than the
-- admission; a known code answers its race day whatever the role or race area; the lookup is not a
-- gate (a revoked phone still gets the race day, and admit_device still refuses it); and the answer
-- feeds admit_device as the phone calls it.
--
-- Mutation round (2026-10-31, the PR for #71 records it), each predicted before it ran, through
-- psql for per-test lines: P1 a code on two race days answers one (v_n < 1): 1 red, test 12;
-- P2 anon granted execute: 2 red, tests 3 and 5; P3 the uid guard removed: 1 red, test 6; P4 the
-- lookup hashing with md5: the file aborts at test 7, since is() does not catch the raise, which is
-- the kill this file can show for it.

begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

-- Fixed ids so the file needs no client-side variables.
-- clubs:   …c01 Hoover, …c02 Other
-- events:  …e01 Hoover's club night, …e02 the other club's regatta, …e03 the other club's second day
-- courses: …ca01 e01 Alpha, …ca02 e01 Bravo, …cb01 e02 Alpha
-- phones:  …7101 admitted as Bravo's mark boat through the lookup; …7102 revoked, then looks up

-- 1–4. The function, its guard, its grants and its index.
select is(array(select pg_get_function_identity_arguments(oid) from pg_proc
                where pronamespace = 'public'::regnamespace and proname = 'race_day_for_code'),
          array['p_admission_code text'],
          'race_day_for_code has one signature, and it takes the code alone');
select ok((select prosecdef and proconfig = array['search_path=""'] from pg_proc
           where oid = 'public.race_day_for_code(text)'::regprocedure),
          'it is security definer with an empty search_path, since no client can read admission_code');
select ok(has_function_privilege('authenticated', 'public.race_day_for_code(text)', 'EXECUTE')
          and has_function_privilege('service_role', 'public.race_day_for_code(text)', 'EXECUTE')
          and not has_function_privilege('anon', 'public.race_day_for_code(text)', 'EXECUTE'),
          'a signed-in phone and the owner''s tooling may call it; anon may not');
select ok(exists(select 1 from pg_indexes where schemaname = 'public' and tablename = 'admission_code'
                   and indexname = 'admission_code_hash_idx'),
          'the lookup by hash alone has an index');

-- Fixture: two clubs, three events, three race areas (service context: table owner, RLS bypassed).
insert into public.club (id, name) values
  ('00000000-0000-0000-0000-000000000c01', 'Hoover (fixture)'),
  ('00000000-0000-0000-0000-000000000c02', 'Other (fixture)');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Club night', date '2026-09-27',
                           '00000000-0000-0000-0000-000000000e01');
select public.create_event('00000000-0000-0000-0000-000000000c02', 'Their regatta', date '2026-09-27',
                           '00000000-0000-0000-0000-000000000e02');
select public.create_event('00000000-0000-0000-0000-000000000c02', 'Their second day', date '2026-09-28',
                           '00000000-0000-0000-0000-000000000e03');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Alpha', '00000000-0000-0000-0000-00000000ca01');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Bravo', '00000000-0000-0000-0000-00000000ca02');
select public.create_course('00000000-0000-0000-0000-000000000e02', 'Alpha', '00000000-0000-0000-0000-00000000cb01');

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'overall_pro', 'OPRO-E01A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'recorder',    'RECO-ALFA', '00000000-0000-0000-0000-00000000ca01');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'mark_boat',   'MARK-BRAV', '00000000-0000-0000-0000-00000000ca02');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e02', 'recorder',    'RECO-E02A', '00000000-0000-0000-0000-00000000cb01');
-- One code issued to two race days: the owner script draws codes at random per event, so this is
-- the collision it does not refuse.
select public.issue_admission_code('00000000-0000-0000-0000-000000000e02', 'safety',      'BOTH-DAYS');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e03', 'safety',      'BOTH-DAYS');

-- 5. Signed-in callers only: a request with no user is refused before anything is read.
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$select public.race_day_for_code('OPRO-E01A')$$, '42501', null,
                 'anon cannot call it at all');
-- 6. The function's own guard, which the grant makes unreachable for anon, for a token of the
-- authenticated role that names no user. Mutation P3 (the guard removed) reddens this one alone.
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok($$select public.race_day_for_code('OPRO-E01A')$$,
                 '28000', 'race_day_for_code: no signed-in caller',
                 'a signed-in role with no user behind it is refused by the function itself');

-- 7–13. As a signed-in phone.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007101","role":"authenticated","is_anonymous":true}', true);
select is(public.race_day_for_code('OPRO-E01A'), '00000000-0000-0000-0000-000000000e01'::uuid,
          'an event-wide role''s code answers its race day');
select is(public.race_day_for_code('MARK-BRAV'), '00000000-0000-0000-0000-000000000e01'::uuid,
          'a bound role''s code answers its race day, whatever the race area');
select is(public.race_day_for_code('RECO-E02A'), '00000000-0000-0000-0000-000000000e02'::uuid,
          'another club''s code answers that club''s race day');
select throws_ok($$select public.race_day_for_code('XXXX-0000')$$,
                 '28000', 'admit_device: event or admission code not recognised',
                 'an unknown code is refused with admit_device''s own message');
select throws_ok($$select public.race_day_for_code(null)$$,
                 '28000', 'admit_device: event or admission code not recognised',
                 'and so is no code');
select throws_ok($$select public.race_day_for_code('BOTH-DAYS')$$,
                 '28000', 'admit_device: event or admission code not recognised',
                 'a code issued to two race days is refused the same way: the phone cannot choose');
select throws_ok($$select public.race_day_for_code('opro-e01a')$$,
                 '28000', 'admit_device: event or admission code not recognised',
                 'the code is hashed as typed: case counts, as it does for admit_device');

-- 14–16. The answer feeds admit_device as the phone calls it, and the lookup wrote nothing.
select lives_ok($$select public.admit_device(public.race_day_for_code('MARK-BRAV'), 'MARK-BRAV')$$,
                'the phone admits itself with the race day the lookup answered');
reset role;
select is((select d.role || ' ' || c.name from public.committee_device d join public.course c on c.id = d.course_id
           where d.auth_uid = '00000000-0000-0000-0000-000000007101'),
          'mark_boat Bravo',
          'and holds exactly the code''s role and race area');
select is((select count(*) from public.committee_device), 1::bigint,
          'the lookups before it wrote no row');

-- 17–20. Not a gate: a revoked phone still learns the race day, and admit_device still refuses it.
select public.revoke_device((select id from public.committee_device
                             where auth_uid = '00000000-0000-0000-0000-000000007101'));
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007101","role":"authenticated","is_anonymous":true}', true);
select is(public.race_day_for_code('OPRO-E01A'), '00000000-0000-0000-0000-000000000e01'::uuid,
          'a revoked phone still gets the race day from the lookup');
select throws_ok($$select public.admit_device(public.race_day_for_code('OPRO-E01A'), 'OPRO-E01A')$$,
                 '42501', 'admit_device: this device was revoked from the event',
                 'and admit_device refuses it there, as before');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000007102","role":"authenticated","is_anonymous":true}', true);
select is(public.race_day_for_code('RECO-ALFA'), '00000000-0000-0000-0000-000000000e01'::uuid,
          'a phone never admitted gets the race day too: the lookup precedes admission');
reset role;
select is((select count(*) from public.committee_device where auth_uid = '00000000-0000-0000-0000-000000007102'),
          0::bigint, 'and still holds no row');

select * from finish();
rollback;
