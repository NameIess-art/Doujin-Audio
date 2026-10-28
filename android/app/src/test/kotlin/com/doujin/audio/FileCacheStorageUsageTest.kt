package com.doujin.audio

import android.os.Environment
import com.doujin.audio.storage.FileCacheOperations
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowStatFs
import org.robolectric.shadows.ShadowEnvironment

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class FileCacheStorageUsageTest {
    @Test
    fun `capacity and reported roots describe only primary storage`() {
        val primary = Environment.getExternalStorageDirectory()
        ShadowStatFs.registerStats(primary.absolutePath, 100, 40, 30)

        val usage = FileCacheOperations(RuntimeEnvironment.getApplication()).storageUsage()

        assertEquals(100L * 4096, usage["totalBytes"])
        assertEquals(30L * 4096, usage["availableBytes"])
        val roots = usage["storageRoots"] as List<*>
        assertTrue(roots.contains(primary.absolutePath))
        assertTrue(roots.contains(primary.canonicalPath))
        assertTrue(roots.contains("content://com.android.externalstorage.documents/tree/primary%3A"))
        assertTrue(roots.none { it.toString().contains("1234-ABCD") })
    }

    @Test
    fun `internal imports and cache belong only to emulated primary storage`() {
        val context = RuntimeEnvironment.getApplication()
        val primary = Environment.getExternalStorageDirectory()
        ShadowStatFs.registerStats(primary.absolutePath, 100, 40, 30)

        for (emulated in listOf(false, true)) {
            ShadowEnvironment.setExternalStorageEmulated(primary, emulated)
            val roots = FileCacheOperations(context).storageUsage()["storageRoots"] as List<*>
            assertEquals(emulated, roots.contains(context.filesDir.absolutePath))
            assertEquals(emulated, roots.contains(context.cacheDir.absolutePath))
        }
    }
}
