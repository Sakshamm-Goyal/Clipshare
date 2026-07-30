package com.clipshare.android.ui

/** Pure state model so pairing is never presented as an active sync session. */
data class SyncUiState(
    val status: Status,
    val startEnabled: Boolean,
    val stopEnabled: Boolean,
    val sendEnabled: Boolean,
    val isRePair: Boolean
) {
    enum class Status {
        NOT_PAIRED,
        PAUSED,
        RUNNING
    }

    companion object {
        fun from(isPaired: Boolean, isSyncEnabled: Boolean): SyncUiState = when {
            !isPaired -> SyncUiState(Status.NOT_PAIRED, false, false, false, false)
            isSyncEnabled -> SyncUiState(Status.RUNNING, true, true, true, true)
            else -> SyncUiState(Status.PAUSED, true, false, false, true)
        }
    }
}
