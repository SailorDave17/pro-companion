-- pgTAP tests for the shore verifier (#62): each device's chain on a race day, read through
-- chain_verification and chain_attribution, after its events reached the log through #48's
-- append_event as its admitted phone. Run with `supabase test db` against the local stack; the whole
-- file is one transaction and rolls back.
--
-- Criterion 1's vectors are chain_verification_vectors_test.sql's (generated). Here the chains are a
-- phone's own, appended through the real write path, so a refusal is the server's own (criterion 2),
-- a re-admission is a real one (criterion 3), and a gap fills by a late upload (criterion 5).
-- Criterion 4 is who may read the result. Roles are switched the way PostgREST switches them; every
-- read goes through a pg_temp function that answers what the caller saw, or its refusal, so a
-- mutation that makes a read raise fails its own test and does not abort the file.
--
-- Owner decisions at pickup (2026-11-15), which these tests hold: the verdict counts from seq 1; a
-- device reports the lowest number held and how many are missing above it; its status is its worst
-- of broken, gapped, refused, intact; every refused number is listed.

begin;
create extension if not exists pgtap with schema extensions;
select plan(27);

-- Fixed ids so the file needs no client-side variables.
-- clubs:      …c01 Hoover, …c02 Other
-- events:     …e01 Hoover's club night, …e03 Hoover's second day, …e02 the other club's regatta
-- courses:    …ca01 e01 Alpha, …ca02 e01 Bravo
-- phones (…b0NN the Auth user, …ad0N its admission):
--   b001: ad01 scorer e01; device …0901 (criterion 2: a refusal at seq 3)
--   b002: ad02 recorder Alpha e01, superseded by ad03 mark_boat Bravo; device …0902 (criterion 3)
--   b004: ad04 safety e01; devices …0904 (criterion 5: a gap filled) and …0905 (a broken chain)
--   b005: ad05 scorer e03; b006: ad06 scorer e02 (the other club); b007: ad07 scorer e01, revoked;
--   b008: never admitted

-- 1–4. The layers, held from the catalog: the verdict and the caller check are callable by no client
-- role, the two readers by phones and service_role and never by anon, and both readers are security
-- definer with an empty search path.
select ok(not has_function_privilege('anon', 'public.chain_verdict(uuid, text)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'public.chain_verdict(uuid, text)', 'EXECUTE')
          and not has_function_privilege('service_role', 'public.chain_verdict(uuid, text)', 'EXECUTE'),
          'no client role may call chain_verdict directly');
select ok(not has_function_privilege('anon', 'public.chain_reader_check(uuid)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'public.chain_reader_check(uuid)', 'EXECUTE')
          and not has_function_privilege('service_role', 'public.chain_reader_check(uuid)', 'EXECUTE'),
          'no client role may call chain_reader_check directly');
select is(array(select r || ' ' || f from unnest(array['anon', 'authenticated', 'service_role']) r,
                       unnest(array['public.chain_verification(uuid)', 'public.chain_attribution(uuid)']) f
                where has_function_privilege(r, f, 'EXECUTE') order by 1),
          array['authenticated public.chain_attribution(uuid)', 'authenticated public.chain_verification(uuid)',
                'service_role public.chain_attribution(uuid)', 'service_role public.chain_verification(uuid)'],
          'phones and service_role may call both readers, and anon neither');
select is(array(select p.proname::text || ' ' || p.prosecdef::text || ' ' || coalesce(array_to_string(p.proconfig, ','), '')
                from pg_proc p
                where p.pronamespace = 'public'::regnamespace
                  and p.proname in ('chain_verification', 'chain_attribution', 'chain_reader_check')
                order by p.proname),
          array['chain_attribution true search_path=""', 'chain_reader_check true search_path=""',
                'chain_verification true search_path=""'],
          'the readers and the caller check are security definer with an empty search path');

-- Fixture (table owner, RLS bypassed).
insert into public.club (id, name) values
  ('00000000-0000-0000-0000-000000000c01', 'Hoover (fixture)'),
  ('00000000-0000-0000-0000-000000000c02', 'Other (fixture)');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Club night', date '2026-11-15',
                           '00000000-0000-0000-0000-000000000e01');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Second day', date '2026-11-16',
                           '00000000-0000-0000-0000-000000000e03');
select public.create_event('00000000-0000-0000-0000-000000000c02', 'Their regatta', date '2026-11-15',
                           '00000000-0000-0000-0000-000000000e02');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Alpha', '00000000-0000-0000-0000-00000000ca01');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Bravo', '00000000-0000-0000-0000-00000000ca02');
insert into public.committee_device (id, event_id, club_id, course_id, auth_uid, role, superseded_by, superseded_at, revoked_at) values
  ('00000000-0000-0000-0000-00000000ad01', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b001', 'scorer', null, null, null),
  ('00000000-0000-0000-0000-00000000ad02', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-00000000ca01',
   '00000000-0000-0000-0000-00000000b002', 'recorder', '00000000-0000-0000-0000-00000000ad03', now(), null),
  ('00000000-0000-0000-0000-00000000ad03', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-00000000ca02',
   '00000000-0000-0000-0000-00000000b002', 'mark_boat', null, null, null),
  ('00000000-0000-0000-0000-00000000ad04', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b004', 'safety', null, null, null),
  ('00000000-0000-0000-0000-00000000ad05', '00000000-0000-0000-0000-000000000e03', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b005', 'scorer', null, null, null),
  ('00000000-0000-0000-0000-00000000ad06', '00000000-0000-0000-0000-000000000e02', '00000000-0000-0000-0000-000000000c02', null,
   '00000000-0000-0000-0000-00000000b006', 'scorer', null, null, null),
  ('00000000-0000-0000-0000-00000000ad07', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b007', 'scorer', null, null, now());

-- The texts: event k is device p_device's seq p_seq, keys in RFC 8785 order, linked to event p_prev's
-- hash (genesis when null) unless p_prev_hash names another.
create temp table t (k int primary key, txt text not null);
grant select on t to authenticated, service_role;
create function pg_temp.add(p_k int, p_adm text, p_role text, p_device text, p_seq int, p_kind text,
                            p_payload text, p_prev int, p_source text default 'tap', p_prev_hash text default null)
returns void language plpgsql as $$
declare
  v_prev text := coalesce(p_prev_hash,
                          case when p_prev is null then repeat('0', 64)
                               else (select encode(sha256(convert_to(t.txt, 'UTF8')), 'hex') from t where t.k = p_prev) end);
begin
  insert into t values (p_k, format(
    '{"admission_id":"00000000-0000-0000-0000-00000000%s","corrects_ulid":null,"device_id":"01J8Z0D000000000000000%s",'
    '"device_ts":%s,"gps":null,"kind":"%s","payload":%s,"payload_version":1,"person":null,"prev_hash":"%s",'
    '"role":"%s","seq":%s,"source":"%s","ulid":"01J8%s"}',
    p_adm, p_device, 1731600000000 + p_k * 1000, p_kind, p_payload, v_prev, p_role, p_seq, p_source,
    lpad(p_k::text, 22, '0')));
end;
$$;
create function pg_temp.txt(p_k int) returns text language sql stable as $$ select t.txt from t where t.k = p_k $$;
grant execute on function pg_temp.txt(int) to authenticated;
create function pg_temp.ulid(p_k int) returns text language sql immutable as $$ select '01J8' || lpad(p_k::text, 22, '0') $$;
grant execute on function pg_temp.ulid(int) to authenticated, service_role;

-- b001's scorer phone, device …0901: three notes, a start (not the scorer's to write, #75), then
-- three more notes linking on from it.
select pg_temp.add(11, 'ad01', 'scorer', '0901', 1, 'note', '{"text":"one"}', null);
select pg_temp.add(12, 'ad01', 'scorer', '0901', 2, 'note', '{"text":"two"}', 11);
select pg_temp.add(13, 'ad01', 'scorer', '0901', 3, 'start', '{"fleet":null}', 12);
select pg_temp.add(14, 'ad01', 'scorer', '0901', 4, 'note', '{"text":"four"}', 13);
select pg_temp.add(15, 'ad01', 'scorer', '0901', 5, 'note', '{"text":"five"}', 14);
select pg_temp.add(16, 'ad01', 'scorer', '0901', 6, 'note', '{"text":"six"}', 15);
-- b002, device …0902: two notes as the Alpha recorder, the role-change marker, then two as the Bravo
-- mark boat.
select pg_temp.add(21, 'ad02', 'recorder', '0902', 1, 'note', '{"text":"recorder one"}', null);
select pg_temp.add(22, 'ad02', 'recorder', '0902', 2, 'note', '{"text":"recorder two"}', 21);
select pg_temp.add(23, 'ad02', 'recorder', '0902', 3, 'admission.superseded',
                   '{"superseded_by":"00000000-0000-0000-0000-00000000ad03"}', 22, 'core');
select pg_temp.add(24, 'ad03', 'mark_boat', '0902', 4, 'note', '{"text":"mark boat four"}', 23);
select pg_temp.add(25, 'ad03', 'mark_boat', '0902', 5, 'note', '{"text":"mark boat five"}', 24);
-- b004, device …0904: four notes, a far mark's day. Device …0905: seq 2's link is not seq 1's hash.
select pg_temp.add(41, 'ad04', 'safety', '0904', 1, 'note', '{"text":"far one"}', null);
select pg_temp.add(42, 'ad04', 'safety', '0904', 2, 'note', '{"text":"far two"}', 41);
select pg_temp.add(43, 'ad04', 'safety', '0904', 3, 'note', '{"text":"far three"}', 42);
select pg_temp.add(44, 'ad04', 'safety', '0904', 4, 'note', '{"text":"far four"}', 43);
select pg_temp.add(51, 'ad04', 'safety', '0905', 1, 'note', '{"text":"spare one"}', null);
select pg_temp.add(52, 'ad04', 'safety', '0905', 2, 'note', '{"text":"spare two"}', 51, 'tap', repeat('f', 64));

-- append_event's answer, or its error as an answer.
create function pg_temp.try_append(p_k int) returns text
language plpgsql as $$
declare
  v jsonb;
begin
  v := public.append_event('00000000-0000-0000-0000-000000000e01', pg_temp.txt(p_k));
  return (v ->> 'outcome') || coalesce(' ' || (v ->> 'reason'), '');
exception when others then
  return 'error ' || sqlstate || ': ' || sqlerrm;
end;
$$;
grant execute on function pg_temp.try_append(int) to authenticated;

-- What the calling role reads of a race day's chains: one line per device, its last four digits, then
-- status/verdict, the break point, lowest..highest, missing and the refused numbers; or the refusal.
create function pg_temp.chains(p_event text) returns text
language plpgsql as $$
declare
  v text;
begin
  select coalesce(string_agg(right(c.device_id, 4) || ' ' || c.status || '/' || c.verdict
                             || coalesce(' at ' || c.at_seq || ' ' || right(c.at_ulid, 2), '')
                             || coalesce(' after ' || c.after_seq, '')
                             || ' ' || c.lowest_seq || '..' || c.highest_seq
                             || ' missing ' || c.missing || ' refused ' || c.refused_seqs::text,
                             '; ' order by c.device_id), 'none')
    into v
  from public.chain_verification(p_event::uuid) c;
  return v;
exception when others then
  return 'refused ' || sqlstate || ': ' || sqlerrm;
end;
$$;
grant execute on function pg_temp.chains(text) to authenticated, anon, service_role;

-- What the calling role reads of one device's attribution: seq:role@race area, by seq; or the refusal.
create function pg_temp.attributed(p_event text, p_device text) returns text
language plpgsql as $$
declare
  v text;
begin
  select coalesce(string_agg(a.seq || ':' || coalesce(a.role, '?') || '@'
                             || coalesce(right(a.course_id::text, 4), 'event') || ' ' || right(a.admission_id::text, 4),
                             ', ' order by a.seq), 'none')
    into v
  from public.chain_attribution(p_event::uuid) a
  where a.device_id = '01J8Z0D000000000000000' || p_device;
  return v;
exception when others then
  return 'refused ' || sqlstate || ': ' || sqlerrm;
end;
$$;
grant execute on function pg_temp.attributed(text, text) to authenticated, anon, service_role;

-- Signs a phone in, the way PostgREST sets the claims for its token.
create function pg_temp.as_phone(p_uid text) returns void
language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-00000000' || p_uid, 'role', 'authenticated',
                      'is_anonymous', true)::text, true);
$$;
grant execute on function pg_temp.as_phone(text) to authenticated;

-- 5–7. Criterion 2: b001 uploads seq 1 to 6. The server refuses seq 3 and keeps its stub, and the
-- verifier reads the stub in its place: refused at 3, verified past it, neither gapped nor broken.
set local role authenticated;
select pg_temp.as_phone('b001');
select is(array[pg_temp.try_append(11), pg_temp.try_append(12), pg_temp.try_append(13),
                pg_temp.try_append(14), pg_temp.try_append(15), pg_temp.try_append(16)],
          array['accepted', 'accepted', 'refused kind_not_permitted', 'accepted', 'accepted', 'accepted'],
          'append_event takes seq 1, 2 and 4 to 6, and refuses seq 3, a start the scorer may not write');
select is(pg_temp.chains('00000000-0000-0000-0000-000000000e01'),
          '0901 refused/intact 1..6 missing 0 refused {3}',
          'the scorer''s own chain reads refused at 3, intact past it: the stub fills its number');
reset role;
select is((select count(*) from public.event_log where device_id = '01J8Z0D0000000000000000901'), 5::bigint,
          'control: the log holds five of the six, so seq 3 is filled by its stub alone');

-- 8–11. Criterion 3: b002 logs as the Alpha recorder, then (re-admitted as the Bravo mark boat, the
-- row already superseded) the marker and two more. One chain across both admissions, each event
-- attributed to the admission it was written under.
set local role authenticated;
select pg_temp.as_phone('b002');
select is(array[pg_temp.try_append(21), pg_temp.try_append(22), pg_temp.try_append(23),
                pg_temp.try_append(24), pg_temp.try_append(25)],
          array['accepted', 'accepted', 'accepted', 'accepted', 'accepted'],
          'append_event takes all five, the first three under the recorder''s admission');
select is(split_part(pg_temp.chains('00000000-0000-0000-0000-000000000e01'), '; ', 2),
          '0902 intact/intact 1..5 missing 0 refused {}',
          'the chain runs on across the change of admission: intact from 1 to 5');
select is(pg_temp.attributed('00000000-0000-0000-0000-000000000e01', '0902'),
          '1:recorder@ca01 ad02, 2:recorder@ca01 ad02, 3:recorder@ca01 ad02, 4:mark_boat@ca02 ad03, 5:mark_boat@ca02 ad03',
          'seq 1 to 3 are the Alpha recorder''s, and 4 and 5 the Bravo mark boat''s');
reset role;
select is((select count(distinct admission_id) from public.event_log where device_id = '01J8Z0D0000000000000000902'),
          2::bigint, 'control: the device''s events name two admissions');

-- 12–15. Criterion 5: b004's far mark uploads seq 1, 2 and 4, then catches up with seq 3. Gapped,
-- one missing, then intact on the rerun. A second device of b004's links seq 2 to the wrong hash.
set local role authenticated;
select pg_temp.as_phone('b004');
select is(array[pg_temp.try_append(41), pg_temp.try_append(42), pg_temp.try_append(44),
                pg_temp.try_append(51), pg_temp.try_append(52)],
          array['accepted', 'accepted', 'accepted', 'accepted', 'accepted'],
          'append_event takes the far mark''s seq 1, 2 and 4, and both of the spare''s');
select is(split_part(pg_temp.chains('00000000-0000-0000-0000-000000000e01'), '; ', 3),
          '0904 gapped/gapped 1..4 missing 1 refused {}',
          'with seq 3 not yet on shore the far mark''s chain reads gapped, one missing, and not broken');
select is(pg_temp.try_append(43), 'accepted', 'the far mark''s seq 3 arrives late');
select is(split_part(pg_temp.chains('00000000-0000-0000-0000-000000000e01'), '; ', 3),
          '0904 intact/intact 1..4 missing 0 refused {}',
          'run again, the far mark''s chain reads intact: the gap was filled');

-- 16–17. Criterion 4: a phone admitted to the race day reads every device's status, with the first
-- bad event of a broken one, and the attribution.
select is(pg_temp.chains('00000000-0000-0000-0000-000000000e01'),
          '0901 refused/intact 1..6 missing 0 refused {3}; 0902 intact/intact 1..5 missing 0 refused {}; '
          '0904 intact/intact 1..4 missing 0 refused {}; 0905 broken/broken at 2 52 after 1 1..2 missing 0 refused {}',
          'an admitted phone reads every device''s status, and the broken one''s first bad event, seq 2 after seq 1');
select is(pg_temp.attributed('00000000-0000-0000-0000-000000000e01', '0901'),
          '1:scorer@event ad01, 2:scorer@event ad01, 4:scorer@event ad01, 5:scorer@event ad01, 6:scorer@event ad01',
          'and every event''s admission: the scorer''s, event-wide');

-- 18–23. Criterion 4: nobody else reads it. A phone of the club's other race day, a phone of another
-- club, a revoked phone and a phone never admitted are refused; so is the anon key.
select pg_temp.as_phone('b005');
select is(pg_temp.chains('00000000-0000-0000-0000-000000000e01'),
          'refused 42501: chain verification: the caller is not admitted to this race day',
          'a phone admitted to the club''s other race day is refused');
select pg_temp.as_phone('b006');
select is(pg_temp.chains('00000000-0000-0000-0000-000000000e01'),
          'refused 42501: chain verification: the caller is not admitted to this race day',
          'a phone of another club is refused');
select is(pg_temp.attributed('00000000-0000-0000-0000-000000000e01', '0901'),
          'refused 42501: chain verification: the caller is not admitted to this race day',
          'and refused the attribution too');
select pg_temp.as_phone('b007');
select is(pg_temp.chains('00000000-0000-0000-0000-000000000e01'),
          'refused 42501: chain verification: the caller is not admitted to this race day',
          'a revoked phone is refused');
select pg_temp.as_phone('b008');
select is(pg_temp.chains('00000000-0000-0000-0000-000000000e01'),
          'refused 42501: chain verification: the caller is not admitted to this race day',
          'a phone never admitted is refused');
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select is(pg_temp.chains('00000000-0000-0000-0000-000000000e01'),
          'refused 42501: permission denied for function chain_verification',
          'the anon key alone is refused');

-- 24–25. The owner's tooling reads it as service_role; and each phone of the other club reads its own
-- race day, which here holds nothing.
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is(split_part(pg_temp.chains('00000000-0000-0000-0000-000000000e01'), '; ', 1),
          '0901 refused/intact 1..6 missing 0 refused {3}', 'service_role reads the race day''s chains');
set local role authenticated;
select pg_temp.as_phone('b006');
select is(pg_temp.chains('00000000-0000-0000-0000-000000000e02'), 'none',
          'the other club''s phone reads its own race day, where no device has logged');

-- 26–27. What a reader is given is the chain's facts, never an event's text.
reset role;
select is(array(select unnest(p.proargnames) from pg_proc p where p.oid = 'public.chain_attribution(uuid)'::regprocedure
                except select unnest(array['p_event', 'device_id', 'seq', 'ulid', 'admission_id', 'role', 'course_id'])),
          array[]::text[],
          'chain_attribution answers only its declared columns: no canonical text, payload or person');
select is(array(select unnest(p.proargnames) from pg_proc p where p.oid = 'public.chain_verification(uuid)'::regprocedure
                except select unnest(array['p_event', 'device_id', 'status', 'verdict', 'at_seq', 'at_ulid', 'after_seq',
                                           'reason', 'lowest_seq', 'highest_seq', 'missing', 'refused_seqs'])),
          array[]::text[],
          'chain_verification answers only its declared columns: no canonical text, payload or person');

reset role;
select * from finish();
rollback;
