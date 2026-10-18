package com.doujin.audio

import android.content.ComponentCallbacks2
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterFragmentActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class MainActivityMemoryPressureTest {
    @Test
    fun `ordinary background does not become Flutter memory pressure`() {
        val (activity, fragment) = activityWithRecordingFragment()

        repeat(3) { activity.onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) }

        assertTrue(fragment.trimLevels.isEmpty())
    }

    @Test
    @Suppress("DEPRECATION") // Older Android releases still deliver these pressure levels.
    fun `real memory pressure still reaches Flutter after background`() {
        val (activity, fragment) = activityWithRecordingFragment()
        val pressureLevels = listOf(
            ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE,
            ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW,
            ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL,
            ComponentCallbacks2.TRIM_MEMORY_BACKGROUND,
            ComponentCallbacks2.TRIM_MEMORY_MODERATE,
            ComponentCallbacks2.TRIM_MEMORY_COMPLETE,
        )

        for (level in pressureLevels) {
            activity.onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN)
            activity.onTrimMemory(level)
        }

        assertEquals(pressureLevels, fragment.trimLevels)
    }

    private fun activityWithRecordingFragment(): Pair<MainActivity, RecordingFlutterFragment> {
        // Construct without launching an engine: this tests the Activity's
        // actual callback forwarding without requiring Flutter's native JNI.
        val activity = Robolectric.buildActivity(MainActivity::class.java).get()
        val fragment = RecordingFlutterFragment()
        FlutterFragmentActivity::class.java.getDeclaredField("flutterFragment").apply {
            isAccessible = true
            set(activity, fragment)
        }
        return activity to fragment
    }

    private class RecordingFlutterFragment : FlutterFragment() {
        val trimLevels = mutableListOf<Int>()

        override fun onTrimMemory(level: Int) {
            trimLevels += level
        }
    }
}
