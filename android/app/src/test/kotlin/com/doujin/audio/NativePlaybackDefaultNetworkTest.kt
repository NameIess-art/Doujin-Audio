package com.doujin.audio

import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import com.doujin.audio.player.recovery.AndroidNativePlaybackRecoveryEnvironment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowNetwork
import org.robolectric.shadows.ShadowNetworkCapabilities

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NativePlaybackDefaultNetworkTest {
    @Test
    fun `default network changes and regained validation signal recovery once`() {
        val context = RuntimeEnvironment.getApplication()
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val shadowConnectivity = shadowOf(connectivity)
        val mainLooper = Looper.getMainLooper()
        val environment = AndroidNativePlaybackRecoveryEnvironment(context, Handler(mainLooper)) { message, error ->
            throw AssertionError(message, error)
        }
        val triggers = mutableListOf<String>()
        environment.startListening { triggers += it }
        val callback = shadowConnectivity.networkCallbacks.single()

        val initialNetwork = connectivity.activeNetwork
        if (initialNetwork != null) callback.onAvailable(initialNetwork)
        val validated = ShadowNetworkCapabilities.newInstance().apply {
            shadowOf(this).addCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        }
        val wireless = ShadowNetwork.newInstance(101)
        callback.onAvailable(wireless)
        callback.onCapabilitiesChanged(wireless, validated)
        callback.onAvailable(wireless)
        shadowOf(mainLooper).idle()
        assertEquals(listOf("network_available"), triggers)

        val cellular = ShadowNetwork.newInstance(102)
        callback.onAvailable(cellular)
        callback.onLost(wireless)
        val unvalidated = ShadowNetworkCapabilities.newInstance()
        callback.onCapabilitiesChanged(cellular, unvalidated)
        callback.onCapabilitiesChanged(cellular, validated)
        callback.onCapabilitiesChanged(cellular, validated)
        shadowOf(mainLooper).idle()
        assertEquals(List(3) { "network_available" }, triggers)

        callback.onLost(cellular)
        callback.onAvailable(wireless)
        environment.stopListening()
        shadowOf(mainLooper).idle()
        assertEquals(3, triggers.size)
        assertTrue(shadowConnectivity.networkCallbacks.isEmpty())
    }
}
