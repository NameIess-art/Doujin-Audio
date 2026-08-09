package com.doujin.audio.channel

import android.app.Activity
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

internal data class WindowBrightnessLease(
    val token: String,
    val brightness: Float
)

internal class WindowBrightnessLeaseController(
    private val readWindowBrightness: () -> Float,
    private val readSystemBrightness: () -> Float,
    private val writeWindowBrightness: (Float) -> Unit,
    private val nextToken: () -> String = { UUID.randomUUID().toString() }
) {
    private data class ActiveLease(val token: String, val originalBrightness: Float)

    private var activeLease: ActiveLease? = null

    fun begin(): WindowBrightnessLease {
        restoreActive()
        val original = readWindowBrightness()
        val effective = if (original >= 0f) original else readSystemBrightness()
        val token = nextToken()
        activeLease = ActiveLease(token, original)
        return WindowBrightnessLease(token, effective.coerceIn(0.05f, 1f))
    }

    fun set(token: String, brightness: Float): Boolean {
        if (activeLease?.token != token) return false
        writeWindowBrightness(brightness.coerceIn(0.05f, 1f))
        return true
    }

    fun end(token: String): Boolean {
        val lease = activeLease ?: return false
        if (lease.token != token) return false
        writeWindowBrightness(lease.originalBrightness)
        activeLease = null
        return true
    }

    fun restoreActive() {
        val lease = activeLease ?: return
        writeWindowBrightness(lease.originalBrightness)
        activeLease = null
    }
}

internal class VideoDisplayMethodHandler(
    private val activity: Activity
) : MethodChannel.MethodCallHandler {
    private val brightnessController = WindowBrightnessLeaseController(
        readWindowBrightness = { activity.window.attributes.screenBrightness },
        readSystemBrightness = {
            runCatching {
                Settings.System.getInt(
                    activity.contentResolver,
                    Settings.System.SCREEN_BRIGHTNESS
                ) / 255f
            }.getOrDefault(0.5f)
        },
        writeWindowBrightness = { brightness ->
            activity.window.attributes = activity.window.attributes.apply {
                screenBrightness = brightness
            }
        }
    )

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val envelope = ChannelEnvelopeResult(result)
        try {
            when (call.method) {
                VideoDisplayMethods.BEGIN_BRIGHTNESS_CONTROL -> {
                    val lease = brightnessController.begin()
                    envelope.success(
                        mapOf(
                            "token" to lease.token,
                            "brightness" to lease.brightness.toDouble()
                        )
                    )
                }
                VideoDisplayMethods.SET_BRIGHTNESS -> {
                    val reader = call.argumentReader()
                    val token = reader.requiredString("token")
                    val brightness = reader.requiredDouble("brightness")
                    require(brightness in 0.05..1.0) {
                        "brightness must be between 0.05 and 1.0."
                    }
                    require(brightnessController.set(token, brightness.toFloat())) {
                        "Brightness lease is no longer active."
                    }
                    envelope.success(null)
                }
                VideoDisplayMethods.END_BRIGHTNESS_CONTROL -> {
                    val token = call.argumentReader().requiredString("token")
                    require(brightnessController.end(token)) {
                        "Brightness lease is no longer active."
                    }
                    envelope.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: IllegalArgumentException) {
            envelope.error(
                ChannelErrorCodes.INVALID_ARGUMENT,
                error.message ?: "Invalid arguments.",
                mapOf("method" to call.method)
            )
        } catch (error: Exception) {
            envelope.error(
                ChannelErrorCodes.PLATFORM_ERROR,
                error.message ?: "Unable to update video display settings.",
                mapOf("method" to call.method)
            )
        }
    }

    fun dispose() {
        brightnessController.restoreActive()
    }
}
