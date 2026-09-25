-- 20260924000200_label_migration_history.sql
-- pro-companion #44: the first file applied to the live project by scripts/migrate_live.dart, which
-- runs each migration and records it in the Supabase CLI's history table in one transaction, under
-- the file's own version. Applying this proved that flow: one file ran and the history gained
-- exactly one row. Its one statement labels that table, so anyone reading the database can find
-- the procedure that writes it. Re-runnable: a comment is replaced, never duplicated.

comment on table supabase_migrations.schema_migrations is
  'One row per supabase/migrations file, keyed by the file''s version. On the live project it is '
  'written by scripts/migrate_live.dart through the Management API, in the same transaction as the '
  'file (pro-companion #44; README, Server side). Locally the Supabase CLI writes it.';
