// Applies supabase/migrations/ to the companion's live Supabase project through the Management
// API, and records each file in the Supabase CLI's migration history
// (supabase_migrations.schema_migrations) under the file's own version (#44).
//
// Why a script: the Management API's query route runs SQL and never writes that history, and its
// migrations routes write history under a version they choose themselves. Neither keeps the live
// history in step with the files. This does, so "what is applied" is a read, not a memory.
//
//   dart run scripts/migrate_live.dart                    plan: applied, pending, remote-only
//   dart run scripts/migrate_live.dart apply              apply every pending file, oldest first
//   dart run scripts/migrate_live.dart record <version>   record an applied file; runs nothing
//   dart run scripts/migrate_live.dart sql apply <version>    print the SQL apply would send
//   dart run scripts/migrate_live.dart sql record <version>   print the SQL record would send
//
// apply and record write to production: run them only at the owner's go-ahead (README, Server
// side). plan and sql never write.

import 'dart:convert';
import 'dart:io';

const migrationsDir = 'supabase/migrations';
const defaultProjectRef = 'pxywvqhdywgrysmwvbxy';

/// Where the Management API token is looked for, in order: the Supabase CLI's own variable (in
/// your shell), then the name the owner's git-ignored .env.local uses.
const tokenNames = ['SUPABASE_ACCESS_TOKEN', 'SUPPABASE_TOKEN'];

/// The history table exactly as Supabase CLI 2.117.0 creates it, measured on the local stack for
/// #44: three columns, written additively so an existing table is left as it is.
const historyDdl = '''
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (version text not null primary key);
alter table supabase_migrations.schema_migrations add column if not exists statements text[];
alter table supabase_migrations.schema_migrations add column if not exists name text;''';

final migrationFileName = RegExp(r'^(\d{14})_([a-z0-9_]+)\.sql$');

/// A statement that opens or closes a transaction. A plpgsql block's `begin` has no semicolon after
/// it and its `end;` is not listed, so function bodies do not match.
final transactionControl = RegExp(
  r'^\s*(begin|commit|rollback|start\s+transaction)(\s+(work|transaction))?\s*;',
  caseSensitive: false,
  multiLine: true,
);

class Migration {
  const Migration(this.version, this.name);

  final String version;
  final String name;

  String get fileName => '${version}_$name.sql';
}

/// The migrations among [fileNames], oldest first. A .sql file whose name is not
/// `<14 digits>_<snake_case>.sql` is refused rather than skipped, since skipping it would leave
/// it unapplied with nothing saying so.
List<Migration> localMigrations(Iterable<String> fileNames) {
  final out = <Migration>[];
  for (final name in fileNames.where((n) => n.endsWith('.sql'))) {
    final m = migrationFileName.firstMatch(name);
    if (m == null) {
      throw FormatException('not a migration file name (want <14 digits>_<snake_case>.sql)', name);
    }
    out.add(Migration(m.group(1)!, m.group(2)!));
  }
  out.sort((a, b) => a.version.compareTo(b.version));
  for (var i = 1; i < out.length; i++) {
    if (out[i].version == out[i - 1].version) {
      throw FormatException('two migration files share a version', out[i].version);
    }
  }
  return out;
}

class Plan {
  const Plan(this.applied, this.pending, this.remoteOnly);

  final List<Migration> applied;
  final List<Migration> pending;

  /// Versions recorded in the live history with no file here: someone applied a change this repo
  /// does not carry. Nothing is applied while any exist.
  final List<String> remoteOnly;
}

Plan planFor(List<Migration> local, Set<String> recorded) {
  final versions = {for (final m in local) m.version};
  return Plan(
    [for (final m in local) if (recorded.contains(m.version)) m],
    [for (final m in local) if (!recorded.contains(m.version)) m],
    recorded.where((v) => !versions.contains(v)).toList()..sort(),
  );
}

/// [text] as a dollar-quoted literal, with a tag the text does not contain.
String dollarQuoted(String text) {
  var tag = 'migration';
  for (var n = 1; text.contains('\$$tag\$'); n++) {
    tag = 'migration$n';
  }
  return '\$$tag\$$text\$$tag\$';
}

/// The history row for [m]: its version, its name and the file verbatim as the one statement.
String historyRow(Migration m, String sql) =>
    'insert into supabase_migrations.schema_migrations (version, name, statements)\n'
    "values ('${m.version}', '${m.name}', array[${dollarQuoted(sql)}]);";

/// [m] applied and recorded in one transaction, so both land or neither does.
String applySql(Migration m, String sql) {
  if (transactionControl.hasMatch(sql)) {
    throw ArgumentError('${m.fileName} controls its own transaction; apply wraps every file in one');
  }
  return 'begin;\n$sql\n;\n${historyRow(m, sql)}\ncommit;\n';
}

/// [m] recorded as applied without running it, creating the history table if it is missing. For a
/// file already applied by some other route (#39's went through the query route).
String recordSql(Migration m, String sql) => 'begin;\n$historyDdl\n${historyRow(m, sql)}\ncommit;\n';

/// KEY=VALUE lines of an env file; comments and blank lines skipped, quotes and CRs stripped.
Map<String, String> parseEnvFile(String text) {
  final out = <String, String>{};
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    var value = line.substring(eq + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    out[line.substring(0, eq).trim()] = value;
  }
  return out;
}

/// The token from the environment, then the env file. The failure names every variable looked for
/// and every name the file holds, and never a value.
String resolveToken(Map<String, String> environment, Map<String, String> envFile) {
  for (final name in tokenNames) {
    final value = environment[name] ?? envFile[name];
    if (value != null && value.isNotEmpty) return value;
  }
  throw StateError('no Management API token: looked for ${tokenNames.join(' and ')} in the '
      'environment and in .env.local, which names: '
      '${envFile.keys.isEmpty ? '(nothing)' : envFile.keys.join(', ')}');
}

class ApiError implements Exception {
  ApiError(this.status, this.body);

  final int status;
  final String body;

  @override
  String toString() => 'Management API answered $status: $body';
}

class ManagementApi {
  ManagementApi(this.ref, this.token);

  final String ref;
  final String token;

  /// Runs [sql]. [readOnly] is always sent: omitted, the route defaults to a writable connection.
  Future<List<dynamic>> query(String sql, {required bool readOnly}) async {
    final client = HttpClient();
    try {
      final request = await client
          .postUrl(Uri.https('api.supabase.com', '/v1/projects/$ref/database/query'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'query': sql, 'read_only': readOnly}));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode ~/ 100 != 2) throw ApiError(response.statusCode, body);
      final decoded = jsonDecode(body);
      return decoded is List ? decoded : [decoded];
    } finally {
      client.close();
    }
  }

  /// The recorded versions, or null when the history table does not exist.
  Future<Set<String>?> recordedVersions() async {
    final present = await query(
        "select to_regclass('supabase_migrations.schema_migrations') is not null as present",
        readOnly: true);
    if ((present.first as Map)['present'] != true) return null;
    final rows = await query(
        'select version from supabase_migrations.schema_migrations order by version',
        readOnly: true);
    return {for (final r in rows) (r as Map)['version'] as String};
  }
}

/// [text] with the line endings git stores. A Windows checkout under core.autocrlf reads CRLF, and
/// the history must hold the file as committed, not as one machine checked it out (#44: the first
/// record from a Windows worktree stored CRLF bytes, which no other checkout has).
String committedLineEndings(String text) => text.replaceAll('\r\n', '\n');

String readMigration(Migration m) =>
    committedLineEndings(File('$migrationsDir/${m.fileName}').readAsStringSync());

Migration findMigration(List<Migration> local, String version) => local.firstWhere(
    (m) => m.version == version,
    orElse: () => throw ArgumentError('no file in $migrationsDir has version $version'));

ManagementApi connect() {
  final envFile = File('.env.local').existsSync()
      ? parseEnvFile(File('.env.local').readAsStringSync())
      : <String, String>{};
  final environment = Platform.environment;
  final ref = environment['SUPABASE_PROJECT_REF'] ?? envFile['SUPABASE_PROJECT_REF'] ?? defaultProjectRef;
  return ManagementApi(ref, resolveToken(environment, envFile));
}

void printPlan(Plan plan) {
  for (final m in plan.applied) {
    stdout.writeln('applied     ${m.fileName}');
  }
  for (final m in plan.pending) {
    stdout.writeln('pending     ${m.fileName}');
  }
  for (final v in plan.remoteOnly) {
    stdout.writeln('REMOTE ONLY $v (recorded live, no file here)');
  }
}

const usage = 'usage: dart run scripts/migrate_live.dart [plan | apply | record <version> | '
    'sql apply <version> | sql record <version>]';

Future<int> run(List<String> args) async {
  final local = localMigrations(
      Directory(migrationsDir).listSync().whereType<File>().map((f) => f.uri.pathSegments.last));
  final command = args.isEmpty ? 'plan' : args.first;

  switch (command) {
    case 'sql':
      if (args.length != 3 || !{'apply', 'record'}.contains(args[1])) break;
      final m = findMigration(local, args[2]);
      // Bytes, not stdout.write: on Windows stdout encodes with the ANSI code page, and the
      // migrations carry characters it would change.
      stdout.add(utf8.encode(
          args[1] == 'apply' ? applySql(m, readMigration(m)) : recordSql(m, readMigration(m))));
      return 0;

    case 'plan':
      final recorded = await connect().recordedVersions();
      if (recorded == null) {
        stderr.writeln('the live project has no migration history table; record the files '
            'already applied first (README, Server side)');
        return 1;
      }
      final plan = planFor(local, recorded);
      printPlan(plan);
      return plan.remoteOnly.isEmpty ? 0 : 1;

    case 'record':
      if (args.length != 2) break;
      final m = findMigration(local, args[1]);
      final api = connect();
      final before = await api.recordedVersions() ?? <String>{};
      if (before.contains(m.version)) {
        stderr.writeln('${m.version} is already recorded; nothing to do');
        return 1;
      }
      await api.query(recordSql(m, readMigration(m)), readOnly: false);
      final after = await api.recordedVersions() ?? <String>{};
      if (!after.contains(m.version) || after.length != before.length + 1) {
        stderr.writeln('history read back without ${m.version} as its one new row: $after');
        return 1;
      }
      stdout.writeln('recorded    ${m.fileName} (not run); history holds ${after.length}');
      return 0;

    case 'apply':
      if (args.length != 1) break;
      final api = connect();
      final initial = await api.recordedVersions();
      if (initial == null) {
        stderr.writeln('no migration history table on the live project: record the files '
            'already applied first (README, Server side)');
        return 1;
      }
      var recorded = initial;
      final plan = planFor(local, recorded);
      if (plan.remoteOnly.isNotEmpty) {
        printPlan(plan);
        stderr.writeln('refusing: the live history records versions this repo has no file for');
        return 1;
      }
      if (plan.pending.isEmpty) {
        stdout.writeln('nothing pending; history holds ${recorded.length}');
        return 0;
      }
      for (final m in plan.pending) {
        await api.query(applySql(m, readMigration(m)), readOnly: false);
        final after = await api.recordedVersions() ?? <String>{};
        if (!after.contains(m.version) || after.length != recorded.length + 1) {
          stderr.writeln('history read back without ${m.version} as its one new row: $after');
          return 1;
        }
        stdout.writeln('applied     ${m.fileName}; history holds ${after.length}');
        recorded = after;
      }
      return 0;
  }
  stderr.writeln(usage);
  return 64;
}

Future<void> main(List<String> args) async {
  try {
    exitCode = await run(args);
  } on Object catch (e) {
    stderr.writeln(e);
    exitCode = 1;
  }
}
