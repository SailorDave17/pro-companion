/// The append-only store (ADR 002). For the core's own hosts and for tests.
/// UI code must not import this; the import-boundary test refuses it.
library;

export 'src/envelope.dart' show EventEnvelope, GpsFix, NewEvent, newUlid;
export 'src/store.dart' show EventStore;
