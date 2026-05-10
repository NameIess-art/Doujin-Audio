package com.nameless.audio

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

data class StoredNativePlaybackSession(
    val sessionId: String,
    val uri: String,
    val title: String,
    val subtitle: String?,
    val artUri: String?,
    val positionMs: Long,
    val volume: Float,
    val repeatOne: Boolean,
    val channelSwapEnabled: Boolean,
    val playing: Boolean,
    val playWhenReady: Boolean
)

data class StoredPlaybackTimerRuntimeState(
    val timerModeIndex: Int?,
    val durationMs: Long?,
    val waitingForPlayback: Boolean,
    val timerEndsAtMs: Long?,
    val autoResumeAtMs: Long?,
    val pausedSessionIds: List<String>,
    val generation: Int
) {
    val hasRuntime: Boolean
        get() = (timerModeIndex != null && durationMs != null && waitingForPlayback) ||
            timerEndsAtMs != null ||
            autoResumeAtMs != null ||
            pausedSessionIds.isNotEmpty()

    val shouldKeepForegroundServiceAlive: Boolean
        get() = (timerModeIndex != null && durationMs != null && waitingForPlayback) ||
            timerEndsAtMs != null ||
            autoResumeAtMs != null
}

object NativePlaybackStateStore {
    private const val preferencesName = "audio_player_native_playback_state"
    private const val keySessions = "sessions"
    private const val keyPausedSessionIds = "paused_session_ids"
    private const val keyTimerCandidateSessionIds = "timer_candidate_session_ids"
    private const val keyTimerRuntimeState = "timer_runtime_state_v2"

    fun saveSessions(
        context: Context,
        sessions: List<StoredNativePlaybackSession>
    ) {
        val array = JSONArray()
        sessions.forEach { session ->
            array.put(
                JSONObject()
                    .put("sessionId", session.sessionId)
                    .put("uri", session.uri)
                    .put("title", session.title)
                    .put("subtitle", session.subtitle)
                    .put("artUri", session.artUri)
                    .put("positionMs", session.positionMs)
                    .put("volume", session.volume.toDouble())
                    .put("repeatOne", session.repeatOne)
                    .put("channelSwapEnabled", session.channelSwapEnabled)
                    .put("playing", session.playing)
                    .put("playWhenReady", session.playWhenReady)
            )
        }
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putString(keySessions, array.toString())
            .apply()
    }

    fun clearSessions(context: Context) {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .remove(keySessions)
            .apply()
    }

    fun loadSessions(context: Context): List<StoredNativePlaybackSession> {
        val raw = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getString(keySessions, null)
            ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val sessionId = item.optString("sessionId").takeIf { it.isNotBlank() }
                        ?: continue
                    val uri = item.optString("uri").takeIf { it.isNotBlank() }
                        ?: continue
                    add(
                        StoredNativePlaybackSession(
                            sessionId = sessionId,
                            uri = uri,
                            title = item.optString("title", "Audio"),
                            subtitle = item.optNullableString("subtitle"),
                            artUri = item.optNullableString("artUri"),
                            positionMs = item.optLong("positionMs", 0L).coerceAtLeast(0L),
                            volume = item.optDouble("volume", 1.0).toFloat(),
                            repeatOne = item.optBoolean("repeatOne", false),
                            channelSwapEnabled = item.optBoolean("channelSwapEnabled", false),
                            playing = item.optBoolean("playing", false),
                            playWhenReady = item.optBoolean("playWhenReady", false)
                        )
                    )
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun storePausedSessionIds(context: Context, sessionIds: List<String>) {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putStringSet(keyPausedSessionIds, sessionIds.toSet())
            .apply()
    }

    fun loadPausedSessionIds(context: Context): List<String> {
        return context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getStringSet(keyPausedSessionIds, emptySet())
            ?.toList()
            ?.sorted()
            ?: emptyList()
    }

    fun clearPausedSessionIds(context: Context) {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .remove(keyPausedSessionIds)
            .apply()
    }

    fun storeTimerCandidateSessionIds(context: Context, sessionIds: List<String>) {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putStringSet(keyTimerCandidateSessionIds, sessionIds.toSet())
            .apply()
    }

    fun loadTimerCandidateSessionIds(context: Context): List<String> {
        return context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getStringSet(keyTimerCandidateSessionIds, emptySet())
            ?.toList()
            ?.sorted()
            ?: emptyList()
    }

    fun clearTimerCandidateSessionIds(context: Context) {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .remove(keyTimerCandidateSessionIds)
            .apply()
    }

    fun saveTimerRuntimeState(
        context: Context,
        state: StoredPlaybackTimerRuntimeState
    ) {
        if (!state.hasRuntime) {
            clearTimerRuntimeState(context)
            return
        }
        val encoded = JSONObject()
            .put("timerModeIndex", state.timerModeIndex)
            .put("durationMs", state.durationMs)
            .put("waitingForPlayback", state.waitingForPlayback)
            .put("timerEndsAtMs", state.timerEndsAtMs)
            .put("autoResumeAtMs", state.autoResumeAtMs)
            .put("generation", state.generation)
            .put("pausedSessionIds", JSONArray(state.pausedSessionIds))
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putString(keyTimerRuntimeState, encoded.toString())
            .apply()
    }

    fun loadTimerRuntimeState(context: Context): StoredPlaybackTimerRuntimeState? {
        val raw = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getString(keyTimerRuntimeState, null)
            ?: return null
        return try {
            val json = JSONObject(raw)
            val pausedSessionIds = buildList {
                val array = json.optJSONArray("pausedSessionIds") ?: JSONArray()
                for (index in 0 until array.length()) {
                    array.optString(index)
                        .takeIf { it.isNotBlank() }
                        ?.let(::add)
                }
            }
            StoredPlaybackTimerRuntimeState(
                timerModeIndex = json.optNullableInt("timerModeIndex"),
                durationMs = json.optNullableLong("durationMs"),
                waitingForPlayback = json.optBoolean("waitingForPlayback", false),
                timerEndsAtMs = json.optNullableLong("timerEndsAtMs"),
                autoResumeAtMs = json.optNullableLong("autoResumeAtMs"),
                pausedSessionIds = pausedSessionIds,
                generation = json.optInt("generation", 0)
            )
        } catch (_: Exception) {
            null
        }
    }

    fun clearTimerRuntimeState(context: Context) {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .remove(keyTimerRuntimeState)
            .apply()
    }
}

private fun JSONObject.optNullableString(key: String): String? {
    if (!has(key) || isNull(key)) return null
    return optString(key).takeIf { it.isNotBlank() }
}

private fun JSONObject.optNullableInt(key: String): Int? {
    if (!has(key) || isNull(key)) return null
    return optInt(key)
}

private fun JSONObject.optNullableLong(key: String): Long? {
    if (!has(key) || isNull(key)) return null
    return optLong(key)
}
