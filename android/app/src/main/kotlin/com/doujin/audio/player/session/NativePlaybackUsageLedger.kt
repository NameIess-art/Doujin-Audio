package com.doujin.audio.player.session

import android.content.Context
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.UUID

/** Unconfirmed batches survive the Flutter engine and native service lifetime. */
internal class NativePlaybackUsageLedger(
    context: Context,
    private val elapsedNow: () -> Long = SystemClock::elapsedRealtime,
    private val wallNow: () -> Long = System::currentTimeMillis
) {
    private val preferences = context.getSharedPreferences("playback_usage", Context.MODE_PRIVATE)
    private var epoch = "android:${UUID.randomUUID()}"
    private var sequence = 0L
    private fun newBatch() = JSONObject().put("id", "$epoch:${++sequence}").put("days", JSONArray())
    private val pending = mutableListOf<JSONObject>()
    private var current = newBatch()
    private var elapsed = elapsedNow()
    private var wall = wallNow()
    private var active = emptyMap<String, Map<String, Any?>>()

    init {
        preferences.getString("ledger", null)?.let { encoded ->
            val state = JSONObject(encoded)
            epoch = state.getString("epoch")
            sequence = state.getLong("sequence")
            val stored = state.getJSONArray("batches")
            for (index in 0 until stored.length()) pending += stored.getJSONObject(index)
            current = newBatch()
        }
    }

    @Synchronized
    fun update(items: List<Map<String, Any?>>) {
        settle()
        active = items.associateBy(::workKey)
    }

    private fun settle() {
        val tick = elapsedNow()
        var remaining = (tick - elapsed).coerceAtLeast(0L)
        var start = wall
        elapsed = tick
        wall = wallNow()
        if (active.isEmpty() || remaining == 0L) return
        val days = current.getJSONArray("days")
        while (remaining > 0L) {
            val calendar = Calendar.getInstance().apply { timeInMillis = start }
            val date = "%04d-%02d-%02d".format(java.util.Locale.ROOT,
                calendar.get(Calendar.YEAR), calendar.get(Calendar.MONTH) + 1, calendar.get(Calendar.DAY_OF_MONTH))
            calendar.add(Calendar.DAY_OF_MONTH, 1)
            calendar.set(Calendar.HOUR_OF_DAY, 0)
            calendar.set(Calendar.MINUTE, 0)
            calendar.set(Calendar.SECOND, 0)
            calendar.set(Calendar.MILLISECOND, 0)
            val span = minOf(remaining, (calendar.timeInMillis - start).coerceAtLeast(1L))
            val day = (0 until days.length()).map(days::getJSONObject).firstOrNull { it.getString("date") == date }
                ?: JSONObject().put("date", date).put("totalMs", 0L).put("works", JSONArray()).also(days::put)
            day.put("totalMs", day.getLong("totalMs") + span)
            val works = day.getJSONArray("works")
            for ((key, item) in active) {
                val work = (0 until works.length()).map(works::getJSONObject).firstOrNull { it.getString("key") == key }
                    ?: JSONObject().put("key", key).put("milliseconds", 0L).also(works::put)
                work.put("milliseconds", work.getLong("milliseconds") + span)
                work.put("lastPlayedAtMs", start + span)
                for (field in listOf("uri", "path", "title", "subtitle", "artUri")) work.put(field, item[field])
                (item["usageDescriptor"] as? Map<*, *>)?.let { work.put("descriptor", JSONObject(it)) }
            }
            remaining -= span
            start = calendar.timeInMillis
        }
        persist()
    }

    @Synchronized
    fun read(): List<Map<String, Any?>> {
        settle()
        if (current.getJSONArray("days").length() > 0) {
            pending += current
            current = newBatch()
            persist()
        }
        return pending.map { jsonMap(it) }
    }

    @Synchronized
    fun acknowledge(ids: Set<String>) {
        pending.removeAll { it.getString("id") in ids }
        persist()
    }

    @Synchronized
    fun reset() {
        pending.clear()
        current = newBatch()
        elapsed = elapsedNow()
        wall = wallNow()
        persist()
    }

    private fun persist() {
        val all = JSONArray(pending)
        if (current.getJSONArray("days").length() > 0) all.put(current)
        // SharedPreferences serializes its disk writes off the playback thread.
        val state = JSONObject().put("epoch", epoch).put("sequence", sequence).put("batches", all)
        preferences.edit().putString("ledger", state.toString()).apply()
    }

    companion object {
        @Volatile private var instance: NativePlaybackUsageLedger? = null
        fun get(context: Context): NativePlaybackUsageLedger = instance ?: synchronized(this) {
            instance ?: NativePlaybackUsageLedger(context.applicationContext).also { instance = it }
        }

        private fun workKey(item: Map<String, Any?>): String {
            val descriptor = item["usageDescriptor"] as? Map<*, *>
            val remote = descriptor?.get("remoteMetadata") as? Map<*, *>
            val text = listOf(remote?.get("sourceId"), descriptor?.get("groupSubtitle"), descriptor?.get("groupTitle"), descriptor?.get("path"), item["path"], item["subtitle"], item["title"]).joinToString(" ")
            Regex("RJ\\d+", RegexOption.IGNORE_CASE).find(text)?.let { return "rj:${it.value.uppercase(java.util.Locale.ROOT)}" }
            if (descriptor?.get("remoteMetadataKind") == "asmr.one" && remote?.get("id") != null) return "asmr:${remote["id"]}"
            (descriptor?.get("groupKey") as? String)?.takeIf { it.isNotEmpty() }?.let { return "local:${it.replace('\\', '/').lowercase(java.util.Locale.ROOT)}" }
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
