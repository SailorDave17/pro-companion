-- pgTAP tests for the admission check in append_event (#73; groom decisions G44 and G46): the log's
-- admission column, and that an event is accepted only under the admission, role and race day its
-- phone holds, with the device-handoff link and the role-change marker. Run with `supabase test db`
-- against the local stack; the whole file is one transaction and rolls back.
--
-- Roles are switched the way PostgREST switches them, as in committee_spine_test.sql. Every append
-- goes through pg_temp.try_append, which answers the call's jsonb or its error, so a mutation that
-- makes append_event raise fails its own test and does not abort the file. Admissions are inserted
-- with fixed ids as the table owner (admit_device is re_admission_test.sql's subject), so every text
-- is literal through pg_temp.ev.
--
-- Owner decisions at pickup and at the review (2026-10-31), which these tests hold:
-- - the device-handoff link: another user's admission of the race day counts as the writer's when
--   that user holds no revoked admission there and the named admission's successors end in the slot
--   (role and race area) the caller's active admission holds (from the conflict #6 raised); a slot
--   the caller held and left does not count;
-- - the marker is the device's event of kind admission.superseded under the old admission, and its
--   own seq is the bound; with no marker stored, events under a superseded admission are accepted;
-- - a null role is refused like a wrong one.

begin;
create extension if not exists pgtap with schema extensions;
select plan(47);

-- Fixed ids so the file needs no client-side variables.
-- clubs:      …c01 Hoover, …c02 Other
-- events:     …e01 Hoover's club night, …e03 Hoover's second day
-- courses:    …ca01 e01 Alpha, …ca02 e01 Bravo
-- phones and admissions (…b0NN is the Auth user, …adNN its admission, …07N1 its device):
--   b001: ad01 scorer e01, ad05 scorer e03            (criteria 1 and 3)
--   b002: ad02 mark_boat Alpha e01                    (criterion 2)
--   b003: ad03 recorder Alpha e01, superseded by ad04 mark_boat Alpha; logs the marker (criterion 4)
--   b004: ad06 scorer e01, superseded by ad07 overall_pro; logs no marker
--   b005: ad08 scorer e01, the handoff phone's previous user; revoked by the owner at test 27
--   b006: ad09 scorer e01, the same phone signed in again (the link)
--   b007: ad10 recorder Bravo e01
--   b008: ad11 scorer e01, revoked
--   b009: ad12 recorder Alpha e01; b010: ad13 recorder Alpha e01 (the race-area half of the slot),
--         and ad19 scorer e03 (a row of the right user on the wrong race day)
--   b011: ad14 recorder Alpha e01, superseded by ad15 mark_boat Alpha (the lineage: a role change
--         before a lost session); b012: ad16 scorer e01, superseded by ad17 overall_pro, revoked;
--         b013: ad18 overall_pro e01, the caller that names ad16
--   devices: …0731 and …0732 are both b003's (a spare under one admission)

-- 1–4. The column, its grant, the reason categories and the marker index.
select is((select format_type(a.atttypid, a.atttypmod) || ' ' || a.attgenerated::text from pg_attribute a
           where a.attrelid = 'public.event_log'::regclass and a.attname = 'admission_id'),
          'uuid s', 'the log holds admission_id as a uuid generated from the text');
select ok(has_column_privilege('authenticated', 'public.event_log', 'admission_id', 'SELECT'),
          'a phone may select it, so #50''s select=* still works');
select ok((select pg_get_constraintdef(c.oid) from pg_constraint c
           where c.conrelid = 'public.event_refusal'::regclass and c.conname = 'event_refusal_reason_check')
          like all (array['%admission_mismatch%', '%role_mismatch%', '%admission_superseded%', '%not_admitted%',
                          '%revoked%', '%inconsistent_canonical%', '%ulid_conflict%']),
          'the reason check holds #48''s four categories and #73''s three');
select is(pg_get_indexdef(to_regclass('public.event_log_marker_idx')),
          'CREATE INDEX event_log_marker_idx ON public.event_log USING btree (event_id, device_id, admission_id) WHERE (kind = ''admission.superseded''::text)',
          'the role-change marker is indexed by race day, device and admission');

-- Fixture (table owner, RLS bypassed).
insert into public.club (id, name) values
  ('00000000-0000-0000-0000-000000000c01', 'Hoover (fixture)'),
  ('00000000-0000-0000-0000-000000000c02', 'Other (fixture)');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Club night', date '2026-10-31',
                           '00000000-0000-0000-0000-000000000e01');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Second day', date '2026-11-01',
                           '00000000-0000-0000-0000-000000000e03');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Alpha', '00000000-0000-0000-0000-00000000ca01');
select public.create_course('00000000-0000-0000-0000-000000000e01', 'Bravo', '00000000-0000-0000-0000-00000000ca02');
insert into public.committee_device (id, event_id, club_id, course_id, auth_uid, role, superseded_by, superseded_at, revoked_at) values
  ('00000000-0000-0000-0000-00000000ad01', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b001', 'scorer', null, null, null),
  ('00000000-0000-0000-0000-00000000ad05', '00000000-0000-0000-0000-000000000e03', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b001', 'scorer', null, null, null),
  ('00000000-0000-0000-0000-00000000ad02', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-00000000ca01',
   '00000000-0000-0000-0000-00000000b002', 'mark_boat', null, null, null),
  ('00000000-0000-0000-0000-00000000ad03', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-00000000ca01',
   '00000000-0000-0000-0000-00000000b003', 'recorder', '00000000-0000-0000-0000-00000000ad04', now(), null),
  ('00000000-0000-0000-0000-00000000ad04', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-00000000ca01',
   '00000000-0000-0000-0000-00000000b003', 'mark_boat', null, null, null),
  ('00000000-0000-0000-0000-00000000ad06', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b004', 'scorer', '00000000-0000-0000-0000-00000000ad07', now(), null),
  ('00000000-0000-0000-0000-00000000ad07', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b004', 'overall_pro', null, null, null),
  ('00000000-0000-0000-0000-00000000ad08', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b005', 'scorer', null, null, null),
  ('00000000-0000-0000-0000-00000000ad09', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b006', 'scorer', null, null, null),
  ('00000000-0000-0000-0000-00000000ad10', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-00000000ca02',
   '00000000-0000-0000-0000-00000000b007', 'recorder', null, null, null),
  ('00000000-0000-0000-0000-00000000ad11', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b008', 'scorer', null, null, now()),
  ('00000000-0000-0000-0000-00000000ad12', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-00000000ca01',
   '00000000-0000-0000-0000-00000000b009', 'recorder', null, null, null),
  ('00000000-0000-0000-0000-00000000ad13', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-00000000ca01',
   '00000000-0000-0000-0000-00000000b010', 'recorder', null, null, null),
  ('00000000-0000-0000-0000-00000000ad14', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-00000000ca01',
   '00000000-0000-0000-0000-00000000b011', 'recorder', '00000000-0000-0000-0000-00000000ad15', now(), null),
  ('00000000-0000-0000-0000-00000000ad15', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-00000000ca01',
   '00000000-0000-0000-0000-00000000b011', 'mark_boat', null, null, null),
  ('00000000-0000-0000-0000-00000000ad16', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b012', 'scorer', '00000000-0000-0000-0000-00000000ad17', now(), null),
  ('00000000-0000-0000-0000-00000000ad17', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b012', 'overall_pro', null, null, now()),
  ('00000000-0000-0000-0000-00000000ad18', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b013', 'overall_pro', null, null, null),
  ('00000000-0000-0000-0000-00000000ad19', '00000000-0000-0000-0000-000000000e03', '00000000-0000-0000-0000-000000000c01', null,
   '00000000-0000-0000-0000-00000000b010', 'scorer', null, null, null);

-- A canonical text, keys in RFC 8785 order, naming the admission and role given (null for a JSON
-- null), from one device at one seq.
create function pg_temp.ev(p_adm text, p_role text, p_device text, p_seq int, p_ulid text, p_kind text default 'note')
returns text language sql immutable as $$
  select format('{"admission_id":%s,"corrects_ulid":null,"device_id":"%s","device_ts":%s,"gps":null,"kind":"%s",'
                '"payload":{},"payload_version":1,"person":null,"prev_hash":null,"role":%s,"seq":%s,"source":"tap","ulid":"%s"}',
                coalesce(to_json(p_adm)::text, 'null'), p_device, 1730000000000 + p_seq, p_kind,
                coalesce(to_json(p_role)::text, 'null'), p_seq, p_ulid)
$$;
grant execute on function pg_temp.ev(text, text, text, int, text, text) to authenticated;

-- append_event's answer, or its error as an answer, so a raising mutant reddens one test.
create function pg_temp.try_append(p_event uuid, p_text text) returns jsonb
language plpgsql as $$
begin
  return public.append_event(p_event, p_text);
exception when others then
  return jsonb_build_object('outcome', 'error', 'sqlstate', sqlstate, 'message', sqlerrm);
end;
$$;
grant execute on function pg_temp.try_append(uuid, text) to authenticated;

-- The admission column of one row as the calling role reads it, or its refusal, so a revoked grant
-- reddens one test instead of aborting the file.
create function pg_temp.read_admission(p_ulid text) returns text
language plpgsql as $$
declare
  v_admission text;
begin
  select l.admission_id::text into v_admission from public.event_log l where l.ulid = p_ulid;
  return v_admission;
exception when others then
  return 'refused ' || sqlstate;
end;
$$;
grant execute on function pg_temp.read_admission(text) to authenticated;

-- Signs a phone in, the way PostgREST sets the claims for its token.
create function pg_temp.as_phone(p_uid text) returns void
language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated', 'is_anonymous', true)::text, true);
$$;
grant execute on function pg_temp.as_phone(text) to authenticated;

-- Abbreviations the tests below use.
create temp table ids (k text primary key, v text not null);
insert into ids values
  ('e01', '00000000-0000-0000-0000-000000000e01'), ('e03', '00000000-0000-0000-0000-000000000e03'),
  ('ad01', '00000000-0000-0000-0000-00000000ad01'), ('ad02', '00000000-0000-0000-0000-00000000ad02'),
  ('ad03', '00000000-0000-0000-0000-00000000ad03'), ('ad04', '00000000-0000-0000-0000-00000000ad04'),
  ('ad05', '00000000-0000-0000-0000-00000000ad05'), ('ad06', '00000000-0000-0000-0000-00000000ad06'),
  ('ad08', '00000000-0000-0000-0000-00000000ad08'), ('ad10', '00000000-0000-0000-0000-00000000ad10'),
  ('ad11', '00000000-0000-0000-0000-00000000ad11'), ('ad12', '00000000-0000-0000-0000-00000000ad12'),
  ('ad13', '00000000-0000-0000-0000-00000000ad13'), ('ad14', '00000000-0000-0000-0000-00000000ad14'),
  ('ad16', '00000000-0000-0000-0000-00000000ad16'), ('ad19', '00000000-0000-0000-0000-00000000ad19'),
  ('d1', '01J8Z0D0000000000000000711'), ('d2', '01J8Z0D0000000000000000721'), ('d3', '01J8Z0D0000000000000000731'),
  ('d3b', '01J8Z0D0000000000000000732'), ('d4', '01J8Z0D0000000000000000741'), ('d6', '01J8Z0D0000000000000000761'),
  ('d9', '01J8Z0D0000000000000000791'), ('d13', '01J8Z0D0000000000000000813');
grant select on ids to authenticated;
create function pg_temp.id(p_k text) returns text language sql stable as $$ select v from ids where k = p_k $$;
grant execute on function pg_temp.id(text) to authenticated;

-- 5–11. Criterion 1, and criterion 3's own-admission case: b001 holds ad01 on e01 and ad05 on e03.
set local role authenticated;
select pg_temp.as_phone('00000000-0000-0000-0000-00000000b001');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad01'), 'scorer', pg_temp.id('d1'), 1, '01J80000000000000000000711'))
            - 'hash',
          '{"outcome": "accepted", "duplicate": false}'::jsonb,
          'an event naming the phone''s own admission on the race day, in its role, is accepted');
select is(current_setting('response.status', true), null, 'and answered with no error status');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad02'), 'scorer', pg_temp.id('d1'), 2, '01J80000000000000000000712'))
            - 'hash',
          '{"outcome": "refused", "reason": "admission_mismatch", "code": "append_event_refused",
            "message": "append_event refused the event: admission_mismatch", "details": "admission_mismatch"}'::jsonb,
          'an event naming another phone''s admission is refused as admission_mismatch, with the reason in details');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(null, 'scorer', pg_temp.id('d1'), 3, '01J80000000000000000000713')) ->> 'reason',
          'admission_mismatch', 'an event naming no admission is refused the same way');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev('not an admission', 'scorer', pg_temp.id('d1'), 4, '01J80000000000000000000714')) ->> 'reason',
          'admission_mismatch', 'and so is one whose admission is not even a uuid, with no cast error');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad05'), 'scorer', pg_temp.id('d1'), 5, '01J80000000000000000000715')) ->> 'reason',
          'admission_mismatch', 'criterion 3: the phone''s own admission to the club''s other race day is refused on this one');
select is(pg_temp.try_append(pg_temp.id('e03')::uuid, pg_temp.ev(pg_temp.id('ad05'), 'scorer', pg_temp.id('d1'), 6, '01J80000000000000000000716')) ->> 'outcome',
          'accepted', 'and accepted on the race day it is for (control)');

-- 12–16. Criterion 2: b002 is admitted as mark_boat. The text is stored verbatim, the role never
-- rewritten.
select pg_temp.as_phone('00000000-0000-0000-0000-00000000b002');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad02'), 'course_pro', pg_temp.id('d2'), 1, '01J80000000000000000000721')) ->> 'reason',
          'role_mismatch', 'a mark boat''s event whose role says course_pro is refused as role_mismatch');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad02'), null, pg_temp.id('d2'), 2, '01J80000000000000000000722')) ->> 'reason',
          'role_mismatch', 'and one whose role is null is refused the same way');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad02'), 'mark_boat', pg_temp.id('d2'), 3, '01J80000000000000000000723')) ->> 'outcome',
          'accepted', 'with role mark_boat it is accepted');
reset role;
select is((select jsonb_build_object('verbatim', l.canonical = pg_temp.ev(pg_temp.id('ad02'), 'mark_boat', pg_temp.id('d2'), 3, '01J80000000000000000000723'),
                                     'role', l.role, 'admission', l.admission_id::text)
           from public.event_log l where l.ulid = '01J80000000000000000000723'),
          jsonb_build_object('verbatim', true, 'role', 'mark_boat', 'admission', pg_temp.id('ad02')),
          'and stored verbatim, its role and admission columns read from the text');
select is(array(select r.reason || ' ' || r.seq from public.event_refusal r
                where r.device_id = pg_temp.id('d2') order by r.seq),
          array['role_mismatch 1', 'role_mismatch 2'],
          'both role refusals are kept, since the phone holds a row in the club (G43)');

-- 17–27. Criterion 4 (G46): b003 changed role, recorder (ad03) to mark boat (ad04). Its device d3
-- logs under ad03 up to the marker, and the marker's own seq is the bound. 21 is a text at the
-- marker's own seq under another ULID: a fork the chain verifier will name, which the bound does
-- not refuse, since only what is past the marker is. 22 is a spare device under the same admission,
-- which the first device's marker does not bound.
set local role authenticated;
select pg_temp.as_phone('00000000-0000-0000-0000-00000000b003');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad03'), 'recorder', pg_temp.id('d3'), 1, '01J80000000000000000000731')) ->> 'outcome',
          'accepted', 'before any marker, an event under the superseded admission is accepted');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad03'), 'recorder', pg_temp.id('d3'), 2, '01J80000000000000000000732', 'admission.superseded')) ->> 'outcome',
          'accepted', 'the role-change marker itself, under the old admission, is accepted');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad03'), 'recorder', pg_temp.id('d3'), 3, '01J80000000000000000000733')) ->> 'reason',
          'admission_superseded', 'an event under the old admission past the marker is refused as admission_superseded');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad03'), 'recorder', pg_temp.id('d3'), 1, '01J80000000000000000000731'))
            - 'hash',
          '{"outcome": "accepted", "duplicate": true}'::jsonb,
          'a re-send of the event accepted before the marker is still a no-op, not a refusal');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad03'), 'recorder', pg_temp.id('d3'), 2, '01J80000000000000000000735')) ->> 'outcome',
          'accepted', 'an event at the marker''s own seq is not past it, so the bound does not refuse it');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad03'), 'recorder', pg_temp.id('d3b'), 3, '01J80000000000000000000736')) ->> 'outcome',
          'accepted', 'a spare device under the same superseded admission is not bounded by the first device''s marker');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad04'), 'mark_boat', pg_temp.id('d3'), 4, '01J80000000000000000000734')) ->> 'outcome',
          'accepted', 'an event under the new admission, in its role, is accepted');
select pg_temp.as_phone('00000000-0000-0000-0000-00000000b004');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad06'), 'scorer', pg_temp.id('d4'), 7, '01J80000000000000000000747')) ->> 'outcome',
          'accepted', 'with no marker stored, an event under a superseded admission is accepted');
reset role;
select is(array(select right(l.device_id, 2) || ' seq ' || l.seq || ' ' || right(l.admission_id::text, 4) from public.event_log l
                where l.device_id in (pg_temp.id('d3'), pg_temp.id('d3b'), pg_temp.id('d4')) order by l.device_id, l.seq, l.ulid),
          array['31 seq 1 ad03', '31 seq 2 ad03', '31 seq 2 ad03', '31 seq 4 ad04', '32 seq 3 ad03', '41 seq 7 ad06'],
          'the log holds the events up to the marker, the marker and its fork, the spare device''s, and the new admission''s; not the one past the marker');
select is((select r.reason from public.event_refusal r where r.device_id = pg_temp.id('d3') and r.seq = 3),
          'admission_superseded', 'the refusal past the marker is kept with its reason');
select is((select count(*) from public.event_refusal r where r.device_id = pg_temp.id('d3')), 1::bigint,
          'and the re-send left no refusal record');

-- 28–40. The device-handoff link: b006 is the same phone as b005, signed in again and admitted
-- again as scorer. The events it logged under b005's admission (ad08) are the writer's; another
-- slot's admission, or a revoked user's, is not. The slot is role and race area: b009 and b010 are
-- both recorders on Alpha, b007 on Bravo, b002 a mark boat on Alpha. 29 and 30: once ad08 is
-- revoked, a re-send of the event accepted through it is still a no-op, which only the re-send
-- check can say (the insert trigger is never reached), so a rule tightening after acceptance never
-- turns a retry into a refusal. 34: the named row must be on this race day, even when its user's
-- active row here is in the caller's slot. 37: a slot the caller held and left (b003's superseded
-- recorder row) does not count. 38 and 39: the slot matched is the named admission's lineage head,
-- b011's active mark boat row, not the named row's own. 40: a user with a revoked admission on the
-- race day is no target, whichever of its rows is named.
set local role authenticated;
select pg_temp.as_phone('00000000-0000-0000-0000-00000000b006');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad08'), 'scorer', pg_temp.id('d6'), 1, '01J80000000000000000000761')) ->> 'outcome',
          'accepted', 'an event naming another user''s admission of the race day in the caller''s own slot is accepted');
reset role;
update public.committee_device set revoked_at = now() where id = pg_temp.id('ad08')::uuid;
set local role authenticated;
select pg_temp.as_phone('00000000-0000-0000-0000-00000000b006');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad08'), 'scorer', pg_temp.id('d6'), 1, '01J80000000000000000000761'))
            - 'hash',
          '{"outcome": "accepted", "duplicate": true}'::jsonb,
          'a re-send of that event after the linked admission was revoked is still a no-op, not a refusal');
reset role;
select is((select count(*) from public.event_refusal r where r.device_id = pg_temp.id('d6') and r.seq = 1), 0::bigint,
          'and it left no refusal record');
set local role authenticated;
select pg_temp.as_phone('00000000-0000-0000-0000-00000000b006');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad10'), 'recorder', pg_temp.id('d6'), 2, '01J80000000000000000000762')) ->> 'reason',
          'admission_mismatch', 'one naming another user''s admission in a slot the caller does not hold is refused');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad11'), 'scorer', pg_temp.id('d6'), 3, '01J80000000000000000000763')) ->> 'reason',
          'admission_mismatch', 'and one naming a revoked admission of the slot is refused');
select pg_temp.as_phone('00000000-0000-0000-0000-00000000b009');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad13'), 'recorder', pg_temp.id('d9'), 1, '01J80000000000000000000791')) ->> 'outcome',
          'accepted', 'a recorder on Alpha may write under another recorder-on-Alpha admission');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad19'), 'scorer', pg_temp.id('d9'), 5, '01J80000000000000000000795')) ->> 'reason',
          'admission_mismatch', 'but not under that user''s admission to another race day, though their active row here shares the slot');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad10'), 'recorder', pg_temp.id('d9'), 2, '01J80000000000000000000792')) ->> 'reason',
          'admission_mismatch', 'but not under a recorder-on-Bravo one: the race area is part of the slot');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad02'), 'mark_boat', pg_temp.id('d9'), 3, '01J80000000000000000000793')) ->> 'reason',
          'admission_mismatch', 'nor under a mark-boat-on-Alpha one: the role is part of the slot');
select pg_temp.as_phone('00000000-0000-0000-0000-00000000b003');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad12'), 'recorder', pg_temp.id('d3'), 5, '01J80000000000000000000737')) ->> 'reason',
          'admission_mismatch', 'a mark boat that was Alpha''s recorder earlier that day may not write under a recorder-on-Alpha admission');
select pg_temp.as_phone('00000000-0000-0000-0000-00000000b002');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad14'), 'recorder', pg_temp.id('d2'), 4, '01J80000000000000000000724')) ->> 'outcome',
          'accepted', 'a mark boat on Alpha may write under another user''s superseded recorder admission whose successor is a mark boat on Alpha');
select pg_temp.as_phone('00000000-0000-0000-0000-00000000b009');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad14'), 'recorder', pg_temp.id('d9'), 4, '01J80000000000000000000794')) ->> 'reason',
          'admission_mismatch', 'and a recorder on Alpha may not, though the named row itself was one: the lineage head is what counts');
select pg_temp.as_phone('00000000-0000-0000-0000-00000000b013');
select is(pg_temp.try_append(pg_temp.id('e01')::uuid, pg_temp.ev(pg_temp.id('ad16'), 'scorer', pg_temp.id('d13'), 1, '01J80000000000000000000813')) ->> 'reason',
          'admission_mismatch', 'a user holding a revoked admission on the race day is no target, even through its earlier unrevoked row');

-- 41–44. What the records say, and what a phone reads.
reset role;
select is((select jsonb_object_agg(s.reason, s.n) from (select r.reason, count(*) as n from public.event_refusal r
                                                        where r.event_id = pg_temp.id('e01')::uuid group by r.reason) s),
          '{"admission_mismatch": 12, "role_mismatch": 2, "admission_superseded": 1}'::jsonb,
          'service_role''s view of this file''s refusals: twelve admission, two role, one superseded');
select is((select l.admission_id::text from public.event_log l where l.ulid = '01J80000000000000000000761'),
          pg_temp.id('ad08'), 'an event accepted through the link is attributed to the admission it names, never rewritten');
set local role authenticated;
select pg_temp.as_phone('00000000-0000-0000-0000-00000000b001');
select is(pg_temp.read_admission('01J80000000000000000000711'),
          pg_temp.id('ad01'), 'a phone reads the admission column of its race day''s log');
select lives_ok($$select * from public.event_log where event_id = '00000000-0000-0000-0000-000000000e01'$$,
                'and its select * is not refused by the new column');

-- 45–47. The reason check is a real check: an eighth category is refused, and the three new ones
-- landed above as rows.
reset role;
select throws_ok($$insert into public.event_refusal (event_id, canonical, event_hash, reason, auth_uid)
                   values ('00000000-0000-0000-0000-000000000e01', 'x', 'x', 'something_else', '00000000-0000-0000-0000-00000000b001')$$,
                 '23514', null, 'a reason outside the seven categories is refused by the check');
select is((select count(distinct r.reason) from public.event_refusal r
           where r.reason in ('admission_mismatch', 'role_mismatch', 'admission_superseded')), 3::bigint,
          'each of the three new categories was stored');
select is((select count(*) from public.event_log l where l.event_id in (pg_temp.id('e01')::uuid, pg_temp.id('e03')::uuid)),
          12::bigint, 'the log holds exactly the twelve accepted events of this file');

select * from finish();
rollback;
