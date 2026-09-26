-- pgTAP tests for append_event and the refusal record (#48; groom decisions G37, G43 and G45): the
-- one client path into the event log, what it refuses and why, which refusals are kept, who can read
-- them (only service_role), and that nobody can change one. Run with `supabase test db` against the
-- local stack; the whole file is one transaction and rolls back.
--
-- Roles are switched the way PostgREST switches them, as in committee_spine_test.sql. What these
-- tests cannot show is the HTTP answer to a refusal and that PostgREST commits the record under it;
-- test/append_event_test.dart holds that against the stack's API.

begin;
create extension if not exists pgtap with schema extensions;
select plan(59);

-- Fixed ids so the file needs no client-side variables.
-- clubs:   …c01 Hoover, …c02 Other
-- events:  …e01 Hoover's club night, …e03 Hoover's second day, …e02 the other club's regatta
-- codes:   e01, e03 and e02 each have an event-wide scorer code, so no race area is needed
-- devices: …aa01 admitted to e01; …aa02 admitted to the other club's e02 only; …aa03 admitted to
--          e01 and revoked; …aa04 admitted to e03 only, in e01's club; …aa05 signed in, never
--          admitted
-- log:     01J8…0481 is the one event stored; 01J8…0482 to 01J8…0489 are each refused or failed

-- 1–5. Criterion 1: append_event is the only client path into the log.
select has_function('public', 'append_event', array['uuid', 'text'], 'append_event(event, canonical) exists');
select ok((select p.prosecdef and p.proconfig = array['search_path=""']
                  and p.proowner = (select relowner from pg_class where oid = 'public.event_log'::regclass)
           from pg_proc p where p.oid = 'public.append_event(uuid, text)'::regprocedure),
          'append_event is security definer, with an empty search_path, owned by the log''s owner');
select ok(has_function_privilege('authenticated', 'public.append_event(uuid, text)', 'execute')
          and not has_function_privilege('anon', 'public.append_event(uuid, text)', 'execute')
          and not has_function_privilege('service_role', 'public.append_event(uuid, text)', 'execute'),
          'a signed-in phone can call append_event, and anon and service_role cannot');
select ok(not has_table_privilege('authenticated', 'public.event_log', 'INSERT')
          and not has_any_column_privilege('authenticated', 'public.event_log', 'INSERT')
          and not has_table_privilege('anon', 'public.event_log', 'INSERT')
          and not has_any_column_privilege('anon', 'public.event_log', 'INSERT')
          and not has_table_privilege('service_role', 'public.event_log', 'INSERT')
          and not has_any_column_privilege('service_role', 'public.event_log', 'INSERT'),
          'no role but the log''s owner holds INSERT on event_log, on the table or any column');
select is(array(select p.proname::text from pg_proc p
                where p.pronamespace = 'public'::regnamespace and p.prosrc like '%event_log%'
                  and (has_function_privilege('authenticated', p.oid, 'execute')
                       or has_function_privilege('anon', p.oid, 'execute'))),
          array['append_event'],
          'append_event is the only function a client can call whose body names the log');

-- 6–10. Criterion 4: the refusal table, which no client role can reach.
select has_table('public', 'event_refusal', 'the refusal table exists');
select columns_are('public', 'event_refusal',
                   array['id', 'event_id', 'canonical', 'event_hash', 'device_id', 'seq', 'reason',
                         'auth_uid', 'refused_at'],
                   'a refusal is its event, bytes, hash, device, sequence, reason, caller and time');
select ok((select relrowsecurity from pg_class where oid = 'public.event_refusal'::regclass),
          'event_refusal has RLS enabled');
select ok(not has_table_privilege('authenticated', 'public.event_refusal', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
          and not has_any_column_privilege('authenticated', 'public.event_refusal', 'SELECT, INSERT, UPDATE, REFERENCES')
          and not has_table_privilege('anon', 'public.event_refusal', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
          and not has_any_column_privilege('anon', 'public.event_refusal', 'SELECT, INSERT, UPDATE, REFERENCES')
          and has_table_privilege('service_role', 'public.event_refusal', 'SELECT')
          and not has_table_privilege('service_role', 'public.event_refusal', 'INSERT, UPDATE, DELETE, TRUNCATE'),
          'no client role holds any privilege on event_refusal, and service_role holds SELECT only');
select is((select count(*) from pg_policy where polrelid = 'public.event_refusal'::regclass), 0::bigint,
          'event_refusal has no policy for any role');

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
select public.issue_admission_code('00000000-0000-0000-0000-000000000e01', 'scorer', 'gull-1234');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e03', 'scorer', 'wren-2468');
select public.issue_admission_code('00000000-0000-0000-0000-000000000e02', 'scorer', 'tern-5678');

-- Canonical texts, keys in RFC 8785 order. The phones read them, so they are granted to
-- authenticated; each call's whole answer is checked, so a refusal by this table would show.
create temp table fx (name text primary key, canonical text not null);
insert into fx values
  ('ok', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190001000,"gps":{"accuracy_m":5,"lat":33.4012,"lon":-86.8123},"kind":"finish","payload":{"fleet":"01J8Z0E0000000000000000001","sail":"12345"},"payload_version":1,"person":"Dana (fixture)","prev_hash":"0000000000000000000000000000000000000000000000000000000000000000","role":"scorer","seq":1,"source":"tap","ulid":"01J80000000000000000000481"}'),
  ('ok-altered', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190001000,"gps":{"accuracy_m":5,"lat":33.4012,"lon":-86.8123},"kind":"finish","payload":{"fleet":"01J8Z0E0000000000000000001","sail":"12346"},"payload_version":1,"person":"Dana (fixture)","prev_hash":"0000000000000000000000000000000000000000000000000000000000000000","role":"scorer","seq":1,"source":"tap","ulid":"01J80000000000000000000481"}'),
  ('revoked', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000003","device_ts":1727190002000,"gps":null,"kind":"note","payload":{"text":"Mark 2 — hold"},"payload_version":1,"person":null,"prev_hash":"93322f023cbc83656fe652883020940402d8508b2e6fcaa0835251db33f56e95","role":"scorer","seq":4,"source":"tap","ulid":"01J80000000000000000000482"}'),
  ('other-day', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000004","device_ts":1727190003000,"gps":null,"kind":"note","payload":{},"payload_version":1,"person":null,"prev_hash":"0000000000000000000000000000000000000000000000000000000000000000","role":"scorer","seq":1,"source":"tap","ulid":"01J80000000000000000000483"}'),
  ('no-kind', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190004000,"gps":null,"payload":{},"payload_version":1,"person":null,"prev_hash":"30c56583a183d822b6d45e7f971e5af35da4bcb63bdafc7ed8fce69202087aa9","role":"scorer","seq":2,"source":"tap","ulid":"01J80000000000000000000484"}'),
  ('seq-not-integer', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190004000,"gps":null,"kind":"note","payload":{},"payload_version":1,"person":null,"prev_hash":"30c56583a183d822b6d45e7f971e5af35da4bcb63bdafc7ed8fce69202087aa9","role":"scorer","seq":"three","source":"tap","ulid":"01J80000000000000000000485"}'),
  ('nul', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190004000,"gps":null,"kind":"note","payload":{"text":"a\u0000b"},"payload_version":1,"person":null,"prev_hash":"30c56583a183d822b6d45e7f971e5af35da4bcb63bdafc7ed8fce69202087aa9","role":"scorer","seq":2,"source":"tap","ulid":"01J80000000000000000000486"}'),
  ('not-json', 'not json'),
  ('array', '["01J80000000000000000000481"]'),
  ('stranger', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000002","device_ts":1727190005000,"gps":null,"kind":"note","payload":{},"payload_version":1,"person":null,"prev_hash":"0000000000000000000000000000000000000000000000000000000000000000","role":"scorer","seq":1,"source":"tap","ulid":"01J80000000000000000000487"}'),
  ('transient', '{"corrects_ulid":null,"device_id":"01J8Z0D0000000000000000001","device_ts":1727190006000,"gps":null,"kind":"note","payload":{},"payload_version":1,"person":null,"prev_hash":"30c56583a183d822b6d45e7f971e5af35da4bcb63bdafc7ed8fce69202087aa9","role":"scorer","seq":2,"source":"tap","ulid":"01J80000000000000000000489"}');
grant select on fx to authenticated;

-- Admit the phones.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa01","role":"authenticated","is_anonymous":true}', true);
select public.admit_device('00000000-0000-0000-0000-000000000e01', 'gull-1234');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa02","role":"authenticated","is_anonymous":true}', true);
select public.admit_device('00000000-0000-0000-0000-000000000e02', 'tern-5678');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa03","role":"authenticated","is_anonymous":true}', true);
select public.admit_device('00000000-0000-0000-0000-000000000e01', 'gull-1234');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa04","role":"authenticated","is_anonymous":true}', true);
select public.admit_device('00000000-0000-0000-0000-000000000e03', 'wren-2468');
reset role;
select public.revoke_device((select id from public.committee_device
                             where auth_uid = '00000000-0000-0000-0000-00000000aa03'));

-- 11–15. Criteria 1 and 5: an admitted phone's event is stored exactly as #40 defines it, and a
-- re-send is a no-op, not a refusal.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa01","role":"authenticated","is_anonymous":true}', true);
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'ok')),
          '{"outcome": "accepted", "duplicate": false,
            "hash": "30c56583a183d822b6d45e7f971e5af35da4bcb63bdafc7ed8fce69202087aa9"}'::jsonb,
          'an admitted phone''s event is accepted, with the hash of its bytes');
select is(current_setting('response.status', true), null,
          'and answered with no error status');
reset role;
select ok((select l.canonical = f.canonical and l.event_id = '00000000-0000-0000-0000-000000000e01'
                  and l.kind = 'finish' and l.seq = 1 and l.person = 'Dana (fixture)' and l.received_at = now()
           from public.event_log l, fx f where l.ulid = '01J80000000000000000000481' and f.name = 'ok'),
          'it is stored as #40 defines it: the bytes as sent, typed columns from them, the server''s time');
set local role authenticated;
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'ok')),
          '{"outcome": "accepted", "duplicate": true,
            "hash": "30c56583a183d822b6d45e7f971e5af35da4bcb63bdafc7ed8fce69202087aa9"}'::jsonb,
          'a re-send of a stored event is accepted as a duplicate');
reset role;
select is((select count(*) from public.event_log where ulid = '01J80000000000000000000481')
          + (select count(*) from public.event_refusal
             where event_id in ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000e03')),
          1::bigint,
          'the log holds it once, and the re-send left no refusal record');

-- 16–18. Criteria 2 and 6: a revoked phone is refused, and the refusal is kept with its bytes. The
-- answer carries its reason, and the error status PostgREST sends (test/append_event_test.dart).
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa03","role":"authenticated","is_anonymous":true}', true);
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'revoked')),
          '{"outcome": "refused", "reason": "revoked", "code": "append_event_refused",
            "message": "append_event refused the event: revoked", "details": "revoked",
            "hash": "1a8074be5e2719b0bf9f488536b45261a4b16b7252f8cea1d438b2f84701d212"}'::jsonb,
          'a revoked phone''s event is refused as revoked, with the reason in details');
select is(current_setting('response.status', true), '422', 'and answered with status 422');
reset role;
select is((select jsonb_build_object('event_id', r.event_id, 'bytes', r.canonical = f.canonical,
                                     'event_hash', r.event_hash, 'device_id', r.device_id, 'seq', r.seq,
                                     'reason', r.reason, 'auth_uid', r.auth_uid, 'now', r.refused_at = now())
           from public.event_refusal r, fx f
           where r.reason = 'revoked' and f.name = 'revoked'),
          '{"event_id": "00000000-0000-0000-0000-000000000e01", "bytes": true,
            "event_hash": "1a8074be5e2719b0bf9f488536b45261a4b16b7252f8cea1d438b2f84701d212",
            "device_id": "01J8Z0D0000000000000000003", "seq": 4, "reason": "revoked",
            "auth_uid": "00000000-0000-0000-0000-00000000aa03", "now": true}'::jsonb,
          'the record keeps the bytes as sent, their hash over UTF-8, device, sequence, reason, caller and time');

-- 19–20. Criterion 2: a phone of the club admitted only to another of its events is refused as
-- not admitted, and kept.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa04","role":"authenticated","is_anonymous":true}', true);
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'other-day'))
            ->> 'reason',
          'not_admitted', 'a phone admitted only to the club''s other day is refused as not admitted');
reset role;
select is((select array[r.reason, r.auth_uid::text, r.device_id, r.seq::text] from public.event_refusal r
           where r.event_id = '00000000-0000-0000-0000-000000000e01' and r.device_id = '01J8Z0D0000000000000000004'),
          array['not_admitted', '00000000-0000-0000-0000-00000000aa04', '01J8Z0D0000000000000000004', '1'],
          'and its refusal is kept, since it holds a committee_device row in the club');

-- 21–26. Criterion 2: an admitted phone's text that cannot be stored as an event is refused as
-- inconsistent, and kept. device_id and seq are kept where the text yields them.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa01","role":"authenticated","is_anonymous":true}', true);
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'no-kind'))
            ->> 'reason', 'inconsistent_canonical', 'a text with no kind is refused as inconsistent');
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'seq-not-integer'))
            ->> 'reason', 'inconsistent_canonical', 'a text whose seq is not an integer is refused as inconsistent');
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'nul'))
            ->> 'reason', 'inconsistent_canonical', 'a text escaping U+0000 is refused as inconsistent');
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'not-json'))
            ->> 'reason', 'inconsistent_canonical', 'a text that is not JSON is refused as inconsistent');
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'array'))
            ->> 'reason', 'inconsistent_canonical', 'a JSON array is refused as inconsistent');
reset role;
select is((select jsonb_object_agg(f.name, jsonb_build_array(r.device_id, r.seq, r.reason, r.canonical = f.canonical))
           from public.event_refusal r join fx f on f.canonical = r.canonical
           where r.reason = 'inconsistent_canonical'),
          '{"no-kind":         ["01J8Z0D0000000000000000001", 2, "inconsistent_canonical", true],
            "seq-not-integer": ["01J8Z0D0000000000000000001", null, "inconsistent_canonical", true],
            "nul":             [null, null, "inconsistent_canonical", true],
            "not-json":        [null, null, "inconsistent_canonical", true],
            "array":           [null, null, "inconsistent_canonical", true]}'::jsonb,
          'each is kept as sent, with its device and sequence where the text yields them');

-- 27–29. Owner decision on #48: a different text under a stored ULID is refused as ulid_conflict
-- and kept, including the same text sent for another race day.
set local role authenticated;
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'ok-altered'))
            ->> 'reason', 'ulid_conflict', 'an altered event under a stored ULID is refused as ulid_conflict');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa04","role":"authenticated","is_anonymous":true}', true);
select is(public.append_event('00000000-0000-0000-0000-000000000e03', (select canonical from fx where name = 'ok'))
            ->> 'reason', 'ulid_conflict', 'a stored event sent for another race day is refused as ulid_conflict');
reset role;
select is(array(select r.event_id::text || ' ' || f.name from public.event_refusal r join fx f on f.canonical = r.canonical
                where r.reason = 'ulid_conflict' order by f.name),
          array['00000000-0000-0000-0000-000000000e03 ok', '00000000-0000-0000-0000-000000000e01 ok-altered'],
          'both are kept, each under the race day it was sent for');

-- 30. Criterion 2: nothing refused changed the log.
select is(array(select ulid from public.event_log
                where event_id in ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000e03')),
          array['01J80000000000000000000481'],
          'the log still holds the one accepted event');

-- 31–35. Criterion 3 (G43): a caller holding no committee_device row in the club is refused, and
-- nothing is kept. One answer for another club, a stranger, nobody and no such event.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa02","role":"authenticated","is_anonymous":true}', true);
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'stranger'))
            ->> 'reason', 'not_admitted', 'a phone of another club is refused as not admitted');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa05","role":"authenticated","is_anonymous":true}', true);
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'stranger'))
            ->> 'reason', 'not_admitted', 'a phone never admitted is refused as not admitted');
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'stranger'))
            ->> 'reason', 'not_admitted', 'a caller signed in as nobody is refused as not admitted');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa01","role":"authenticated","is_anonymous":true}', true);
select is(public.append_event('00000000-0000-0000-0000-0000000000ee', (select canonical from fx where name = 'stranger'))
            ->> 'reason', 'not_admitted', 'an event that does not exist is refused as not admitted');
reset role;
select is((select count(*) from public.event_refusal r join fx f on f.canonical = r.canonical where f.name = 'stranger'),
          0::bigint, 'and none of the four is kept');

-- 36–37. Criterion 5: a refused event re-sent leaves exactly one refusal record.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa03","role":"authenticated","is_anonymous":true}', true);
select is(public.append_event('00000000-0000-0000-0000-000000000e01', (select canonical from fx where name = 'revoked'))
            ->> 'reason', 'revoked', 'a refused event re-sent is refused again');
reset role;
select is((select count(*) from public.event_refusal
           where event_hash = '1a8074be5e2719b0bf9f488536b45261a4b16b7252f8cea1d438b2f84701d212'), 1::bigint,
          'and leaves exactly one refusal record');

-- 38–40. Criterion 6: a failure append_event did not judge is raised as it is, so the phone retries
-- it, and it is neither kept nor answered as a refusal. A serialization failure stands in for any
-- transient one; the trigger is this transaction's and rolls back with it.
create function public.append_event_test_fail() returns trigger language plpgsql as $$
begin
  if new.canonical::jsonb ->> 'ulid' = '01J80000000000000000000489' then
    raise exception 'a transient failure' using errcode = '40001';
  end if;
  return new;
end;
$$;
create trigger append_event_test_fail before insert on public.event_log
  for each row execute function public.append_event_test_fail();
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000aa01","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.append_event('00000000-0000-0000-0000-000000000e01',
                                              (select canonical from fx where name = 'transient'))$$,
                 '40001', 'a transient failure', 'a transient failure inside append_event is raised as it is');
select throws_ok($$select public.append_event('00000000-0000-0000-0000-000000000e01', null)$$,
                 '22004', 'append_event: no canonical text', 'a call with no text is an error, not a refusal');
reset role;
select is((select count(*) from public.event_refusal r join fx f on f.canonical = r.canonical where f.name = 'transient')
          + (select count(*) from public.event_log where ulid = '01J80000000000000000000489'), 0::bigint,
          'the failed event is neither kept as a refusal nor stored');
drop trigger append_event_test_fail on public.event_log;

-- 41–48. Criterion 4: no client role can select, insert, update or delete a refusal record.
set local role authenticated;
select throws_ok($$select * from public.event_refusal$$, '42501', null, 'an admitted phone cannot read refusals');
select throws_ok($$insert into public.event_refusal (event_id, canonical, event_hash, reason, auth_uid)
                   values ('00000000-0000-0000-0000-000000000e01', 'x', 'x', 'revoked', '00000000-0000-0000-0000-00000000aa01')$$,
                 '42501', null, 'an admitted phone cannot insert a refusal');
select throws_ok($$update public.event_refusal set reason = 'revoked'$$, '42501', null,
                 'an admitted phone cannot update a refusal');
select throws_ok($$delete from public.event_refusal$$, '42501', null, 'an admitted phone cannot delete a refusal');
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$select * from public.event_refusal$$, '42501', null, 'anon cannot read refusals');
select throws_ok($$insert into public.event_refusal (event_id, canonical, event_hash, reason, auth_uid)
                   values ('00000000-0000-0000-0000-000000000e01', 'x', 'x', 'revoked', '00000000-0000-0000-0000-00000000aa01')$$,
                 '42501', null, 'anon cannot insert a refusal');
select throws_ok($$update public.event_refusal set reason = 'revoked'$$, '42501', null, 'anon cannot update a refusal');
select throws_ok($$delete from public.event_refusal$$, '42501', null, 'anon cannot delete a refusal');

-- 49–53. Criterion 4: service_role reads the refusals and never writes them.
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is((select count(*) from public.event_refusal
           where event_id in ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000e03')),
          9::bigint,
          'service_role reads every refusal kept above: 1 revoked, 1 not admitted, 5 inconsistent, 2 conflicts');
select throws_ok($$insert into public.event_refusal (event_id, canonical, event_hash, reason, auth_uid)
                   values ('00000000-0000-0000-0000-000000000e01', 'x', 'x', 'revoked', '00000000-0000-0000-0000-00000000aa01')$$,
                 '42501', null, 'service_role cannot insert a refusal');
select throws_ok($$update public.event_refusal set reason = 'revoked'$$, '42501', null, 'service_role cannot update a refusal');
select throws_ok($$delete from public.event_refusal$$, '42501', null, 'service_role cannot delete a refusal');
select throws_ok($$truncate public.event_refusal$$, '42501', null, 'service_role cannot truncate the refusals');

-- 54–59. Owner decision on #48 (G45): the refusals are append-only for every role, like the log.
reset role;
select throws_ok($$update public.event_refusal set reason = 'revoked'$$, 'P0001',
                 'event_refusal is append-only: UPDATE refused', 'the table owner cannot update a refusal');
select throws_ok($$update public.event_refusal set reason = 'revoked' where false$$, 'P0001',
                 'event_refusal is append-only: UPDATE refused', 'even an update that matches no row is refused');
select throws_ok($$delete from public.event_refusal$$, 'P0001',
                 'event_refusal is append-only: DELETE refused', 'the table owner cannot delete a refusal');
select throws_ok($$truncate public.event_refusal$$, 'P0001',
                 'event_refusal is append-only: TRUNCATE refused', 'the table owner cannot truncate the refusals');
set local session_replication_role = replica;
select throws_ok($$delete from public.event_refusal$$, 'P0001',
                 'event_refusal is append-only: DELETE refused', 'replica mode does not skip the refusal');
set local session_replication_role = origin;
select is(array(select tgname::text || ':' || tgenabled::text from pg_trigger
                where tgrelid = 'public.event_refusal'::regclass and not tgisinternal order by tgname),
          array['event_refusal_no_delete:A', 'event_refusal_no_truncate:A', 'event_refusal_no_update:A'],
          'the three refusals are enabled always');

select * from finish();
rollback;
