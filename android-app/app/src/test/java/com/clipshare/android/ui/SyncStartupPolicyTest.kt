package com.clipshare.android.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncStartupPolicyTest {
    @Test
    fun resumesAnEnabledPairedSessionWhenAndroidStoppedItsService() {
        assertTrue(
            SyncStartupPolicy.shouldEnsureService(
                isPaired = true,
                isSyncEnabled = true,
                isServiceRunning = false
            )
        )
    }

    @Test
    fun neverRevivesAPausedOrUnpairedSession() {
        assertFalse(SyncStartupPolicy.shouldEnsureService(true, false, false))
        assertFalse(SyncStartupPolicy.shouldEnsureService(false, true, false))
    }

    @Test
    fun leavesAnAlreadyRunningServiceAlone() {
        assertFalse(SyncStartupPolicy.shouldEnsureService(true, true, true))
    }
}
