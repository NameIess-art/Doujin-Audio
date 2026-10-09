package com.doujin.audio.player.session

import android.content.Context
import android.content.SharedPreferences
import android.os.Looper
import android.util.JsonReader
import android.util.JsonToken
import java.io.StringReader
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/** The subset of [StoredNativePlaybackSession] that changes on every tick. */
data class StoredNativePlaybackProgress(
    val sessionId: String,
    val positionMs: Long,
    val playing: Boolean,
    val playWhenReady: Boolean
)

/**
 * Applies progress only after the store has matched its structural generation.
 */
internal fun StoredNativePlaybackSession.withProgressOverlay(
    progress: StoredNativePlaybackProgress?
): StoredNativePlaybackSession {
    if (progress == null || progress.sessionId != sessionId) return this
    return copy(
        positionMs = progress.positionMs.coerceAtLeast(0L),
        playing = progress.playing,
        playWhenReady = progress.playWhenReady
    )
}

data class StoredNativePlaybackSession(
    val sessionId: String,
    val uri: String,
    val path: String,
    val title: String,
    val subtitle: String?,
    val artUri: String?,
    val positionMs: Long,
    val volume: Float,
    val speed: Float,
    val skipSilenceEnabled: Boolean,
    val noiseReductionEnabled: Boolean,
    val eqEnabled: Boolean,
    val eqPresetId: String?,
    val eqBandLevels: Map<Int, Float>,
    val volumeNormalizationEnabled: Boolean,
    val panning: Float,
    val repeatOne: Boolean,
    val repeatAll: Boolean,
    val shuffleModeEnabled: Boolean,
    val queueStartIndex: Int,
    val queue: List<StoredNativePlaybackQueueItem>,
    val channelSwapEnabled: Boolean,
    val playing: Boolean,
    val playWhenReady: Boolean,
    val definitionRevision: Long = 0L,
    val isTemporary: Boolean = false,
    val completed: Boolean = false
)

data class StoredNativePlaybackQueueItem(
    val path: String,
    val uri: String,
    val title: String,
    val subtitle: String?,
    val artUri: String?,
    val candidateUris: List<String> = emptyList()
)

data class StoredPlaybackTimerRuntimeState(
    val timerModeIndex: Int?,
    val durationMs: Long?,
    val waitingForPlayback: Boolean,
    val timerEndsAtWallClockMs: Long?,
    val timerEndsElapsedRealtimeMs: Long?,
    val autoResumeEnabled: Boolean,
    val autoResumeHour: Int,
    val autoResumeMinute: Int,
    val autoResumeAtMs: Long?,
    val pausedSessionIds: List<String>,
    val generation: Int
) {
    val hasRuntime: Boolean
        get() = (timerModeIndex != null && durationMs != null && waitingForPlayback) ||
            timerEndsAtWallClockMs != null ||
            autoResumeAtMs != null ||
            pausedSessionIds.isNotEmpty()

    val shouldKeepForegroundServiceAlive: Boolean
        get() = (timerModeIndex != null && durationMs != null && waitingForPlayback) ||
            timerEndsAtWallClockMs != null ||
            autoResumeAtMs != null
}

data class StoredPlaybackBehavior(
    val pauseOnAudioDeviceDisconnect: Boolean = true,
    val requestAudioFocus: Boolean = true,
    val pauseOnTransientAudioFocusLoss: Boolean = false,
    val resumeAfterTransientAudioFocusGain: Boolean = true
)

object NativePlaybackStateStore {
    private val revisionSequence = AtomicLong()
    private val clearedRevision = AtomicLong()
    private val definitionRevisions = ConcurrentHashMap<String, Long>()
    private val revisionLock = Any()
    @PublishedApi internal val timerStateLock = Any()
    private val temporarySessions = ConcurrentHashMap<String, StoredNativePlaybackSession>()

    // Timer changes never wait for the queue JSON serialization lock.
    internal inline fun <T> withTimerState(action: () -> T): T = synchronized(timerStateLock, action)

    internal fun saveTemporarySession(session: StoredNativePlaybackSession) {
        require(session.isTemporary)
        temporarySessions[session.sessionId] = session.copy(definitionRevision = sessionRevision(session.sessionId))
    }

    internal fun loadTemporarySessions(): List<StoredNativePlaybackSession> = temporarySessions.values.toList()
    internal fun removeTemporarySession(sessionId: String) { temporarySessions.remove(sessionId) }

    internal fun sessionRevision(sessionId: String): Long =
        maxOf(clearedRevision.get(), definitionRevisions[sessionId] ?: 0L)

    internal fun invalidateSession(sessionId: String): Long = synchronized(revisionLock) {
        revisionSequence.incrementAndGet().also { definitionRevisions[sessionId] = it }
    }

    internal fun invalidateAllSessions(): Long = synchronized(revisionLock) {
        revisionSequence.incrementAndGet().also {
            definitionRevisions.clear()
            clearedRevision.set(it)
        }
    }

    @Synchronized
    internal fun saveColdSession(context: Context, session: StoredNativePlaybackSession) {
        invalidateSession(session.sessionId)
        upsertSessions(context, listOf(session))
    }

    @Synchronized
    internal fun upsertSessions(
        context: Context,
        sessions: List<StoredNativePlaybackSession>,
        expectedRevisions: Map<String, Long>? = null
    ) {
        val accepted = sessions.filter { expectedRevisions == null ||
            expectedRevisions[it.sessionId] == sessionRevision(it.sessionId) }
        accepted.filter { it.isTemporary }.forEach(::saveTemporarySession)
        val persistent = accepted.filterNot { it.isTemporary }
        if (persistent.isEmpty()) return
        persistent.forEach { temporarySessions.remove(it.sessionId) }
        saveSessions(context, mergeNativePlaybackDefinitions(loadSessions(context), persistent))
    }

    @Synchronized
    internal fun upsertSessionProgress(
        context: Context,
        progress: List<StoredNativePlaybackProgress>,
        expectedRevisions: Map<String, Long>
    ) {
        val accepted = progress.filter { expectedRevisions[it.sessionId] == sessionRevision(it.sessionId) }
        if (accepted.isEmpty()) return
        val merged = loadSessionProgress(context).toMutableMap()
        accepted.forEach { merged[it.sessionId] = it }
        saveSessionProgress(context, merged.values.toList())
    }

    @Synchronized
    internal fun removeSession(context: Context, sessionId: String, expectedRevision: Long? = null) {
        if (expectedRevision != null && expectedRevision != sessionRevision(sessionId)) return
        if (expectedRevision == null) invalidateSession(sessionId)
        removeTemporarySession(sessionId)
        val sessions = loadSessions(context)
        if (sessions.any { it.sessionId == sessionId }) {
            saveSessions(context, sessions.filterNot { it.sessionId == sessionId })
        } else {
            saveSessionProgress(context, loadSessionProgress(context).values.filterNot { it.sessionId == sessionId })
        }
        withTimerState {
            storePausedSessionIds(context, loadPausedSessionIds(context).filterNot { it == sessionId })
            storeTimerCandidateSessionIds(context, loadTimerCandidateSessionIds(context).filterNot { it == sessionId })
            loadTimerRuntimeState(context)?.let { timer ->
                saveTimerRuntimeState(context, timer.withoutSession(sessionId))
            }
        }
    }

    private const val preferencesName = "audio_player_native_playback_state"
    private const val progressPreferencesName = "audio_player_native_playback_progress"
    private const val keySessions = "sessions"
    // Separate files avoid rewriting the queue XML on every progress tick. The
    // generation prevents an old progress file overlaying a newer queue after a crash.
    private const val keyProgressGeneration = "progress_generation"
    private const val keySessionProgress = "session_progress_v1"
    private const val keyPausedSessionIds = "paused_session_ids"
    private const val keyTimerCandidateSessionIds = "timer_candidate_session_ids"
    private const val keyTimerRuntimeState = "timer_runtime_state_v3"
    private const val keyPlaybackBehavior = "playback_behavior_v1"

    fun savePlaybackBehavior(context: Context, behavior: StoredPlaybackBehavior) {
        val encoded = JSONObject()
            .put("pauseOnAudioDeviceDisconnect", behavior.pauseOnAudioDeviceDisconnect)
            .put("requestAudioFocus", behavior.requestAudioFocus)
            .put("pauseOnTransientAudioFocusLoss", behavior.pauseOnTransientAudioFocusLoss)
            .put(
                "resumeAfterTransientAudioFocusGain",
                behavior.resumeAfterTransientAudioFocusGain
            )
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putString(keyPlaybackBehavior, encoded.toString())
            .apply()
    }

    fun loadPlaybackBehavior(context: Context): StoredPlaybackBehavior {
        val raw = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getString(keyPlaybackBehavior, null)
            ?: return StoredPlaybackBehavior()
        return try {
            val json = JSONObject(raw)
            StoredPlaybackBehavior(
                pauseOnAudioDeviceDisconnect =
                    json.optBoolean("pauseOnAudioDeviceDisconnect", true),
                requestAudioFocus = json.optBoolean("requestAudioFocus", true),
                pauseOnTransientAudioFocusLoss =
                    json.optBoolean("pauseOnTransientAudioFocusLoss", false),
                resumeAfterTransientAudioFocusGain =
                    json.optBoolean("resumeAfterTransientAudioFocusGain", true)
            )
        } catch (_: Exception) {
            StoredPlaybackBehavior()
        }
    }

    @Synchronized
    fun saveSessions(
        context: Context,
        sessions: List<StoredNativePlaybackSession>
    ) {
        val array = JSONArray()
        sessions.filterNot { it.isTemporary }.forEach { session ->
            array.put(
                JSONObject()
                    .put("sessionId", session.sessionId)
                    .put("uri", session.uri)
                    .put("path", session.path)
                    .put("title", session.title)
                    .put("subtitle", session.subtitle)
                    .put("artUri", session.artUri)
                    .put("positionMs", session.positionMs)
                    .put("volume", session.volume.toDouble())
                    .put("speed", session.speed.toDouble())
                    .put("skipSilenceEnabled", session.skipSilenceEnabled)
                    .put("noiseReductionEnabled", session.noiseReductionEnabled)
                    .put("eqEnabled", session.eqEnabled)
                    .put("eqPresetId", session.eqPresetId)
                    .put("volumeNormalizationEnabled", session.volumeNormalizationEnabled)
                    .put("panning", session.panning.toDouble())
                    .put(
                        "eqBandLevels",
                        JSONArray().apply {
                            session.eqBandLevels.forEach { (frequencyHz, gainDb) ->
                                put(
                                    JSONObject()
                                        .put("frequencyHz", frequencyHz)
                                        .put("gainDb", gainDb.toDouble())
                                )
                            }
                        }
                    )
                    .put("repeatOne", session.repeatOne)
                    .put("repeatAll", session.repeatAll)
                    .put("shuffleModeEnabled", session.shuffleModeEnabled)
                    .put("queueStartIndex", session.queueStartIndex)
                    .put(
                        "queue",
                        JSONArray().apply {
                            session.queue.forEach { queueItem ->
                                put(
                                    JSONObject()
                                        .put("path", queueItem.path)
                                        .put("uri", queueItem.uri)
                                        .put("title", queueItem.title)
                                        .put("subtitle", queueItem.subtitle)
                                        .put("artUri", queueItem.artUri)
                                        .put(
                                            "candidateUris",
                                            JSONArray(queueItem.candidateUris)
                                        )
                                )
                            }
                        }
                    )
                    .put("channelSwapEnabled", session.channelSwapEnabled)
                    .put("playing", session.playing)
                    .put("playWhenReady", session.playWhenReady)
                    .put("completed", session.completed)
            )
        }
        val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        val generation = preferences.getLong(keyProgressGeneration, 0L) + 1
        preferences
            .edit()
            .putString(keySessions, array.toString())
            .putLong(keyProgressGeneration, generation)
            .remove(keySessionProgress)
            .apply()
        // All positions are already in the structural snapshot.
        saveSessionProgress(context, emptyList())
    }

    /**
     * Persists only the fields that change every tick. Payload is a few dozen
     * bytes per session regardless of queue size.
     */
    @Synchronized
    fun saveSessionProgress(
        context: Context,
        progress: List<StoredNativePlaybackProgress>
    ) {
        val preferences = progressPreferences(context)
        val generation = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getLong(keyProgressGeneration, 0L)
        val editor = preferences.edit().putLong(keyProgressGeneration, generation)
        if (progress.isEmpty()) {
            editor.remove(keySessionProgress).apply()
            return
        }
        val array = JSONArray()
        progress.forEach { item ->
            array.put(
                JSONObject()
                    .put("sessionId", item.sessionId)
                    .put("positionMs", item.positionMs)
                    .put("playing", item.playing)
                    .put("playWhenReady", item.playWhenReady)
            )
        }
        editor.putString(keySessionProgress, array.toString()).apply()
    }

    private fun progressPreferences(context: Context): SharedPreferences {
        val progress = context.getSharedPreferences(progressPreferencesName, Context.MODE_PRIVATE)
        val definitions = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        val legacy = definitions.getString(keySessionProgress, null) ?: return progress
        // Timer expiry can read the old overlay on main before background restore
        // finishes. Defer the durable migration until a storage/restore executor reads it.
        if (Looper.myLooper() == Looper.getMainLooper()) return progress
        val editor = progress.edit()
        if (!progress.contains(keyProgressGeneration)) editor.putString(keySessionProgress, legacy)
        val generation = progress.getLong(keyProgressGeneration,
            definitions.getLong(keyProgressGeneration, 0L))
        // Preserve a cleared/newer progress file if migration was interrupted. A
        // failed commit leaves the legacy key intact for the next background read.
        if (editor.putLong(keyProgressGeneration, generation).commit()) {
            definitions.edit().remove(keySessionProgress).apply()
        }
        return progress
    }

    private fun loadSessionProgress(context: Context): Map<String, StoredNativePlaybackProgress> {
        val progress = progressPreferences(context)
        val definitions = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        val overlay = if (progress.contains(keyProgressGeneration)) progress else definitions
        if (overlay.getLong(keyProgressGeneration, 0L) != definitions.getLong(keyProgressGeneration, 0L)) {
            return emptyMap()
        }
        val raw = overlay.getString(keySessionProgress, null) ?: return emptyMap()
        return try {
            val array = JSONArray(raw)
            buildMap {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val sessionId = item.optString("sessionId").takeIf { it.isNotBlank() }
                        ?: continue
                    put(
                        sessionId,
                        StoredNativePlaybackProgress(
                            sessionId = sessionId,
                            positionMs = item.optLong("positionMs", 0L).coerceAtLeast(0L),
                            playing = item.optBoolean("playing", false),
                            playWhenReady = item.optBoolean("playWhenReady", false)
                        )
                    )
                }
            }
        } catch (_: Exception) {
            emptyMap()
        }
    }

    @Synchronized
    fun clearSessions(context: Context, expectedRevision: Long? = null) {
        val revision = expectedRevision ?: invalidateAllSessions()
        val newer = loadSessions(context).filter { sessionRevision(it.sessionId) > revision }
        temporarySessions.keys.toList().filter { sessionRevision(it) <= revision }.forEach(temporarySessions::remove)
        if (newer.isNotEmpty()) {
            saveSessions(context, newer)
            return
        }
        val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        val generation = preferences.getLong(keyProgressGeneration, 0L) + 1
        preferences
            .edit()
            .remove(keySessions)
            .putLong(keyProgressGeneration, generation)
            .remove(keySessionProgress)
            .apply()
        saveSessionProgress(context, emptyList())
    }

    /** Called on the file executor; queue values are skipped without creating queue objects. */
    @Synchronized
    internal fun loadActiveSessionRevisions(context: Context): Map<String, Long> {
        // A session can be invalidated while this background read owns the store
        // lock. Do not attach the newer revision to its old persisted definition.
        val readRevision = revisionSequence.get()
        val raw = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getString(keySessions, null)
        val progress = loadSessionProgress(context)
        val ids = try {
            if (raw == null) emptyList() else JsonReader(StringReader(raw)).use { reader ->
                buildList {
                    reader.beginArray()
                    while (reader.hasNext()) {
                        if (reader.peek() != JsonToken.BEGIN_OBJECT) {
                            reader.skipValue()
                            continue
                        }
                        var id: String? = null
                        var uri: String? = null
                        var playing = false
                        var ready = false
                        reader.beginObject()
                        while (reader.hasNext()) {
                            val name = reader.nextName()
                            when (name) {
                                "sessionId", "uri" -> {
                                    if (reader.peek() == JsonToken.STRING || reader.peek() == JsonToken.NUMBER) {
                                        val value = reader.nextString()
                                        if (name == "sessionId") id = value else uri = value
                                    } else reader.skipValue()
                                }
                                "playing", "playWhenReady" -> {
                                    val value = when (reader.peek()) {
                                        JsonToken.BOOLEAN -> reader.nextBoolean()
                                        JsonToken.STRING -> reader.nextString().equals("true", ignoreCase = true)
                                        else -> { reader.skipValue(); false }
                                    }
                                    if (name == "playing") playing = value else ready = value
                                }
                                else -> reader.skipValue()
                            }
                        }
                        reader.endObject()
                        val validId = id?.takeIf(String::isNotBlank) ?: continue
                        if (uri.isNullOrBlank()) continue
                        val overlay = progress[validId]
                        if (overlay?.let { it.playing || it.playWhenReady } ?: (playing || ready)) add(validId)
                    }
                    reader.endArray()
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
        return (ids + loadTemporarySessions().filter { it.playing || it.playWhenReady }.map { it.sessionId })
            .mapNotNull { id -> sessionRevision(id).takeIf { it <= readRevision }?.let { id to it } }
            .toMap()
    }

    @Synchronized
    fun loadSessions(context: Context): List<StoredNativePlaybackSession> {
        val raw = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getString(keySessions, null)
            ?: return loadTemporarySessions()
        val progressBySessionId = loadSessionProgress(context)
        return try {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val sessionId = item.optString("sessionId").takeIf { it.isNotBlank() }
                        ?: continue
                    val uri = item.optString("uri").takeIf { it.isNotBlank() }
                        ?: continue
                    val progress = progressBySessionId[sessionId]
                    add(
                        StoredNativePlaybackSession(
                            sessionId = sessionId,
                            uri = uri,
                            path = item.optString("path").takeIf { it.isNotBlank() } ?: uri,
                            title = item.optString("title", "Audio"),
                            subtitle = item.optNullableString("subtitle"),
                            artUri = item.optNullableString("artUri"),
                            positionMs = item.optLong("positionMs", 0L).coerceAtLeast(0L),
                            volume = item.optDouble("volume", 1.0).toFloat(),
                            speed = item.optDouble("speed", 1.0).toFloat(),
                            skipSilenceEnabled = item.optBoolean("skipSilenceEnabled", false),
                            noiseReductionEnabled = item.optBoolean("noiseReductionEnabled", false),
                            eqEnabled = item.optBoolean("eqEnabled", false),
                            eqPresetId = item.optNullableString("eqPresetId"),
                            eqBandLevels = item.optEqBandLevels(),
                            volumeNormalizationEnabled =
                                item.optBoolean("volumeNormalizationEnabled", false),
                            panning = item.optDouble("panning", 0.0).toFloat(),
                            repeatOne = item.optBoolean("repeatOne", false),
                            repeatAll = item.optBoolean("repeatAll", false),
                            shuffleModeEnabled = item.optBoolean("shuffleModeEnabled", false),
                            queueStartIndex = item.optInt("queueStartIndex", 0).coerceAtLeast(0),
                            queue = item.optQueueItems(),
                            channelSwapEnabled = item.optBoolean("channelSwapEnabled", false),
                            playing = item.optBoolean("playing", false),
                            playWhenReady = item.optBoolean("playWhenReady", false),
                            definitionRevision = sessionRevision(sessionId),
                            completed = item.optBoolean("completed", false)
                        ).withProgressOverlay(progress)
                    )
                }
            } + loadTemporarySessions()
        } catch (_: Exception) {
            loadTemporarySessions()
        }
    }

    fun storePausedSessionIds(context: Context, sessionIds: List<String>) = withTimerState {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putStringSet(keyPausedSessionIds, sessionIds.toSet())
            .apply()
    }

    fun loadPausedSessionIds(context: Context): List<String> = withTimerState {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getStringSet(keyPausedSessionIds, emptySet())
            ?.toList()
            ?.sorted()
            ?: emptyList()
    }

    fun clearPausedSessionIds(context: Context) = withTimerState {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .remove(keyPausedSessionIds)
            .apply()
    }

    fun storeTimerCandidateSessionIds(context: Context, sessionIds: List<String>) = withTimerState {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putStringSet(keyTimerCandidateSessionIds, sessionIds.toSet())
            .apply()
    }

    fun loadTimerCandidateSessionIds(context: Context): List<String> = withTimerState {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getStringSet(keyTimerCandidateSessionIds, emptySet())
            ?.toList()
            ?.sorted()
            ?: emptyList()
    }

    fun clearTimerCandidateSessionIds(context: Context) = withTimerState {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .remove(keyTimerCandidateSessionIds)
            .apply()
    }

    fun saveTimerRuntimeState(
        context: Context,
        state: StoredPlaybackTimerRuntimeState
    ) = withTimerState {
        if (!state.hasRuntime) {
            clearTimerRuntimeState(context)
            return@withTimerState
        }
        val encoded = JSONObject()
            .put("timerModeIndex", state.timerModeIndex)
            .put("durationMs", state.durationMs)
            .put("waitingForPlayback", state.waitingForPlayback)
            .put("timerEndsAtWallClockMs", state.timerEndsAtWallClockMs)
            .put("timerEndsElapsedRealtimeMs", state.timerEndsElapsedRealtimeMs)
            .put("autoResumeEnabled", state.autoResumeEnabled)
            .put("autoResumeHour", state.autoResumeHour)
            .put("autoResumeMinute", state.autoResumeMinute)
            .put("autoResumeAtMs", state.autoResumeAtMs)
            .put("generation", state.generation)
            .put("pausedSessionIds", JSONArray(state.pausedSessionIds))
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putString(keyTimerRuntimeState, encoded.toString())
            .apply()
    }

    fun loadTimerRuntimeState(context: Context): StoredPlaybackTimerRuntimeState? = withTimerState {
        val raw = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getString(keyTimerRuntimeState, null)
            ?: return@withTimerState null
        try {
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
                timerEndsAtWallClockMs = json.optNullableLong("timerEndsAtWallClockMs")
                    ?: json.optNullableLong("timerEndsAtMs"),
                timerEndsElapsedRealtimeMs = json.optNullableLong("timerEndsElapsedRealtimeMs"),
                autoResumeEnabled = json.optBoolean("autoResumeEnabled", false),
                autoResumeHour = json.optInt("autoResumeHour", 7),
                autoResumeMinute = json.optInt("autoResumeMinute", 0),
                autoResumeAtMs = json.optNullableLong("autoResumeAtMs"),
                pausedSessionIds = pausedSessionIds,
                generation = json.optInt("generation", 0)
            )
        } catch (_: Exception) {
            null
        }
    }

    fun clearTimerRuntimeState(context: Context) = withTimerState {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .remove(keyTimerRuntimeState)
            .apply()
    }
}

internal fun mergeNativePlaybackDefinitions(
    existing: List<StoredNativePlaybackSession>,
    updates: List<StoredNativePlaybackSession>
): List<StoredNativePlaybackSession> = existing.associateByTo(linkedMapOf()) { it.sessionId }.apply {
    updates.forEach { put(it.sessionId, it) }
}.values.toList()

internal fun StoredPlaybackTimerRuntimeState.withoutSession(sessionId: String) =
    copy(pausedSessionIds = pausedSessionIds.filterNot { it == sessionId })

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

private fun JSONObject.optEqBandLevels(): Map<Int, Float> {
    val array = optJSONArray("eqBandLevels") ?: return emptyMap()
    return buildMap {
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val frequencyHz = item.optInt("frequencyHz", 0)
            if (frequencyHz <= 0) continue
            put(frequencyHz, item.optDouble("gainDb", 0.0).toFloat())
        }
    }
}

private fun JSONObject.optQueueItems(): List<StoredNativePlaybackQueueItem> {
    val array = optJSONArray("queue") ?: return emptyList()
    return buildList {
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val uri = item.optString("uri").takeIf { it.isNotBlank() } ?: continue
            val path = item.optString("path").takeIf { it.isNotBlank() } ?: uri
            add(
                StoredNativePlaybackQueueItem(
                    path = path,
                    uri = uri,
                    title = item.optString("title", "Audio"),
                    subtitle = item.optNullableString("subtitle"),
                    artUri = item.optNullableString("artUri"),
                    candidateUris = item.optStringList("candidateUris")
                )
            )
        }
    }
}

private fun JSONObject.optStringList(key: String): List<String> {
    val values = optJSONArray(key) ?: return emptyList()
    return buildList {
        for (index in 0 until values.length()) {
            val value = values.optString(index).trim()
            if (value.isNotEmpty() && value !in this) add(value)
        }
    }
}
