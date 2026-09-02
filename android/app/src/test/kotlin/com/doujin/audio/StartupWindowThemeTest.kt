package com.doujin.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class StartupWindowThemeTest {
    @Test
    fun `surface colors follow accent preset in light and dark modes`() {
        assertEquals(
            0xFFF5FFF9.toInt(),
            StartupWindowTheme.surfaceColor("mint", dark = false)
        )
        assertEquals(
            0xFF12201C.toInt(),
            StartupWindowTheme.surfaceColor("mint", dark = true)
        )
        assertEquals(
            0xFFFAF8FF.toInt(),
            StartupWindowTheme.surfaceColor("lavender", dark = false)
        )
        assertEquals(
            0xFF1D1927.toInt(),
            StartupWindowTheme.surfaceColor("lavender", dark = true)
        )
    }

    @Test
    fun `unknown accent falls back to the default rose surface`() {
        assertEquals(
            0xFFFFF8F8.toInt(),
            StartupWindowTheme.surfaceColor("unknown", dark = false)
        )
        assertEquals(
            0xFF211A1B.toInt(),
            StartupWindowTheme.surfaceColor("unknown", dark = true)
        )
    }

    @Test
    fun `splash theme maps correctly for presets and appearance modes`() {
        assertEquals(
            R.style.LaunchTheme_Mint,
            StartupWindowTheme.splashThemeResId("mint", "system")
        )
        assertEquals(
            R.style.LaunchTheme_Mint_Light,
            StartupWindowTheme.splashThemeResId("mint", "light")
        )
        assertEquals(
            R.style.LaunchTheme_Mint_Dark,
            StartupWindowTheme.splashThemeResId("mint", "dark")
        )
        assertEquals(
            R.style.LaunchTheme_Blue_Light,
            StartupWindowTheme.splashThemeResId("sky", "light")
        )
        assertEquals(
            R.style.LaunchTheme_Amber_Dark,
            StartupWindowTheme.splashThemeResId("peach", "dark")
        )
        assertEquals(
            R.style.LaunchTheme_Gray,
            StartupWindowTheme.splashThemeResId("gray", "system")
        )
        assertEquals(
            R.style.LaunchTheme_Rose,
            StartupWindowTheme.splashThemeResId("unknown", "system")
        )
    }
}
