package com.doujin.audio.channel

import com.doujin.audio.player.notification.*
import com.doujin.audio.player.session.*

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.AlarmManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import androidx.annotation.RequiresApi
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

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
    val generation: Int,
    val stopAfterCurrentTrack: Boolean = false
)

internal class PlaybackTimerSyncCoordinator(
    private val loadCandidates: ((FileCacheTaskResult<Map<String, Long>>) -> Unit) -> Boolean,
    private val isSessionCurrent: (String, Long) -> Boolean,
    private val apply: (PlaybackTimerSyncArguments, List<String>) -> Unit
) {
    private var request = 0L
    private var closed = false

    fun sync(arguments: PlaybackTimerSyncArguments, complete: (Exception?) -> Unit) {
        val expectedRequest = ++request
        fun finish(result: FileCacheTaskResult<Map<String, Long>>) {
            if (closed || expectedRequest != request) {
                complete(null)
                return
            }
            val error = try {
                when (result) {
                    is FileCacheTaskResult.Success -> {
                        val ids = result.value.filter { (id, revision) -> isSessionCurrent(id, revision) }.keys.toList()
                        apply(arguments, ids)
                        null
                    }
                    is FileCacheTaskResult.Failure -> result.exception
                }
            } catch (error: Exception) {
                error
            }
            complete(error)
        }
        if (arguments.timerEndsAtWallClockMs == null) {
            finish(FileCacheTaskResult.Success(emptyMap()))
        } else if (!loadCandidates(::finish)) {
            complete(IllegalStateException("Timer synchronization is unavailable"))
        }
    }

    fun close() {
        closed = true
        request++
    }
}

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
        generation = arguments.requiredIntInRange("generation", 0..Int.MAX_VALUE),
        stopAfterCurrentTrack = arguments.optionalBoolean("stopAfterCurrentTrack", false)
    )
}

internal class PowerMethodHandler(
    private val activity: Activity,
    private val taskExecutor: FileCacheTaskExecutor
) : MethodChannel.MethodCallHandler {
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private val closed = AtomicBoolean(false)
    private val appContext: Context get() = activity.applicationContext ?: activity
    private val timerSync = PlaybackTimerSyncCoordinator(
        loadCandidates = { complete ->
            taskExecutor.submit({ NativePlaybackStateStore.loadActiveSessionRevisions(activity.applicationContext) }) {
                result -> mainHandler.post { complete(result) }
            }
        },
        isSessionCurrent = { id, revision -> NativePlaybackStateStore.sessionRevision(id) == revision },
        apply = { arguments, candidateIds ->
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
                generation = arguments.generation,
                timerCandidateSessionIds = candidateIds,
                stopAfterCurrentTrack = arguments.stopAfterCurrentTrack
            )
        }
    )

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
            PowerMethods.CAN_POST_NOTIFICATIONS -> envelope.success(canPostNotifications())
            PowerMethods.OPEN_NOTIFICATION_SETTINGS -> envelope.success(openNotificationSettings())
            PowerMethods.CAN_SCHEDULE_EXACT_ALARMS -> envelope.success(canScheduleExactAlarms())
            PowerMethods.OPEN_EXACT_ALARM_SETTINGS -> envelope.success(openExactAlarmSettings())
            PowerMethods.GET_NATIVE_TIMER_RUNTIME_STATE -> runAsync(
                envelope,
                errorCode = "timer_runtime_state_failed",
                block = ::getNativeTimerRuntimeState
            )
            PowerMethods.GET_BACKGROUND_RUN_DIAGNOSTICS -> runAsync(
                envelope,
                errorCode = "background_diagnostics_failed",
                block = ::getBackgroundRunDiagnostics
            )
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
                timerSync.sync(arguments) { error ->
                    if (error == null) envelope.success(null)
                    else envelope.error("timer_sync_failed", error.message, null)
                }
            }
            PowerMethods.SET_KEEP_SCREEN_ON -> envelope.success(setKeepScreenOn(call))
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

    private fun runAsync(
        envelope: ChannelEnvelopeResult,
        errorCode: String,
        block: () -> Any?
    ) {
        if (closed.get()) {
            envelope.error(errorCode, "Power handler is unavailable.", null)
            return
        }
        val accepted = taskExecutor.submit(block) { taskResult ->
            if (closed.get()) return@submit
            mainHandler.post {
                if (closed.get()) return@post
                when (taskResult) {
                    is FileCacheTaskResult.Success -> envelope.success(taskResult.value)
                    is FileCacheTaskResult.Failure -> envelope.error(
                        errorCode,
                        taskResult.exception.message ?: "Unknown error.",
                        null
                    )
                }
            }
        }
        if (!accepted) {
            envelope.error(errorCode, "Power handler is unavailable.", null)
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val context = appContext
        val manager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return manager?.isIgnoringBatteryOptimizations(context.packageName) == true
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
        return openSettings(
            Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${activity.packageName}")
            )
        ) || openSettings(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) ||
            openApplicationDetailsSettings()
    }

    private fun openBackgroundRunSettings(): Boolean {
        if (Build.MANUFACTURER.equals("vivo", ignoreCase = true)) {
            val openedVendorSettings = vivoBackgroundSettingsIntents().any(::openSettings)
            if (openedVendorSettings) return true
        }
        if (!isIgnoringBatteryOptimizations() && openBatteryOptimizationSettings()) return true
        return openSettings(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) ||
            openApplicationDetailsSettings()
    }

    private fun canPostNotifications(): Boolean {
        val context = appContext
        val enabled = try {
            NotificationManagerCompat.from(context).areNotificationsEnabled()
        } catch (_: Exception) {
            true
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return enabled
        val granted = try {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        } catch (_: Exception) {
            false
        }
        return enabled && granted
    }

    private fun openNotificationSettings(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !canPostNotifications()) {
            val prefs = activity.getSharedPreferences(POWER_PREFS_NAME, Context.MODE_PRIVATE)
            val alreadyRequested = prefs.getBoolean(KEY_NOTIFICATION_PERMISSION_REQUESTED, false)
            val shouldShowRationale = ActivityCompat.shouldShowRequestPermissionRationale(
                activity,
                Manifest.permission.POST_NOTIFICATIONS
            )
            if (!alreadyRequested || shouldShowRationale) {
                prefs.edit().putBoolean(KEY_NOTIFICATION_PERMISSION_REQUESTED, true).apply()
                return try {
                    ActivityCompat.requestPermissions(
                        activity,
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                        NOTIFICATION_PERMISSION_REQUEST_CODE
                    )
                    true
                } catch (_: Exception) {
                    openSystemNotificationSettings()
                }
            }
        }
        return openSystemNotificationSettings()
    }

    private fun openSystemNotificationSettings(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
            }
            if (openSettings(intent)) return true
        }
        return openApplicationDetailsSettings()
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
            "stopAfterCurrentTrack" to state.stopAfterCurrentTrack,
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
            "notificationsEnabled" to canPostNotifications(),
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
        val context = appContext
        val exit = (context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager)
            ?.getHistoricalProcessExitReasons(context.packageName, 0, 1)
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
        return intent.resolveActivity(appContext.packageManager) != null
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

    private fun setKeepScreenOn(call: MethodCall): Boolean {
        val enabled = call.argumentReader().requiredBoolean("enabled")
        return try {
            activity.runOnUiThread {
                if (enabled) {
                    activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    fun dispose() {
        closed.set(true)
        timerSync.close()
        try {
            activity.runOnUiThread {
                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        } catch (_: Exception) {
        }
    }

    private companion object {
        const val POWER_PREFS_NAME = "doujin_audio_power_prefs"
        const val KEY_NOTIFICATION_PERMISSION_REQUESTED = "notification_permission_requested"
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 32011
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
