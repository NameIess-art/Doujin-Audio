package com.doujin.audio.player.session

import android.content.Context
import android.os.SystemClock
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** Unconfirmed batches survive the Flutter engine and native service lifetime. */
internal class NativePlaybackUsageLedger(
    context: Context,
    private val elapsedNow: () -> Long = SystemClock::elapsedRealtime,
    private val wallNow: () -> Long = System::currentTimeMillis,
    private val writer: Executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "NativePlaybackUsageStore").apply { isDaemon = true }
    }
) {
    private val preferences = context.getSharedPreferences("playback_usage", Context.MODE_PRIVATE)
    private var epoch = "android:${UUID.randomUUID()}"
    private var sequence = 0L
    private fun newBatchId() = "$epoch:${++sequence}"
    private val pending = mutableListOf<UsageBatch>()
    private val days = linkedMapOf<String, UsageDay>()
    private var currentId = newBatchId()
    private var elapsed = elapsedNow()
    private var wall = wallNow()
    private var activeItems = emptyList<Map<String, Any?>>()
    private var active = emptyMap<String, Map<String, Any?>>()
    private var queuedCheckpoint: UsageCheckpoint? = null
    private var writing = false

    init {
        preferences.getString("ledger", null)?.let { encoded ->
            val state = JSONObject(encoded)
            epoch = state.getString("epoch")
            sequence = state.getLong("sequence")
            val stored = state.getJSONArray("batches")
            for (index in 0 until stored.length()) {
                val batch = stored.getJSONObject(index)
                val storedDays = batch.getJSONArray("days")
                pending += UsageBatch(
                    batch.getString("id"),
                    List(storedDays.length()) { jsonMap(storedDays.getJSONObject(it)) }
                )
            }
            currentId = newBatchId()
        }
    }

    @Synchronized
    fun update(items: List<Map<String, Any?>>) {
        if (items == activeItems) return
        val changed = settle()
        activeItems = items
        active = items.associateBy(::workKey)
        if (changed) persist()
    }

    @Synchronized
    fun checkpoint() {
        if (settle()) persist() else scheduleWrite()
    }

    private fun settle(): Boolean {
        val tick = elapsedNow()
        var remaining = (tick - elapsed).coerceAtLeast(0L)
        var start = wall
        elapsed = tick
        wall = wallNow()
        if (active.isEmpty() || remaining == 0L) return false
        val calendar = Calendar.getInstance()
        while (remaining > 0L) {
            calendar.timeInMillis = start
            val year = calendar.get(Calendar.YEAR).toString().padStart(4, '0')
            val month = (calendar.get(Calendar.MONTH) + 1).toString().padStart(2, '0')
            val dayOfMonth = calendar.get(Calendar.DAY_OF_MONTH).toString().padStart(2, '0')
            val date = "$year-$month-$dayOfMonth"
            calendar.add(Calendar.DAY_OF_MONTH, 1)
            calendar.set(Calendar.HOUR_OF_DAY, 0)
            calendar.set(Calendar.MINUTE, 0)
            calendar.set(Calendar.SECOND, 0)
            calendar.set(Calendar.MILLISECOND, 0)
            val span = minOf(remaining, (calendar.timeInMillis - start).coerceAtLeast(1L))
            val day = days.getOrPut(date, ::UsageDay)
            day.totalMs += span
            for ((key, item) in active) {
                val work = day.works.getOrPut(key, ::UsageWork)
                work.milliseconds += span
                work.lastPlayedAtMs = start + span
                work.item = item
                (item["usageDescriptor"] as? Map<*, *>)?.let { work.descriptor = it }
            }
            remaining -= span
            start = calendar.timeInMillis
        }
        return true
    }

    @Synchronized
    fun read(): List<Map<String, Any?>> {
        settle()
        if (days.isNotEmpty()) {
            pending += currentBatch()
            days.clear()
            currentId = newBatchId()
            persist()
        }
        return pending.map(UsageBatch::toMap)
    }

    @Synchronized
    fun acknowledge(ids: Set<String>) {
        if (pending.removeAll { it.id in ids }) persist()
    }

    @Synchronized
    fun reset() {
        pending.clear()
        days.clear()
        currentId = newBatchId()
        elapsed = elapsedNow()
        wall = wallNow()
        persist()
    }

    private fun currentBatch() = UsageBatch(
        currentId,
        days.map { (date, day) ->
            mapOf(
                "date" to date,
                "totalMs" to day.totalMs,
                "works" to day.works.map { (key, work) -> work.toMap(key) }
            )
        }
    )

    private fun persist() {
        val batches = pending.toMutableList()
        if (days.isNotEmpty()) batches += currentBatch()
        queuedCheckpoint = UsageCheckpoint(epoch, sequence, batches)
        scheduleWrite()
    }

    private fun scheduleWrite() {
        if (writing || queuedCheckpoint == null) return
        writing = true
        writer.execute(::writeCheckpoints)
    }

    private fun writeCheckpoints() {
        // One writer drains the latest immutable snapshot. A slow write can
        // never land after a newer acknowledgement or reset.
        while (true) {
            val checkpoint = synchronized(this) {
                val next = queuedCheckpoint
                if (next == null) {
                    writing = false
                    return
                }
                queuedCheckpoint = null
                next
            }
            try {
                val state = JSONObject()
                    .put("epoch", checkpoint.epoch)
                    .put("sequence", checkpoint.sequence)
                    .put("batches", JSONArray(checkpoint.batches.map { JSONObject(it.toMap()) }))
                preferences.edit().putString("ledger", state.toString()).apply()
            } catch (error: Exception) {
                Log.e("NativePlaybackUsage", "Could not persist playback usage", error)
                synchronized(this) {
                    val newerCheckpoint = queuedCheckpoint != null
                    if (!newerCheckpoint) queuedCheckpoint = checkpoint
                    if (!newerCheckpoint) {
                        writing = false
                        return
                    }
                }
            }
        }
    }

    private data class UsageBatch(val id: String, val days: List<Map<String, Any?>>) {
        fun toMap(): Map<String, Any?> = mapOf("id" to id, "days" to days)
    }

    private data class UsageCheckpoint(val epoch: String, val sequence: Long, val batches: List<UsageBatch>)

    private class UsageDay {
        var totalMs = 0L
        val works = linkedMapOf<String, UsageWork>()
    }

    private class UsageWork {
        var milliseconds = 0L
        var lastPlayedAtMs = 0L
        var item = emptyMap<String, Any?>()
        var descriptor: Map<*, *>? = null

        fun toMap(key: String): Map<String, Any?> = buildMap {
            put("key", key)
            put("milliseconds", milliseconds)
            put("lastPlayedAtMs", lastPlayedAtMs)
            for (field in usageFields) item[field]?.let { put(field, it) }
            descriptor?.let { put("descriptor", it) }
        }
    }

    companion object {
        private val usageFields = listOf("uri", "path", "title", "subtitle", "artUri")
        private val workId = Regex("RJ\\d+", RegexOption.IGNORE_CASE)
        @Volatile private var instance: NativePlaybackUsageLedger? = null
        fun get(context: Context): NativePlaybackUsageLedger = instance ?: synchronized(this) {
            instance ?: NativePlaybackUsageLedger(context.applicationContext).also { instance = it }
        }

        private fun workKey(item: Map<String, Any?>): String {
            val descriptor = item["usageDescriptor"] as? Map<*, *>
            val remote = descriptor?.get("remoteMetadata") as? Map<*, *>
            val text = listOf(remote?.get("sourceId"), descriptor?.get("groupSubtitle"), descriptor?.get("groupTitle"), descriptor?.get("path"), item["path"], item["subtitle"], item["title"]).joinToString(" ")
            workId.find(text)?.let { return "rj:${it.value.uppercase(Locale.ROOT)}" }
            if (descriptor?.get("remoteMetadataKind") == "asmr.one" && remote?.get("id") != null) return "asmr:${remote["id"]}"
            (descriptor?.get("groupKey") as? String)?.takeIf { it.isNotEmpty() }?.let { return "local:${it.replace('\\', '/').lowercase(Locale.ROOT)}" }
            val path = (item["path"] as? String)?.replace('\\', '/')
            return if (!path.isNullOrEmpty() && !path.startsWith("http")) "local:${path.substringBeforeLast('/', path)}"
                else "uri:${item["uri"]}"
        }

        fun jsonMap(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith { key -> jsonValue(value.get(key)) }
        private fun jsonValue(value: Any?): Any? = when (value) {
            JSONObject.NULL -> null
            is JSONObject -> jsonMap(value)
            is JSONArray -> (0 until value.length()).map { jsonValue(value.get(it)) }
            else -> value
        }
    }
}
