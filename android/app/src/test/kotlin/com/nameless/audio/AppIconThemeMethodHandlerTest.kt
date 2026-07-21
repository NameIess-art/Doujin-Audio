package com.nameless.audio

import android.content.res.Configuration
import com.nameless.audio.channel.appIconAliasName
import com.nameless.audio.channel.isDarkThemeMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppIconThemeMethodHandlerTest {
    @Test
    fun `explicit theme modes resolve independently from system mode`() {
        assertFalse(isDarkThemeMode("light", Configuration.UI_MODE_NIGHT_YES))
        assertTrue(isDarkThemeMode("dark", Configuration.UI_MODE_NIGHT_NO))
    }

    @Test
    fun `system theme mode follows ui mode night flag`() {
        assertFalse(isDarkThemeMode("system", Configuration.UI_MODE_NIGHT_NO))
        assertTrue(isDarkThemeMode("system", Configuration.UI_MODE_NIGHT_YES))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `unsupported theme mode is rejected`() {
        isDarkThemeMode("sepia", Configuration.UI_MODE_NIGHT_NO)
    }

    @Test
    fun `alias component names stay stable`() {
        val packageName = "com.nameless.audio"
        assertEquals(
            "$packageName.MainActivityLight",
            appIconAliasName(packageName, dark = false)
        )
        assertEquals(
            "$packageName.MainActivityDark",
            appIconAliasName(packageName, dark = true)
        )
    }
}
