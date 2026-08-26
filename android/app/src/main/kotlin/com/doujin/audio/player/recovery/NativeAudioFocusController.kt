package com.doujin.audio.player.recovery

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler

internal class NativeAudioFocusController(
    context: Context,
    private val handler: Handler,
    private val logInfo: (String) -> Unit,
    private val logWarn: (String, Throwable) -> Unit,
    private val onFocusChange: (Int) -> Unit
) : NativePlaybackAudioFocusAccess {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private var focusRequest: AudioFocusRequest? = null
    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { change ->
        logInfo("audio_focus_change focus=${focusChangeName(change)}")
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> isHeld = true
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> isHeld = false
        }
        onFocusChange(change)
    }

    override var isHeld: Boolean = false
        private set

    override fun requestIfNeeded(): Boolean {
        if (isHeld) return true
        val manager = audioManager ?: run {
            logInfo("audio_focus_request_skip no_audio_manager")
            return false
        }
        val result = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = focusRequest ?: AudioFocusRequest.Builder(
                    AudioManager.AUDIOFOCUS_GAIN
                )
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .setAcceptsDelayedFocusGain(false)
                    .setWillPauseWhenDucked(false)
                    .setOnAudioFocusChangeListener(focusChangeListener, handler)
                    .build()
                    .also { focusRequest = it }
                manager.requestAudioFocus(request)
            } else {
                @Suppress("DEPRECATION")
                manager.requestAudioFocus(
                    focusChangeListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN
                )
            }
        } catch (error: RuntimeException) {
            logWarn("audio_focus_request_failed", error)
            AudioManager.AUDIOFOCUS_REQUEST_FAILED
        }
        isHeld = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        logInfo(
            "audio_focus_request_result result=${requestResultName(result)} held=$isHeld"
        )
        return isHeld
    }

    override fun abandon(reason: String) {
        if (!isHeld && focusRequest == null) return
        val manager = audioManager ?: run {
            logInfo("audio_focus_abandon_skip no_audio_manager reason=$reason")
            isHeld = false
            return
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let(manager::abandonAudioFocusRequest)
            } else {
                @Suppress("DEPRECATION")
                manager.abandonAudioFocus(focusChangeListener)
            }
            logInfo("audio_focus_abandoned reason=$reason")
        } catch (error: RuntimeException) {
            logWarn("audio_focus_abandon_failed reason=$reason", error)
        } finally {
            isHeld = false
        }
    }

    private fun focusChangeName(change: Int): String = when (change) {
        AudioManager.AUDIOFOCUS_GAIN -> "gain"
        AudioManager.AUDIOFOCUS_LOSS -> "loss"
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> "loss_transient"
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> "loss_transient_can_duck"
        else -> "unknown($change)"
    }

    private fun requestResultName(result: Int): String = when (result) {
        AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> "granted"
        AudioManager.AUDIOFOCUS_REQUEST_FAILED -> "failed"
        AudioManager.AUDIOFOCUS_REQUEST_DELAYED -> "delayed"
        else -> "unknown($result)"
    }
}
