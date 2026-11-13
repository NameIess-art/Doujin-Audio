package com.doujin.audio

import android.content.Context
import com.doujin.audio.player.session.NativePlaybackUsageLedger
import java.util.Calendar
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class NativePlaybackUsageLedgerTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private var tick = 0L
    private var wall = 0L
    private val work = mapOf<String, Any?>("uri" to "file:///RJ123456/a.mp3", "title" to "RJ123456")
    private fun ledger(writer: Executor = Executor { it.run() }) =
        NativePlaybackUsageLedger(context, { tick }, { wall }, writer)
    private fun advance(ms: Long) { tick += ms; wall += ms }

    @Before fun setup() {
        context.getSharedPreferences("playback_usage", Context.MODE_PRIVATE).edit().clear().commit()
        tick = 0
        wall = Calendar.getInstance().apply {
            set(2026, Calendar.OCTOBER, 22, 23, 59, 58)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
    }

    @Test fun `overlap counts once and cross midnight is split`() {
        val ledger = ledger()
        ledger.update(listOf(work, work))
        advance(3000)
        ledger.update(emptyList())
        advance(5000)
        val days = ledger.read().single()["days"] as List<*>
        assertEquals(listOf(2000L, 1000L), days.map { (it as Map<*, *>)["totalMs"] })
        val firstWorks = (days[0] as Map<*, *>)["works"] as List<*>
        assertEquals(1, firstWorks.size)
        assertEquals("rj:RJ123456", (firstWorks.single() as Map<*, *>)["key"])
    }

    @Test fun `unacknowledged batches survive ledger recreation without repeating time`() {
        val first = ledger()
        first.update(listOf(work))
        advance(1000)
        first.update(emptyList())
        val batch = first.read().single()
        val restored = ledger()
        assertEquals(batch["id"], restored.read().single()["id"])
        restored.acknowledge(setOf(batch["id"] as String))
        assertTrue(ledger().read().isEmpty())
    }

    @Test fun `reset preserves active playback but discards previous epoch contributions`() {
        val ledger = ledger()
        ledger.update(listOf(work))
        advance(1000)
        ledger.reset()
        advance(500)
        val days = ledger.read().single()["days"] as List<*>
        assertEquals(500L, (days.single() as Map<*, *>)["totalMs"])
    }

    @Test fun `checkpoint persists unchanged audible playback before read`() {
        val first = ledger()
        first.update(listOf(work))
        advance(1200)
        first.update(listOf(work))
        first.checkpoint()
        val restored = ledger().read().single()
        assertEquals(first.read().single()["id"], restored["id"])
        val day = (restored["days"] as List<*>).single() as Map<*, *>
        assertEquals(1200L, (day["totalMs"] as Number).toLong())
    }

    @Test fun `queued writes cannot restore acknowledged batches`() {
        val writes = ArrayDeque<Runnable>()
        val first = ledger(Executor { writes.addLast(it) })
        first.update(listOf(work))
        advance(500)
        first.checkpoint()
        first.update(emptyList())
        val batch = first.read().single()
        first.acknowledge(setOf(batch["id"] as String))
        assertEquals(1, writes.size)
        assertTrue(ledger().read().isEmpty())

        writes.removeFirst().run()
        assertTrue(ledger().read().isEmpty())
        first.checkpoint()
        first.acknowledge(setOf("unknown"))
        assertTrue(writes.isEmpty())
    }
}
