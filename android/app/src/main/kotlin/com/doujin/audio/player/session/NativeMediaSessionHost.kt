@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.session

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import com.doujin.audio.MainActivity

internal class NativeMediaSessionHost(
    private val context: Context,
    private val candidate: () -> NativePlaybackSession?,
    onPlayerCommand: (Int) -> Unit,
    private val onSetPlayWhenReady: (NativePlaybackSession, Boolean) -> Boolean,
    logSecurityEvent: (String, Throwable?) -> Unit,
    private val logInfo: (String, NativePlaybackSession?) -> Unit,
    private val logWarn: (String, Throwable) -> Unit
) {
    private val callback = NativeMediaSessionCallback(
        appPackageName = context.packageName,
        appUid = context.applicationInfo.uid,
        onPlayerCommand = onPlayerCommand,
        logSecurityEvent = logSecurityEvent
    )
    private val resources = NativeMediaSessionResourceLease<MediaSession, ExoPlayer>()

    fun isAttachedTo(player: ExoPlayer?): Boolean =
        player != null && (resources.currentSession?.player as? MediaSessionPlayer)?.delegate === player

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
        val builder = MediaSession.Builder(context, sessionPlayer(player, playbackSession))
            .setId("Doujin Audio")
            .setCallback(callback)
        if (pendingIntent != null) builder.setSessionActivity(pendingIntent)
        return resources.installSession(builder::build).also {
            logInfo("media_session_create", playbackSession)
        }
    }

    fun update() {
        val playbackSession = candidate()
        val nextPlayer = playbackSession?.playerOrNull()
        val existing = resources.currentSession
        if (nextPlayer == null) {
            release("no_media_session_candidate")
            return
        }
        if (existing == null) {
            ensure()
            return
        }
        attachPlayer(existing, nextPlayer, playbackSession)
    }

    fun ensurePlayer(session: NativePlaybackSession): ExoPlayer {
        val player = session.ensurePlayer()
        update()
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
        session: NativePlaybackSession
    ) {
        if (isAttachedTo(player)) return
        logInfo("media_session_switch_player", session)
        target.player = sessionPlayer(player, session)
        resources.onPlayerAttached(ExoPlayer::release)
    }

    private fun sessionPlayer(player: ExoPlayer, session: NativePlaybackSession): MediaSessionPlayer =
        MediaSessionPlayer(player) { onSetPlayWhenReady(session, it) }
}

// Media3 uses one command code for play and pause. Intercept the actual request
// on the session player so native playback commands still use ExoPlayer directly.
internal class MediaSessionPlayer(
    val delegate: Player,
    private val onSetPlayWhenReady: (Boolean) -> Boolean
) : ForwardingPlayer(delegate) {
    override fun play() = setPlayWhenReady(true)

    override fun pause() = setPlayWhenReady(false)

    override fun setPlayWhenReady(playWhenReady: Boolean) {
        if (onSetPlayWhenReady(playWhenReady)) super.setPlayWhenReady(playWhenReady)
    }
}
