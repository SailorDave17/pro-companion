/// The local core's interface: what UI code may import (ADR 001, ADR 003).
///
/// The store and the host are deliberately not exported here. UI code talks
/// to a [CoreClient] and nothing else; the import-boundary test holds it to
/// that.
library;

export 'src/chain.dart'
    show ChainRefusal, ChainState, ChainVerdict, canonicalJson, chainHash, genesisHash, verifyChain, verifyChains;
export 'src/chain_status.dart' show ChainBreak, ChainPoint, ChainStatus, DeviceChain, DeviceChainStates;
export 'src/client.dart' show CoreClient;
export 'src/clock_offsets.dart' show ClockKinds, CrossPhoneElapsed, CrossPhoneFlags, crossPhoneElapsed, offsetFor;
export 'src/envelope.dart' show EventEnvelope, GpsFix, NewEvent, isUlid;
export 'src/finishes.dart'
    show FinishEntry, FinishEvents, FinishKinds, FinishSources, finishOrder, lastUndoable, lastUndoableFinish;
export 'src/fleets.dart'
    show Fleet, FleetEvents, FleetKinds, fleetOf, fleetPayloadKey, fleets, lastFleetSwitch, recentFleets, selectedFleet;
export 'src/kinds.dart' show EventKinds;
export 'src/location.dart' show ClockOffsetReasons, GpsReasons, GpsTimeSample;
export 'src/mark_finishes.dart'
    show CourseEvents, CourseKinds, lastMarkFleet, lastUndoableMarkFinish, markFinishOrder, shortenedAt;
export 'src/order.dart' show happened;
export 'src/pulls.dart' show PullRun, PullRunState, PullStatus;
export 'src/results.dart'
    show BetweenRaces, DuplicateSail, ProvisionalResults, ResultsEvents, ResultsKinds, UnnamedFinish, discardsSet, placeholderId, provisionalResults, raceStarts, racesOf;
export 'src/roles.dart' show RoleEvents, RoleKinds, Roles, currentRole, currentRolePick;
export 'src/roundings.dart'
    show
        FleetRunningOrder,
        RoundingEntry,
        RoundingEvents,
        RoundingKinds,
        RunningEntry,
        knownRoundingSails,
        lapPayloadKey,
        lastUndoableRounding,
        racePayloadKey,
        roundingsAt,
        runningOrder,
        runningOrders,
        stationedMarks;
export 'src/scoring.dart'
    show DiscardStep, Discards, Race, RaceScore, ScoreCode, Series, Standing, scoreSeries;
export 'src/starts.dart'
    show
        FleetRaceState,
        OcsEntry,
        StartEvents,
        StartKinds,
        anchorTime,
        elapsedAnchor,
        gunTime,
        individualRecallsOf,
        knownSails,
        lastUndoableStart,
        ocsAt,
        raceState,
        sequenceOf;
export 'src/stations.dart'
    show StandardMarks, StationEvents, StationKinds, currentStation, currentStationPick, markOf, markPayloadKey;
export 'src/uploads.dart' show RefusedUpload, Revocation, UploadRun, UploadRunState, UploadStatus;
export 'src/wire.dart' show CoreException, isWireSafe;
