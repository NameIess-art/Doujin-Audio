package com.nameless.audio

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class PlaybackTimerStateRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        PlaybackTimerAlarmScheduler.rescheduleFromStoredState(
            context.applicationContext
        )
    }
}
