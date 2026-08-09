package com.doujin.audio.player.notification

import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

internal fun isPlaybackTimerStateRestoreAction(action: String?): Boolean {
    return when (action) {
        Intent.ACTION_BOOT_COMPLETED,
        Intent.ACTION_MY_PACKAGE_REPLACED,
        Intent.ACTION_TIME_CHANGED,
        Intent.ACTION_TIMEZONE_CHANGED,
        AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED -> true
        else -> false
    }
}

class PlaybackTimerStateRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (!isPlaybackTimerStateRestoreAction(action)) return
        PlaybackTimerAlarmScheduler.rescheduleFromStoredState(
            context.applicationContext,
            reasonAction = action
        )
    }
}
