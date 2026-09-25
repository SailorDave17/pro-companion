/// The local core's interface: what UI code may import (ADR 001, ADR 003).
///
/// The store and the host are deliberately not exported here. UI code talks
/// to a [CoreClient] and nothing else; the import-boundary test holds it to
/// that.
library;

export 'src/client.dart' show CoreClient;
export 'src/envelope.dart' show EventEnvelope, GpsFix, NewEvent, isUlid;
export 'src/finishes.dart'
    show FinishEntry, FinishEvents, FinishKinds, finishOrder, lastUndoable, lastUndoableFinish;
export 'src/fleets.dart'
    show Fleet, FleetEvents, FleetKinds, fleetOf, fleetPayloadKey, fleets, lastFleetSwitch, recentFleets, selectedFleet;
export 'src/order.dart' show happened;
export 'src/scoring.dart'
    show DiscardStep, Discards, Race, RaceScore, ScoreCode, Series, Standing, scoreSeries;
export 'src/starts.dart' show FleetRaceState, StartEvents, StartKinds, elapsedAnchor, raceState;
export 'src/wire.dart' show CoreException, isWireSafe;
