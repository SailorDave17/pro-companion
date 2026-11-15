-- 20261115000100_chain_verification.sql
-- pro-companion #62 (held H29; groom decisions G37 and G44): the shore verifier. The server
-- classifies each device's chain on a race day as intact, gapped or broken, says where it refused an
-- event, and attributes each event to the admission it was written under, so a protest committee can
-- tell a far mark's lagging log from an altered one.
--
-- docs/event-chain.md is the specification, and fixtures/chain/ holds the vectors this verifier is
-- held to, beside the phone's core (packages/core/lib/src/chain.dart) and burgee:
--
-- - An event's hash is recomputed here from the canonical text the log stores, never read from a
--   column or a re-serialisation of one.
-- - A refusal stub (#60: the device, the number and the refused text's hash in event_refusal) fills
--   its number with its hash, so a refused event is never read as a gap (G37, "refused at N").
-- - The chain is per device, not per admission: a re-admission (#70) changes the admission_id the
--   device's later events carry and the chain runs on across it. Attribution is per event (G44).
-- - Each race day is verified on its own, as on the phone (#67).
--
-- Owner decisions at pickup (2026-11-15): the verdict counts from seq 1, as the specification and the
-- vectors do, so a phone whose events from before its admission never reached shore (#64) reads
-- gapped; beside it each device reports the lowest number held and how many are missing above it.
-- A device's status is its worst: broken, gapped, refused, intact (the order #67's committee log
-- uses), and every refused number is listed whatever the status.
--
-- Who reads it: a phone admitted to the race day, and service_role (the owner's tooling). The two
-- readers are security definer, because a phone may read only its own committee_device row (#39)
-- and attribution needs every admission's role and race area; so they check the caller themselves
-- and refuse anyone else with 42501. They return the chain's facts and never an event's text.
--
-- A new file, never an edit of an applied one. Every statement is re-runnable against the schema
-- this file creates.

-- The verdict for one device -------------------------------------------------------------------------
-- verifyChain's rule, statement for statement. Events and stubs are read by sequence number; at one
-- number a stub comes before an event, stubs among themselves by hash and events by ULID, both in
-- code-unit order (collate "C"), so two holding one number are named the same way by every verifier.
-- A stub whose hash is an event's held at its number is that event, refused, and is read once.
-- No client role may call it: the readers below call it after their own check.

create or replace function public.chain_verdict(p_event uuid, p_device text)
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  c_genesis constant text := repeat('0', 64);
  r         record;
  v_first   boolean := true;
  v_gapped  boolean := false;
  v_seq     bigint;
  v_hash    text;
begin
  for r in
    with held as (
      select l.seq, l.ulid, encode(sha256(convert_to(l.canonical, 'UTF8')), 'hex') as hash,
             l.canonical::jsonb ->> 'prev_hash' as prev_hash
      from public.event_log l
      where l.event_id = p_event and l.device_id = p_device
    ), stubs as (
      select distinct f.seq, f.event_hash as hash
      from public.event_refusal f
      where f.event_id = p_event and f.device_id = p_device and f.seq is not null
        and not exists (select 1 from held h where h.seq = f.seq and h.hash = f.event_hash)
    ), links as (
      select h.seq, h.ulid, h.hash, h.prev_hash, false as refused, h.ulid as tiebreak from held h
      union all
      select s.seq, null, s.hash, null, true, s.hash from stubs s
    )
    select * from links
    order by seq, refused desc, tiebreak collate "C"
  loop
    if not r.refused then
      if r.prev_hash is null then
        return jsonb_build_object('verdict', 'broken', 'at_seq', r.seq, 'at_ulid', r.ulid,
                                  'reason', 'it carries no previous hash');
      end if;
      if r.seq > 1 and r.prev_hash = c_genesis then
        return jsonb_build_object('verdict', 'broken', 'at_seq', r.seq, 'at_ulid', r.ulid,
                                  'reason', format('it claims to start the chain at seq %s: the events before '
                                                   'it were removed and it was re-linked', r.seq));
      end if;
    end if;

    if v_first then
      if not r.refused and r.seq = 1 and r.prev_hash <> c_genesis then
        return jsonb_build_object('verdict', 'broken', 'at_seq', r.seq, 'at_ulid', r.ulid,
                                  'reason', 'the first event does not start from genesis');
      end if;
      if r.seq > 1 then
        v_gapped := true;
      end if;
      v_first := false;
    elsif r.seq = v_seq then
      return jsonb_build_object('verdict', 'broken', 'at_seq', r.seq, 'at_ulid', r.ulid,
                                'reason', format('two events hold seq %s: the chain forks there', r.seq));
    elsif r.refused then
      -- A stub's own link cannot be checked: it has no previous hash. Only the number it fills
      -- counts, and the event after it is checked against its hash.
      if r.seq <> v_seq + 1 then
        v_gapped := true;
      end if;
    elsif r.seq = v_seq + 1 then
      if r.prev_hash <> v_hash then
        return jsonb_build_object('verdict', 'broken', 'at_seq', r.seq, 'at_ulid', r.ulid, 'after_seq', v_seq,
                                  'reason', format('its previous hash is not seq %s''s: one of the two was '
                                                   'altered', v_seq));
      end if;
    else
      v_gapped := true;
      if r.prev_hash = v_hash then
        return jsonb_build_object('verdict', 'broken', 'at_seq', r.seq, 'at_ulid', r.ulid, 'after_seq', v_seq,
                                  'reason', format('it links straight to seq %s across missing seqs: an event '
                                                   'was removed and the chain re-linked', v_seq));
      end if;
    end if;
    v_seq := r.seq;
    v_hash := r.hash;
  end loop;
  return jsonb_build_object('verdict', case when v_gapped then 'gapped' else 'intact' end);
end;
$$;

revoke execute on function public.chain_verdict(uuid, text) from public, anon, authenticated, service_role;

comment on function public.chain_verdict(uuid, text) is
  'The verdict on one device''s chain on one race day (#62): intact, gapped or broken, with the break '
  'point (at_seq, at_ulid, after_seq) and the reason. docs/event-chain.md is the rule, and it reads '
  'refusal stubs in their events'' places. Hashes are recomputed from the stored canonical text. No '
  'client role may call it; chain_verification and chain_attribution are the readers.';

-- Who may read ------------------------------------------------------------------------------------------

create or replace function public.chain_reader_check(p_event uuid)
returns void
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return;
  end if;
  if not public.is_admitted_to_event(p_event) then
    raise exception 'chain verification: the caller is not admitted to this race day'
      using errcode = '42501';
  end if;
end;
$$;

revoke execute on function public.chain_reader_check(uuid) from public, anon, authenticated, service_role;

comment on function public.chain_reader_check(uuid) is
  'Refuses with 42501 a caller who is neither service_role nor a phone admitted to the race day (#62 '
  'criterion 4). Called by chain_verification and chain_attribution; no client role may call it.';

-- Each device's status ------------------------------------------------------------------------------

create or replace function public.chain_verification(p_event uuid)
returns table (
  device_id    text,
  status       text,
  verdict      text,
  at_seq       bigint,
  at_ulid      text,
  after_seq    bigint,
  reason       text,
  lowest_seq   bigint,
  highest_seq  bigint,
  missing      bigint,
  refused_seqs bigint[]
)
language plpgsql stable security definer
set search_path = ''
as $$
begin
  perform public.chain_reader_check(p_event);
  return query
    with numbers as (
      select l.device_id as device, l.seq from public.event_log l where l.event_id = p_event
      union
      select f.device_id, f.seq from public.event_refusal f
      where f.event_id = p_event and f.device_id is not null and f.seq is not null
    ), devices as (
      select n.device, min(n.seq) as lowest, max(n.seq) as highest, count(distinct n.seq) as held
      from numbers n group by n.device
    ), judged as (
      select d.*, public.chain_verdict(p_event, d.device) as v,
             array(select distinct f.seq from public.event_refusal f
                   where f.event_id = p_event and f.device_id = d.device and f.seq is not null
                   order by f.seq) as refused
      from devices d
    )
    select j.device,
           case when j.v ->> 'verdict' <> 'intact' then j.v ->> 'verdict'
                when cardinality(j.refused) > 0 then 'refused'
                else 'intact' end,
           j.v ->> 'verdict',
           (j.v ->> 'at_seq')::bigint,
           j.v ->> 'at_ulid',
           (j.v ->> 'after_seq')::bigint,
           j.v ->> 'reason',
           j.lowest,
           j.highest,
           j.highest - j.lowest + 1 - j.held,
           j.refused
    from judged j
    order by j.device collate "C";
end;
$$;

revoke execute on function public.chain_verification(uuid) from public, anon;
grant  execute on function public.chain_verification(uuid) to authenticated, service_role;

comment on function public.chain_verification(uuid) is
  'Each device''s chain on a race day (#62). status is the worst that applies: broken, gapped, refused, '
  'intact. verdict is the chain''s own, counted from seq 1 as docs/event-chain.md does, with the break '
  'point and its reason when broken. lowest_seq and highest_seq are the numbers held (events and refusal '
  'stubs), missing how many between them are not, and refused_seqs every number the server refused. '
  'Readable by a phone admitted to the race day and by service_role; anyone else is refused (42501).';

-- Each event's admission ------------------------------------------------------------------------------

create or replace function public.chain_attribution(p_event uuid)
returns table (
  device_id    text,
  seq          bigint,
  ulid         text,
  admission_id uuid,
  role         text,
  course_id    uuid
)
language plpgsql stable security definer
set search_path = ''
as $$
begin
  perform public.chain_reader_check(p_event);
  return query
    select l.device_id, l.seq, l.ulid, l.admission_id, d.role, d.course_id
    from public.event_log l
    left join public.committee_device d on d.id = l.admission_id and d.event_id = l.event_id
    where l.event_id = p_event
    order by l.device_id collate "C", l.seq, l.ulid collate "C";
end;
$$;

revoke execute on function public.chain_attribution(uuid) from public, anon;
grant  execute on function public.chain_attribution(uuid) to authenticated, service_role;

comment on function public.chain_attribution(uuid) is
  'Each event in a race day''s log with the admission it was written under, and that admission''s role '
  'and race area (#62 criterion 3, G44). A device''s chain runs across its admissions; this says which '
  'one each event belongs to. Readable by a phone admitted to the race day and by service_role; anyone '
  'else is refused (42501).';
