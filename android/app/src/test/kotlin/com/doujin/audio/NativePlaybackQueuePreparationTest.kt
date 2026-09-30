package com.doujin.audio

import com.doujin.audio.player.session.*
import org.junit.Assert.*
import org.junit.Test

class NativePlaybackQueuePreparationTest {
    @Test
    fun `a newer queue supersedes only its own session while another session completes`() {
        val environment = FakeQueueEnvironment()
        val preparation = NativePlaybackQueuePreparation(environment)
        val results = mutableMapOf<String, Boolean>()
        preparation.prepare("a", emptyList(), { true }) { results["a-old"] = it.isSuccess }
        preparation.prepare("b", emptyList(), { true }) { results["b"] = it.isSuccess }
        preparation.prepare("a", emptyList(), { true }) { results["a-new"] = it.isSuccess }
        assertEquals(mapOf("a-old" to false), results)
        environment.runAll()
        assertEquals(mapOf("a-old" to false, "b" to true, "a-new" to true), results)
    }

    @Test
    fun `a removed or replaced session cannot apply a prepared queue`() {
        val environment = FakeQueueEnvironment()
        val preparation = NativePlaybackQueuePreparation(environment)
        var current = true
        var accepted: Boolean? = null
        preparation.prepare("a", emptyList(), { current }) { accepted = it.isSuccess }
        current = false
        environment.runAll()
        assertEquals(false, accepted)
    }

    @Test
    fun `pause invalidates pending autoplay preparation`() {
        val environment = FakeQueueEnvironment()
        val preparation = NativePlaybackQueuePreparation(environment)
        var accepted: Boolean? = null
        preparation.prepare("a", emptyList(), { true }) { accepted = it.isSuccess }
        preparation.cancel("a")
        environment.runAll()
        assertEquals(false, accepted)
    }
}

private class FakeQueueEnvironment : NativePlaybackQueuePreparationEnvironment {
    private val background = ArrayDeque<() -> Unit>()
    private val main = ArrayDeque<() -> Unit>()
    override fun execute(task: () -> Unit) { background += task }
    override fun postMain(task: () -> Unit) { main += task }
    override fun shutdown() { background.clear() }
    fun runAll() {
        while (background.isNotEmpty()) background.removeFirst().invoke()
        while (main.isNotEmpty()) main.removeFirst().invoke()
    }
}
