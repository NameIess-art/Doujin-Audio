package com.doujin.audio.player.session

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log
import java.io.ByteArrayOutputStream
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener

internal class NativePlaybackRecoveryDatabase(val owner: Context) :
    SQLiteOpenHelper(owner, fileName, null, SCHEMA_VERSION) {

    companion object {
        internal const val fileName = "native_playback_recovery.db"
        internal const val SCHEMA_VERSION = 2
        private const val legacyDefinitions = "audio_player_native_playback_state"
        private const val legacyProgress = "audio_player_native_playback_progress"
        private const val definitionsKey = "sessions"
        private const val progressKey = "session_progress_v1"
        private const val generationKey = "progress_generation"
        // Keep even very large sessions readable through a fixed-size CursorWindow.
        private const val payloadChunkBytes = 64 * 1024
    }

    private data class StoredSessionRow(
        val progress: StoredNativePlaybackProgress,
        val metaJson: String?
    )

    override fun onConfigure(db: SQLiteDatabase) {
        db.setForeignKeyConstraintsEnabled(true)
        try {
            db.enableWriteAheadLogging()
        } catch (error: SQLiteException) {
            Log.w("PlaybackRecovery", "Unable to enable WAL mode; using default journal mode", error)
        }
        db.rawQuery("PRAGMA busy_timeout = 5000", null).use { it.moveToFirst() }
    }

    override fun onCreate(db: SQLiteDatabase) {
        createSchema(db)
        migrateLegacyDefinitions(db)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion == 1 && newVersion == 2) {
            migrateV1ToV2(db)
            return
        }
        Log.w(
            "PlaybackRecovery",
            "Rebuilding native playback recovery schema from v$oldVersion to v$newVersion"
        )
        rebuildSchema(db)
    }

    override fun onDowngrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        Log.w(
            "PlaybackRecovery",
            "Rebuilding native playback recovery schema from v$oldVersion to v$newVersion"
        )
        rebuildSchema(db)
    }

    private fun migrateV1ToV2(db: SQLiteDatabase) {
        var hasMetaColumn = false
        db.rawQuery("PRAGMA table_info(sessions)", null).use { cursor ->
            val nameIndex = cursor.getColumnIndex("name")
            while (cursor.moveToNext()) {
                if (nameIndex >= 0 && cursor.getString(nameIndex) == "meta_json") {
                    hasMetaColumn = true
                    break
                }
            }
        }
        if (!hasMetaColumn) {
            db.execSQL("ALTER TABLE sessions ADD COLUMN meta_json TEXT")
        }
    }

    private fun createSchema(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE sessions (
                session_id TEXT NOT NULL PRIMARY KEY,
                position_ms INTEGER NOT NULL,
                playing INTEGER NOT NULL,
                play_when_ready INTEGER NOT NULL,
                meta_json TEXT
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
    }

    private fun rebuildSchema(db: SQLiteDatabase) {
        db.execSQL("DROP TABLE IF EXISTS retained_uris")
        db.execSQL("DROP TABLE IF EXISTS definition_chunks")
        db.execSQL("DROP TABLE IF EXISTS sessions")
        createSchema(db)
    }

    override fun onOpen(db: SQLiteDatabase) {
        super.onOpen(db)
        // SQLiteOpenHelper commits onCreate and the database version together.
        // A crash during preference cleanup therefore leaves the DB authoritative.
        if (db.isReadOnly) return
        val definitions = owner.getSharedPreferences(legacyDefinitions, Context.MODE_PRIVATE)
        if (definitions.contains(definitionsKey) || definitions.contains(progressKey) ||
            definitions.contains(generationKey)
        ) {
            definitions.edit().remove(definitionsKey).remove(progressKey).remove(generationKey).apply()
        }
        val progress = owner.getSharedPreferences(legacyProgress, Context.MODE_PRIVATE)
        if (progress.contains(progressKey) || progress.contains(generationKey)) {
            progress.edit().remove(progressKey).remove(generationKey).apply()
        }
    }

    fun upsertDefinitions(sessions: List<StoredNativePlaybackSession>) = writableDatabase.transaction {
        sessions.forEach { writeDefinition(it) }
    }

    fun updateMetadata(sessions: List<StoredNativePlaybackSession>) = writableDatabase.transaction {
        sessions.forEach { session ->
            val values = session.toSessionRowValues()
            if (update("sessions", values, "session_id = ?", arrayOf(session.sessionId)) == 0) {
                writeDefinition(session)
            }
        }
    }

    fun updateProgress(progress: List<StoredNativePlaybackProgress>) = writableDatabase.transaction {
        progress.forEach {
            update("sessions", it.toValues(), "session_id = ?", arrayOf(it.sessionId))
        }
    }

    fun pauseSessions() {
        writableDatabase.execSQL(
            "UPDATE sessions SET playing = 0, play_when_ready = 0 WHERE playing != 0 OR play_when_ready != 0"
        )
    }

    fun removeSessions(sessionIds: List<String>) {
        if (sessionIds.isEmpty()) return
        writableDatabase.transaction {
            for (ids in sessionIds.chunked(500)) {
                delete("sessions", "session_id IN (${ids.joinToString(",") { "?" }})", ids.toTypedArray())
            }
        }
    }

    fun retainedUris(): Set<String> =
        readableDatabase.rawQuery("SELECT DISTINCT uri FROM retained_uris", null).use { cursor ->
            buildSet {
                while (cursor.moveToNext()) add(cursor.getString(0))
            }
        }

    fun sessionIds(activeOnly: Boolean = false): List<String> = readableDatabase.query(
        "sessions",
        arrayOf("session_id"),
        if (activeOnly) "(playing != 0 OR play_when_ready != 0)" else null,
        null,
        null,
        null,
        "rowid"
    ).use { cursor ->
        buildList {
            while (cursor.moveToNext()) add(cursor.getString(0))
        }
    }

    fun loadSessions(sessionIds: Set<String>?, activeOnly: Boolean): List<StoredNativePlaybackSession> {
        val db = readableDatabase
        return readSessionRows(sessionIds, activeOnly).mapNotNull { row ->
            val progress = row.progress
            val payload = ByteArrayOutputStream()
            db.rawQuery(
                "SELECT payload FROM definition_chunks WHERE session_id = ? ORDER BY chunk_index",
                arrayOf(progress.sessionId)
            ).use { cursor ->
                while (cursor.moveToNext()) payload.write(cursor.getBlob(0))
            }
            try {
                val chunkJson = JSONObject(payload.toString(Charsets.UTF_8.name()))
                val decoded = if (row.metaJson != null) {
                    JSONObject(row.metaJson).decodeDefinition(queueSource = chunkJson)
                } else {
                    chunkJson.decodeDefinition()
                }
                decoded?.withProgressOverlay(progress)
            } catch (error: JSONException) {
                Log.w("PlaybackRecovery", "Unable to decode a stored playback session", error)
                null
            }
        }
    }

    private fun readSessionRows(sessionIds: Set<String>?, activeOnly: Boolean): List<StoredSessionRow> {
        val db = readableDatabase
        val pages = sessionIds?.chunked(500) ?: listOf(null)
        return buildList {
            for (ids in pages) {
                val predicates = buildList {
                    if (activeOnly) add("(playing != 0 OR play_when_ready != 0)")
                    if (ids != null) add("session_id IN (${ids.joinToString(",") { "?" }})")
                }
                db.query(
                    "sessions",
                    arrayOf("session_id", "position_ms", "playing", "play_when_ready", "meta_json"),
                    predicates.joinToString(" AND ").ifEmpty { null },
                    ids?.toTypedArray(),
                    null,
                    null,
                    "rowid"
                ).use { cursor ->
                    while (cursor.moveToNext()) {
                        val progress = StoredNativePlaybackProgress(
                            sessionId = cursor.getString(0),
                            positionMs = cursor.getLong(1),
                            playing = cursor.getInt(2) != 0,
                            playWhenReady = cursor.getInt(3) != 0
                        )
                        val metaJson = if (cursor.isNull(4)) null else cursor.getString(4)
                        add(StoredSessionRow(progress = progress, metaJson = metaJson))
                    }
                }
            }
        }
    }

    private fun SQLiteDatabase.writeDefinition(session: StoredNativePlaybackSession) {
        val args = arrayOf(session.sessionId)
        val state = session.toSessionRowValues()
        if (update("sessions", state, "session_id = ?", args) == 0) {
            state.put("session_id", session.sessionId)
            insertOrThrow("sessions", null, state)
        }
        delete("definition_chunks", "session_id = ?", args)
        val payload = session.encodeQueueDefinition().toString().toByteArray(Charsets.UTF_8)
        compileStatement("INSERT INTO definition_chunks VALUES (?, ?, ?)").use { insert ->
            insert.bindString(1, session.sessionId)
            for ((index, start) in (payload.indices step payloadChunkBytes).withIndex()) {
                insert.bindLong(2, index.toLong())
                insert.bindBlob(3, payload.copyOfRange(start, minOf(start + payloadChunkBytes, payload.size)))
                insert.executeInsert()
            }
        }
        delete("retained_uris", "session_id = ?", args)
        compileStatement("INSERT INTO retained_uris VALUES (?, ?)").use { insert ->
            insert.bindString(1, session.sessionId)
            for (uri in session.retainedContentUris()) {
                insert.bindString(2, uri)
                insert.executeInsert()
            }
        }
    }

    private fun migrateLegacyDefinitions(db: SQLiteDatabase) {
        val definitions = owner.getSharedPreferences(legacyDefinitions, Context.MODE_PRIVATE)
        val raw = definitions.getString(definitionsKey, null) ?: return
        val separateProgress = owner.getSharedPreferences(legacyProgress, Context.MODE_PRIVATE)
        val overlay = if (separateProgress.contains(generationKey)) separateProgress else definitions
        val progress = if (overlay.getLong(generationKey, 0L) == definitions.getLong(generationKey, 0L)) {
            val entries = legacyObjects(overlay.getString(progressKey, null), "progress")
            entries.associate { item ->
                val id = item.optString("sessionId")
                id to StoredNativePlaybackProgress(
                    sessionId = id,
                    positionMs = item.optLong("positionMs", 0L),
                    playing = item.optBoolean("playing"),
                    playWhenReady = item.optBoolean("playWhenReady")
                )
            }
        } else {
            emptyMap()
        }
        for (json in legacyObjects(raw, "definitions")) {
            val session = try {
                json.decodeDefinition()
            } catch (error: JSONException) {
                Log.w("PlaybackRecovery", "Unable to migrate a legacy playback session", error)
                null
            } ?: continue
            db.writeDefinition(session.withProgressOverlay(progress[session.sessionId]))
        }
    }

    private fun legacyObjects(raw: String?, label: String): Sequence<JSONObject> = sequence {
        if (raw == null) return@sequence
        // Parse one recovery definition at a time. Large legacy arrays already
        // occupy memory as a preference string, without a second full JSON tree.
        val tokens = JSONTokener(raw)
        try {
            if (tokens.nextClean() != '[') throw JSONException("Expected a playback array")
            while (true) {
                if (tokens.nextClean() == ']') break
                tokens.back()
                val value = tokens.nextValue()
                if (value is JSONObject) yield(value)
                when (tokens.nextClean()) {
                    ']' -> break
                    ',' -> continue
                    else -> throw JSONException("Invalid playback array separator")
                }
            }
        } catch (error: JSONException) {
            Log.w("PlaybackRecovery", "Unable to read remaining legacy playback $label", error)
        }
    }
}

internal fun StoredNativePlaybackSession.retainedContentUris(): Set<String> = buildSet {
    fun retain(value: String?) {
        if (value?.startsWith("content:", ignoreCase = true) == true) add(value)
    }
    retain(path)
    retain(uri)
    retain(artUri)
    for (item in queue) {
        retain(item.path)
        retain(item.uri)
        retain(item.artUri)
        item.candidateUris.forEach(::retain)
    }
}

private fun StoredNativePlaybackSession.toSessionRowValues() = toStoredProgress().toValues().apply {
    put("meta_json", encodeMetadata().toString())
}

private fun StoredNativePlaybackProgress.toValues() = ContentValues().apply {
    put("position_ms", positionMs.coerceAtLeast(0L))
    put("playing", playing)
    put("play_when_ready", playWhenReady)
}

private inline fun SQLiteDatabase.transaction(block: SQLiteDatabase.() -> Unit) {
    beginTransaction()
    try {
        block()
        setTransactionSuccessful()
    } finally {
        endTransaction()
    }
}
