import 'dart:ui' show IsolateNameServer;

import 'package:pro_companion_core/host.dart';

// The core host's entry point travels with startCore: CoreService runs it by
// its library's name, and a library is compiled into a build only when
// something the build starts from imports it. Every build that reaches the core
// comes through here - the app, and each integration flow, whose own file is
// the root library - so each one carries the host too.
export 'core_host.dart' show coreMain;

/// Connects to the local core (ADR 001), which runs in the foreground
/// service's own engine (ADR 003, #32). MainActivity binds that service as it
/// is created, so the core may still be opening the log: this waits until the
/// port it publishes answers.
Future<CoreClient> startCore() => connectCore(() => IsolateNameServer.lookupPortByName(corePortName));
