/// Sync (#6, ADR 006): uploads this phone's own events to the companion's
/// server through append_event, exactly once each, and keeps each outcome in
/// the core's store. It runs in the headless core engine beside the store;
/// only the core host wires it (#32 builds the host, #113 starts sync in
/// it), and the UI never imports it (test/import_boundary_test.dart).
library;

export 'src/engine.dart' show SignInRateLimited, SyncEngine, SyncRun;
export 'src/key.dart' show requirePublishableKey;
