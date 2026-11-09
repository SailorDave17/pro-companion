import 'dart:convert';
import 'dart:io';

import 'package:supabase/supabase.dart';

/// Where the client keeps a magic link's PKCE code verifier between asking for
/// the link and opening it (#104).
///
/// The client's flow is PKCE by default, and it keeps the verifier in the
/// `pkceAsyncStorage` it is given: with none, `signInWithOtp` fails an assert
/// in a debug build and a null check in a release one (*measured* in
/// supabase 2.16.1 and gotrue 2.27.2). The verifier must also outlive the
/// core host's engine, since the volunteer leaves the app for the mail app
/// between the two, so it is a file beside the session's, not memory.
/// Written to a temporary file and renamed, as `SessionFile` is, so a kill
/// mid-write leaves the previous contents rather than half of them.
///
/// gotrue keeps one verifier under one key, so a second request replaces the
/// first, and only the newest link can sign the phone in.
class PkceFile extends GotrueAsyncStorage {
  PkceFile(String dir)
      : _file = File('$dir${Platform.pathSeparator}sync_pkce.json'),
        _tmp = File('$dir${Platform.pathSeparator}sync_pkce.json.tmp');

  final File _file;
  final File _tmp;

  Map<String, String> _read() {
    if (!_file.existsSync()) return {};
    try {
      final json = jsonDecode(_file.readAsStringSync());
      if (json is! Map) return {};
      return {
        for (final e in json.entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      };
    } on FormatException {
      // Not what this class writes. Treated as empty: the next request
      // replaces it, and an exchange against it fails as a missing verifier.
      return {};
    } on FileSystemException {
      return {};
    }
  }

  void _write(Map<String, String> items) {
    if (items.isEmpty) {
      if (_file.existsSync()) _file.deleteSync();
      return;
    }
    _tmp.writeAsStringSync(jsonEncode(items), flush: true);
    _tmp.renameSync(_file.path);
  }

  @override
  Future<String?> getItem({required String key}) async => _read()[key];

  @override
  Future<void> setItem({required String key, required String value}) async => _write({..._read(), key: value});

  @override
  Future<void> removeItem({required String key}) async => _write({..._read()}..remove(key));
}
