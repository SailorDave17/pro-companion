import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pro_companion/core_host.dart' show SyncConfig;

import '../scripts/sync_defines.dart' as defines;

/// #113 criterion 2: a build that syncs takes the project's URL and publishable key from a defines
/// file that holds nothing else. scripts/sync_defines.dart writes it from the local stack's status,
/// which also prints the secret key, the service_role key and the JWT secret.
void main() {
  // A legacy service_role key's shape, built here so no key-shaped literal sits in this public tree
  // (security-audit on #113 flagged the literal): header and claims as a JWT, a stand-in signature.
  String b64(Object json) => base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final serviceRole = '${b64({'alg': 'HS256'})}.${b64({'role': 'service_role'})}.stand-in';

  // The shape `supabase status -o env` prints, with stand-in values.
  final status = {
    'API_URL': 'http://127.0.0.1:54421',
    'PUBLISHABLE_KEY': 'sb_publishable_stand-in',
    'SECRET_KEY': 'sb_secret_stand-in',
    'SERVICE_ROLE_KEY': serviceRole,
    'JWT_SECRET': 'stand-in-jwt-secret',
    'DB_URL': 'postgresql://postgres:postgres@127.0.0.1:54422/postgres',
  };

  test('the script and the host name the same two defines', () {
    expect([defines.urlName, defines.keyName], [SyncConfig.urlName, SyncConfig.keyName]);
  });

  test('the file holds the URL and the publishable key, and nothing else the status printed', () {
    final file = defines.definesFrom(status);
    expect(file, {defines.urlName: status['API_URL'], defines.keyName: status['PUBLISHABLE_KEY']});
  });

  test('a status whose publishable key is a secret one, or that lacks either value, is refused', () {
    expect(() => defines.definesFrom({...status, 'PUBLISHABLE_KEY': status['SECRET_KEY']!}), throwsArgumentError);
    expect(() => defines.definesFrom({...status, 'PUBLISHABLE_KEY': status['SERVICE_ROLE_KEY']!}),
        throwsArgumentError);
    expect(() => defines.definesFrom({...status}..remove('API_URL')), throwsStateError);
    expect(() => defines.definesFrom({...status}..remove('PUBLISHABLE_KEY')), throwsStateError);
  });

  group('the script', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('pc_defines_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('writes the file a build reads, and prints the key by name only', () async {
      final path = p.join(dir.path, 'sync.defines.json');
      final out = StringBuffer();
      expect(await defines.run(['--out', path], status: () async => status, out: out), 0);
      expect(jsonDecode(File(path).readAsStringSync()), defines.definesFrom(status));
      expect('$out', contains(defines.keyName));
      expect('$out', isNot(contains(status['PUBLISHABLE_KEY'])));
    });

    test('refuses to write an env file, in any spelling the filesystem resolves to one', () async {
      // The case and trailing-dot spellings are #113's review: on NTFS each one is .env.local.
      final envFile = File(p.join(dir.path, '.env.local'))..writeAsStringSync('SUPABASE_SECRET_KEY=keep me\n');
      for (final name in ['.env.local', '.env', '.ENV.local', '.Env.local', '.env.local${p.separator}.']) {
        final path = p.join(dir.path, name);
        expect(await defines.run(['--out', path], status: () async => status), 64, reason: name);
      }
      expect(envFile.readAsStringSync(), 'SUPABASE_SECRET_KEY=keep me\n', reason: 'the env file is untouched');
      expect(File(p.join(dir.path, '.env')).existsSync(), isFalse);
    });

    test('refuses a file that is not .json', () async {
      final path = p.join(dir.path, 'sync.defines.txt');
      expect(await defines.run(['--out', path], status: () async => status), 64);
      expect(File(path).existsSync(), isFalse);
    });
  });

  test('git ignores the defines file, so the publishable key stays out of the public tree', () {
    for (final name in ['sync.defines.json', 'live.defines.json']) {
      final ignored = Process.runSync('git', ['check-ignore', '-q', name]);
      expect(ignored.exitCode, 0, reason: '$name must be ignored');
    }
  });
}
