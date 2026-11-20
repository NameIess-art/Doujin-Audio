package com.doujin.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class StartupWindowThemeTest {
    @Test
    fun `surface colors follow accent preset in light and dark modes`() {
        assertEquals(
            0xFFF5FFF9.toInt(),
            StartupWindowTheme.surfaceColor("teal", dark = false)
        )
        assertEquals(
            0xFF101513.toInt(),
            StartupWindowTheme.surfaceColor("teal", dark = true)
        )
        assertEquals(
            0xFFFAF8FF.toInt(),
            StartupWindowTheme.surfaceColor("purple", dark = false)
        )
        assertEquals(
            0xFF131117.toInt(),
            StartupWindowTheme.surfaceColor("purple", dark = true)
        )
        assertEquals(
            0xFFF7F8FA.toInt(),
            StartupWindowTheme.surfaceColor("monochrome", dark = false)
        )
        assertEquals(
            0xFF121315.toInt(),
            StartupWindowTheme.surfaceColor("monochrome", dark = true)
        )
        assertEquals(
            0xFF000000.toInt(),
            StartupWindowTheme.surfaceColor("monochrome", dark = true, pureBlack = true)
        )
        assertEquals(
            0xFFF7F9FF.toInt(),
            StartupWindowTheme.surfaceColor("blue", dark = false)
        )
        assertEquals(
            0xFF101218.toInt(),
            StartupWindowTheme.surfaceColor("blue", dark = true)
        )
        assertEquals(
            0xFF000000.toInt(),
            StartupWindowTheme.surfaceColor("blue", dark = true, pureBlack = true)
        )
        assertEquals(
            0xFFF7F9FF.toInt(),
            StartupWindowTheme.surfaceColor("blue", dark = false, pureBlack = true)
        )
    }

    @Test
    fun `unknown accent falls back to the default rose surface`() {
        assertEquals(
            0xFFFFF8F8.toInt(),
            StartupWindowTheme.surfaceColor("unknown", dark = false)
        )
        assertEquals(
            0xFF141112.toInt(),
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
            R.style.LaunchTheme_Gray,
            StartupWindowTheme.splashThemeResId("monochrome", "system")
        )
        assertEquals(
            R.style.LaunchTheme_Amber_Dark,
            StartupWindowTheme.splashThemeResId("yellow", "dark")
        )
        assertEquals(
            R.style.LaunchTheme_Lavender_Light,
            StartupWindowTheme.splashThemeResId("purple", "light")
        )
        assertEquals(
            R.style.LaunchTheme_Rose,
            StartupWindowTheme.splashThemeResId("unknown", "system")
        )
        assertEquals(
            R.style.LaunchTheme_PureBlack,
            StartupWindowTheme.splashThemeResId("mint", "dark", pureBlack = true, dark = true)
        )
        assertEquals(
            R.style.LaunchTheme_PureBlack,
            StartupWindowTheme.splashThemeResId("mint", "system", pureBlack = true, dark = true)
        )
        assertEquals(
            R.style.LaunchTheme_Mint_Light,
            StartupWindowTheme.splashThemeResId("mint", "light", pureBlack = true, dark = false)
        )
    }
}
