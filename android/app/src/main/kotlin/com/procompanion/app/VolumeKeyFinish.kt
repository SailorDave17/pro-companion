package com.procompanion.app

import android.view.KeyEvent

/**
 * The volume-down key as a finish (#19): what MainActivity does with each key
 * event while the finish screen may be showing.
 *
 * A press is judged once, at its first down. Taken, every event of that press
 * is kept from the system — its key-repeats and its up as well — so the system
 * never sees half a press and no volume, the phone's or another app's media
 * session's, moves. Only that first down is a finish, so a held key is one.
 * Everything else, volume-up always included (owner decision 2026-10-06),
 * passes through untouched.
 */
class VolumeKeyFinish {
    enum class Verdict {
        /** Not ours: the system handles it as it would anyway. */
        PASS,

        /** The first down of a taken press: log one finish, and keep it. */
        FINISH,

        /** The rest of a taken press: keep it, log nothing. */
        SWALLOW,
    }

    /** Set by the finish screen while it is the screen showing. */
    var armed = false

    /** A press was taken at its first down and has not come up yet. */
    private var holding = false

    /** [screenOn]: the screen is interactive and this window has focus (G4). */
    fun judge(event: KeyEvent, screenOn: Boolean): Verdict {
        if (event.keyCode != KeyEvent.KEYCODE_VOLUME_DOWN) return Verdict.PASS
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            holding = armed && screenOn
            return if (holding) Verdict.FINISH else Verdict.PASS
        }
        if (!holding) return Verdict.PASS
        // Swallowing the up has a spare: passed on, Flutter's embedding drops an up for a
        // key it never saw go down, so no test can see this line (measured on #19 with
        // Flutter 3.44.9: passing the up on reddened none of the device tests, and no
        // volume request reached the audio service). It stays, so the press is whole here
        // rather than by the engine's grace.
        if (event.action == KeyEvent.ACTION_UP) holding = false
        return Verdict.SWALLOW
    }
}
