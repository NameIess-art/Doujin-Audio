package com.doujin.audio

import android.app.Activity
import android.content.pm.PackageManager
import com.doujin.audio.channel.ChannelErrorCodes
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
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class UpdateMethodHandlerTest {
    private fun invoke(handler: UpdateMethodHandler, method: String, arguments: Any?): Map<*, *> {
        var response: Any? = null
        val result = object : MethodChannel.Result {
            override fun success(value: Any?) { response = value }
            override fun error(code: String, message: String?, details: Any?) = error("Envelope expected")
            override fun notImplemented() = error("Known method expected")
        }
        handler.onMethodCall(MethodCall(method, arguments), result)
        return response as Map<*, *>
    }

    @Test
    fun `installDownloadedApk returns needsPermission without eagerly opening settings`() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        shadowOf(activity.packageManager as PackageManager).setCanRequestPackageInstalls(false)
        val handler = UpdateMethodHandler(activity)

        val response = invoke(handler, UpdateMethods.INSTALL_APK, mapOf("path" to "/tmp/update.apk"))

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

    @Test
    fun `installDownloadedApk rejects paths outside updates cache directory or non-apk extensions`() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        shadowOf(activity.packageManager as PackageManager).setCanRequestPackageInstalls(true)
        val handler = UpdateMethodHandler(activity)

        val updatesDir = File(activity.cacheDir, "updates").apply { mkdirs() }
        val siblingDir = File(activity.cacheDir, "updates_evil").apply { mkdirs() }
        val outsideApk = File(activity.cacheDir, "escape.apk").apply { writeBytes(byteArrayOf(1)) }
        val siblingApk = File(siblingDir, "evil.apk").apply { writeBytes(byteArrayOf(1)) }
        val traversalPath = File(updatesDir, "../escape.apk").path
        val nonApk = File(updatesDir, "payload.bin").apply { writeBytes(byteArrayOf(1)) }

        for (badPath in listOf(outsideApk.path, siblingApk.path, traversalPath, nonApk.path)) {
            val response = invoke(handler, UpdateMethods.INSTALL_APK, mapOf("path" to badPath))
            assertEquals(badPath, false, response["ok"])
            assertEquals(badPath, ChannelErrorCodes.INVALID_ARGUMENT, response["errorCode"])
        }
        assertNull(shadowOf(activity).nextStartedActivity)
    }

    @Test
    fun `installDownloadedApk accepts canonical apk inside updates directory and checks existence`() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        shadowOf(activity.packageManager as PackageManager).setCanRequestPackageInstalls(true)
        val handler = UpdateMethodHandler(activity)
        val updatesDir = File(activity.cacheDir, "updates").apply { mkdirs() }
        val missingApk = File(updatesDir, "DoujinAudio-v2.APK")

        val response = invoke(handler, UpdateMethods.INSTALL_APK, mapOf("path" to missingApk.path))
        assertEquals(
            mapOf(
                "ok" to true,
                "value" to mapOf(
                    "ok" to false,
                    "needsPermission" to false,
                    "message" to "APK file does not exist."
                )
            ),
            response
        )
    }

    @Test
    fun `unexpected failures in update handler return platform error envelope`() {
        val failingActivity = object : Activity() {
            override fun getPackageManager(): PackageManager {
                throw IllegalStateException("pm unavailable")
            }
        }
        val handler = UpdateMethodHandler(failingActivity)
        val response = invoke(handler, UpdateMethods.GET_APP_VERSION, null)
        assertEquals(false, response["ok"])
        assertEquals(ChannelErrorCodes.PLATFORM_ERROR, response["errorCode"])
    }
}
