import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pro_companion_core/host.dart';

/// Where the phone's event log lives: app-private storage, never backed up to
/// or shared with another app.
Future<String> coreDbPath() async =>
    p.join((await getApplicationSupportDirectory()).path, 'core.db');

/// Starts the local core for this app (ADR 001) in its own isolate (ADR 003).
/// #32 moves it into the foreground service; callers keep the same client.
Future<CoreClient> startCore() async => spawnCore(await coreDbPath());
