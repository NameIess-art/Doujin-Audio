package com.doujin.audio.player.recovery

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import androidx.core.content.ContextCompat

internal class NativePlaybackAudioDeviceDisconnectMonitor(
    private val context: Context,
    private val onDisconnected: () -> Unit
) {
    private var registered = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) onDisconnected()
        }
    }

    fun start() {
        if (registered) return
        ContextCompat.registerReceiver(
            context,
            receiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        registered = true
    }

    fun shutdown() {
        if (!registered) return
        context.unregisterReceiver(receiver)
        registered = false
    }
}
