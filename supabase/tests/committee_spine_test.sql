-- pgTAP tests for the committee spine (#39). Run with `supabase test db` against the local stack;
-- the whole file is one transaction and rolls back, so it is also safe to run against a live
-- project through a write-capable connection.
--
-- Roles are switched with `set local role` and `request.jwt.claims`, which is exactly what PostgREST
-- does per request, so what is proven here is the database's answer, not the SDK's. The magic-link
-- path (#5) differs from the anonymous path only in the is_anonymous claim, which no policy here
-- reads, so both are exercised as claims rather than as sign-in flows.

begin;
create extension if not exists pgtap with schema extensions;
select plan(31);

-- Fixed ids so the file needs no client-side variables.
-- clubs:   …c01 Hoover, …c02 Other
-- events:  …e01 on Hoover (code gull-1234), …e02 on Other (code tern-5678)
-- courses: …ca01 on e01, …cb01 on e02 (since #58 every fleet names its race area)
-- devices: …aa01 anonymous, …aa02 named volunteer

-- 1–4. RLS is on for every spine table (mutation: `alter table … disable row level security` on
-- any one of them reddens exactly one of these and the visibility tests below it).
select ok((select relrowsecurity from pg_class where oid = 'public.club'::regclass),             'club has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.event'::regclass),            'event has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.fleet'::regclass),            'fleet has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.committee_device'::regclass), 'committee_device has RLS enabled');

-- 5–8. Provisioning creates a club flagged standalone and no user account.
select is((select count(*) from auth.users), 0::bigint, 'no auth users before provisioning');
select lives_ok($$select public.provision_club('Hoover Sailing Club')$$, 'provision_club runs for the service context');
select is((select standalone from public.club where name = 'Hoover Sailing Club'), true, 'provisioned club is flagged standalone');
select is((select count(*) from auth.users), 0::bigint, 'provisioning created no auth user');

-- Fixture: two clubs with fixed ids and one event each (service context: table owner, RLS bypassed).
insert into public.club (id, name) values
  ('00000000-0000-0000-0000-000000000c01', 'Hoover (fixture)'),
  ('00000000-0000-0000-0000-000000000c02', 'Other (fixture)');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Club night', date '2026-09-27', 'gull-1234',
                           '00000000-0000-0000-0000-000000000e01');
select public.create_event('00000000-0000-0000-0000-000000000c02', 'Their regatta', date '2026-09-27', 'tern-5678',
                           '00000000-0000-0000-0000-000000000e02');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Main', '00000000-0000-0000-0000-00000000ca01');
select public.create_course('00000000-0000-0000-0000-000000000e02', 'Main', '00000000-0000-0000-0000-00000000cb01');

-- 9. The hash is not the code.
select isnt((select admission_code_hash from public.event where id = '00000000-0000-0000-0000-000000000e01'),
            'gull-1234', 'admission code is stored hashed');

-- Device A: anonymous sign-in (device-handoff path).
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa01","role":"authenticated","is_anonymous":true}', true);

-- 10–11. Before admission a phone sees nothing.
select is((select count(*) from public.club), 0::bigint, 'an un-admitted phone sees no club');
select is((select count(*) from public.committee_device), 0::bigint, 'an un-admitted phone sees no device row');

-- 12–14. Admission with the right code; wrong code and unknown event are refused alike.
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'mark_boat', 'gull-1234')$$,
                'anonymous device is admitted with the right code');
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e02', 'pro', 'wrong-code')$$,
                 '28000', null, 'wrong admission code is refused');
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-0000000000ff', 'pro', 'gull-1234')$$,
                 '28000', null, 'unknown event is refused with the same message');

-- 15–19. What the admitted phone can see: its own device row, its own club and event, nothing of the other club.
select is((select count(*) from public.committee_device), 1::bigint, 'admitted phone reads exactly its own device row');
select is((select role from public.committee_device), 'mark_boat', 'the row carries the granted role');
select is((select count(*) from public.club), 1::bigint, 'admitted phone sees its own club only');
select is((select count(*) from public.event where id = '00000000-0000-0000-0000-000000000e02'), 0::bigint,
          'the other club''s event is invisible');
select is((select count(*) from public.club where id = '00000000-0000-0000-0000-000000000c02'), 0::bigint,
          'the other club is invisible');

-- 20–21. Withheld columns fail loudly rather than leak.
select throws_ok($$select admission_code_hash from public.event$$, '42501', null,
                 'admission_code_hash is not granted to clients');
select throws_ok($$select auth_uid from public.committee_device$$, '42501', null,
                 'auth_uid is not granted to clients');

-- 22–24. Writes: an admitted phone can add a fleet to its own event, not to another club's; it cannot provision.
select lives_ok($$insert into public.fleet (event_id, course_id, name)
                  values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca01', 'Lasers')$$,
                'admitted phone writes a fleet on its own event');
select throws_ok($$insert into public.fleet (event_id, course_id, name)
                   values ('00000000-0000-0000-0000-000000000e02', '00000000-0000-0000-0000-00000000cb01', 'Sneak')$$,
                 '42501', null, 'fleet write on another club''s event is refused');
select throws_ok($$select public.provision_club('Rogue Club')$$, '42501', null,
                 'a phone cannot provision a club');

-- Device B: named volunteer (magic-link path) on the same event.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa02","role":"authenticated","is_anonymous":false}', true);

-- 25–27. Same tables, same policies, same cross-club refusal.
select lives_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'recorder', 'gull-1234', 'Jo Volunteer')$$,
                'named volunteer is admitted with the right code');
select is((select person from public.committee_device), 'Jo Volunteer', 'named volunteer''s row carries the person');
select is((select count(*) from public.club where id = '00000000-0000-0000-0000-000000000c02'), 0::bigint,
          'named volunteer cannot see the other club either');

-- Revocation of device A by the service context.
reset role;
select public.revoke_device((select id from public.committee_device
                             where auth_uid = '00000000-0000-0000-0000-00000000aa01'));

-- 28–31. A revoked device's next write is refused, its re-admission is refused, and device B is unaffected.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa01","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$insert into public.fleet (event_id, course_id, name)
                   values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca01', 'Optis')$$,
                 '42501', null, 'revoked device''s write is refused');
select throws_ok($$select public.admit_device('00000000-0000-0000-0000-000000000e01', 'mark_boat', 'gull-1234')$$,
                 '42501', null, 'revoked device cannot re-admit itself with the code');
select isnt((select revoked_at from public.committee_device), null, 'revoked device still reads its own row, marked revoked');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa02","role":"authenticated","is_anonymous":false}', true);
select lives_ok($$insert into public.fleet (event_id, course_id, name)
                  values ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-00000000ca01', '420s')$$,
                'the other device on the event still writes');

select * from finish();
rollback;
