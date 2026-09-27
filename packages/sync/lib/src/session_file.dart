import 'dart:convert';
import 'dart:io';

/// The one copy of the phone's session outside memory (ADR 006 decision 3).
///
/// Rewritten on every auth change, so a refresh-token rotation is on disk
/// before the next one: a refresh from a copy two rotations old costs the
/// whole session (measured on #47). Written to a temporary file and renamed,
/// so a kill mid-write leaves the previous session rather than half of one.
/// Every read and write is synchronous, so two writes can never interleave on
/// the temporary file.
class SessionFile {
  SessionFile(String dir)
      : _file = File('$dir${Platform.pathSeparator}sync_session.json'),
        _tmp = File('$dir${Platform.pathSeparator}sync_session.json.tmp'),
        _setAside = File('$dir${Platform.pathSeparator}sync_session.unreadable.json');

  final File _file;
  final File _tmp;
  final File _setAside;

  bool get exists => _file.existsSync();

  String? read() => _file.existsSync() ? _file.readAsStringSync() : null;

  /// The refresh token the file holds, or null.
  String? refreshToken() {
    try {
      final json = jsonDecode(read() ?? 'null');
      return json is Map ? json['refresh_token'] as String? : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      // Not text at all: the session in memory is then newer than the file.
      return null;
    }
  }

  void write(String json) {
    _tmp.writeAsStringSync(json, flush: true);
    _tmp.renameSync(_file.path);
  }

  /// GoTrue rejected the session, or the phone signed out: nothing in it can
  /// be used again.
  void delete() {
    if (_file.existsSync()) _file.deleteSync();
  }

  /// The file cannot be read as a session. It is moved aside, for diagnosis
  /// only, so the phone can sign in again rather than stay locked behind it.
  void setAside() {
    if (!_file.existsSync()) return;
    if (_setAside.existsSync()) _setAside.deleteSync();
    _file.renameSync(_setAside.path);
  }
}
