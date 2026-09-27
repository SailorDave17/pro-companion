import 'dart:convert';

import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

/// JSON on the calling isolate, in place of the helper isolate a SupabaseClient
/// otherwise spawns for response bodies over 10 kB. Sync's answers are small
/// (append_event's three keys, the phone's own admissions) and sync already
/// runs off the UI's isolate, in the core engine (ADR 006). So it spawns no
/// isolate of its own, and closing it waits on nothing.
class InlineJson implements YAJsonIsolate {
  @override
  String? get debugName => 'sync (inline)';

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<dynamic> decode(String json) async => jsonDecode(json);

  @override
  Future<String> encode(Object? json) async => jsonEncode(json);
}
