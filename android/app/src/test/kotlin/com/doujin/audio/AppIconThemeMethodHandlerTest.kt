package com.doujin.audio

import android.content.res.Configuration
import com.doujin.audio.channel.ICON_COLOR_GROUPS
import com.doujin.audio.channel.appIconLauncherActivityName
import com.doujin.audio.channel.effectiveLauncherThemeMode
import com.doujin.audio.channel.iconColorGroupLauncherSuffix
import com.doujin.audio.channel.launcherActivityNames
import com.doujin.audio.channel.launcherActivityUpdates
import com.doujin.audio.channel.launcherThemeModeSuffix
import com.doujin.audio.channel.validIconColorGroupOrDefault
import com.doujin.audio.channel.validThemeModeOrDefault
import org.junit.Assert.assertEquals
import org.junit.Test

class AppIconThemeMethodHandlerTest {
    @Test
    fun `three appearance modes expose stable launcher suffixes`() {
        assertEquals("System", launcherThemeModeSuffix("system"))
        assertEquals("Light", launcherThemeModeSuffix("light"))
        assertEquals("Dark", launcherThemeModeSuffix("dark"))
    }

    @Test
    fun `system appearance resolves to the current light or dark launcher activity`() {
        assertEquals(
            "light",
            effectiveLauncherThemeMode("system", Configuration.UI_MODE_NIGHT_NO)
        )
        assertEquals(
            "dark",
            effectiveLauncherThemeMode("system", Configuration.UI_MODE_NIGHT_YES)
        )
        assertEquals(
            "dark",
            effectiveLauncherThemeMode("dark", Configuration.UI_MODE_NIGHT_NO)
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `unsupported theme mode is rejected`() {
        launcherThemeModeSuffix("sepia")
    }

    @Test
    fun `launcher activity component names stay in the code namespace`() {
        assertEquals(
            "com.doujin.audio.common.MainActivityWarmSystem",
            appIconLauncherActivityName(mode = "system", colorGroup = "warm")
        )
        assertEquals(
            "com.doujin.audio.common.MainActivityBlueDark",
            appIconLauncherActivityName(mode = "dark", colorGroup = "blue")
        )
    }

    @Test
    fun `six color groups expose eighteen launcher activities`() {
        assertEquals(6, ICON_COLOR_GROUPS.size)
        assertEquals("Neutral", iconColorGroupLauncherSuffix("neutral"))
        val activities = launcherActivityNames()
        assertEquals(18, activities.size)
        assertEquals(18, activities.toSet().size)
    }

    @Test
    fun `icon switches leave exactly one launcher activity enabled`() {
        val activities = launcherActivityNames()
        val target = "com.doujin.audio.common.MainActivityGreenSystem"
        val updates = launcherActivityUpdates(activities, target)

        assertEquals(activities.size, updates.size)
        assertEquals(target to true, updates.first())
        assertEquals(listOf(target), updates.filter { it.second }.map { it.first })
        assertEquals(activities.toSet(), updates.map { it.first }.toSet())
    }

    @Test(expected = IllegalArgumentException::class)
    fun `unregistered launcher activity is rejected`() {
        launcherActivityUpdates(
            launcherActivityNames(),
            "com.doujin.audio.MainActivityMissing"
        )
    }

    @Test
    fun `invalid persisted launcher values use stable defaults`() {
        assertEquals("system", validThemeModeOrDefault("sepia"))
        assertEquals("warm", validIconColorGroupOrDefault("teal"))
        assertEquals("dark", validThemeModeOrDefault("dark"))
        assertEquals("purple", validIconColorGroupOrDefault("purple"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `unsupported color group is rejected`() {
        iconColorGroupLauncherSuffix("teal")
    }
}
