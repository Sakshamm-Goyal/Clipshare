package com.clipshare.android.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncUiStateTest {
    @Test
    fun pairedButStoppedIsShownAsPausedAndCannotSendClipboard() {
        val state = SyncUiState.from(isPaired = true, isSyncEnabled = false)

        assertEquals(SyncUiState.Status.PAUSED, state.status)
        assertTrue(state.startEnabled)
        assertFalse(state.stopEnabled)
        assertFalse(state.sendEnabled)
        assertTrue(state.isRePair)
    }

    @Test
    fun runningSyncEnablesStopAndManualClipboardSend() {
        val state = SyncUiState.from(isPaired = true, isSyncEnabled = true)

        assertEquals(SyncUiState.Status.RUNNING, state.status)
        assertTrue(state.startEnabled)
        assertTrue(state.stopEnabled)
        assertTrue(state.sendEnabled)
    }

    @Test
    fun unpairedDeviceCannotStartOrSend() {
        val state = SyncUiState.from(isPaired = false, isSyncEnabled = false)

        assertEquals(SyncUiState.Status.NOT_PAIRED, state.status)
        assertFalse(state.startEnabled)
        assertFalse(state.stopEnabled)
        assertFalse(state.sendEnabled)
        assertFalse(state.isRePair)
    }
}
