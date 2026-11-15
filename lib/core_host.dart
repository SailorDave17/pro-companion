import 'dart:convert';
import 'dart:isolate' show SendPort;
import 'dart:ui' show DartPluginRegistrant, IsolateNameServer;

import 'package:flutter/foundation.dart' show BindingBase, debugPrint;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_sync/sync.dart';

import 'confirmation.dart';
import 'location/location_feed.dart';

/// What CoreService (android/app/src/main/kotlin/.../CoreService.kt) and this
/// engine say to each other.
const coreHostChannel = MethodChannel('pro_companion/core_host');

/// Where the phone's event log lives: app-private storage, never shared with
/// another app. Before #32 the UI engine opened it, at the same path, so a
/// phone updated past #32 keeps its log. Whether it leaves the phone in the
/// volunteer's own Android backup is #169's to measure and decide (#113
/// criterion 3); until then the platform's default applies to it. Sync's
/// session does not live here: see [coreMain].
Future<String> coreDbPath() async =>
    p.join((await getApplicationSupportDirectory()).path, 'core.db');

/// The project sync sends to (#113): its URL and its publishable key, compiled
/// in from a defines file that holds those two and nothing else
/// (`--dart-define-from-file=sync.defines.json`; README, "A build syncs only when it is given a
/// project", and docs/field-builds.md for the live project's).
/// Never `.env.local`, which also holds the secret key and the owner's token.
class SyncConfig {
  const SyncConfig(this.url, this.publishableKey);

  /// The two names a defines file sets.
  static const urlName = 'PRO_COMPANION_SUPABASE_URL';
  static const keyName = 'PRO_COMPANION_SUPABASE_PUBLISHABLE_KEY';

  final String url;
  final String publishableKey;

  /// What this build was compiled with, or null for a build that names no
  /// project, which runs with sync off.
  static SyncConfig? get compiled =>
      of(const String.fromEnvironment(urlName), const String.fromEnvironment(keyName));

  /// Null when [url] and [publishableKey] are both empty: a build with no
  /// defines file, whose phone logs and never syncs. One without the other is
  /// a broken defines file, which is refused rather than half-used.
  static SyncConfig? of(String url, String publishableKey) {
    if (url.isEmpty && publishableKey.isEmpty) return null;
    if (url.isEmpty || publishableKey.isEmpty) {
      throw ArgumentError('the defines file sets ${url.isEmpty ? keyName : urlName} '
          'without ${url.isEmpty ? urlName : keyName}: a build that syncs needs both');
    }
    return SyncConfig(url, publishableKey);
  }
}

/// Opens sync on [store] for [config], keeping its session in [sessionDir],
/// or answers null with sync off and the reason logged. The core logs
/// whatever happens here: a sync that cannot open costs uploads, never taps.
SyncEngine? openSync(
  EventStore store, {
  required SyncConfig? Function() config,
  required String? sessionDir,
  void Function(String line)? log,
}) {
  log ??= debugPrint;
  try {
    final project = config();
    if (project == null) {
      log('SYNC OFF this build names no project');
      return null;
    }
    if (sessionDir == null || sessionDir.isEmpty) {
      log('SYNC OFF the host was given no directory for the session');
      return null;
    }
    return SyncEngine.open(
        url: project.url, publishableKey: project.publishableKey, store: store, sessionDir: sessionDir, log: log);
  } on Object catch (e) {
    // ArgumentError's text names the define or the key's kind, never the key.
    log('SYNC OFF ${e is ArgumentError ? e.message : e.runtimeType}');
    return null;
  }
}

/// Serves [store] for the UI with [sync], when there is one, wired in (#113):
/// the join screen's join (#71), the sign-in screen's two calls (#104), and a
/// nudge after every request that appended one of this phone's own events.
/// With no sync, join and sign-in answer `no_server`, as before #113.
SendPort serveHost(EventStore store, SyncEngine? sync) => serveStore(store,
    join: sync?.join,
    signIn: sync == null
        ? null
        : SignInHandlers(requestLink: sync.requestMagicLink, completeLink: sync.completeMagicLink),
    onAppended: sync?.nudge);

/// The services this engine's channels need, and no widgets: the host has no
/// widget tree (ADR 006 decision 4, #113 criterion 6).
class CoreHostBinding extends BindingBase with SchedulerBinding, ServicesBinding {
  static bool _initialized = false;

  static void ensureInitialized() {
    if (_initialized) return;
    CoreHostBinding();
    _initialized = true;
  }
}

/// The core host (ADR 003, #32). CoreService runs this in a FlutterEngine of
/// its own, with no widget tree, by the name of this library and function: in
/// an integration test the root library is the test's file, not main.dart.
///
/// [args] is what CoreService passes: the app's no-backup directory
/// (`getNoBackupFilesDir`), where sync keeps its session (#113 criterion 3).
/// A restored copy of a session is a refresh token many rotations old, and
/// presenting one costs the whole session (ADR 006), so it must never come
/// back from a backup or a device transfer.
///
/// It opens the log, builds sync on it in this same engine (ADR 006 decision
/// 1), and publishes the core's port, where the UI engine finds it
/// (lib/core_bootstrap.dart). It feeds the core where the phone is (#31),
/// from the service's own location feed, so events appended with the UI gone
/// carry a current position. Then it tells the service it is ready, which
/// releases the appends that arrived while the engine started: a call sent
/// before its handler exists is dropped (ADR 003 decision 4). Last it starts
/// sync, which from then on runs on its own: after every append, and on its
/// timers while anything waits or another phone may have written.
@pragma('vm:entry-point')
Future<void> coreMain(List<String> args) async {
  CoreHostBinding.ensureInitialized();
  // path_provider's Android half registers from Dart, which only main's
  // isolate gets without asking.
  DartPluginRegistrant.ensureInitialized();
  final store = EventStore.open(await coreDbPath());
  final sync = openSync(store, config: () => SyncConfig.compiled, sessionDir: args.isEmpty ? null : args.first);
  final port = serveHost(store, sync);
  IsolateNameServer.removePortNameMapping(corePortName);
  IsolateNameServer.registerPortWithName(port, corePortName);
  final core = PortCoreClient(port, closesCore: false);
  forwardLocation(const PlatformLocationFeed(), core);
  final confirmation = ConfirmationService(const PlatformConfirmationDevice());
  coreHostChannel.setMethodCallHandler((call) => handleHostCall(core, call, confirmation: confirmation));
  await coreHostChannel.invokeMethod<void>('ready');
  sync?.start();
}

/// One call from CoreService. `append` carries an event's wire form as JSON,
/// as an intent delivers it, and answers with the stored event's, also as
/// JSON, once the core has committed it. An argument that is not such an event
/// is a PlatformException coded `malformed`; a refusal by the core carries the
/// core's own code.
///
/// `link` carries one event from race-timer as it arrived, with the moment it
/// did, and answers with the core's status (#33, ADR 004). [confirmation] fires
/// here, once the event is committed, and only when this call stored it, so a
/// PRO with the phone in a pocket feels each signal and never a retry's echo.
/// A failure throws, and CoreService tells race-timer `no_core`.
Future<Object?> handleHostCall(CoreClient core, MethodCall call, {ConfirmationService? confirmation}) async {
  if (call.method == 'link') {
    final arguments = call.arguments as Map;
    final answer =
        await core.receiveLink(arguments['event'] as String, receivedMs: arguments['received_ms'] as int);
    if (answer.stored) confirmation?.fire();
    return answer.status;
  }
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
