package com.nameless.audio

import com.nameless.audio.channel.ICON_COLOR_GROUPS
import com.nameless.audio.channel.appIconLauncherActivityName
import com.nameless.audio.channel.iconColorGroupLauncherSuffix
import com.nameless.audio.channel.launcherActivityNames
import com.nameless.audio.channel.launcherActivityUpdates
import com.nameless.audio.channel.launcherThemeModeSuffix
import com.nameless.audio.channel.validIconColorGroupOrDefault
import com.nameless.audio.channel.validThemeModeOrDefault
import org.junit.Assert.assertEquals
import org.junit.Test

class AppIconThemeMethodHandlerTest {
    @Test
    fun `three appearance modes expose stable launcher suffixes`() {
        assertEquals("System", launcherThemeModeSuffix("system"))
        assertEquals("Light", launcherThemeModeSuffix("light"))
        assertEquals("Dark", launcherThemeModeSuffix("dark"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `unsupported theme mode is rejected`() {
        launcherThemeModeSuffix("sepia")
    }

    @Test
    fun `launcher activity component names stay stable`() {
        val packageName = "com.nameless.audio"
        assertEquals(
            "$packageName.common.MainActivityWarmSystem",
            appIconLauncherActivityName(packageName, mode = "system", colorGroup = "warm")
        )
        assertEquals(
            "$packageName.common.MainActivityBlueDark",
            appIconLauncherActivityName(packageName, mode = "dark", colorGroup = "blue")
        )
    }

    @Test
    fun `six color groups expose eighteen launcher activities`() {
        assertEquals(6, ICON_COLOR_GROUPS.size)
        assertEquals("Neutral", iconColorGroupLauncherSuffix("neutral"))
        val activities = launcherActivityNames("com.nameless.audio")
        assertEquals(18, activities.size)
        assertEquals(18, activities.toSet().size)
    }

    @Test
    fun `icon switches leave exactly one launcher activity enabled`() {
        val activities = launcherActivityNames("com.nameless.audio")
        val target = "com.nameless.audio.common.MainActivityGreenSystem"
        val updates = launcherActivityUpdates(activities, target)

        assertEquals(activities.size, updates.size)
        assertEquals(target to true, updates.first())
        assertEquals(listOf(target), updates.filter { it.second }.map { it.first })
        assertEquals(activities.toSet(), updates.map { it.first }.toSet())
    }

    @Test(expected = IllegalArgumentException::class)
    fun `unregistered launcher activity is rejected`() {
        launcherActivityUpdates(
            launcherActivityNames("com.nameless.audio"),
            "com.nameless.audio.MainActivityMissing"
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
