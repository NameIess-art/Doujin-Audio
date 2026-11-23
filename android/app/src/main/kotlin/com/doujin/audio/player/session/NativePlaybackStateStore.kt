package com.doujin.audio.player.session

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/** The subset of [StoredNativePlaybackSession] that changes on every tick. */
data class StoredNativePlaybackProgress(
    val sessionId: String,
    val positionMs: Long,
    val playing: Boolean,
    val playWhenReady: Boolean
)

/** Applies progress associated with the same committed definition. */
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
    val completed: Boolean = false,
    val frontBack: Float = 0f,
    val discardedQueuePrefix: Boolean = false
)

data class StoredNativePlaybackQueueItem(
    val path: String,
    val uri: String,
    val title: String,
    val subtitle: String?,
    val artUri: String?,
    val candidateUris: List<String> = emptyList(),
    val usageDescriptor: Map<String, Any?>? = null,
    val clipStartMs: Long = 0L,
    val clipEndMs: Long? = null,
    val httpHeaders: Map<String, String> = emptyMap(),
    val playOnceBeforeQueue: Boolean = false
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
    val generation: Int,
    val stopAfterCurrentTrack: Boolean = false
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
    private val stagedLock = Any()
    @PublishedApi internal val timerStateLock = Any()
    private val temporarySessions = ConcurrentHashMap<String, StoredNativePlaybackSession>()
    private val stagedSessions = mutableMapOf<String, StoredNativePlaybackSession>()
    private val persistedRevisions = mutableMapOf<String, Long>()
    private var recoveryDatabase: NativePlaybackRecoveryDatabase? = null
    private val persistenceExecutor: ExecutorService by lazy {
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "NativePlaybackStateStore").apply { isDaemon = true }
        }
    }

    internal fun executeOnPersistenceExecutor(task: () -> Unit) {
        persistenceExecutor.execute {
            try {
                task()
            } catch (error: Exception) {
                Log.e("PlaybackRecovery", "Unable to persist playback state", error)
            }
        }
    }

    internal fun awaitPendingPersistenceForTest(timeoutMs: Long = 10_000L): Boolean {
        val latch = CountDownLatch(1)
        persistenceExecutor.execute { latch.countDown() }
        return latch.await(timeoutMs, TimeUnit.MILLISECONDS)
    }

    // Accessed under the store monitor. Separate Android data directories also
    // isolate recovery databases used by tests and profile installations.
    private fun database(context: Context): NativePlaybackRecoveryDatabase {
        val owner = context.applicationContext
        val existing = recoveryDatabase
        if (existing?.owner === owner) return existing
        existing?.close()
        persistedRevisions.clear()
        return NativePlaybackRecoveryDatabase(owner).also { recoveryDatabase = it }
    }

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

    internal fun stageSessions(
        sessions: List<StoredNativePlaybackSession>,
        expectedRevisions: Map<String, Long>
    ) {
        synchronized(stagedLock) {
            sessions.forEach { session ->
                val currentRevision = sessionRevision(session.sessionId)
                if (expectedRevisions[session.sessionId] == currentRevision) {
                    stagedSessions[session.sessionId] =
                        session.copy(definitionRevision = currentRevision)
                }
            }
        }
    }

    internal fun invalidateSession(sessionId: String): Long = synchronized(revisionLock) {
        revisionSequence.incrementAndGet().also {
            definitionRevisions[sessionId] = it
            synchronized(stagedLock) { stagedSessions.remove(sessionId) }
        }
    }

    internal fun invalidateAllSessions(): Long = synchronized(revisionLock) {
        revisionSequence.incrementAndGet().also {
            definitionRevisions.clear()
            clearedRevision.set(it)
            synchronized(stagedLock) { stagedSessions.clear() }
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
        val accepted = sessions.mapNotNull { session ->
            val revision = sessionRevision(session.sessionId)
            session.copy(definitionRevision = revision).takeIf {
                expectedRevisions == null || expectedRevisions[session.sessionId] == revision
            }
        }
        val persistent = accepted.filterNot { it.isTemporary }
        if (persistent.isNotEmpty()) {
            database(context).upsertDefinitions(persistent)
            persistent.forEach {
                temporarySessions.remove(it.sessionId)
                persistedRevisions[it.sessionId] = it.definitionRevision
            }
        }
        accepted.filter { it.isTemporary }.forEach {
            if (sessionRevision(it.sessionId) == it.definitionRevision) saveTemporarySession(it)
        }
        synchronized(stagedLock) {
            accepted.forEach { session ->
                // A later transport state can share the definition revision.
                if (stagedSessions[session.sessionId] == session) {
                    stagedSessions.remove(session.sessionId)
                }
            }
        }
    }

    @Synchronized
    internal fun upsertSessionMetadata(
        context: Context,
        sessions: List<StoredNativePlaybackSession>,
        expectedRevisions: Map<String, Long>? = null
    ) {
        val accepted = sessions.mapNotNull { session ->
            val revision = sessionRevision(session.sessionId)
            session.copy(definitionRevision = revision).takeIf {
                expectedRevisions == null || expectedRevisions[session.sessionId] == revision
            }
        }
        val persistent = accepted.filterNot { it.isTemporary }
        if (persistent.isNotEmpty()) {
            database(context).updateMetadata(persistent)
            persistent.forEach {
                temporarySessions.remove(it.sessionId)
                persistedRevisions[it.sessionId] = it.definitionRevision
            }
        }
        accepted.filter { it.isTemporary }.forEach {
            if (sessionRevision(it.sessionId) == it.definitionRevision) saveTemporarySession(it)
        }
        synchronized(stagedLock) {
            accepted.forEach { session ->
                if (stagedSessions[session.sessionId] == session) {
                    stagedSessions.remove(session.sessionId)
                }
            }
        }
    }

    @Synchronized
    internal fun upsertSessionProgress(
        context: Context,
        progress: List<StoredNativePlaybackProgress>,
        expectedRevisions: Map<String, Long>
    ) {
        val accepted = progress.filter { expectedRevisions[it.sessionId] == sessionRevision(it.sessionId) }
        val durable = accepted.filter { item ->
            val temporary = temporarySessions[item.sessionId] ?: return@filter true
            if (temporary.definitionRevision == expectedRevisions[item.sessionId]) {
                temporarySessions.replace(item.sessionId, temporary, temporary.withProgressOverlay(item))
            }
            false
        }
        if (durable.isNotEmpty()) database(context).updateProgress(durable)
        // The application looper stages progress before queuing this write.
        // An older disk write must preserve a newer staged transport state.
    }

    @Synchronized
    internal fun pauseStoredSessions(context: Context) {
        database(context).pauseSessions()
        synchronized(stagedLock) {
            stagedSessions.replaceAll { _, session ->
                session.copy(playing = false, playWhenReady = false)
            }
        }
    }

    @Synchronized
    internal fun retainedRecoveryContentUris(context: Context): Set<String> {
        val staged = synchronized(stagedLock) { stagedSessions.values.toList() }
        return database(context).retainedUris() +
            (loadTemporarySessions() + staged).flatMap { it.retainedContentUris() }
    }

    @Synchronized
    internal fun removeSession(context: Context, sessionId: String, expectedRevision: Long? = null) {
        if (expectedRevision != null && expectedRevision != sessionRevision(sessionId)) return
        if (expectedRevision == null) invalidateSession(sessionId)
        synchronized(stagedLock) { stagedSessions.remove(sessionId) }
        removeTemporarySession(sessionId)
        database(context).removeSessions(listOf(sessionId))
        persistedRevisions.remove(sessionId)
        withTimerState {
            storePausedSessionIds(context, loadPausedSessionIds(context).filterNot { it == sessionId })
            removeTimerCandidateSessionId(context, sessionId)
            loadTimerRuntimeState(context)?.let { timer ->
                saveTimerRuntimeState(context, timer.withoutSession(sessionId))
            }
        }
    }

    private const val preferencesName = "audio_player_native_playback_state"
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
    fun clearSessions(context: Context, expectedRevision: Long? = null) {
        val revision = expectedRevision ?: invalidateAllSessions()
        val db = database(context)
        val retired = db.sessionIds().filter { (persistedRevisions[it] ?: 0L) <= revision }
        db.removeSessions(retired)
        persistedRevisions.keys.removeAll(retired.toSet())
        temporarySessions.values.removeAll { it.definitionRevision <= revision }
        synchronized(stagedLock) {
            stagedSessions.values.removeAll { it.definitionRevision <= revision }
        }
    }

    /** Timer candidate discovery reads only the progress columns. */
    @Synchronized
    internal fun loadActiveSessionRevisions(context: Context): Map<String, Long> {
        val stagedById = synchronized(stagedLock) {
            stagedSessions.values.filter { sessionRevision(it.sessionId) == it.definitionRevision }
        }.associateBy { it.sessionId }
        val ids = database(context).sessionIds(activeOnly = true)
        val durable = ids.filterNot { it in stagedById }.mapNotNull { id ->
            val revision = persistedRevisions[id] ?: 0L
            (id to revision).takeIf { sessionRevision(id) == revision }
        }
        val temporary = loadTemporarySessions().filter {
            it.sessionId !in stagedById &&
                (it.playing || it.playWhenReady) &&
                sessionRevision(it.sessionId) == it.definitionRevision
        }.map {
            it.sessionId to it.definitionRevision
        }
        val staged = stagedById.values.filter {
            it.playing || it.playWhenReady
        }.map {
            it.sessionId to it.definitionRevision
        }
        return (durable + temporary + staged).toMap()
    }

    @Synchronized
    internal fun loadSessions(
        context: Context,
        sessionIds: Set<String>? = null,
        activeOnly: Boolean = false
    ): List<StoredNativePlaybackSession> {
        if (sessionIds?.isEmpty() == true) return emptyList()
        val stagedById = synchronized(stagedLock) {
            stagedSessions.values.filter { sessionRevision(it.sessionId) == it.definitionRevision }
        }.associateBy { it.sessionId }
        val db = database(context)
        val durable = db.loadSessions(sessionIds, activeOnly)
            .filterNot { it.sessionId in stagedById }
            .mapNotNull {
                val revision = persistedRevisions[it.sessionId] ?: 0L
                it.copy(definitionRevision = revision).takeIf { sessionRevision(it.sessionId) == revision }
            }
        val temporary = loadTemporarySessions().filter {
            it.sessionId !in stagedById &&
                (sessionIds == null || it.sessionId in sessionIds) &&
                (!activeOnly || it.playing || it.playWhenReady) &&
                sessionRevision(it.sessionId) == it.definitionRevision
        }
        val staged = stagedById.values.filter {
            (sessionIds == null || it.sessionId in sessionIds) &&
                (!activeOnly || it.playing || it.playWhenReady)
        }
        return durable + temporary + staged
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

    internal fun removeTimerCandidateSessionId(context: Context, sessionId: String) = withTimerState {
        val candidates = loadTimerCandidateSessionIds(context)
        if (sessionId in candidates) {
            val remaining = candidates.filterNot { it == sessionId }
            if (remaining.isEmpty()) clearTimerCandidateSessionIds(context)
            else storeTimerCandidateSessionIds(context, remaining)
        }
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
            .put("stopAfterCurrentTrack", state.stopAfterCurrentTrack)
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
                generation = json.optInt("generation", 0),
                // Older Android alarms always finished the current track at expiry.
                stopAfterCurrentTrack = json.optBoolean(
                    "stopAfterCurrentTrack",
                    json.optNullableLong("timerEndsAtWallClockMs") != null ||
                        json.optNullableLong("timerEndsAtMs") != null
                )
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

internal fun StoredPlaybackTimerRuntimeState.withoutSession(sessionId: String): StoredPlaybackTimerRuntimeState {
    if (sessionId !in pausedSessionIds) return this
    val remaining = pausedSessionIds.filterNot { it == sessionId }
    return copy(
        autoResumeAtMs = autoResumeAtMs.takeIf { remaining.isNotEmpty() },
        pausedSessionIds = remaining
    )
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
