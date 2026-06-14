package com.nameless.audio

import android.app.Activity
import android.app.AlarmManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class PowerMethodHandler(
    private val activity: Activity
) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            PowerMethods.SET_KEEP_CPU_AWAKE,
            PowerMethods.STOP_PLAYBACK_KEEP_ALIVE -> result.success(null)
            PowerMethods.CAN_MANAGE_ALL_FILES_ACCESS -> result.success(canManageAllFilesAccess())
            PowerMethods.OPEN_MANAGE_ALL_FILES_ACCESS_SETTINGS ->
                result.success(openManageAllFilesAccessSettings())
            PowerMethods.IS_IGNORING_BATTERY_OPTIMIZATIONS ->
                result.success(isIgnoringBatteryOptimizations())
            PowerMethods.OPEN_BATTERY_OPTIMIZATION_SETTINGS ->
                result.success(openBatteryOptimizationSettings())
            PowerMethods.OPEN_BACKGROUND_RUN_SETTINGS -> result.success(openBackgroundRunSettings())
            PowerMethods.CAN_SCHEDULE_EXACT_ALARMS -> result.success(canScheduleExactAlarms())
            PowerMethods.OPEN_EXACT_ALARM_SETTINGS -> result.success(openExactAlarmSettings())
            PowerMethods.GET_NATIVE_TIMER_RUNTIME_STATE -> result.success(getNativeTimerRuntimeState())
            PowerMethods.EXECUTE_TIMER_EXPIRED_NOW -> {
                PlaybackTimerAlarmScheduler.executeNow(
                    activity.applicationContext,
                    PlaybackTimerAlarmScheduler.actionTimerExpired,
                    call.argument<Int>("generation")
                )
                result.success(true)
            }
            PowerMethods.EXECUTE_AUTO_RESUME_NOW -> {
                PlaybackTimerAlarmScheduler.executeNow(
                    activity.applicationContext,
                    PlaybackTimerAlarmScheduler.actionAutoResume,
                    call.argument<Int>("generation")
                )
                result.success(true)
            }
            PowerMethods.SYNC_PLAYBACK_TIMER_ALARMS -> {
                PlaybackTimerAlarmScheduler.sync(
                    activity.applicationContext,
                    timerModeIndex = call.argument<Int>("timerMode"),
                    durationMs = call.argument<Number>("timerDurationMs")?.toLong(),
                    waitingForPlayback = call.argument<Boolean>("timerWaitingForPlayback") ?: false,
                    timerEndsAtWallClockMs = call.argument<Long>("timerEndsAtWallClockMs"),
                    autoResumeEnabled = call.argument<Boolean>("autoResumeEnabled") ?: false,
                    autoResumeHour = call.argument<Int>("autoResumeHour") ?: 7,
                    autoResumeMinute = call.argument<Int>("autoResumeMinute") ?: 0,
                    autoResumeAtMs = call.argument<Long>("autoResumeAtMs"),
                    pausedSessionIds = call.argument<List<String>>("pausedSessionIds") ?: emptyList(),
                    generation = call.argument<Int>("generation") ?: 0
                )
                result.success(null)
            }
            else -> result.notImplemented()
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
