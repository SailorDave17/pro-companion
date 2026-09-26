-- pgTAP tests for the club's sign-in paths (#5, groom decisions G39 and G27): the sign-in mode and
-- set_sign_in_mode(), admission holding a new phone to the mode (criterion 3), a device-handoff
-- admission tied to its event, club, role and race area and never to a person (criteria 1 and 8), a
-- replacement phone joining under the same code (criterion 7), and a club's phone denied another
-- club's event on every client path (criterion 5). Run with `supabase test db` against the local
-- stack; the whole file is one transaction and rolls back.
--
-- Roles are switched the way PostgREST switches them, as in committee_spine_test.sql. The two paths
-- differ only in the token's is_anonymous claim: true is the device-handoff path, false a named
-- account's (magic link), and a token with no claim is neither. test/sign_in_path_test.dart holds the
-- same rules against real sign-ins on the stack, and four phones appending at once (criterion 6).
-- Every refusal gets its own phone, as in admission_code_test.sql.

begin;
create extension if not exists pgtap with schema extensions;
select plan(63);

-- Fixed ids so the file needs no client-side variables.
-- clubs:   …c01 Hoover, whose mode is switched; …c02 Other; …c03 Spare, which only the refused
--          switches name, so a mutation letting one through changes no club a later test reads
-- events:  …e01 Hoover's club night, …e02 the other club's regatta
-- courses: …ca01 e01 Alpha, …ca02 e01 Bravo, …cb01 e02 Alpha
-- phones:  …b501, b506–b508, b511, b512, b514, b520 anonymous (device handoff); …b502, b504, b510,
--          b513 named accounts; …b503, b505, b509, b515 tokens that do not say. A phone a later
--          test reads again holds a code no other admitted phone holds, except the two recorders
--          on Alpha that criterion 7 is about.
-- log:     01J8…0511 to 01J8…0621, one event each, named in fx below

-- 1–8. The mode, its switch and the admission function.
select has_column('public', 'club', 'sign_in_mode', 'a club has a sign-in mode');
select col_not_null('public', 'club', 'sign_in_mode', 'every club has one');
select col_default_is('public', 'club', 'sign_in_mode', 'both', 'and a club starts at both');
select is((select array_agg(m[1] order by m[1])
           from regexp_matches((select pg_get_constraintdef(oid) from pg_constraint
                                where conname = 'club_sign_in_mode_check'), '''([a-z_]+)''', 'g') as m),
          array['both', 'device_handoff', 'named_volunteers'],
          'the mode is exactly device_handoff, named_volunteers or both (G39)');
select ok(has_function_privilege('service_role', 'public.set_sign_in_mode(uuid, text)', 'execute')
          and not has_function_privilege('authenticated', 'public.set_sign_in_mode(uuid, text)', 'execute')
          and not has_function_privilege('anon', 'public.set_sign_in_mode(uuid, text)', 'execute'),
          'only service_role can switch a mode: the owner script (G27)');
select is(array(select p.oid::regprocedure::text from pg_proc p
                where p.oid in ('public.set_sign_in_mode(uuid, text)'::regprocedure,
                                'public.admit_device(uuid, text, text)'::regprocedure)
                  and not (p.prosecdef and p.proconfig = array['search_path=""'])),
          array[]::text[],
          'set_sign_in_mode and admit_device are security definer with an empty search_path');
select ok(has_function_privilege('authenticated', 'public.admit_device(uuid, text, text)', 'execute')
          and not has_function_privilege('anon', 'public.admit_device(uuid, text, text)', 'execute')
          and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
                                              and proname = 'admit_device') = 1,
          'admit_device keeps its one signature and #65''s grants');
select ok(has_column_privilege('authenticated', 'public.club', 'sign_in_mode', 'SELECT'),
          'a club''s admitted phones can read its mode, like every other column of club');

-- Fixture: two clubs, two events, three race areas, a fleet on each event (table owner, RLS
-- bypassed).
insert into public.club (id, name) values
  ('00000000-0000-0000-0000-000000000c01', 'Hoover (fixture)'),
  ('00000000-0000-0000-0000-000000000c02', 'Other (fixture)'),
  ('00000000-0000-0000-0000-000000000c03', 'Spare (fixture)');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Club night', date '2026-09-27',
                           '00000000-0000-0000-0000-000000000e01');
select public.create_event('00000000-0000-0000-0000-000000000c02', 'Their regatta', date '2026-09-27',
                           '00000000-0000-0000-0000-000000000e02');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Alpha', '00000000-0000-0000-0000-00000000ca01');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Bravo', '00000000-0000-0000-0000-00000000ca02');
select public.create_course('00000000-0000-0000-0000-000000000e02', 'Alpha', '00000000-0000-0000-0000-00000000cb01');
insert into public.fleet (event_id, course_id, name) values
  ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca01', 'Lasers'),
  ('00000000-0000-0000-0000-000000000e02', '00000000-0000-0000-0000-00000000cb01', 'Their fleet');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'overall_pro', 'OPRO-E01A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'scorer',      'SCOR-E01A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'safety',      'SAFE-E01A');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'course_pro',  'CPRO-ALFA', '00000000-0000-0000-0000-00000000ca01');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'recorder',    'RECO-ALFA', '00000000-0000-0000-0000-00000000ca01');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'course_pro',  'CPRO-BRAV', '00000000-0000-0000-0000-00000000ca02');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'recorder',    'RECO-BRAV', '00000000-0000-0000-0000-00000000ca02');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'mark_boat',   'MARK-BRAV', '00000000-0000-0000-0000-00000000ca02');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e02', 'scorer',      'SCOR-E02A');

-- One valid event per append below, keys in RFC 8785 order, each from its phone's own device.
create temp table fx (name text primary key, canonical text not null);
insert into fx (name, canonical)
select name, format('{"corrects_ulid":null,"device_id":"%s","device_ts":%s,"gps":null,"kind":"note",'
                    '"payload":{},"payload_version":1,"person":null,"prev_hash":null,"role":null,'
                    '"seq":%s,"source":"tap","ulid":"%s"}', device, 1727190000000 + seq, seq, ulid)
from (values
  ('b501-1',     '01J8Z0D0000000000000000501', 1, '01J80000000000000000000511'),
  ('b501-club-b', '01J8Z0D0000000000000000501', 2, '01J80000000000000000000512'),
  ('b502-1',     '01J8Z0D0000000000000000502', 1, '01J80000000000000000000521'),
  ('b506-1',     '01J8Z0D0000000000000000506', 1, '01J80000000000000000000561'),
  ('b508-1',     '01J8Z0D0000000000000000508', 1, '01J80000000000000000000581'),
  ('b508-2',     '01J8Z0D0000000000000000508', 2, '01J80000000000000000000582'),
  ('b512-1',     '01J8Z0D0000000000000000512', 1, '01J80000000000000000000591'),
  ('b520-1',     '01J8Z0D0000000000000000520', 1, '01J80000000000000000000620'),
  ('b520-club-a', '01J8Z0D0000000000000000520', 2, '01J80000000000000000000621')
) v(name, device, seq, ulid);
grant select on fx to authenticated;

-- A refusal's DETAIL, which throws_ok cannot see. Returns 'no refusal' when the call succeeds.
create function pg_temp.refusal_detail(p_call text) returns text
language plpgsql as $$
declare
  v_detail text;
begin
  execute p_call;
  return 'no refusal';
exception when others then
  get stacked diagnostics v_detail = pg_exception_detail;
  return v_detail;
end;
$$;
grant execute on function pg_temp.refusal_detail(text) to authenticated;

-- A call's answer as text, or its refusal. A test comparing an answer calls through this, so a
-- mutation that makes the call raise fails that test and not the whole transaction after it.
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

-- 9–13. Criterion 3: a club starts at both, and only the owner's tooling switches it.
select is((select sign_in_mode from public.club where id = '00000000-0000-0000-0000-000000000c01'), 'both',
          'a club made with no mode is at both, as admission behaved before #5');
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b501","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.set_sign_in_mode('00000000-0000-0000-0000-000000000c03', 'device_handoff')$$,
                 '42501', null, 'a phone cannot switch a club''s mode');
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$select public.set_sign_in_mode('00000000-0000-0000-0000-000000000c03', 'device_handoff')$$,
                 '42501', null, 'anon cannot switch it');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select throws_ok($$select public.set_sign_in_mode('00000000-0000-0000-0000-0000000000ff', 'both')$$,
                 'P0002', 'set_sign_in_mode: no such club', 'switching a club that does not exist is refused');
select throws_ok($$select public.set_sign_in_mode('00000000-0000-0000-0000-000000000c03', 'anyone')$$,
                 '23514', 'new row for relation "club" violates check constraint "club_sign_in_mode_check"',
                 'a mode that is not one of the three is refused');

-- 14–16. Criterion 3, at both: every path admits, a token that does not say included.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b501","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'SCOR-E01A')$$,
                'at both, an anonymous sign-in is admitted');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b502","role":"authenticated","is_anonymous":false}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'OPRO-E01A')$$,
                'at both, a named account is admitted');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b503","role":"authenticated"}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'RECO-ALFA')$$,
                'at both, a token that does not say is admitted, as before #5');

-- 17–23. Criterion 3, at device_handoff: only an anonymous sign-in is admitted new, and the phones
-- already admitted are unaffected.
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is(public.set_sign_in_mode('00000000-0000-0000-0000-000000000c01', 'device_handoff'), 'both',
          'the switch answers with the mode it replaced');
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b504","role":"authenticated","is_anonymous":false}', true);
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'MARK-BRAV')$$,
                 '42501', 'admit_device: the club''s sign-in mode does not admit this sign-in',
                 'at device_handoff, a named account is refused');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b513","role":"authenticated","is_anonymous":false}', true);
select is(pg_temp.refusal_detail($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'MARK-BRAV')$$),
          'sign_in_mode=device_handoff path=named_volunteers',
          'and the refusal names the mode and the path, so a phone can say which way to sign in');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b505","role":"authenticated"}', true);
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'CPRO-ALFA')$$,
                 '42501', 'admit_device: the club''s sign-in mode does not admit this sign-in',
                 'a token that does not say is neither path, so a single-path mode refuses it');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b506","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'RECO-BRAV')$$,
                'at device_handoff, an anonymous sign-in is admitted');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b502","role":"authenticated","is_anonymous":false}', true);
select is(pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'OPRO-E01A')$$),
          (select id::text from public.committee_device),
          'a named account admitted at both gets its own admission back at device_handoff');
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'b502-1')) ->> 'outcome',
          'accepted', 'and its events are still accepted');

-- 24–32. Criterion 3, at named_volunteers: the mirror image, and a phone refused before is admitted
-- once its path is named, with no new sign-in.
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is(public.set_sign_in_mode('00000000-0000-0000-0000-000000000c01', 'named_volunteers'), 'device_handoff',
          'switching again answers with device_handoff');
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b507","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'CPRO-ALFA')$$,
                 '42501', 'admit_device: the club''s sign-in mode does not admit this sign-in',
                 'at named_volunteers, an anonymous sign-in is refused');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b514","role":"authenticated","is_anonymous":true}', true);
select is(pg_temp.refusal_detail($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'CPRO-ALFA')$$),
          'sign_in_mode=named_volunteers path=device_handoff',
          'and its refusal names that mode and path');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b515","role":"authenticated"}', true);
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'CPRO-ALFA')$$,
                 '42501', 'admit_device: the club''s sign-in mode does not admit this sign-in',
                 'a token that does not say is refused at named_volunteers too');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b504","role":"authenticated","is_anonymous":false}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'MARK-BRAV')$$,
                'the named account refused at device_handoff is admitted now, with the same code');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b501","role":"authenticated","is_anonymous":true}', true);
select is(pg_temp.answer($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'SCOR-E01A')$$),
          (select id::text from public.committee_device),
          'an anonymous phone admitted at both gets its own admission back at named_volunteers');
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'b501-1')) ->> 'outcome',
          'accepted', 'and its events are still accepted');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b506","role":"authenticated","is_anonymous":true}', true);
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'b506-1')) ->> 'outcome',
          'accepted', 'so are those of an anonymous phone admitted at device_handoff');
select lives_ok($$insert into public.fleet (event_id, course_id, name)
                  values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca02', 'Toppers')$$,
                'and it still adds a fleet on its race area: no policy reads the mode');

-- 33. No refused presentation created a row.
reset role;
select is(array(select right(auth_uid::text, 4) from public.committee_device
                where event_id = '00000000-0000-0000-0000-000000000e01'
                  and auth_uid in ('00000000-0000-0000-0000-00000000b504', '00000000-0000-0000-0000-00000000b505',
                                   '00000000-0000-0000-0000-00000000b507', '00000000-0000-0000-0000-00000000b513',
                                   '00000000-0000-0000-0000-00000000b514', '00000000-0000-0000-0000-00000000b515')),
          array['b504'],
          'of the refused phones, only the one admitted after the switch holds an admission');

-- 34–35. Back to both, and the anonymous phone refused at named_volunteers is admitted.
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is(public.set_sign_in_mode('00000000-0000-0000-0000-000000000c01', 'both'), 'named_volunteers',
          'switching back answers with named_volunteers');
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b507","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'CPRO-ALFA')$$,
                'at both again, the anonymous phone refused before is admitted');

-- 36–44. Criteria 1 and 8: only a named volunteer's admission names a person. A device-handoff
-- admission is tied to its event, club, role and race area.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b508","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.admit_device(p_event => '00000000-0000-0000-0000-000000000e01',
                                              p_admission_code => 'RECO-ALFA', p_person => 'Pat (fixture)')$$,
                 '22023', 'admit_device: only a named volunteer''s admission names a person',
                 'a device-handoff phone naming a person is refused, not recorded as a guess');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b509","role":"authenticated"}', true);
select throws_ok($$select public.admit_device(p_event => '00000000-0000-0000-0000-000000000e01',
                                              p_admission_code => 'RECO-ALFA', p_person => 'Pat (fixture)')$$,
                 '22023', 'admit_device: only a named volunteer''s admission names a person',
                 'so is a token that does not say it is a named account');
reset role;
select is((select count(*) from public.committee_device
           where auth_uid in ('00000000-0000-0000-0000-00000000b508', '00000000-0000-0000-0000-00000000b509')),
          0::bigint, 'neither refusal created a row');
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b508","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'RECO-ALFA')$$,
                'the same phone naming no one is admitted');
select is((select jsonb_build_object('event', event_id, 'club', club_id, 'role', role, 'race area', course_id,
                                     'person', person)
           from public.committee_device),
          jsonb_build_object('event', '00000000-0000-0000-0000-000000000e01', 'club', '00000000-0000-0000-0000-000000000c01',
                             'role', 'recorder', 'race area', '00000000-0000-0000-0000-00000000ca01', 'person', null),
          'its admission is the event, club, role and race area of its code, and no person');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b511","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'SAFE-E01A', '   ')$$,
                'a blank person is not a person');
select is((select person from public.committee_device), null, 'and is recorded as none');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b510","role":"authenticated","is_anonymous":false}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'CPRO-BRAV', 'Jo Volunteer')$$,
                'a named account names a person');
select is((select person from public.committee_device), 'Jo Volunteer', 'and it is on its admission');

-- 45–50. Criterion 7: a replacement phone presents the same code mid-race, and joins without the
-- original being revoked. Both append to the event.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b508","role":"authenticated","is_anonymous":true}', true);
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'b508-1')) ->> 'outcome',
          'accepted', 'the original recorder on Alpha logs an event');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b512","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'RECO-ALFA')$$,
                'a replacement phone presents the same recorder code');
reset role;
select is(array(select right(d.auth_uid::text, 4) || ' ' || d.role || ' ' || c.name || ' '
                       || case when d.revoked_at is null then 'active' else 'revoked' end
                from public.committee_device d join public.course c on c.id = d.course_id
                where d.auth_uid in ('00000000-0000-0000-0000-00000000b508', '00000000-0000-0000-0000-00000000b512')
                order by d.auth_uid),
          array['b508 recorder Alpha active', 'b512 recorder Alpha active'],
          'each holds its own active admission as recorder on Alpha');
set local role authenticated;
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'b512-1')) ->> 'outcome',
          'accepted', 'the replacement appends to the same event');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b508","role":"authenticated","is_anonymous":true}', true);
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'b508-2')) ->> 'outcome',
          'accepted', 'and the original, not revoked, goes on appending');
reset role;
select is(array(select right(device_id, 3) || ' seq ' || seq from public.event_log
                where event_id = '00000000-0000-0000-0000-000000000e01'
                  and ulid in ('01J80000000000000000000581', '01J80000000000000000000582', '01J80000000000000000000591')
                order by device_id, seq),
          array['508 seq 1', '508 seq 2', '512 seq 1'],
          'the log holds both phones'' events on the one event');

-- 51–63. Criterion 5: a device-handoff phone of club A is denied club B's event on every client
-- path, and a phone of club B is denied club A's. b501 is club A's scorer; b520 is club B's.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b520","role":"authenticated","is_anonymous":true}', true);
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e02', 'SCOR-E02A')$$,
                'club B''s phone is admitted to its own regatta');
select is(public.append_event('00000000-0000-0000-0000-000000000e02', (select canonical from fx where name = 'b520-1')) ->> 'outcome',
          'accepted', 'and its regatta takes its events: the denials below are about the club');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b501","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e02', 'SCOR-E01A')$$,
                 '28000', 'admit_device: event or admission code not recognised',
                 'club A''s code does not admit its phone to club B''s event');
select is((select r ->> 'outcome' || ' ' || (r ->> 'reason')
           from (select public.append_event('00000000-0000-0000-0000-000000000e02',
                                            (select canonical from fx where name = 'b501-club-b')) as r) s),
          'refused not_admitted', 'club A''s phone appending to club B''s event is refused as not admitted');
select throws_ok($$insert into public.fleet (event_id, course_id, name)
                   values ('00000000-0000-0000-0000-000000000e02', '00000000-0000-0000-0000-00000000cb01', 'Sneak')$$,
                 '42501', 'new row violates row-level security policy for table "fleet"',
                 'it cannot add a fleet to club B''s event');
select is(array(select name from public.club
                where id in ('00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-000000000c02')),
          array['Hoover (fixture)'], 'it reads its own club and not club B');
select is(array(select name from public.event
                where id in ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000e02')),
          array['Club night'], 'its own event and not club B''s');
select is(array(select distinct event_id::text from public.course
                where event_id in ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000e02')),
          array['00000000-0000-0000-0000-000000000e01'], 'its own event''s race areas and not club B''s');
select is(array(select distinct event_id::text from public.fleet
                where event_id in ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000e02')),
          array['00000000-0000-0000-0000-000000000e01'], 'its own event''s fleets and not club B''s');
select is(array[public.is_admitted_to_club('00000000-0000-0000-0000-000000000c01'),
                public.is_admitted_to_club('00000000-0000-0000-0000-000000000c02'),
                public.is_admitted_to_event('00000000-0000-0000-0000-000000000e01'),
                public.is_admitted_to_event('00000000-0000-0000-0000-000000000e02'),
                public.is_admitted_to_race_area('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca01'),
                public.is_admitted_to_race_area('00000000-0000-0000-0000-000000000e02', '00000000-0000-0000-0000-00000000cb01')],
          array[true, false, true, false, true, false],
          'every admission helper the policies use answers yes for club A and no for club B');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000b520","role":"authenticated","is_anonymous":true}', true);
select is((select r ->> 'outcome' || ' ' || (r ->> 'reason')
           from (select public.append_event('00000000-0000-0000-0000-000000000e01',
                                            (select canonical from fx where name = 'b520-club-a')) as r) s),
          'refused not_admitted', 'club B''s phone appending to club A''s event is refused the same way');
reset role;
select is((select count(*) from public.event_log
           where ulid in ('01J80000000000000000000512', '01J80000000000000000000621')),
          0::bigint, 'neither cross-club event reached a log');
select is((select count(*) from public.event_refusal
           where event_id in ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000e02')
             and auth_uid in ('00000000-0000-0000-0000-00000000b501', '00000000-0000-0000-0000-00000000b520')),
          0::bigint, 'and neither is kept as a refusal, since neither phone holds a row in the other club (G43)');

select * from finish();
rollback;
