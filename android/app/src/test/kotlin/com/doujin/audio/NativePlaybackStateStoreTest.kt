package com.doujin.audio

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import com.doujin.audio.player.session.NativePlaybackRecoveryDatabase
import com.doujin.audio.player.session.decodeDefinition
import com.doujin.audio.player.session.encodeDefinition
import com.doujin.audio.player.session.NativePlaybackStateStore
import com.doujin.audio.player.session.StoredNativePlaybackProgress
import com.doujin.audio.player.session.StoredNativePlaybackQueueItem
import com.doujin.audio.player.session.StoredNativePlaybackSession
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

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
        context.deleteDatabase(NativePlaybackRecoveryDatabase.fileName)
        definitions.edit().clear().commit()
        progress.edit().clear().commit()
    }

    @Test
    fun `older writes with the same definition revision preserve a newer pause`() {
        val active = session("pause-race", 2_000L).copy(playing = true, playWhenReady = true)
        val paused = active.copy(playing = false, playWhenReady = false, positionMs = 3_000L)
        val revision = NativePlaybackStateStore.sessionRevision(active.sessionId)
        val revisions = mapOf(active.sessionId to revision)
        NativePlaybackStateStore.stageSessions(listOf(paused), revisions)

        NativePlaybackStateStore.upsertSessions(context, listOf(active), revisions)
        assertTrue(NativePlaybackStateStore.loadSessions(context, activeOnly = true).isEmpty())

        NativePlaybackStateStore.upsertSessionProgress(
            context, listOf(playingProgress(active.sessionId, 2_500L)), revisions
        )
        assertTrue(NativePlaybackStateStore.loadSessions(context, activeOnly = true).isEmpty())
        assertEquals(3_000L, NativePlaybackStateStore.loadSessions(context).single().positionMs)
    }

    @After
    fun clearStore() {
        NativePlaybackStateStore.removeTemporarySession("T")
        NativePlaybackStateStore.clearSessions(context)
    }

    @Test
    fun `large chapter definitions keep clipping content references and progress across chunks`() {
        val contentUri = "content://com.example/documents/章"
        val queue = List(10_000) { index ->
            StoredNativePlaybackQueueItem(
                path = "/chapter-$index",
                uri = "https://example.com/chapter.m3u8",
                title = "Chapter $index 👋",
                subtitle = null,
                artUri = null,
                candidateUris = listOf(contentUri),
                clipStartMs = index * 20_000L,
                clipEndMs = (index + 1) * 20_000L,
                httpHeaders = mapOf("Referer" to "https://japaneseasmr.com/")
            )
        }
        NativePlaybackStateStore.upsertSessions(context, listOf(session("A", 1_000L).copy(queue = queue)))
        val initialChunks = chunkRows("A")
        assertTrue(initialChunks.size > 2)

        for (position in listOf(16_000L, 31_000L, 46_000L)) {
            saveProgress(playingProgress("A", position))
        }

        assertEquals(initialChunks, chunkRows("A"))
        val restored = NativePlaybackStateStore.loadSessions(context, setOf("A")).single()
        assertEquals(queue, restored.queue)
        assertEquals(46_000L, restored.positionMs)
        assertTrue(restored.playing)
        assertEquals(setOf(contentUri), NativePlaybackStateStore.retainedRecoveryContentUris(context))
        assertEquals(setOf("A"), NativePlaybackStateStore.loadActiveSessionRevisions(context).keys)
    }

    @Test
    fun `legacy recovery migrates valid progress once and keeps timer preferences`() {
        seedLegacy(session("A", 1_000L), playingProgress("A", 9_000L))
        definitions.edit().putString("playback_behavior_v1", """{"requestAudioFocus":false}""").commit()

        NativePlaybackRecoveryDatabase(context).use { database ->
            assertEquals(9_000L, database.loadSessions(null, false).single().positionMs)
            assertFalse(definitions.contains("sessions"))
            assertFalse(definitions.contains(progressKey))
            assertFalse(NativePlaybackStateStore.loadPlaybackBehavior(context).requestAudioFocus)
            assertEquals(listOf("A"), database.sessionIds(activeOnly = true))
            database.updateProgress(listOf(playingProgress("A", 24_000L)))
        }

        // The database version remains authoritative if termination left old keys behind.
        seedLegacy(session("A", 1_000L), playingProgress("A", 9_000L))
        NativePlaybackRecoveryDatabase(context).use { database ->
            assertEquals(24_000L, database.loadSessions(null, false).single().positionMs)
            assertFalse(definitions.contains("sessions"))
        }
    }

    @Test
    fun `recovery preserves front back position and reads older definitions as neutral`() {
        val stored = session("A", 1_000L).copy(frontBack = -0.75f)
        NativePlaybackStateStore.upsertSessions(context, listOf(stored))
        assertEquals(-0.75f, NativePlaybackStateStore.loadSessions(context, setOf("A")).single().frontBack)

        val legacy = stored.encodeDefinition().apply { remove("frontBack") }
        assertEquals(0f, legacy.decodeDefinition()!!.frontBack)
    }

    @Test
    fun `legacy overlay with the wrong generation never replaces structural progress`() {
        seedLegacy(session("A", 1_000L), playingProgress("A", 9_000L))
        progress.edit().putLong(generationKey, 2L)
            .putString(progressKey, encode(playingProgress("A", 30_000L))).commit()

        val restored = NativePlaybackRecoveryDatabase(context).use { it.loadSessions(null, false).single() }
        assertEquals(1_000L, restored.positionMs)
        assertFalse(restored.playing)
        assertFalse(progress.contains(progressKey))
    }

    @Test
    fun `legacy progress sidecar is authoritative even after removal of all progress rows`() {
        seedLegacy(session("A", 1_000L), playingProgress("A", 9_000L))
        progress.edit().putLong(generationKey, 3L).commit()

        NativePlaybackRecoveryDatabase(context).use { database ->
            assertEquals(1_000L, database.loadSessions(null, false).single().positionMs)
        }
    }

    @Test
    fun `scoped writes replace only one definition and do not rewrite another sessions progress`() {
        val first = session("A", 1_000L)
        val second = session("B", 2_000L)
        NativePlaybackStateStore.upsertSessions(context, listOf(first, second))
        saveProgress(playingProgress("A", 16_000L), playingProgress("B", 17_000L))
        val untouchedChunks = chunkRows("B")

        NativePlaybackStateStore.upsertSessions(context, listOf(first.copy(positionMs = 21_000L)))
        val restored = NativePlaybackStateStore.loadSessions(context, setOf("A")).single()
        assertEquals(21_000L, restored.positionMs)
        assertFalse(restored.playing)
        assertEquals(untouchedChunks, chunkRows("B"))
        val other = NativePlaybackStateStore.loadSessions(context, activeOnly = true).single()
        assertEquals("B", other.sessionId)
        assertEquals(17_000L, other.positionMs)
    }

    @Test
    fun `definition write failure rolls back progress chunks and retained references`() {
        val initialUri = "content://example/original"
        val first = session("A", 1_000L).copy(uri = initialUri)
        NativePlaybackStateStore.upsertSessions(context, listOf(first))
        saveProgress(playingProgress("A", 7_000L))

        assertThrows(JSONException::class.java) {
            NativePlaybackStateStore.upsertSessions(context, listOf(
                first.copy(uri = "content://example/replaced"),
                session("B", 2_000L).copy(volume = Float.POSITIVE_INFINITY)
            ))
        }

        assertEquals(7_000L, NativePlaybackStateStore.loadSessions(context, setOf("A")).single().positionMs)
        assertEquals(setOf(initialUri), NativePlaybackStateStore.retainedRecoveryContentUris(context))
        assertTrue(NativePlaybackStateStore.loadSessions(context, setOf("B")).isEmpty())

        NativePlaybackStateStore.upsertSessions(context, listOf(first.copy(positionMs = 11_000L)))
        assertEquals(11_000L, NativePlaybackStateStore.loadSessions(context, setOf("A")).single().positionMs)
    }

    @Test
    fun `removing one definition drops its URI refs and rejects its late progress`() {
        val removedUri = "content://example/removed"
        val retainedUri = "content://example/retained"
        NativePlaybackStateStore.upsertSessions(context,
            listOf(session("A", 1_000L).copy(uri = removedUri), session("B", 2_000L).copy(uri = retainedUri)))
        saveProgress(playingProgress("A", 16_000L), playingProgress("B", 17_000L))
        val oldRevision = NativePlaybackStateStore.sessionRevision("A")
        NativePlaybackStateStore.removeSession(context, "A")
        NativePlaybackStateStore.upsertSessionProgress(context, listOf(playingProgress("A", 31_000L)),
            mapOf("A" to oldRevision))

        val restored = NativePlaybackStateStore.loadSessions(context).single()
        assertEquals("B", restored.sessionId)
        assertEquals(17_000L, restored.positionMs)
        assertEquals(setOf(retainedUri), NativePlaybackStateStore.retainedRecoveryContentUris(context))
    }

    @Test
    fun `clear removes old revisions and preserves a newer cold selection`() {
        NativePlaybackStateStore.upsertSessions(context, listOf(session("A", 1_000L)))
        saveProgress(playingProgress("A", 90_000L))
        assertEquals(90_000L, NativePlaybackStateStore.loadSessions(context).single().positionMs)
        val clearRevision = NativePlaybackStateStore.invalidateAllSessions()
        NativePlaybackStateStore.saveColdSession(context, session("B", 22_000L))

        NativePlaybackStateStore.clearSessions(context, clearRevision)

        val restored = NativePlaybackStateStore.loadSessions(context).single()
        assertEquals("B", restored.sessionId)
        assertEquals(22_000L, restored.positionMs)
        NativePlaybackStateStore.saveColdSession(context, session("A", 10L))
        assertEquals(10L, NativePlaybackStateStore.loadSessions(context, setOf("A")).single().positionMs)
    }

    @Test
    fun `scoped restore skips invalidated definitions while preserving temporary sessions`() {
        NativePlaybackStateStore.upsertSessions(context, listOf(session("A", 1_000L)))
        NativePlaybackStateStore.invalidateSession("A")
        NativePlaybackStateStore.saveTemporarySession(session("T", 2_000L).copy(
            isTemporary = true, playWhenReady = true))
        assertTrue(NativePlaybackStateStore.loadSessions(context, setOf("A")).isEmpty())
        assertEquals("T", NativePlaybackStateStore.loadSessions(context, activeOnly = true).single().sessionId)
        assertEquals(setOf("T"), NativePlaybackStateStore.loadActiveSessionRevisions(context).keys)
        assertTrue(chunkRows("T").isEmpty())

        saveProgress(StoredNativePlaybackProgress("T", 8_000L, playing = false, playWhenReady = false))
        assertTrue(NativePlaybackStateStore.loadActiveSessionRevisions(context).isEmpty())
        assertEquals(8_000L, NativePlaybackStateStore.loadSessions(context, setOf("T")).single().positionMs)
    }

    @Test
    fun `staged sessions override stale SQLite rows before persistence completes`() {
        try {
            val initial = session("S1", 1_000L).copy(playing = true, playWhenReady = true)
            NativePlaybackStateStore.upsertSessions(context, listOf(initial))
            assertEquals(setOf("S1"), NativePlaybackStateStore.loadActiveSessionRevisions(context).keys)

            val newRevision = NativePlaybackStateStore.invalidateSession("S1")
            assertTrue(NativePlaybackStateStore.loadSessions(context, setOf("S1")).isEmpty())

            val stagedActive = session("S1", 5_000L).copy(playing = true, playWhenReady = true)
            NativePlaybackStateStore.stageSessions(listOf(stagedActive), mapOf("S1" to newRevision))
            assertEquals(5_000L, NativePlaybackStateStore.loadSessions(context, setOf("S1")).single().positionMs)
            assertEquals(newRevision, NativePlaybackStateStore.loadActiveSessionRevisions(context)["S1"])

            val staleSqlActive = session("S2", 2_000L).copy(playing = true, playWhenReady = true)
            NativePlaybackStateStore.upsertSessions(context, listOf(staleSqlActive))
            val s2Revision = NativePlaybackStateStore.sessionRevision("S2")
            NativePlaybackStateStore.stageSessions(
                listOf(staleSqlActive.copy(playing = false, playWhenReady = false, positionMs = 9_000L)),
                mapOf("S2" to s2Revision)
            )
            val activeSessions = NativePlaybackStateStore.loadSessions(context, activeOnly = true)
            assertEquals(listOf("S1"), activeSessions.map { it.sessionId })
            assertEquals(setOf("S1"), NativePlaybackStateStore.loadActiveSessionRevisions(context).keys)
            assertEquals(9_000L, NativePlaybackStateStore.loadSessions(context, setOf("S2")).single().positionMs)
        } finally {
            NativePlaybackStateStore.clearSessions(context)
        }
    }

    @Test
    fun `recovery database configures WAL busy timeout migrates v1 to v2 without data loss and updates metadata without rewriting chunks`() {
        NativePlaybackRecoveryDatabase(context).use { database ->
            val db = database.writableDatabase
            val journalMode = db.rawQuery("PRAGMA journal_mode", null).use { cursor ->
                assertTrue(cursor.moveToFirst())
                cursor.getString(0)
            }
            assertTrue(journalMode.lowercase() in setOf("wal", "memory"))
            val busyTimeout = run {
                db.beginTransaction()
                try {
                    db.rawQuery("PRAGMA busy_timeout", null).use { cursor ->
                        assertTrue(cursor.moveToFirst())
                        cursor.getInt(0)
                    }
                } finally {
                    db.endTransaction()
                }
            }
            assertEquals(5000, busyTimeout)

            val initial = session("scalar-test", 1_000L)
            database.upsertDefinitions(listOf(initial))
            val initialChunks = chunkRows("scalar-test")
            assertTrue(initialChunks.isNotEmpty())

            val updated = initial.copy(
                positionMs = 5_000L,
                speed = 1.75f,
                volume = 1.5f,
                queueStartIndex = 12,
                repeatOne = true,
                frontBack = -0.5f,
                playing = true,
                playWhenReady = true
            )
            database.updateMetadata(listOf(updated))
            assertEquals(initialChunks, chunkRows("scalar-test"))
            val restored = database.loadSessions(setOf("scalar-test"), activeOnly = false).single()
            assertEquals(5_000L, restored.positionMs)
            assertEquals(1.75f, restored.speed)
            assertEquals(1.5f, restored.volume)
            assertEquals(12, restored.queueStartIndex)
            assertTrue(restored.repeatOne)
            assertEquals(-0.5f, restored.frontBack)
            assertEquals(initial.queue, restored.queue)

            // Simulate a v1 database upgraded to v2: sessions table had no meta_json and definition_chunks held full JSON.
            db.execSQL("DROP TABLE IF EXISTS retained_uris")
            db.execSQL("DROP TABLE IF EXISTS definition_chunks")
            db.execSQL("DROP TABLE IF EXISTS sessions")
            db.execSQL(
                """
                CREATE TABLE sessions (
                    session_id TEXT NOT NULL PRIMARY KEY,
                    position_ms INTEGER NOT NULL,
                    playing INTEGER NOT NULL,
                    play_when_ready INTEGER NOT NULL
                )
                """.trimIndent()
            )
            db.execSQL(
                """
                CREATE TABLE definition_chunks (
                    session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
                    chunk_index INTEGER NOT NULL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY (session_id, chunk_index)
                ) WITHOUT ROWID
                """.trimIndent()
            )
            db.execSQL(
                """
                CREATE TABLE retained_uris (
                    session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
                    uri TEXT NOT NULL,
                    PRIMARY KEY (session_id, uri)
                ) WITHOUT ROWID
                """.trimIndent()
            )
            val legacySession = session("v1-session", 3_000L).copy(speed = 1.25f)
            db.execSQL(
                "INSERT INTO sessions (session_id, position_ms, playing, play_when_ready) VALUES (?, ?, ?, ?)",
                arrayOf<Any>(legacySession.sessionId, 3_000L, 0, 0)
            )
            db.execSQL(
                "INSERT INTO definition_chunks (session_id, chunk_index, payload) VALUES (?, ?, ?)",
                arrayOf<Any>(legacySession.sessionId, 0, legacySession.encodeDefinition().toString().toByteArray(Charsets.UTF_8))
            )

            database.onUpgrade(db, 1, 2)
            val migrated = database.loadSessions(setOf("v1-session"), activeOnly = false).single()
            assertEquals(3_000L, migrated.positionMs)
            assertEquals(1.25f, migrated.speed)
            assertEquals(legacySession.queue, migrated.queue)

            database.onDowngrade(db, 2, 1)
            assertTrue(database.sessionIds().isEmpty())
            database.upsertDefinitions(listOf(session("after-downgrade", 2_000L)))
            assertEquals(listOf("after-downgrade"), database.sessionIds())
        }
    }

    private fun seedLegacy(session: StoredNativePlaybackSession, value: StoredNativePlaybackProgress) {
        definitions.edit().putLong(generationKey, 3L)
            .putString("sessions", JSONArray().put(session.encodeDefinition()).toString())
            .putString(progressKey, encode(value)).commit()
    }

    private fun saveProgress(vararg values: StoredNativePlaybackProgress) {
        NativePlaybackStateStore.upsertSessionProgress(context, values.toList(),
            values.associate { it.sessionId to NativePlaybackStateStore.sessionRevision(it.sessionId) })
    }

    private fun chunkRows(sessionId: String): List<String> = SQLiteDatabase.openDatabase(
        context.getDatabasePath(NativePlaybackRecoveryDatabase.fileName).absolutePath,
        null,
        SQLiteDatabase.OPEN_READONLY
    ).use { db ->
        db.rawQuery(
            "SELECT hex(payload) FROM definition_chunks WHERE session_id = ? ORDER BY chunk_index",
            arrayOf(sessionId)
        ).use { cursor -> buildList { while (cursor.moveToNext()) add(cursor.getString(0)) } }
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
