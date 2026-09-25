-- pgTAP tests for the event log (#40): the append-only table every committee event is stored in, its
-- envelope columns generated from the canonical text, the receipt time, the re-send rule, and who
-- may change a row (nobody). Run with `supabase test db` against the local stack; the whole file is
-- one transaction and rolls back. #28's chain vectors are checked in event_log_vectors_test.sql.
--
-- Rows are inserted as the table owner. That is the role #48's append_event will run as, and until
-- #48 lands no client has an insert path at all. Roles are switched the way PostgREST switches them,
-- as in committee_spine_test.sql.

begin;
create extension if not exists pgtap with schema extensions;
select plan(43);

-- Fixed ids so the file needs no client-side variables.
-- clubs:   …c01 Hoover, …c02 Other
-- events:  …e01 Hoover's club night (gull-1234), …e03 Hoover's second day (wren-9012),
--          …e02 the other club's regatta (tern-5678)
-- devices: …aa01 admitted to e01, …aa02 admitted to e02
-- log:     01J8…0401 to 01J8…0404 are stored on e01; 01J8…0405 is never stored

-- 1–6. The table.
select has_table('public', 'event_log', 'the event log table exists');
select is(array(select attname::text || ' ' || format_type(atttypid, atttypmod) from pg_attribute
                where attrelid = 'public.event_log'::regclass and attnum > 0 and not attisdropped
                order by attnum),
          array['ulid text', 'event_id uuid', 'device_ts bigint', 'device_id text', 'seq bigint', 'person text',
                'role text', 'gps jsonb', 'source text', 'kind text', 'payload_version integer', 'payload jsonb',
                'corrects_ulid text', 'prev_hash text', 'canonical text', 'received_at timestamp with time zone'],
          'the ADR 001 envelope as columns, the canonical text as text, and a receipt time');
select col_is_pk('public', 'event_log', 'ulid', 'the ULID is the primary key');
select is(array(select attname::text from pg_attribute
                where attrelid = 'public.event_log'::regclass and attgenerated = 's' order by attnum),
          array['ulid', 'device_ts', 'device_id', 'seq', 'person', 'role', 'gps', 'source', 'kind',
                'payload_version', 'payload', 'corrects_ulid', 'prev_hash'],
          'every envelope column is generated from the canonical text');
select ok((select relrowsecurity from pg_class where oid = 'public.event_log'::regclass), 'event_log has RLS enabled');
select fk_ok('public', 'event_log', 'event_id', 'public', 'event', 'id', 'every row names the race day whose log it is');

-- Fixture: two clubs and three events (service context: table owner, RLS bypassed).
insert into public.club (id, name) values
  ('00000000-0000-0000-0000-000000000c01', 'Hoover (fixture)'),
  ('00000000-0000-0000-0000-000000000c02', 'Other (fixture)');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Club night', date '2026-09-27', 'gull-1234',
                           '00000000-0000-0000-0000-000000000e01');
select public.create_event('00000000-0000-0000-0000-000000000c01', 'Second day', date '2026-09-28', 'wren-9012',
                           '00000000-0000-0000-0000-000000000e03');
select public.create_event('00000000-0000-0000-0000-000000000c02', 'Their regatta', date '2026-09-27', 'tern-5678',
                           '00000000-0000-0000-0000-000000000e02');

-- Canonical texts, keys in RFC 8785 order. Only the owner reads this table, so no client test can
-- be refused by it instead of by the log.
create temp table fx (name text primary key, canonical text not null);
insert into fx values
  ('full', '{"corrects_ulid":"01J80000000000000000000409","device_id":"01J8Z0D0000000000000000001","device_ts":1727190001000,"gps":{"accuracy_m":5,"lat":33.4012,"lon":-86.8123},"kind":"finish","payload":{"fleet":"01J8Z0E0000000000000000001","sail":"12345"},"payload_version":1,"person":"Dana (fixture)","prev_hash":"93322f023cbc83656fe652883020940402d8508b2e6fcaa0835251db33f56e95","role":"recorder","seq":7,"source":"tap","ulid":"01J80000000000000000000401"}'),
  ('full-altered', '{"corrects_ulid":"01J80000000000000000000409","device_id":"01J8Z0D0000000000000000001","device_ts":1727190001000,"gps":{"accuracy_m":5,"lat":33.4012,"lon":-86.8123},"kind":"finish","payload":{"fleet":"01J8Z0E0000000000000000001","sail":"12346"},"payload_version":1,"person":"Dana (fixture)","prev_hash":"93322f023cbc83656fe652883020940402d8508b2e6fcaa0835251db33f56e95","role":"recorder","seq":7,"source":"tap","ulid":"01J80000000000000000000401"}'),
  ('bare', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190002000,"gps":null,"kind":"note","payload":{"text":"Mark 2 — hold"},"payload_version":1,"person":null,"prev_hash":null,"role":null,"seq":8,"source":"tap","ulid":"01J80000000000000000000402"}'),
  ('start', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190003000,"gps":null,"kind":"start","payload":{"fleet":"01J8Z0E0000000000000000001"},"payload_version":1,"person":null,"prev_hash":"e259853094cbe74261840aa9119c5c9fcaf93b7cc1f791653b89a288c2211af4","role":"overall_pro","seq":9,"source":"race-timer","ulid":"01J80000000000000000000403"}'),
  ('new-kind', '{"admission":"01J80000000000000000000499","corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190004000,"gps":null,"kind":"weather.gust","payload":{"dir_deg":270,"gust_kn":23.5},"payload_version":7,"person":null,"prev_hash":"e259853094cbe74261840aa9119c5c9fcaf93b7cc1f791653b89a288c2211af4","role":"mark_boat","seq":10,"source":"tap","ulid":"01J80000000000000000000404"}'),
  ('no-kind', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190005000,"gps":null,"payload":{},"payload_version":1,"person":null,"prev_hash":"e259853094cbe74261840aa9119c5c9fcaf93b7cc1f791653b89a288c2211af4","role":"overall_pro","seq":11,"source":"tap","ulid":"01J80000000000000000000405"}'),
  ('seq-not-integer', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190005000,"gps":null,"kind":"note","payload":{},"payload_version":1,"person":null,"prev_hash":"e259853094cbe74261840aa9119c5c9fcaf93b7cc1f791653b89a288c2211af4","role":"overall_pro","seq":"three","source":"tap","ulid":"01J80000000000000000000405"}');

-- 7–10. Criteria 1 and 7: an event is stored from its event id and canonical text, and every
-- envelope field lands in its typed column beside the text.
select lives_ok($$insert into public.event_log (event_id, canonical)
                  select '00000000-0000-0000-0000-000000000e01', canonical from fx where name = 'full'$$,
                'an event is stored from its event id and its canonical text alone');
select is((select jsonb_build_object(
             'ulid', ulid, 'event_id', event_id, 'device_ts', device_ts, 'device_id', device_id, 'seq', seq,
             'person', person, 'role', role, 'gps', gps, 'source', source, 'kind', kind,
             'payload_version', payload_version, 'payload', payload, 'corrects_ulid', corrects_ulid,
             'prev_hash', prev_hash)
           from public.event_log where ulid = '01J80000000000000000000401'),
          '{"ulid": "01J80000000000000000000401", "event_id": "00000000-0000-0000-0000-000000000e01",
            "device_ts": 1727190001000, "device_id": "01J8Z0D0000000000000000001", "seq": 7,
            "person": "Dana (fixture)", "role": "recorder", "gps": {"lat": 33.4012, "lon": -86.8123, "accuracy_m": 5},
            "source": "tap", "kind": "finish", "payload_version": 1,
            "payload": {"fleet": "01J8Z0E0000000000000000001", "sail": "12345"},
            "corrects_ulid": "01J80000000000000000000409",
            "prev_hash": "93322f023cbc83656fe652883020940402d8508b2e6fcaa0835251db33f56e95"}'::jsonb,
          'every envelope field of the text lands in its own typed column');
select ok((select l.canonical::text = f.canonical from public.event_log l, fx f
           where l.ulid = '01J80000000000000000000401' and f.name = 'full'),
          'the canonical text is stored exactly as sent');
insert into public.event_log (event_id, canonical)
  select '00000000-0000-0000-0000-000000000e01', canonical from fx where name = 'bare';
select is((select jsonb_build_object('person', person, 'role', role, 'gps', gps, 'gps is sql null', gps is null,
                                     'corrects_ulid', corrects_ulid, 'prev_hash', prev_hash)
           from public.event_log where ulid = '01J80000000000000000000402'),
          '{"person": null, "role": null, "gps": null, "gps is sql null": true, "corrects_ulid": null,
            "prev_hash": null}'::jsonb,
          'a JSON null is SQL NULL in its typed column, gps included');

-- 11. Criterion 5: the database's receipt time is stored, never the writer's.
insert into public.event_log (event_id, canonical, received_at)
  select '00000000-0000-0000-0000-000000000e01', canonical, timestamptz '2000-01-01 00:00:00+00'
  from fx where name = 'start';
select is((select received_at from public.event_log where ulid = '01J80000000000000000000403'), now(),
          'a receipt time the writer supplies (2000-01-01) is ignored, and the database''s is stored');

-- 12–16. Criterion 3: a re-sent event is a no-op; anything else under a stored ULID is refused
-- (owner decision 2026-09-25). rows_inserted answers -1 where the insert errors, so a re-send that
-- errors fails its own test rather than aborting the file.
create function pg_temp.rows_inserted(p_sql text) returns integer language plpgsql as $$
declare
  v_rows integer;
begin
  execute p_sql;
  get diagnostics v_rows = row_count;
  return v_rows;
exception when others then
  return -1;
end;
$$;
select lives_ok($$insert into public.event_log (event_id, canonical)
                  select '00000000-0000-0000-0000-000000000e01', canonical from fx where name = 'full'$$,
                'a re-sent event is not an error');
select is(pg_temp.rows_inserted($$insert into public.event_log (event_id, canonical)
                                  select '00000000-0000-0000-0000-000000000e01', canonical from fx where name = 'full'$$),
          0, 'a re-sent event inserts no row');
select is((select count(*) from public.event_log where ulid = '01J80000000000000000000401'), 1::bigint,
          'and the log still holds the event once');
select throws_ok($$insert into public.event_log (event_id, canonical)
                   select '00000000-0000-0000-0000-000000000e01', canonical from fx where name = 'full-altered'$$,
                 '23505', 'duplicate key value violates unique constraint "event_log_pkey"',
                 'a different body under a stored ULID is refused, not dropped');
select throws_ok($$insert into public.event_log (event_id, canonical)
                   select '00000000-0000-0000-0000-000000000e03', canonical from fx where name = 'full'$$,
                 '23505', 'duplicate key value violates unique constraint "event_log_pkey"',
                 'the same text sent for another race day is refused');

-- 17–18. Criterion 6: a new kind with a new payload version needs no migration, and an envelope
-- field this schema does not know stays in the text.
select lives_ok($$insert into public.event_log (event_id, canonical)
                  select '00000000-0000-0000-0000-000000000e01', canonical from fx where name = 'new-kind'$$,
                'a kind never seen before, at payload version 7, is stored');
select ok((select l.kind = 'weather.gust' and l.payload_version = 7 and l.canonical::text = f.canonical
           from public.event_log l, fx f where l.ulid = '01J80000000000000000000404' and f.name = 'new-kind'),
          'with its kind and version typed, and its unknown admission field kept in the text');

-- 19–22. Criterion 10: no typed column can disagree with the text. A writer names none of them,
-- so it cannot supply a disagreeing value, and a text that cannot fill them is refused.
select throws_ok($$insert into public.event_log (event_id, canonical, kind)
                   select '00000000-0000-0000-0000-000000000e01', canonical, 'start' from fx where name = 'bare'$$,
                 '428C9', 'cannot insert a non-DEFAULT value into column "kind"',
                 'an insert whose kind disagrees with its text is refused');
select throws_ok($$insert into public.event_log (event_id, canonical)
                   select '00000000-0000-0000-0000-000000000e01', canonical from fx where name = 'no-kind'$$,
                 '23502', 'null value in column "kind" of relation "event_log" violates not-null constraint',
                 'a text with no kind is refused');
select throws_ok($$insert into public.event_log (event_id, canonical)
                   values ('00000000-0000-0000-0000-000000000e01', 'not json')$$,
                 '22P02', null, 'a text that is not JSON is refused');
select throws_ok($$insert into public.event_log (event_id, canonical)
                   select '00000000-0000-0000-0000-000000000e01', canonical from fx where name = 'seq-not-integer'$$,
                 '22P02', 'invalid input syntax for type bigint: "three"',
                 'a text whose seq is not an integer is refused');

-- Admit device A to e01 and device B to the other club's e02.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa01","role":"authenticated","is_anonymous":true}', true);
select public.admit_device('00000000-0000-0000-0000-000000000e01', 'recorder', 'gull-1234');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa02","role":"authenticated","is_anonymous":true}', true);
select public.admit_device('00000000-0000-0000-0000-000000000e02', 'recorder', 'tern-5678');

-- 23–29. Criteria 2 and 4: no client writes the log. A phone of another club is refused, and so is
-- a phone admitted to the event: the one client path is #48's append_event, which checks the club.
-- Each insert is a complete, valid event, so nothing but the missing write path can refuse it.
select throws_ok($$insert into public.event_log (event_id, canonical) values ('00000000-0000-0000-0000-000000000e01',
                   '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190005000,"gps":null,"kind":"note","payload":{},"payload_version":1,"person":null,"prev_hash":"e259853094cbe74261840aa9119c5c9fcaf93b7cc1f791653b89a288c2211af4","role":"overall_pro","seq":11,"source":"tap","ulid":"01J80000000000000000000405"}')$$,
                 '42501', null, 'a phone of another club cannot insert into this club''s log');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa01","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$insert into public.event_log (event_id, canonical) values ('00000000-0000-0000-0000-000000000e01',
                   '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190005000,"gps":null,"kind":"note","payload":{},"payload_version":1,"person":null,"prev_hash":"e259853094cbe74261840aa9119c5c9fcaf93b7cc1f791653b89a288c2211af4","role":"overall_pro","seq":11,"source":"tap","ulid":"01J80000000000000000000405"}')$$,
                 '42501', null, 'nor can a phone admitted to the event insert directly');
select throws_ok($$update public.event_log set received_at = now()$$, '42501', null,
                 'an admitted phone cannot update the log');
select throws_ok($$delete from public.event_log$$, '42501', null, 'an admitted phone cannot delete from the log');
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$insert into public.event_log (event_id, canonical) values ('00000000-0000-0000-0000-000000000e01',
                   '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190005000,"gps":null,"kind":"note","payload":{},"payload_version":1,"person":null,"prev_hash":"e259853094cbe74261840aa9119c5c9fcaf93b7cc1f791653b89a288c2211af4","role":"overall_pro","seq":11,"source":"tap","ulid":"01J80000000000000000000405"}')$$,
                 '42501', null, 'anon cannot insert into the log');
select throws_ok($$update public.event_log set received_at = now()$$, '42501', null, 'anon cannot update the log');
select throws_ok($$delete from public.event_log$$, '42501', null, 'anon cannot delete from the log');

-- 30–31. The client refusal has layers, no write grant and no write policy, and either alone
-- refuses with the same code, so each is held from the catalog. The append-only triggers are a
-- third layer, held by 37–42.
reset role;
select ok(has_any_column_privilege('authenticated', 'public.fleet', 'INSERT')
          and not has_table_privilege('authenticated', 'public.event_log', 'INSERT, UPDATE, DELETE, TRUNCATE')
          and not has_any_column_privilege('authenticated', 'public.event_log', 'INSERT, UPDATE')
          and not has_table_privilege('anon', 'public.event_log', 'INSERT, UPDATE, DELETE, TRUNCATE')
          and not has_any_column_privilege('anon', 'public.event_log', 'INSERT, UPDATE'),
          'no client role holds a write privilege on event_log (fleet''s insert grant is the control)');
select is((select count(*) from pg_policy where polrelid = 'public.event_log'::regclass and polcmd <> 'r'), 0::bigint,
          'event_log has no write policy');

-- 32–36. service_role and the owner's tooling read the log and never write it.
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is((select count(*) from public.event_log), 4::bigint, 'service_role reads the whole log');
select throws_ok($$insert into public.event_log (event_id, canonical) values ('00000000-0000-0000-0000-000000000e01',
                   '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190005000,"gps":null,"kind":"note","payload":{},"payload_version":1,"person":null,"prev_hash":"e259853094cbe74261840aa9119c5c9fcaf93b7cc1f791653b89a288c2211af4","role":"overall_pro","seq":11,"source":"tap","ulid":"01J80000000000000000000405"}')$$,
                 '42501', null, 'service_role cannot insert into the log');
select throws_ok($$update public.event_log set received_at = now()$$, '42501', null, 'service_role cannot update the log');
select throws_ok($$delete from public.event_log$$, '42501', null, 'service_role cannot delete from the log');
select throws_ok($$truncate public.event_log$$, '42501', null, 'service_role cannot truncate the log');

-- 37–42. Criterion 2, for every role (owner decision 2026-09-25): the table owner is refused by the
-- append-only triggers, which fire per statement and in replica mode too.
reset role;
select throws_ok($$update public.event_log set received_at = now()$$, 'P0001',
                 'event_log is append-only: UPDATE refused', 'the table owner cannot update the log');
select throws_ok($$update public.event_log set received_at = now() where false$$, 'P0001',
                 'event_log is append-only: UPDATE refused', 'even an update that matches no row is refused');
select throws_ok($$delete from public.event_log$$, 'P0001',
                 'event_log is append-only: DELETE refused', 'the table owner cannot delete from the log');
select throws_ok($$truncate public.event_log$$, 'P0001',
                 'event_log is append-only: TRUNCATE refused', 'the table owner cannot truncate the log');
set local session_replication_role = replica;
select throws_ok($$delete from public.event_log$$, 'P0001',
                 'event_log is append-only: DELETE refused', 'replica mode does not skip the refusal');
set local session_replication_role = origin;
select is(array(select tgname::text || ':' || tgenabled::text from pg_trigger
                where tgrelid = 'public.event_log'::regclass and not tgisinternal order by tgname),
          array['event_log_before_insert:O', 'event_log_no_delete:A', 'event_log_no_truncate:A',
                'event_log_no_update:A'],
          'the three refusals are enabled always; the insert trigger is not, so a restore keeps receipt times');

-- 43. Nothing refused above changed the log.
select is((select count(*) from public.event_log), 4::bigint, 'the log holds the four events stored above');

select * from finish();
rollback;
