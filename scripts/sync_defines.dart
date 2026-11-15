// Writes the defines file a build that syncs is compiled with (#113): the project's URL and its
// publishable key, and nothing else.
//
//   dart run scripts/sync_defines.dart [--out sync.defines.json]
//   flutter run --dart-define-from-file=sync.defines.json
//
// It reads the local stack's `supabase status`, so the build syncs with the stack on this machine.
// An emulator reaches it at its own 127.0.0.1 once `adb reverse tcp:54421 tcp:54421` is set, as the
// device scripts do. A field build's file names the live project instead and is written by hand;
// docs/field-builds.md says how.
//
// The file is git-ignored (sync.defines.json and *.defines.json). It never holds the secret key,
// the service_role key or the JWT secret that the same status prints, and it is never .env.local,
// which holds the owner's token: a build ships everything in its defines file to every phone.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pro_companion_sync/sync.dart' show requirePublishableKey;

import 'owner.dart' show readLocalStatus;

/// The two names the core host reads (lib/core_host.dart, `SyncConfig`).
const urlName = 'PRO_COMPANION_SUPABASE_URL';
const keyName = 'PRO_COMPANION_SUPABASE_PUBLISHABLE_KEY';

const defaultOut = 'sync.defines.json';

/// The defines file's contents for the stack [status] describes: exactly [urlName] and [keyName].
/// Throws when the status lacks either, or its publishable key is not one.
Map<String, String> definesFrom(Map<String, String> status) {
  final url = status['API_URL'];
  final key = status['PUBLISHABLE_KEY'];
  if (url == null || url.isEmpty || key == null || key.isEmpty) {
    throw StateError('supabase status gave no API_URL and PUBLISHABLE_KEY: is the local stack running?');
  }
  requirePublishableKey(key);
  return {urlName: url, keyName: key};
}

/// Whether [path] may be written as a defines file: a `.json` file whose name, as the filesystem
/// resolves it, is not an env file. The name is read from the normalised absolute path and compared
/// without case, since `.ENV.local` and `.env.local/.` are `.env.local` on NTFS (review of #113:
/// a case-sensitive test of the last segment let both overwrite it).
bool isDefinesPath(String path) {
  final name = p.basename(p.normalize(File(path).absolute.path)).toLowerCase();
  return name.endsWith('.json') && !name.startsWith('.env');
}

Future<int> run(List<String> args, {Future<Map<String, String>> Function()? status, StringSink? out}) async {
  out ??= stdout;
  var path = defaultOut;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--out' && i + 1 < args.length) {
      path = args[++i];
    } else {
      stderr.writeln('usage: dart run scripts/sync_defines.dart [--out $defaultOut]');
      return 64;
    }
  }
  if (!isDefinesPath(path)) {
    stderr.writeln('refused: $path is not a .json file, or is an env file, which holds secrets; '
        'a defines file is shipped to phones');
    return 64;
  }
  final Map<String, String> defines;
  try {
    defines = definesFrom(await (status ?? readLocalStatus)());
  } on Object catch (e) {
    stderr.writeln(e is ArgumentError ? e.message : e);
    return 1;
  }
  File(path).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(defines)}\n');
  // The URL is no secret; the key is printed by name only.
  out.writeln('wrote $path: $urlName=${defines[urlName]}, $keyName');
  return 0;
}

Future<void> main(List<String> args) async => exitCode = await run(args);
