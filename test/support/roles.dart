import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

/// The ULID of the pick [withRole] seeds.
const seededRolePick = '01J70000000000000000R01EPK';

/// Seeds a pick of [role] on [core]'s own phone, before anything else in its
/// log, so the app opens on that role's home rather than the picker (#20).
/// It takes no time on the core's clock, so a test's timestamps are unmoved.
FakeCore withRole(FakeCore core, [String role = Roles.overallPro]) => core
  ..seed([
    EventEnvelope(
      ulid: seededRolePick,
      deviceTs: 0,
      deviceId: core.deviceIdValue,
      seq: 0,
      source: 'tap',
      kind: RoleKinds.assigned,
      payloadVersion: 1,
      role: role,
      payload: {'role': role},
    ),
  ]);
