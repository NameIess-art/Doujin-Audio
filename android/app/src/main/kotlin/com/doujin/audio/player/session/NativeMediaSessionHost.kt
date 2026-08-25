package com.doujin.audio.player.session

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import com.doujin.audio.player.notification.activeLauncherActivityName

internal class NativeMediaSessionHost(
    private val context: Context,
    private val candidate: () -> NativePlaybackSession?,
    handlePlayerCommandRequest: (Int, Boolean) -> Int,
    logSecurityEvent: (String, Throwable?) -> Unit,
    private val logInfo: (String, NativePlaybackSession?) -> Unit,
    private val logWarn: (String, Throwable) -> Unit
) {
    private val callback = NativeMediaSessionCallback(
        appPackageName = context.packageName,
        appUid = context.applicationInfo.uid,
        handlePlayerCommandRequest = handlePlayerCommandRequest,
        logSecurityEvent = logSecurityEvent
    )
    private var mediaSession: MediaSession? = null
    private var dummyPlayer: ExoPlayer? = null

    fun current(): MediaSession? = mediaSession

    fun ensureBootstrap() {
        if (mediaSession != null) return
        var player: ExoPlayer? = null
        try {
            val createdPlayer = ExoPlayer.Builder(context).build()
            player = createdPlayer
            dummyPlayer = createdPlayer
            mediaSession = MediaSession.Builder(context, createdPlayer)
                .setId("Doujin Audio Bootstrap")
                .setCallback(callback)
                .build()
        } catch (error: Exception) {
            player?.release()
            if (dummyPlayer === player) dummyPlayer = null
            logWarn("ensure_media_session_for_bootstrap_failed", error)
        }
    }

    fun ensure(): MediaSession? {
        val playbackSession = candidate()
        val player = playbackSession?.playerOrNull() ?: return mediaSession
        mediaSession?.let { existing ->
            attachPlayer(existing, player, playbackSession)
            return existing
        }
        val launchIntent = Intent(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .setComponent(
                ComponentName(
                    context.packageName,
                    activeLauncherActivityName(context)
                )
            )
            .apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
        val pendingIntent = if (context.packageManager.resolveActivity(launchIntent, 0) != null) {
            PendingIntent.getActivity(
                context,
                0,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else null
        val builder = MediaSession.Builder(context, player)
            .setId("Doujin Audio")
            .setCallback(callback)
        if (pendingIntent != null) builder.setSessionActivity(pendingIntent)
        return builder.build().also {
            mediaSession = it
            logInfo("media_session_create", playbackSession)
        }
    }

    fun update(hasSessions: Boolean) {
        val nextPlayer = candidate()?.playerOrNull()
        val existing = mediaSession
        if (nextPlayer == null) {
            if (!hasSessions) release("no_media_session_candidate")
            return
        }
        if (existing == null) {
            ensure()
            return
        }
        attachPlayer(existing, nextPlayer)
    }

    fun ensurePlayer(session: NativePlaybackSession, hasSessions: Boolean): ExoPlayer {
        val player = session.ensurePlayer()
        update(hasSessions)
        ensure()
        return player
    }

    fun release(reason: String) {
        val existing = mediaSession
        val bootstrapPlayer = dummyPlayer
        if (existing == null && bootstrapPlayer == null) return
        logInfo("media_session_release reason=$reason", null)
        try {
            existing?.release()
        } finally {
            mediaSession = null
            bootstrapPlayer?.release()
            dummyPlayer = null
        }
    }

    private fun attachPlayer(
        target: MediaSession,
        player: ExoPlayer,
        session: NativePlaybackSession? = null
    ) {
        if (target.player === player) return
        logInfo("media_session_switch_player", session)
        target.player = player
        dummyPlayer?.release()
        dummyPlayer = null
    }
}
