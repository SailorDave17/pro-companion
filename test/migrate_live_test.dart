import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../scripts/migrate_live.dart' as script;

/// #44: scripts/migrate_live.dart keeps the live project's migration history in step with
/// supabase/migrations/. These tests hold the parts that decide what runs and what is recorded;
/// the live read-backs are the evidence that the Management API honours them.
void main() {
  const spine = script.Migration('20260924000100', 'committee_spine');
  const next = script.Migration('20260924000200', 'label_migration_history');

  group('local migrations', () {
    test('are read oldest first, and anything that is not .sql is ignored', () {
      final local = script.localMigrations(
          ['20260924000200_label_migration_history.sql', 'README.md', '20260924000100_committee_spine.sql']);
      expect(local.map((m) => m.fileName),
          ['20260924000100_committee_spine.sql', '20260924000200_label_migration_history.sql']);
    });

    test('a .sql file with a malformed name is refused, not skipped', () {
      expect(() => script.localMigrations(['2026-09-24_spine.sql']), throwsFormatException);
    });

    test('two files with one version are refused', () {
      expect(() => script.localMigrations(['20260924000100_a.sql', '20260924000100_b.sql']),
          throwsFormatException);
    });

    test("this repo's own migrations all parse", () {
      final names = Directory(script.migrationsDir)
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last);
      expect(script.localMigrations(names), isNotEmpty);
    });

    test('a migration is read with the line endings git stores, whatever the checkout', () {
      expect(script.committedLineEndings('a;\r\nb;\r\n'), 'a;\nb;\n');
      // On a Windows checkout under core.autocrlf this file is CRLF on disk.
      expect(script.readMigration(spine), isNot(contains('\r')));
    });
  });

  group('the plan', () {
    test('after the repair only the new file is pending', () {
      final plan = script.planFor([spine, next], {'20260924000100'});
      expect(plan.applied.map((m) => m.version), ['20260924000100']);
      expect(plan.pending.map((m) => m.version), ['20260924000200']);
      expect(plan.remoteOnly, isEmpty);
    });

    test('pending files come oldest first', () {
      final plan = script.planFor([spine, next], {});
      expect(plan.pending.map((m) => m.version), ['20260924000100', '20260924000200']);
    });

    test('a recorded version with no file here is reported', () {
      final plan = script.planFor([spine], {'20260924000100', '20260101000000'});
      expect(plan.remoteOnly, ['20260101000000']);
    });
  });

  group('the SQL', () {
    const body = 'create table t (id int);\n'
        'create function f() returns void language plpgsql as \$\$\nbegin\n  perform 1;\nend;\n\$\$;\n';

    test('apply runs the file and its history row in one transaction', () {
      final sql = script.applySql(next, body);
      expect(sql, startsWith('begin;\n$body'));
      expect(sql.trimRight(), endsWith('commit;'));
      expect(sql, contains("values ('20260924000200', 'label_migration_history', array[\$migration\$$body\$migration\$]);"));
    });

    test('a plpgsql begin/end block is not mistaken for transaction control', () {
      expect(() => script.applySql(next, body), returnsNormally);
    });

    test('a file that controls its own transaction is refused', () {
      expect(() => script.applySql(next, 'begin;\ncreate table t (id int);\ncommit;\n'),
          throwsArgumentError);
      expect(() => script.applySql(next, 'create table t (id int);\nCOMMIT ;\n'), throwsArgumentError);
    });

    test('record creates the history table and runs nothing from the file', () {
      final sql = script.recordSql(spine, body);
      expect(sql, contains(script.historyDdl));
      // The file text appears only inside the quoted history row, never as a statement.
      final outsideTheRow = sql.replaceFirst('\$migration\$$body\$migration\$', '');
      expect(outsideTheRow, isNot(contains('create table t')));
      expect(outsideTheRow, contains("values ('20260924000100', 'committee_spine', array[]);"));
    });

    test('the history table is the CLI 2.117.0 shape: version key, statements, name', () {
      expect(script.historyDdl, contains('schema_migrations (version text not null primary key)'));
      expect(script.historyDdl, contains('add column if not exists statements text[]'));
      expect(script.historyDdl, contains('add column if not exists name text'));
    });

    test('the quote tag is one the text does not contain', () {
      final quoted = script.dollarQuoted('a \$migration\$ b');
      expect(quoted, startsWith('\$migration1\$'));
      expect(quoted, endsWith('\$migration1\$'));
    });
  });

  group('the token', () {
    test('the shell comes before .env.local, and either name works', () {
      // The same name on both sides, so only the shell-first rule can pick the answer.
      expect(script.resolveToken({'SUPPABASE_TOKEN': 'shell'}, {'SUPPABASE_TOKEN': 'file'}), 'shell');
      expect(script.resolveToken({}, {'SUPPABASE_TOKEN': 'file'}), 'file');
      expect(script.resolveToken({'SUPABASE_ACCESS_TOKEN': 'cli'}, {}), 'cli');
    });

    test('a missing token names what was looked for and what is there, never a value', () {
      expect(
        () => script.resolveToken({}, {'SUPABASE_URL': 'https://example.invalid'}),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('SUPPABASE_TOKEN'))
            .having((e) => e.message, 'message', contains('SUPABASE_URL'))
            .having((e) => e.message, 'message', isNot(contains('example.invalid')))),
      );
    });

    test('.env.local values lose their quotes and carriage returns', () {
      expect(script.parseEnvFile('# c\nA="x"\r\nB=y\n\nC\n'), {'A': 'x', 'B': 'y'});
    });
  });
}
