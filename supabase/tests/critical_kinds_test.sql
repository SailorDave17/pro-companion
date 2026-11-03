-- pgTAP tests for the critical-kind check in append_event (#75; groom decisions G24, G29 and G30):
-- a critical kind is stored only from a role, and for a fleet on a race area, its admission allows.
-- Run with `supabase test db` against the local stack; the whole file is one transaction and rolls
-- back.
--
-- Every append goes through pg_temp.verdict, which signs in as one of the phones below, sends one
-- text through append_event and answers 'accepted', the refusal's reason, or 'error <SQLSTATE>', so
-- a mutation that makes append_event raise fails its own test and does not abort the file.
-- Admissions are inserted with fixed ids as the table owner, and so are the fleets: a fleet is the
-- fleet.defined event in the race day's log (owner decisions at pickup, 2026-11-02, on the issue).
--
-- One race day, e01, with two race areas, Alpha (ca01) and Bravo (ca02).
--   phones: cpA course_pro Alpha (ad01), cpB course_pro Bravo (ad02), opro overall_pro (ad03),
--           recA recorder Alpha (ad04), mbA mark_boat Alpha (ad05), scorer (ad06), safety (ad07)
--   fleets: fa defined under ad01, so on Alpha; fb under ad02, so on Bravo; fo under ad03 (event-
--           wide) on a day with two race areas, so on none; fc under ad03 naming Bravo in
--           payload.course (#74); fp under ad02 naming Alpha, which wins over its admission's
--           Bravo; fq under ad02 naming a course of no race area of e01, so on Bravo; fu not
--           defined until criterion 8 lands it; fr under ad02 naming Charlie, a real course of
--           the second race day, so on Bravo; fx, whose fleet.defined the server refused.
-- A second race day, e02, with race area Charlie (ca03) and a course PRO on it (ad08), holds a
-- fleet (fe2) and a finish, so the race-day conjuncts have something to exclude.
-- Refusal records written as the owner (auth uid …b0ff): a finish refused not_admitted, one
-- refused revoked, fx's fleet.defined refused role_mismatch, and a text that is not JSON.
--
-- Owner decisions at the review (2026-11-02), which tests 49–79 hold: start.undo,
-- start.time_corrected, start.ocs_cleared and course.undo are corrections, judged through a chain
-- as the event they name; a correction (or a fleet) whose target the server finally refused is
-- refused with that reason, not_admitted waiting and revoked passed on as admission_mismatch.

begin;
create extension if not exists pgtap with schema extensions;
select plan(82);

-- 1–6. The map, who can reach it, and the reasons.
select ok(not exists (select 1 from unnest(array['public.critical_kind', 'public.critical_correction']) t,
                                    unnest(array['anon', 'authenticated', 'service_role']) r,
                                    unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
                      where has_table_privilege(r, t, p))
          and (select bool_and(c.relrowsecurity) from pg_class c
               where c.oid in ('public.critical_kind'::regclass, 'public.critical_correction'::regclass)),
          'no client or service role reads or writes the map, and both tables have row security on');
select ok(not has_function_privilege('anon', 'public.critical_kind_refusal(uuid, jsonb, text, uuid)', 'execute')
          and not has_function_privilege('authenticated', 'public.critical_kind_refusal(uuid, jsonb, text, uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.critical_kind_refusal(uuid, jsonb, text, uuid)', 'execute'),
          'the check is callable only by its owner, which append_event runs as');
select ok((select p.prosecdef and p.proconfig = array['search_path=""']
           from pg_proc p where p.oid = 'public.append_event(uuid, text)'::regprocedure)
          and has_function_privilege('authenticated', 'public.append_event(uuid, text)', 'execute')
          and not has_function_privilege('anon', 'public.append_event(uuid, text)', 'execute')
          and not has_function_privilege('service_role', 'public.append_event(uuid, text)', 'execute'),
          'append_event keeps #48''s definer, empty search_path and grants');
select ok((select pg_get_constraintdef(c.oid) from pg_constraint c
           where c.conrelid = 'public.event_refusal'::regclass and c.conname = 'event_refusal_reason_check')
          like all (array['%kind_not_permitted%', '%race_area_mismatch%', '%admission_superseded%',
                          '%role_mismatch%', '%admission_mismatch%', '%ulid_conflict%']),
          'the reason check holds #75''s two categories beside the earlier seven');
select is((select count(*) from public.critical_kind), 30::bigint,
          'the map holds 30 rows: seven start kinds and an abandonment for two PROs, three each for the two '
          'line-finish kinds and a shortened course, two for an at-mark finish, three for a release');
select is(array(select c.kind || ' ' || c.target from public.critical_correction c order by c.kind),
          array['course.undo corrects_ulid', 'finish.sail payload.finish', 'finish.undo corrects_ulid',
                'start.ocs_cleared corrects_ulid', 'start.time_corrected corrects_ulid', 'start.undo corrects_ulid'],
          'the six kinds that carry no fleet of their own are judged as the event they name');

-- Fixture (table owner, RLS bypassed).
insert into public.club (id, name) values ('00000000-0000-0000-0000-000000000c01', 'Hoover (fixture)');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Club night', date '2026-11-02',
                           '00000000-0000-0000-0000-000000000e01');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Alpha', '00000000-0000-0000-0000-00000000ca01');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Bravo', '00000000-0000-0000-0000-00000000ca02');

create temp table phones (k text primary key, uid text not null, adm text not null, role text not null, course text);
insert into phones values
  ('cpA',    '00000000-0000-0000-0000-00000000b001', '00000000-0000-0000-0000-00000000ad01', 'course_pro',  '00000000-0000-0000-0000-00000000ca01'),
  ('cpB',    '00000000-0000-0000-0000-00000000b002', '00000000-0000-0000-0000-00000000ad02', 'course_pro',  '00000000-0000-0000-0000-00000000ca02'),
  ('opro',   '00000000-0000-0000-0000-00000000b003', '00000000-0000-0000-0000-00000000ad03', 'overall_pro', null),
  ('recA',   '00000000-0000-0000-0000-00000000b004', '00000000-0000-0000-0000-00000000ad04', 'recorder',    '00000000-0000-0000-0000-00000000ca01'),
  ('mbA',    '00000000-0000-0000-0000-00000000b005', '00000000-0000-0000-0000-00000000ad05', 'mark_boat',   '00000000-0000-0000-0000-00000000ca01'),
  ('scorer', '00000000-0000-0000-0000-00000000b006', '00000000-0000-0000-0000-00000000ad06', 'scorer',      null),
  ('safety', '00000000-0000-0000-0000-00000000b007', '00000000-0000-0000-0000-00000000ad07', 'safety',      null);
insert into public.committee_device (id, event_id, club_id, course_id, auth_uid, role)
select p.adm::uuid, '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01',
       p.course::uuid, p.uid::uuid, p.role
from phones p;
grant select on phones to authenticated;

create temp table fleets (k text primary key, ulid text not null);
insert into fleets values
  ('fa', '01J8Z0F000000000000000FA01'), ('fb', '01J8Z0F000000000000000FB01'),
  ('fo', '01J8Z0F000000000000000F001'), ('fc', '01J8Z0F000000000000000FC01'),
  ('fp', '01J8Z0F000000000000000FP01'), ('fq', '01J8Z0F000000000000000FQ01'),
  ('fu', '01J8Z0F000000000000000FU01'), ('fr', '01J8Z0F000000000000000FR01'),
  ('fx', '01J8Z0F000000000000000FX01'), ('fe2', '01J8Z0F000000000000000FE02'),
  -- Not fleets: the ULID of a note on e01, and of a finish on e02, which tests 77-79 name.
  ('note', '01J8Z0F000000000000000N001'), ('e2finish', '01J8Z0F000000000000000E201');
grant select on fleets to authenticated;

-- The second race day: Charlie, and a course PRO on it.
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Second day', date '2026-11-03',
                           '00000000-0000-0000-0000-000000000e02');
select public.create_course('00000000-0000-0000-0000-000000000e02', 'Charlie', '00000000-0000-0000-0000-00000000ca03');
insert into public.committee_device (id, event_id, club_id, course_id, auth_uid, role) values
  ('00000000-0000-0000-0000-00000000ad08', '00000000-0000-0000-0000-000000000e02', '00000000-0000-0000-0000-000000000c01',
   '00000000-0000-0000-0000-00000000ca03', '00000000-0000-0000-0000-00000000b008', 'course_pro');

-- An event as a phone's upload would leave it, stored as the table owner: kind p_kind on race day
-- p_event under the admission given, its ULID fleets' p_k.
create function pg_temp.store(p_k text, p_adm text, p_kind text, p_payload text,
                              p_event text default '00000000-0000-0000-0000-000000000e01') returns void
language sql as $$
  insert into public.event_log (event_id, canonical)
  select p_event::uuid,
         format('{"admission_id":"%s","corrects_ulid":null,"device_id":"01J8Z0D000000000000000%s","device_ts":1730000000000,'
                '"gps":null,"kind":"%s","payload":%s,"payload_version":1,"person":null,"prev_hash":null,"role":null,'
                '"seq":1,"source":"tap","ulid":"%s"}',
                p_adm, right(f.ulid, 4), p_kind, p_payload, f.ulid)
  from fleets f where f.k = p_k
$$;

-- A fleet as a phone's upload would leave it: its fleet.defined in the race day's log, under the
-- admission given, naming p_course in payload.course when given.
create function pg_temp.define_fleet(p_k text, p_adm text, p_course text default null,
                                     p_event text default '00000000-0000-0000-0000-000000000e01') returns void
language sql as $$
  select pg_temp.store(p_k, p_adm, 'fleet.defined',
                       format('{"class":null,%s"name":"Fleet %s"}',
                              case when p_course is null then '' else format('"course":"%s",', p_course) end, p_k),
                       p_event)
$$;
select pg_temp.define_fleet('fa', '00000000-0000-0000-0000-00000000ad01');
select pg_temp.define_fleet('fb', '00000000-0000-0000-0000-00000000ad02');
select pg_temp.define_fleet('fo', '00000000-0000-0000-0000-00000000ad03');
select pg_temp.define_fleet('fc', '00000000-0000-0000-0000-00000000ad03', '00000000-0000-0000-0000-00000000ca02');
select pg_temp.define_fleet('fp', '00000000-0000-0000-0000-00000000ad02', '00000000-0000-0000-0000-00000000ca01');
select pg_temp.define_fleet('fq', '00000000-0000-0000-0000-00000000ad02', '00000000-0000-0000-0000-0000000000ff');
select pg_temp.define_fleet('fr', '00000000-0000-0000-0000-00000000ad02', '00000000-0000-0000-0000-00000000ca03');
select pg_temp.define_fleet('fe2', '00000000-0000-0000-0000-00000000ad08', null, '00000000-0000-0000-0000-000000000e02');
select pg_temp.store('note', '00000000-0000-0000-0000-00000000ad02', 'note', '{"text":"Mark 2 hold"}');
select pg_temp.store('e2finish', '00000000-0000-0000-0000-00000000ad08', 'finish', '{"fleet":null}',
                     '00000000-0000-0000-0000-000000000e02');

-- Refusal records, as append_event would have kept them, under a uid no phone in this file holds.
-- r1 and r2 are finishes; fx's is its fleet.defined; r4 names its ULID in a text that is not JSON.
insert into public.event_refusal (event_id, canonical, event_hash, device_id, seq, reason, auth_uid) values
  ('00000000-0000-0000-0000-000000000e01',
   '{"admission_id":null,"kind":"finish","payload":{"fleet":null},"seq":1,"ulid":"01J8R000000000000000000R01"}',
   'fixture-r1', '01J8Z0D0000000000000000FF1', 1, 'not_admitted', '00000000-0000-0000-0000-00000000b0ff'),
  ('00000000-0000-0000-0000-000000000e01',
   '{"admission_id":null,"kind":"finish","payload":{"fleet":null},"seq":2,"ulid":"01J8R000000000000000000R02"}',
   'fixture-r2', '01J8Z0D0000000000000000FF1', 2, 'revoked', '00000000-0000-0000-0000-00000000b0ff'),
  ('00000000-0000-0000-0000-000000000e01',
   '{"admission_id":null,"kind":"fleet.defined","payload":{"name":"X"},"seq":3,"ulid":"01J8Z0F000000000000000FX01"}',
   'fixture-r3', '01J8Z0D0000000000000000FF1', 3, 'role_mismatch', '00000000-0000-0000-0000-00000000b0ff'),
  ('00000000-0000-0000-0000-000000000e01', 'not json, but it says "ulid":"01J8R000000000000000000R04"',
   'fixture-r4', null, null, 'inconsistent_canonical', '00000000-0000-0000-0000-00000000b0ff');

-- The payload of a race-time event for fleet p_k, or for no fleet (a single-fleet day's).
create function pg_temp.fleet(p_k text default null) returns text language sql stable as $$
  select coalesce((select format('{"fleet":"%s"}', f.ulid) from fleets f where f.k = p_k), '{"fleet":null}')
$$;
grant execute on function pg_temp.fleet(text) to authenticated;

-- A fixture's ULID, raw.
create function pg_temp.fid(p_k text) returns text language sql stable as $$
  select f.ulid from fleets f where f.k = p_k
$$;
grant execute on function pg_temp.fid(text) to authenticated;

-- The ULID an append with an explicit p_seq stores its event under, so a correction can name it.
create function pg_temp.ulid(p_seq bigint) returns text language sql immutable as $$
  select '01J80000000000000000' || lpad(p_seq::text, 6, '0')
$$;
grant execute on function pg_temp.ulid(bigint) to authenticated;

create temp sequence n;
grant usage, select on sequence n to authenticated;

-- append_event's answer, or its error as an answer.
create function pg_temp.try_append(p_event uuid, p_text text) returns jsonb
language plpgsql as $$
begin
  return public.append_event(p_event, p_text);
exception when others then
  return jsonb_build_object('outcome', 'error', 'sqlstate', sqlstate, 'message', sqlerrm);
end;
$$;
grant execute on function pg_temp.try_append(uuid, text) to authenticated;

-- Phone p_who appends one event of p_kind to e01, under its own admission and role, and the answer
-- in a word. p_seq fixes its seq and ULID (pg_temp.ulid), so a later test can name it, and the same
-- p_seq with the same arguments is the same text.
create function pg_temp.verdict(p_who text, p_kind text, p_payload text default '{"fleet":null}',
                                p_corrects text default null, p_seq bigint default null) returns text
language plpgsql as $$
declare
  v_phone  phones%rowtype;
  v_n      bigint := coalesce(p_seq, nextval('pg_temp.n'));
  v_answer jsonb;
begin
  select * into v_phone from phones where k = p_who;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_phone.uid, 'role', 'authenticated', 'is_anonymous', true)::text, true);
  v_answer := pg_temp.try_append('00000000-0000-0000-0000-000000000e01',
    format('{"admission_id":"%s","corrects_ulid":%s,"device_id":"01J8Z0D000000000000000%s","device_ts":%s,"gps":null,'
           '"kind":"%s","payload":%s,"payload_version":1,"person":null,"prev_hash":null,"role":"%s","seq":%s,'
           '"source":"tap","ulid":"%s"}',
           v_phone.adm, coalesce(to_json(p_corrects)::text, 'null'), right(v_phone.uid, 4), 1730000000000 + v_n,
           p_kind, p_payload, v_phone.role, v_n, pg_temp.ulid(v_n)));
  return case v_answer ->> 'outcome'
           when 'accepted' then 'accepted'
           when 'refused' then v_answer ->> 'reason'
           else 'error ' || (v_answer ->> 'sqlstate') end;
end;
$$;
grant execute on function pg_temp.verdict(text, text, text, text, bigint) to authenticated;

-- The critical kinds, read as the owner for the safety and overall PRO sweeps below.
create temp table crit as select distinct k.kind from public.critical_kind k order by k.kind;
grant select on crit to authenticated;

set local role authenticated;

-- 7–9. Criterion 2: a course PRO's start, on its own race area and on another.
select is(pg_temp.verdict('cpA', 'start', pg_temp.fleet('fb'), null, 9001), 'race_area_mismatch',
          'a course PRO on Alpha starting a fleet on Bravo is refused as race_area_mismatch');
select is(pg_temp.verdict('cpA', 'start', pg_temp.fleet('fa')), 'accepted',
          'and the same start for a fleet on its own race area is accepted');
reset role;
select is((select r.reason || ' ' || r.seq from public.event_refusal r
           where r.event_id = '00000000-0000-0000-0000-000000000e01' and r.seq = 9001),
          'race_area_mismatch 9001', 'the refusal is kept with its reason, as any refusal is (G43)');
set local role authenticated;

-- 10–15. Criterion 3: with no fleet, a postponement or abandonment is the whole race day's.
select is(pg_temp.verdict('opro', 'start.postponement', '{"fleet":null}', null, 9010), 'accepted',
          'an overall PRO''s postponement with no fleet is accepted');
select is(pg_temp.verdict('cpA', 'start.postponement'), 'race_area_mismatch',
          'a course PRO''s postponement with no fleet is refused: the whole race day is off its race area');
select is(pg_temp.verdict('opro', 'race.abandoned'), 'accepted',
          'an overall PRO''s abandonment with no fleet is accepted');
select is(pg_temp.verdict('cpA', 'race.abandoned'), 'race_area_mismatch',
          'a course PRO''s abandonment with no fleet is refused the same way');
select is(pg_temp.verdict('scorer', 'start.postponement'), 'kind_not_permitted',
          'a scorer''s postponement is refused as a kind its role may not write at all');
select is(pg_temp.verdict('cpA', 'start.postponement', pg_temp.fleet('fa')), 'accepted',
          'a course PRO''s postponement of a fleet on its own race area is accepted (control)');

-- 16–19. Criterion 4: a recorder writes line finishes on its race area, and no start.
select is(pg_temp.verdict('recA', 'finish', pg_temp.fleet('fa'), null, 9016), 'accepted',
          'a recorder on Alpha logging a line finish for a fleet on Alpha is accepted');
select is(pg_temp.verdict('recA', 'start', pg_temp.fleet('fa')), 'kind_not_permitted',
          'and its start is refused as kind_not_permitted');
select is(pg_temp.verdict('recA', 'finish', pg_temp.fleet('fb'), null, 9018), 'race_area_mismatch',
          'and its line finish for a fleet on Bravo as race_area_mismatch');
select is(pg_temp.verdict('recA', 'finish.missed', pg_temp.fleet('fa')), 'accepted',
          'a missed finish is a line finish, and accepted the same way');

-- 20–23. Criterion 5: a mark boat writes a shortened course and finishes at its mark, and no line
-- finish.
select is(pg_temp.verdict('mbA', 'course.shortened', pg_temp.fleet('fa')), 'accepted',
          'a mark boat on Alpha shortening the course for a fleet on Alpha is accepted');
select is(pg_temp.verdict('mbA', 'finish.at_mark', pg_temp.fleet('fa'), null, 9021), 'accepted',
          'and its finish at the mark is accepted');
select is(pg_temp.verdict('mbA', 'finish', pg_temp.fleet('fa')), 'kind_not_permitted',
          'and its line finish is refused as kind_not_permitted');
select is(pg_temp.verdict('mbA', 'course.shortened', pg_temp.fleet('fb')), 'race_area_mismatch',
          'and its shortened course for a fleet on Bravo as race_area_mismatch');

-- 24–28. Criterion 6: the scorer releases results for any fleet and writes no start; safety writes
-- no critical kind; the overall PRO writes every one, on any race area.
select is(pg_temp.verdict('scorer', 'results.released', pg_temp.fleet('fb')), 'accepted',
          'a scorer releasing results for a fleet on Bravo is accepted');
select is(pg_temp.verdict('scorer', 'results.released', pg_temp.fleet('fa')), 'accepted',
          'and for a fleet on Alpha: any fleet (G30)');
select is(pg_temp.verdict('scorer', 'start', pg_temp.fleet('fa')), 'kind_not_permitted',
          'and its start is refused');
select is(array(select distinct pg_temp.verdict('safety', c.kind, pg_temp.fleet('fa')) from crit c),
          array['kind_not_permitted'],
          'safety is refused every critical kind in the map, as kind_not_permitted');
select is(array(select distinct pg_temp.verdict('opro', c.kind, pg_temp.fleet('fb')) from crit c),
          array['accepted'],
          'the overall PRO writes every critical kind in the map, for a fleet on Bravo');

-- 29. Criterion 7: a kind the map does not name is open to every admitted role, whatever its fleet,
-- even one the server does not hold.
select is(array(select distinct pg_temp.verdict(p.k, k.kind, pg_temp.fleet('fu'))
                from phones p, unnest(array['note', 'rounding.sail', 'wind.reading']) k(kind)),
          array['accepted'],
          'a note, a rounding and a wind reading are accepted from all six roles, on seven phones');

-- 30–33. Criteria 8 and 10: a critical event for a fleet the server does not hold yet is not
-- judged. It raises PCW01, outside class 22, 23502 and 23505, so it keeps no record and sync retries
-- it; once the fleet lands, the same text is accepted.
select is(pg_temp.verdict('cpA', 'start', pg_temp.fleet('fu'), null, 9030), 'error PCW01',
          'a start for a fleet whose fleet.defined is not in the log raises PCW01');
select ok((select v from (select pg_temp.verdict('cpA', 'course.shortened', pg_temp.fleet('fu')) as v) s)
          similar to 'error [0-9A-Z]{5}'
          and (select v from (select pg_temp.verdict('cpA', 'course.shortened', pg_temp.fleet('fu')) as v) s)
          not similar to 'error (22%|23502|23505)',
          'the SQLSTATE raised is outside class 22 and is neither 23502 nor 23505, which append_event reads as refusals');
reset role;
select is((select count(*) from public.event_refusal r
           where r.event_id = '00000000-0000-0000-0000-000000000e01' and r.seq = 9030)
          + (select count(*) from public.event_log l where l.ulid = pg_temp.ulid(9030)), 0::bigint,
          'and it left no refusal record and no row');
select pg_temp.define_fleet('fu', '00000000-0000-0000-0000-00000000ad01');
set local role authenticated;
select is(pg_temp.verdict('cpA', 'start', pg_temp.fleet('fu'), null, 9030), 'accepted',
          'once the fleet''s fleet.defined lands, the same text is accepted');

-- 34–41. Corrections follow the finish they name: a sail number by payload.finish, an undo by
-- corrects_ulid. 9016 is recA's line finish on Alpha, 9021 mbA's finish at the mark on Alpha.
select is(pg_temp.verdict('mbA', 'finish.sail', format('{"finish":"%s","sail":"123"}', pg_temp.ulid(9021))), 'accepted',
          'a mark boat numbering its own finish at the mark is accepted');
select is(pg_temp.verdict('mbA', 'finish.undo', '{}', pg_temp.ulid(9021)), 'accepted',
          'and taking it back');
select is(pg_temp.verdict('recA', 'finish.sail', format('{"finish":"%s","sail":"456"}', pg_temp.ulid(9016))), 'accepted',
          'a recorder numbering its line finish is accepted');
select is(pg_temp.verdict('mbA', 'finish.sail', format('{"finish":"%s","sail":"789"}', pg_temp.ulid(9016))), 'kind_not_permitted',
          'a mark boat numbering a line finish is refused: it is judged as the line finish it names');
select is(pg_temp.verdict('recA', 'finish.undo', '{}', pg_temp.ulid(9021)), 'kind_not_permitted',
          'a recorder taking back a finish at a mark is refused the same way');
select is(pg_temp.verdict('cpB', 'finish.undo', '{}', pg_temp.ulid(9016)), 'race_area_mismatch',
          'a course PRO on Bravo taking back a line finish on Alpha is refused by the finish''s own fleet');
select is(pg_temp.verdict('recA', 'finish.sail', format('{"finish":"%s","sail":"1"}', pg_temp.ulid(999999))), 'error PCW01',
          'a sail number for a finish the server does not hold yet raises PCW01, to be retried');
select is(pg_temp.verdict('safety', 'finish.sail', format('{"finish":"%s","sail":"2"}', pg_temp.ulid(9016))), 'kind_not_permitted',
          'and safety numbering a line finish is refused');

-- 42–48. Which race area a fleet races on: payload.course first (#74), then the defining
-- admission's race area, else none and the role alone.
select is(pg_temp.verdict('cpB', 'start', pg_temp.fleet('fo')), 'accepted',
          'an event-wide phone''s fleet on a day with two race areas is on none, so a course PRO on Bravo may start it');
select is(pg_temp.verdict('recA', 'finish', pg_temp.fleet('fo')), 'accepted',
          'and a recorder on Alpha may finish it: the role alone is checked');
select is(pg_temp.verdict('cpB', 'start', pg_temp.fleet('fc')), 'accepted',
          'a fleet whose fleet.defined names Bravo is on Bravo, whoever defined it');
select is(pg_temp.verdict('cpA', 'start', pg_temp.fleet('fc')), 'race_area_mismatch',
          'so a course PRO on Alpha may not start it');
select is(pg_temp.verdict('cpA', 'start', pg_temp.fleet('fp')), 'accepted',
          'a fleet naming Alpha, defined under a Bravo admission, is on Alpha: payload.course comes first');
select is(pg_temp.verdict('cpB', 'start', pg_temp.fleet('fp')), 'race_area_mismatch',
          'so a course PRO on Bravo may not start it');
select is(pg_temp.verdict('cpA', 'start', pg_temp.fleet('fq')), 'race_area_mismatch',
          'a course that is no race area of the day is passed over for the defining admission''s, Bravo');

-- 49–53. The four kinds that carry no fleet (the review): fixtures, each asserted. 9101 is the
-- Bravo course PRO's start, 9102 an OCS at it, 9103 the overall PRO's time correction of it, 9104
-- the Alpha course PRO's own start, 9105 the Alpha mark boat's shortened course.
select is(pg_temp.verdict('cpB', 'start', pg_temp.fleet('fb'), null, 9101), 'accepted', 'fixture: a start on Bravo');
select is(pg_temp.verdict('cpB', 'start.ocs', format('{"fleet":"%s","sail":"7","start":"%s"}', pg_temp.fid('fb'), pg_temp.ulid(9101)),
                          null, 9102), 'accepted', 'fixture: an OCS at it');
select is(pg_temp.verdict('opro', 'start.time_corrected', '{"time":1730000000999}', pg_temp.ulid(9101), 9103), 'accepted',
          'fixture: the overall PRO''s time correction of it, judged as the Bravo start');
select is(pg_temp.verdict('cpA', 'start', pg_temp.fleet('fa'), null, 9104), 'accepted', 'fixture: a start on Alpha');
select is(pg_temp.verdict('mbA', 'course.shortened', pg_temp.fleet('fa'), null, 9105), 'accepted',
          'fixture: a shortened course on Alpha');

-- 54–64. Each is judged as the event it names, through a chain, as the core writes it: no fleet.
select is(pg_temp.verdict('cpA', 'start.undo', '{}', pg_temp.ulid(9101)), 'race_area_mismatch',
          'the Alpha course PRO taking back Bravo''s start is refused');
select is(pg_temp.verdict('cpA', 'start.time_corrected', '{"time":1730000000555}', pg_temp.ulid(9101)), 'race_area_mismatch',
          'and retiming it');
select is(pg_temp.verdict('cpA', 'start.ocs_cleared', '{}', pg_temp.ulid(9102)), 'race_area_mismatch',
          'and clearing a Bravo OCS');
select is(pg_temp.verdict('cpA', 'start.undo', '{}', pg_temp.ulid(9103)), 'race_area_mismatch',
          'and taking back a time correction of Bravo''s start: the chain reaches the start');
select is(pg_temp.verdict('cpB', 'start.undo', '{}', pg_temp.ulid(9103)), 'accepted',
          'which the Bravo course PRO may (control on the chain)');
select is(pg_temp.verdict('cpA', 'start.undo', '{}', pg_temp.ulid(9010)), 'race_area_mismatch',
          'a course PRO taking back the overall PRO''s whole-day postponement is refused, as the postponement would be');
select is(pg_temp.verdict('opro', 'start.undo', '{}', pg_temp.ulid(9010)), 'accepted',
          'and the overall PRO may');
select is(pg_temp.verdict('cpA', 'start.undo', '{}', pg_temp.ulid(9104)), 'accepted',
          'the Alpha course PRO taking back its own start is accepted');
select is(pg_temp.verdict('recA', 'start.undo', '{}', pg_temp.ulid(9104)), 'kind_not_permitted',
          'a recorder taking it back is refused: what it is judged as is a start');
select is(pg_temp.verdict('mbA', 'course.undo', '{}', pg_temp.ulid(9105)), 'accepted',
          'the Alpha mark boat taking back its shortened course is accepted');
select is(pg_temp.verdict('cpB', 'course.undo', '{}', pg_temp.ulid(9105)), 'race_area_mismatch',
          'and the Bravo course PRO taking it back is refused');

-- 65–70. A correction whose target the server refused (the review). 9018 is the Alpha recorder's
-- finish for the Bravo fleet, refused race_area_mismatch at test 18.
select is(pg_temp.verdict('recA', 'finish.undo', '{}', pg_temp.ulid(9018)), 'race_area_mismatch',
          'taking back a refused finish is refused with the finish''s reason, not retried');
select is(pg_temp.verdict('recA', 'finish.sail', format('{"finish":"%s","sail":"5"}', pg_temp.ulid(9018))), 'race_area_mismatch',
          'and so is numbering it');
select is(pg_temp.verdict('recA', 'finish.undo', '{}', '01J8R000000000000000000R01'), 'error PCW01',
          'a finish refused not_admitted may still land, so a correction of it waits');
select is(pg_temp.verdict('recA', 'finish.undo', '{}', '01J8R000000000000000000R02'), 'admission_mismatch',
          'a finish refused revoked passes on admission_mismatch, never revoked');
select is(pg_temp.verdict('cpA', 'start', pg_temp.fleet('fx')), 'role_mismatch',
          'a start for a fleet whose fleet.defined was refused is refused with that reason');
select is(pg_temp.verdict('recA', 'finish.undo', '{}', '01J8R000000000000000000R04'), 'error PCW01',
          'a refusal whose text is not JSON names no ULID it can be read by, so the correction waits, with no cast error');

-- 71–73. A single-fleet day (no fleet): a bound role writes its own kinds, checked by role only.
select is(pg_temp.verdict('cpA', 'start'), 'accepted', 'the Alpha course PRO''s start with no fleet is accepted');
select is(pg_temp.verdict('recA', 'finish'), 'accepted', 'the Alpha recorder''s line finish with no fleet is accepted');
select is(pg_temp.verdict('mbA', 'course.shortened'), 'accepted',
          'the Alpha mark boat''s shortened course with no fleet is accepted');

-- 74–76. payload.course counts only when it is a race area of the day.
select is(pg_temp.verdict('cpB', 'start', pg_temp.fleet('fq')), 'accepted',
          'fq''s course is no race area at all, so fq is on Bravo and the Bravo course PRO may start it (control on 48)');
select is(pg_temp.verdict('cpA', 'start', pg_temp.fleet('fr')), 'race_area_mismatch',
          'fr names Charlie, the second race day''s, so it is on its defining admission''s Bravo: refused to Alpha');
select is(pg_temp.verdict('cpB', 'start', pg_temp.fleet('fr')), 'accepted',
          'and accepted from Bravo');

-- 77–79. Only a fleet.defined on this race day is a fleet, and only an event on it can be corrected.
select is(pg_temp.verdict('cpA', 'start', pg_temp.fleet('note')), 'error PCW01',
          'a fleet id that is the ULID of a note is no fleet: the start waits');
select is(pg_temp.verdict('cpA', 'start', pg_temp.fleet('fe2')), 'error PCW01',
          'a fleet defined on the second race day is no fleet of this one');
select is(pg_temp.verdict('recA', 'finish.undo', '{}', pg_temp.fid('e2finish')), 'error PCW01',
          'and a finish on the second race day is not one this day''s correction can name');

-- 80–82. What the records say.
reset role;
select is((select jsonb_object_agg(s.reason, s.n) from (select r.reason, count(*) as n from public.event_refusal r
                                                        where r.event_id = '00000000-0000-0000-0000-000000000e01'
                                                          and r.auth_uid <> '00000000-0000-0000-0000-00000000b0ff'
                                                        group by r.reason) s),
          '{"kind_not_permitted": 21, "race_area_mismatch": 18, "admission_mismatch": 1, "role_mismatch": 1}'::jsonb,
          'the phones'' refusals: 21 of a kind the role may not write, 18 off the race area, two passed on from a refused target');
select is((select count(*) from public.event_log l where l.event_id = '00000000-0000-0000-0000-000000000e01'),
          75::bigint, 'the log holds the eight fleets, the note and the 66 accepted events of this file');
select is((select count(*) from public.event_log l
           where l.event_id = '00000000-0000-0000-0000-000000000e01' and l.kind = 'start'
             and l.device_id = '01J8Z0D000000000000000b001'
             and l.payload ->> 'fleet' = pg_temp.fid('fb')), 0::bigint,
          'the Alpha course PRO''s start for the Bravo fleet was not stored (control on 7)');

select * from finish();
rollback;
