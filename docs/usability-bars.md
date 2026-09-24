# Usability bars — the wet-hands bar for race-time screens

- **Status: ratified 2026-09-23 (groom decision G3). Not yet confirmed on the water.** Amended #8's
  field session records each value below as *confirmed* or *adjusted*, with the observation behind
  it. Any adjustment is filed as an issue against this file.
- Enforced by: `lib/ui/bars.dart` (the constants), `lib/ui/sunlight.dart` (the colour tokens), and
  the bar-check helper `test/support/bar_check.dart`, which every race-time screen's tests run.
  `test/usability_bars_doc_test.dart` fails if this file and the constants disagree.

## Why there is a bar at all

Race officers told the owner the closest competitor, SailAlign, is unusable on the water. A PRO
logging finishes has wet hands or gloves, is in glare, and is watching the line, not the phone.
So every race-time action has to be hittable without looking, readable in direct sun, and
confirmed by feel and sound. These numbers make that testable.

## The bar

| Bar | Value | Why |
|---|---|---|
| Minimum interactive target | **64 dp** both ways | Android's 48 dp assumes a dry fingertip and full attention; a wet or gloved thumb misses it. |
| Primary race-time actions | **Full width**, less a **16 dp** gutter each side | A thumb finds a full-width control without aiming. |
| Text contrast | **7:1** minimum (WCAG AAA) | 4.5:1 (AA) washes out in direct sun. Asserted from the colour tokens, pair by pair. |
| Taps from the role home | **2** at most for a screen-level race-time action, its own tap included | Anything deeper is not reachable mid-finish. |
| Item corrections | **1 tap more**, to select the item | Correcting one finish (Missed above, Undo this) is select-then-act. Owner decision 2026-09-24 (#4), over always-visible row actions, which would have left about 3 finishes on screen. |
| Swipes | **None** as the only way to an action | Wet swipes misfire and cannot be done without looking. |
| Confirm dialogs | **None** on a race-time route; undo instead | A modal steals the next tap, which is the next boat. |
| Confirmation | **One vibration and one tone** per logged action, only once it is committed | So nobody has to look down to know it took. |

## Confirmation details

- The vibration is declared as touch feedback (`USAGE_TOUCH`). On race-timer's measurements that was
  the class that survived total-silence Do Not Disturb; `USAGE_ALARM` was dropped without an error.
- The tone follows the **notification** volume until #86 makes it a setting (alarm, media or
  notification). Notification was the owner's choice for the default (2026-09-24), over the
  recommended alarm, so a phone with its ringer on silent or vibrate gets the buzz alone.
- A failed append fires neither, and the screen says "Not logged. Tap again."

## What the bar-check helper cannot see

- A target touching the screen edge or a scrollable's edge is skipped. That's Flutter's
  `MinimumTapTargetGuideline`, which it uses, avoiding targets partly scrolled away.
- Whether the buzz and beep are noticed in wind and engine noise, and whether text is legible in
  real sun. Those are amended #8's to observe.
