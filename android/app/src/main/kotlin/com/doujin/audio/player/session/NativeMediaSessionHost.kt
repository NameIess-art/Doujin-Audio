package com.doujin.audio.player.session

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import com.doujin.audio.MainActivity

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
    private val resources = NativeMediaSessionResourceLease<MediaSession, ExoPlayer>()

    fun current(): MediaSession? = resources.currentSession

    fun ensureBootstrap() {
        if (resources.currentSession != null) return
        try {
            resources.installBootstrap(
                createPlayer = { ExoPlayer.Builder(context).build() },
                createSession = { player ->
                    MediaSession.Builder(context, player)
                        .setId("Doujin Audio Bootstrap")
                        .setCallback(callback)
                        .build()
                },
                releasePlayer = ExoPlayer::release
            )
        } catch (error: Exception) {
            logWarn("ensure_media_session_for_bootstrap_failed", error)
        }
    }

    fun ensure(): MediaSession? {
        val playbackSession = candidate()
        val player = playbackSession?.playerOrNull() ?: return resources.currentSession
        resources.currentSession?.let { existing ->
            attachPlayer(existing, player, playbackSession)
            return existing
        }
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
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
        return resources.installSession(builder::build).also {
            logInfo("media_session_create", playbackSession)
        }
    }

    fun update(hasSessions: Boolean) {
        val nextPlayer = candidate()?.playerOrNull()
        val existing = resources.currentSession
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
        if (!resources.hasResources) return
        logInfo("media_session_release reason=$reason", null)
        resources.release(MediaSession::release, ExoPlayer::release)
    }

    private fun attachPlayer(
        target: MediaSession,
        player: ExoPlayer,
        session: NativePlaybackSession? = null
    ) {
        if (target.player === player) return
        logInfo("media_session_switch_player", session)
        target.player = player
        resources.onPlayerAttached(ExoPlayer::release)
    }
}
