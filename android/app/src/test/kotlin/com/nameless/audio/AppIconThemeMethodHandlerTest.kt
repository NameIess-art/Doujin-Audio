package com.nameless.audio

import android.content.res.Configuration
import com.nameless.audio.channel.ICON_COLOR_GROUPS
import com.nameless.audio.channel.appIconAliasName
import com.nameless.audio.channel.iconColorGroupAliasSuffix
import com.nameless.audio.channel.isDarkThemeMode
import com.nameless.audio.channel.launcherAliasNames
import com.nameless.audio.channel.launcherAliasUpdates
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
            "$packageName.MainActivityWarmLight",
            appIconAliasName(packageName, dark = false, colorGroup = "warm")
        )
        assertEquals(
            "$packageName.MainActivityBlueDark",
            appIconAliasName(packageName, dark = true, colorGroup = "blue")
        )
    }

    @Test
    fun `six color groups expose stable alias suffixes`() {
        assertEquals(6, ICON_COLOR_GROUPS.size)
        assertEquals("Neutral", iconColorGroupAliasSuffix("neutral"))
        val aliases = launcherAliasNames("com.nameless.audio")
        assertEquals(12, aliases.size)
        assertEquals(12, aliases.toSet().size)
    }

    @Test
    fun `icon switches update only the target and current aliases`() {
        val updates = launcherAliasUpdates("current", "target")
        assertEquals(listOf("target" to true, "current" to false), updates)
        assertTrue(launcherAliasUpdates("same", "same").isEmpty())
    }

    @Test(expected = IllegalArgumentException::class)
    fun `unsupported color group is rejected`() {
        iconColorGroupAliasSuffix("teal")
    }
}
