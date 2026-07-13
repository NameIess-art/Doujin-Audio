package com.nameless.audio.player.notification

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class PlaybackTimerStateRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        PlaybackTimerAlarmScheduler.rescheduleFromStoredState(
            context.applicationContext,
            reasonAction = intent?.action
        )
    }
}
