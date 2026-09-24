import 'dart:isolate';
import 'dart:typed_data';

/// The core's wire protocol (ADR 003 decision 3).
///
/// The UI and the core run in separate isolate groups once the core moves into
/// the foreground service (#32), and a message between groups may carry only
/// null, bool, num, String, List, Map, SendPort and typed data. A Dart record
/// or class instance is refused at send time. So everything that crosses is
/// checked against that rule here, even while the core is spawned in the UI's
/// own group, where the VM would let a record through and hide the defect
/// until #32.
///
/// A request is `[replyPort, command, args]`; a reply is `['ok', result]` or
/// `['err', code, message]`.
abstract final class Wire {
  static const append = 'append';
  static const readAll = 'readAll';
  static const count = 'count';
  static const deviceId = 'deviceId';
  static const close = 'close';

  /// Every command the core serves. There is no update and no delete, and a
  /// command not listed here is refused (#24 criterion 3).
  static const commands = {append, readAll, count, deviceId, close};

  static const ok = 'ok';
  static const err = 'err';
}

/// True when [value] may cross an isolate-group boundary.
bool isWireSafe(Object? value) {
  if (value == null || value is bool || value is num || value is String) return true;
  if (value is SendPort || value is TypedData) return true;
  if (value is List) return value.every(isWireSafe);
  if (value is Map) {
    return value.entries.every((e) => isWireSafe(e.key) && isWireSafe(e.value));
  }
  return false;
}

/// Throws when [value] could not cross an isolate-group boundary, naming it.
void requireWireSafe(Object? value, String name) {
  if (!isWireSafe(value)) {
    throw ArgumentError.value(value, name, 'is not plain data and cannot cross the core boundary');
  }
}

/// A refusal or failure reported by the core, carried back across the port.
class CoreException implements Exception {
  const CoreException(this.code, this.message);

  /// `refused` (the store said no), `invalid` (bad arguments),
  /// `unknown_command`, or `failed` (anything else).
  final String code;
  final String message;

  @override
  String toString() => 'CoreException($code): $message';
}
