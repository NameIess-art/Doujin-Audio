package com.nameless.audio.channel

import com.nameless.audio.player.notification.*
import com.nameless.audio.player.session.*

import android.app.Activity
import android.app.ActivityManager
import android.app.AlarmManager
import android.app.ApplicationExitInfo
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.Settings
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal data class PlaybackTimerSyncArguments(
    val timerModeIndex: Int?,
    val durationMs: Long?,
    val waitingForPlayback: Boolean,
    val timerEndsAtWallClockMs: Long?,
    val autoResumeEnabled: Boolean,
    val autoResumeHour: Int,
    val autoResumeMinute: Int,
    val autoResumeAtMs: Long?,
    val pausedSessionIds: List<String>,
    val generation: Int
)

private data class ApplicationExitDiagnostics(
    val reason: Int,
    val subReason: Int?,
    val description: String?,
    val timestampMs: Long
)

internal fun parsePlaybackTimerSyncArguments(call: MethodCall): PlaybackTimerSyncArguments {
    val arguments = call.argumentReader()
    val pausedSessionIds = arguments.requiredStringList("pausedSessionIds")
    require(pausedSessionIds.distinct().size == pausedSessionIds.size) {
        "pausedSessionIds contains duplicates."
    }
    return PlaybackTimerSyncArguments(
        timerModeIndex = arguments.requiredNullableInt("timerMode", 0..1),
        durationMs = arguments.requiredNullableLong("timerDurationMs", minimum = 1L),
        waitingForPlayback = arguments.requiredBoolean("timerWaitingForPlayback"),
        timerEndsAtWallClockMs = arguments.requiredNullableLong(
            "timerEndsAtWallClockMs",
            minimum = 0L
        ),
        autoResumeEnabled = arguments.requiredBoolean("autoResumeEnabled"),
        autoResumeHour = arguments.requiredIntInRange("autoResumeHour", 0..23),
        autoResumeMinute = arguments.requiredIntInRange("autoResumeMinute", 0..59),
        autoResumeAtMs = arguments.requiredNullableLong("autoResumeAtMs", minimum = 0L),
        pausedSessionIds = pausedSessionIds,
        generation = arguments.requiredIntInRange("generation", 0..Int.MAX_VALUE)
    )
}

internal class PowerMethodHandler(
    private val activity: Activity
) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val envelope = ChannelEnvelopeResult(result)
        try {
            when (call.method) {
            PowerMethods.CAN_MANAGE_ALL_FILES_ACCESS -> envelope.success(canManageAllFilesAccess())
            PowerMethods.OPEN_MANAGE_ALL_FILES_ACCESS_SETTINGS ->
                envelope.success(openManageAllFilesAccessSettings())
            PowerMethods.IS_IGNORING_BATTERY_OPTIMIZATIONS ->
                envelope.success(isIgnoringBatteryOptimizations())
            PowerMethods.OPEN_BATTERY_OPTIMIZATION_SETTINGS -> envelope.success(openBatteryOptimizationSettings())
            PowerMethods.OPEN_BACKGROUND_RUN_SETTINGS -> envelope.success(openBackgroundRunSettings())
            PowerMethods.CAN_SCHEDULE_EXACT_ALARMS -> envelope.success(canScheduleExactAlarms())
            PowerMethods.OPEN_EXACT_ALARM_SETTINGS -> envelope.success(openExactAlarmSettings())
            PowerMethods.GET_NATIVE_TIMER_RUNTIME_STATE -> envelope.success(getNativeTimerRuntimeState())
            PowerMethods.GET_BACKGROUND_RUN_DIAGNOSTICS ->
                envelope.success(getBackgroundRunDiagnostics())
            PowerMethods.EXECUTE_TIMER_EXPIRED_NOW -> {
                PlaybackTimerAlarmScheduler.executeNow(
                    activity.applicationContext,
                    PlaybackTimerAlarmScheduler.actionTimerExpired,
                    call.argumentReader().requiredIntInRange("generation", 0..Int.MAX_VALUE),
                    onComplete = envelope::success
                )
            }
            PowerMethods.EXECUTE_AUTO_RESUME_NOW -> {
                PlaybackTimerAlarmScheduler.executeNow(
                    activity.applicationContext,
                    PlaybackTimerAlarmScheduler.actionAutoResume,
                    call.argumentReader().requiredIntInRange("generation", 0..Int.MAX_VALUE),
                    onComplete = envelope::success
                )
            }
            PowerMethods.SYNC_PLAYBACK_TIMER_ALARMS -> {
                val arguments = parsePlaybackTimerSyncArguments(call)
                PlaybackTimerAlarmScheduler.sync(
                    activity.applicationContext,
                    timerModeIndex = arguments.timerModeIndex,
                    durationMs = arguments.durationMs,
                    waitingForPlayback = arguments.waitingForPlayback,
                    timerEndsAtWallClockMs = arguments.timerEndsAtWallClockMs,
                    autoResumeEnabled = arguments.autoResumeEnabled,
                    autoResumeHour = arguments.autoResumeHour,
                    autoResumeMinute = arguments.autoResumeMinute,
                    autoResumeAtMs = arguments.autoResumeAtMs,
                    pausedSessionIds = arguments.pausedSessionIds,
                    generation = arguments.generation
                )
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
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val manager = activity.getSystemService(Activity.POWER_SERVICE) as? PowerManager
        return manager?.isIgnoringBatteryOptimizations(activity.packageName) == true
    }

    private fun canManageAllFilesAccess(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return true
        return try {
            Environment.isExternalStorageManager()
        } catch (_: Exception) {
            false
        }
    }

    private fun openManageAllFilesAccessSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return openApplicationDetailsSettings()
        return openSettings(
            Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:${activity.packageName}")
            )
        ) || openSettings(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)) ||
            openApplicationDetailsSettings()
    }

    private fun openBatteryOptimizationSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return openApplicationDetailsSettings()
        return openSettings(
            Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${activity.packageName}")
            )
        ) || openSettings(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) ||
            openApplicationDetailsSettings()
    }

    private fun openBackgroundRunSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return openApplicationDetailsSettings()
        if (Build.MANUFACTURER.equals("vivo", ignoreCase = true)) {
            val openedVendorSettings = vivoBackgroundSettingsIntents().any(::openSettings)
            if (openedVendorSettings) return true
        }
        if (!isIgnoringBatteryOptimizations() && openBatteryOptimizationSettings()) return true
        return openSettings(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) ||
            openApplicationDetailsSettings()
    }

    private fun canScheduleExactAlarms(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return try {
            activity.getSystemService(AlarmManager::class.java)?.canScheduleExactAlarms() == true
        } catch (_: Exception) {
            false
        }
    }

    private fun openExactAlarmSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return openApplicationDetailsSettings()
        return openSettings(
            Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                data = Uri.parse("package:${activity.packageName}")
            }
        ) || openApplicationDetailsSettings()
    }

    private fun getNativeTimerRuntimeState(): Map<String, Any?>? {
        val state = NativePlaybackStateStore.loadTimerRuntimeState(activity.applicationContext)
            ?: return null
        return mapOf(
            "timerMode" to state.timerModeIndex,
            "timerDurationMs" to state.durationMs,
            "timerWaitingForPlayback" to state.waitingForPlayback,
            "timerEndsAtWallClockMs" to state.timerEndsAtWallClockMs,
            "timerEndsElapsedRealtimeMs" to state.timerEndsElapsedRealtimeMs,
            "autoResumeEnabled" to state.autoResumeEnabled,
            "autoResumeHour" to state.autoResumeHour,
            "autoResumeMinute" to state.autoResumeMinute,
            "autoResumeAtMs" to state.autoResumeAtMs,
            "pausedSessionIds" to state.pausedSessionIds,
            "generation" to state.generation
        )
    }

    private fun getBackgroundRunDiagnostics(): Map<String, Any?> {
        val lastExit = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            getApplicationExitDiagnostics()
        } else {
            null
        }
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "batteryOptimizationExempt" to isIgnoringBatteryOptimizations(),
            "vendorBackgroundSettingsAvailable" to
                vivoBackgroundSettingsIntents().any(::canOpenSettings),
            "lastExitReason" to lastExit?.reason,
            "lastExitSubReason" to lastExit?.subReason,
            "lastExitDescription" to lastExit?.description,
            "lastExitTimestampMs" to lastExit?.timestampMs,
            "cleanerForceStopDetected" to isCleanerForceStop(
                reason = lastExit?.reason,
                description = lastExit?.description
            )
        )
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun getApplicationExitDiagnostics(): ApplicationExitDiagnostics? {
        val exit = (activity.getSystemService(Activity.ACTIVITY_SERVICE) as? ActivityManager)
            ?.getHistoricalProcessExitReasons(activity.packageName, 0, 1)
            ?.firstOrNull()
            ?: return null
        return ApplicationExitDiagnostics(
            reason = exit.reason,
            subReason = applicationExitSubReason(exit),
            description = exit.description,
            timestampMs = exit.timestamp
        )
    }

    private fun vivoBackgroundSettingsIntents(): List<Intent> {
        return vivoBackgroundSettingsTargets(Build.MANUFACTURER).map { target ->
            Intent(target.first).apply { setPackage(target.second) }
        }
    }

    private fun canOpenSettings(intent: Intent): Boolean {
        return intent.resolveActivity(activity.packageManager) != null
    }

    private fun openApplicationDetailsSettings(): Boolean {
        return openSettings(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", activity.packageName, null)
            )
        )
    }

    private fun openSettings(intent: Intent): Boolean {
        return try {
            intent.flags = intent.flags or Intent.FLAG_ACTIVITY_NEW_TASK
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}

internal fun isCleanerForceStop(reason: Int?, description: String?): Boolean {
    return reason == ApplicationExitInfo.REASON_USER_REQUESTED &&
        description?.contains("cleaner", ignoreCase = true) == true
}

private fun applicationExitSubReason(exitInfo: ApplicationExitInfo?): Int? {
    if (exitInfo == null) return null
    return try {
        exitInfo.javaClass
            .getMethod("getSubReason")
            .invoke(exitInfo) as? Int
    } catch (_: ReflectiveOperationException) {
        null
    } catch (_: SecurityException) {
        null
    }
}

internal fun vivoBackgroundSettingsTargets(
    manufacturer: String
): List<Pair<String, String>> {
    if (!manufacturer.equals("vivo", ignoreCase = true)) return emptyList()
    return listOf(
        "com.iqoo.powersaving.battery.high.power.jump" to "com.iqoo.powersaving",
        "com.iqoo.secure.BGSTARTUPMANAGER" to "com.vivo.permissionmanager"
    )
}
