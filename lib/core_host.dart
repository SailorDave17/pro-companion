import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant, IsolateNameServer;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';

import 'location/location_feed.dart';

/// What CoreService (android/app/src/main/kotlin/.../CoreService.kt) and this
/// engine say to each other.
const coreHostChannel = MethodChannel('pro_companion/core_host');

/// Where the phone's event log lives: app-private storage, never backed up to
/// or shared with another app. Before #32 the UI engine opened it, at the
/// same path, so a phone updated past #32 keeps its log.
Future<String> coreDbPath() async =>
    p.join((await getApplicationSupportDirectory()).path, 'core.db');

/// The core host (ADR 003, #32). CoreService runs this in a FlutterEngine of
/// its own, with no widget tree, by the name of this library and function: in
/// an integration test the root library is the test's file, not main.dart.
///
/// It opens the log and publishes the core's port, where the UI engine finds
/// it (lib/core_bootstrap.dart). It feeds the core where the phone is (#31),
/// from the service's own location feed, so events appended with the UI gone
/// carry a current position. Last it tells the service it is ready, which
/// releases the appends that arrived while the engine started: a call sent
/// before its handler exists is dropped (ADR 003 decision 4).
@pragma('vm:entry-point')
Future<void> coreMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  // path_provider's Android half registers from Dart, which only main's
  // isolate gets without asking.
  DartPluginRegistrant.ensureInitialized();
  final port = serveCore(await coreDbPath());
  IsolateNameServer.removePortNameMapping(corePortName);
  IsolateNameServer.registerPortWithName(port, corePortName);
  final core = PortCoreClient(port, closesCore: false);
  forwardLocation(const PlatformLocationFeed(), core);
  coreHostChannel.setMethodCallHandler((call) => handleHostCall(core, call));
  await coreHostChannel.invokeMethod<void>('ready');
}

/// One call from CoreService. `append` carries an event's wire form as JSON,
/// as an intent delivers it, and answers with the stored event's, also as
/// JSON, once the core has committed it. An argument that is not such an event
/// is a PlatformException coded `malformed`; a refusal by the core carries the
/// core's own code.
Future<Object?> handleHostCall(CoreClient core, MethodCall call) async {
  if (call.method != 'append') throw MissingPluginException('the core host has no method ${call.method}');
  final NewEvent event;
  try {
    event = NewEvent.fromWire(jsonDecode(call.arguments as String) as Map);
  } on Object catch (e) {
    throw PlatformException(code: 'malformed', message: 'not an event: $e');
  }
  try {
    return jsonEncode((await core.append(event)).toWire());
  } on CoreException catch (e) {
    throw PlatformException(code: e.code, message: e.message);
  }
}
