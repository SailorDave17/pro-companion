-- 20260925000200_six_committee_roles.sql
-- pro-companion #57, groom decision G28: the committee's six roles. overall_pro, course_pro,
-- recorder, mark_boat, safety and scorer. The signal boat is the PRO, so there is no signal_boat
-- role, and #39's pro becomes overall_pro. G38 binds course_pro, recorder and mark_boat to one race
-- area; that binding lands with the admission-code story (#65). The roles are listed in
-- docs/roles.md.
--
-- A new file, never an edit of the applied spine. Every statement is re-runnable against the schema
-- this file creates.

-- #39's inline check refuses every new role name, so it goes first.
alter table public.committee_device drop constraint if exists committee_device_role_check;

-- Every pro admission becomes overall_pro. An overall PRO may write any critical kind (G29), so no
-- admission loses a privilege. The count goes to the migration's output: psql and the Supabase CLI
-- print it, while the Management API's query route drops notices, so a live apply reads the count
-- before and after instead.
do $$
declare
  v_changed integer;
begin
  update public.committee_device set role = 'overall_pro' where role = 'pro';
  get diagnostics v_changed = row_count;
  raise notice 'committee_device: % row(s) changed from pro to overall_pro', v_changed;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'committee_device_role_g28_check'
                   and conrelid = 'public.committee_device'::regclass) then
    alter table public.committee_device
      add constraint committee_device_role_g28_check
      check (role in ('overall_pro', 'course_pro', 'recorder', 'mark_boat', 'safety', 'scorer'));
  end if;
end;
$$;

comment on column public.committee_device.role is
  'The committee role this admission grants (groom decision G28; docs/roles.md). course_pro, recorder '
  'and mark_boat are bound to one race area (G38, from #65); overall_pro, scorer and safety are '
  'event-wide.';
