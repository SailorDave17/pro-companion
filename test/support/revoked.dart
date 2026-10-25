import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

/// A revocation as sync would leave one (#53), named.
const revokedDay = Revocation(
  eventId: 'b3c7e9a1-2d4f-4b6a-8c0e-1f2a3b4c5d6e',
  eventName: 'Fall Series Day 2',
  at: 1000,
);

/// [core] with the revoked banner up: a bar check run over it explores every screen under the
/// banner (the review of #53 found the mark boat's screens and a multi-fleet day never were).
FakeCore revoked(FakeCore core) => core..revocationValue = revokedDay;
