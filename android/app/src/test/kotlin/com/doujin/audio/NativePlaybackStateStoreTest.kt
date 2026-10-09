package com.doujin.audio

import android.content.Context
import com.doujin.audio.player.session.NativePlaybackStateStore
import com.doujin.audio.player.session.StoredNativePlaybackProgress
import com.doujin.audio.player.session.StoredNativePlaybackQueueItem
import com.doujin.audio.player.session.StoredNativePlaybackSession
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.concurrent.Executors

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class NativePlaybackStateStoreTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val definitions get() = context.getSharedPreferences("audio_player_native_playback_state", Context.MODE_PRIVATE)
    private val progress get() = context.getSharedPreferences("audio_player_native_playback_progress", Context.MODE_PRIVATE)
    private val progressKey = "session_progress_v1"
    private val generationKey = "progress_generation"

    @Before
    fun reset() {
        NativePlaybackStateStore.clearSessions(context)
        definitions.edit().clear().commit()
        progress.edit().clear().commit()
    }

    @Test
    fun `progress updates touch only the small container and restore over unchanged queues`() {
        val stored = session("A", 1_000L)
        NativePlaybackStateStore.saveSessions(context, listOf(stored))
        val initialDefinitions = definitions.all.toMap()

        for (position in listOf(16_000L, 31_000L, 46_000L)) {
            NativePlaybackStateStore.saveSessionProgress(context, listOf(playingProgress("A", position)))
        }

        assertEquals(initialDefinitions, definitions.all)
        assertFalse(definitions.contains(progressKey))
        assertTrue(progress.contains(progressKey))
        assertFalse(progress.contains("sessions"))
        val restored = NativePlaybackStateStore.loadSessions(context).single()
        assertEquals(46_000L, restored.positionMs)
        assertEquals(stored.queue, restored.queue)
        assertTrue(restored.playing)
        assertEquals(setOf("A"), NativePlaybackStateStore.loadActiveSessionRevisions(context).keys)
    }

    @Test
    fun `legacy progress migrates once and does not replace newer progress on recovery`() {
        seedLegacyProgress(playingProgress("A", 9_000L))

        // The timer's main-thread fallback reads compatibly without committing migration.
        assertEquals(9_000L, NativePlaybackStateStore.loadSessions(context).single().positionMs)
        assertTrue(definitions.contains(progressKey))
        assertFalse(progress.contains(progressKey))
        assertEquals(9_000L, loadOnBackground().single().positionMs)
        assertFalse(definitions.contains(progressKey))
        assertTrue(progress.contains(progressKey))
        assertEquals(setOf("A"), NativePlaybackStateStore.loadActiveSessionRevisions(context).keys)

        NativePlaybackStateStore.saveSessionProgress(context, listOf(playingProgress("A", 24_000L)))
        // Simulate termination after the new file landed but before the old key was removed.
        definitions.edit().putString(progressKey, encode(playingProgress("A", 9_000L))).commit()
        assertEquals(24_000L, loadOnBackground().single().positionMs)
        assertFalse(definitions.contains(progressKey))
    }

    @Test
    fun `cleared new progress is authoritative over a leftover legacy key`() {
        seedLegacyProgress(playingProgress("A", 9_000L))
        loadOnBackground()
        NativePlaybackStateStore.saveSessionProgress(context, emptyList())
        definitions.edit().putString(progressKey, encode(playingProgress("A", 9_000L))).commit()

        val restored = loadOnBackground().single()
        assertEquals(1_000L, restored.positionMs)
        assertFalse(restored.playing)
        assertFalse(definitions.contains(progressKey))
        assertFalse(progress.contains(progressKey))
    }

    @Test
    fun `structural replacement rejects the previous progress file after an interrupted write`() {
        NativePlaybackStateStore.saveSessions(context, listOf(session("A", 1_000L)))
        NativePlaybackStateStore.saveSessionProgress(context, listOf(playingProgress("A", 30_000L)))
        val oldProgress = progress.getString(progressKey, null)
        val oldGeneration = progress.getLong(generationKey, 0L)
        val replacement = session("A", 500L).copy(uri = "file:///new.mp3", path = "/new.mp3")
        NativePlaybackStateStore.upsertSessions(context, listOf(replacement))

        assertFalse(progress.contains(progressKey))
        // The structural file reached disk while the old progress file remained.
        progress.edit().putString(progressKey, oldProgress).putLong(generationKey, oldGeneration).commit()
        val restored = NativePlaybackStateStore.loadSessions(context).single()
        assertEquals("/new.mp3", restored.path)
        assertEquals(500L, restored.positionMs)
        assertFalse(restored.playing)
        assertTrue(NativePlaybackStateStore.loadActiveSessionRevisions(context).isEmpty())
    }

    @Test
    fun `removing one definition preserves other progress and rejects its late write`() {
        NativePlaybackStateStore.saveSessions(context, listOf(session("A", 1_000L), session("B", 2_000L)))
        NativePlaybackStateStore.saveSessionProgress(context,
            listOf(playingProgress("A", 16_000L), playingProgress("B", 17_000L)))
        val oldRevision = NativePlaybackStateStore.sessionRevision("A")

        NativePlaybackStateStore.removeSession(context, "A")
        NativePlaybackStateStore.upsertSessionProgress(context, listOf(playingProgress("A", 31_000L)),
            mapOf("A" to oldRevision))

        val restored = NativePlaybackStateStore.loadSessions(context).single()
        assertEquals("B", restored.sessionId)
        assertEquals(17_000L, restored.positionMs)
        assertTrue(restored.playing)
        assertFalse(progress.contains(progressKey))
    }

    @Test
    fun `clear removes both stores so reusing a session id cannot restore its old position`() {
        seedLegacyProgress(playingProgress("A", 90_000L))
        NativePlaybackStateStore.clearSessions(context)

        assertTrue(NativePlaybackStateStore.loadSessions(context).isEmpty())
        assertFalse(definitions.contains("sessions"))
        assertFalse(definitions.contains(progressKey))
        assertFalse(progress.contains(progressKey))
        NativePlaybackStateStore.saveSessions(context, listOf(session("A", 10L)))
        assertEquals(10L, NativePlaybackStateStore.loadSessions(context).single().positionMs)
    }

    @Test
    fun `clear keeps a newer cold selection and its exact position`() {
        NativePlaybackStateStore.saveSessions(context, listOf(session("A", 1_000L)))
        val clearRevision = NativePlaybackStateStore.invalidateAllSessions()
        NativePlaybackStateStore.saveColdSession(context, session("B", 22_000L))

        NativePlaybackStateStore.clearSessions(context, clearRevision)

        val restored = NativePlaybackStateStore.loadSessions(context).single()
        assertEquals("B", restored.sessionId)
        assertEquals(22_000L, restored.positionMs)
        assertFalse(progress.contains(progressKey))
    }

    private fun seedLegacyProgress(value: StoredNativePlaybackProgress) {
        NativePlaybackStateStore.saveSessions(context, listOf(session(value.sessionId, 1_000L)))
        definitions.edit().remove(generationKey).putString(progressKey, encode(value)).commit()
        progress.edit().clear().commit()
    }

    private fun loadOnBackground(): List<StoredNativePlaybackSession> {
        val executor = Executors.newSingleThreadExecutor()
        return try {
            executor.submit<List<StoredNativePlaybackSession>> {
                NativePlaybackStateStore.loadSessions(context)
            }.get()
        } finally {
            executor.shutdown()
        }
    }

    private fun playingProgress(id: String, positionMs: Long) =
        StoredNativePlaybackProgress(id, positionMs, playing = true, playWhenReady = true)

    private fun encode(value: StoredNativePlaybackProgress) = JSONArray().put(JSONObject()
        .put("sessionId", value.sessionId).put("positionMs", value.positionMs)
        .put("playing", value.playing).put("playWhenReady", value.playWhenReady)).toString()

    private fun session(id: String, positionMs: Long) = StoredNativePlaybackSession(
        sessionId = id, uri = "file:///track.mp3", path = "/track.mp3", title = "Track",
        subtitle = null, artUri = null, positionMs = positionMs, volume = 1f, speed = 1f,
        skipSilenceEnabled = false, noiseReductionEnabled = false, eqEnabled = false,
        eqPresetId = null, eqBandLevels = emptyMap(), volumeNormalizationEnabled = false,
        panning = 0f, repeatOne = false, repeatAll = false, shuffleModeEnabled = false,
        queueStartIndex = 0,
        queue = List(500) { index -> StoredNativePlaybackQueueItem("/$index.mp3", "file:///$index.mp3", "Track $index", null, null) },
        channelSwapEnabled = false, playing = false, playWhenReady = false)
}
