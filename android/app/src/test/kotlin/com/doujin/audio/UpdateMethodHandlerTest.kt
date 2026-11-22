package com.doujin.audio

import android.app.Activity
import android.content.pm.PackageManager
import com.doujin.audio.channel.UpdateMethods
import com.doujin.audio.update.UpdateMethodHandler
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class UpdateMethodHandlerTest {
    @Test
    fun `installDownloadedApk returns needsPermission without eagerly opening settings`() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        shadowOf(activity.packageManager as PackageManager).setCanRequestPackageInstalls(false)
        val handler = UpdateMethodHandler(activity)

        var response: Any? = null
        val result = object : MethodChannel.Result {
            override fun success(value: Any?) { response = value }
            override fun error(code: String, message: String?, details: Any?) = error("Envelope expected")
            override fun notImplemented() = error("Known method expected")
        }

        handler.onMethodCall(
            MethodCall(UpdateMethods.INSTALL_APK, mapOf("path" to "/tmp/update.apk")),
            result
        )

        assertNull(shadowOf(activity).nextStartedActivity)
        assertEquals(
            mapOf(
                "ok" to true,
                "value" to mapOf(
                    "ok" to false,
                    "needsPermission" to true,
                    "message" to "Install permission is required."
                )
            ),
            response
        )
    }
}
