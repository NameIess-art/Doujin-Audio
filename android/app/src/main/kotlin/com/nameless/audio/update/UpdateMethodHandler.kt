package com.nameless.audio.update

import com.nameless.audio.channel.*

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

internal class UpdateMethodHandler(
    private val activity: Activity
) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val envelope = ChannelEnvelopeResult(result)
        try {
            when (call.method) {
                UpdateMethods.GET_APP_VERSION -> envelope.success(currentAppVersion())
                UpdateMethods.INSTALL_APK -> envelope.success(
                    installDownloadedApk(call.argumentReader().requiredString("path"))
                )
                UpdateMethods.CAN_INSTALL_UNKNOWN_APPS -> envelope.success(canInstallUnknownApps())
                UpdateMethods.OPEN_INSTALL_PERMISSION_SETTINGS ->
                    envelope.success(openInstallPermissionSettings())
                UpdateMethods.OPEN_RELEASE_PAGE -> envelope.success(
                    openReleasePage(call.argumentReader().requiredString("url"))
                )
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

    private fun currentAppVersion(): Map<String, Any> {
        val packageInfo = activity.packageManager.getPackageInfo(activity.packageName, 0)
        val buildNumber = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toLong()
        }
        return mapOf(
            "versionName" to (packageInfo.versionName ?: "unknown"),
            "buildNumber" to buildNumber,
            "androidAssetVariant" to currentAndroidAssetVariant()
        )
    }

    private fun currentAndroidAssetVariant(): String {
        return when (Build.SUPPORTED_ABIS.firstOrNull()) {
            "arm64-v8a" -> "arm64"
            "armeabi-v7a", "armeabi" -> "armv7"
            "x86_64" -> "x64"
            else -> "universal"
        }
    }

    private fun installDownloadedApk(apkPath: String): Map<String, Any?> {
        if (!canInstallUnknownApps()) {
            openInstallPermissionSettings()
            return installResult(false, true, "Install permission is required.")
        }
        val apkFile = File(apkPath)
        if (!apkFile.exists() || apkFile.length() <= 0) {
            return installResult(false, false, "APK file does not exist.")
        }

        return try {
            val uri = FileProvider.getUriForFile(
                activity,
                "${activity.packageName}.fileprovider",
                apkFile
            )
            activity.startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            )
            installResult(true, false, null)
        } catch (error: Exception) {
            installResult(false, false, error.message ?: "Cannot open installer.")
        }
    }

    private fun installResult(ok: Boolean, needsPermission: Boolean, message: String?) =
        mapOf("ok" to ok, "needsPermission" to needsPermission, "message" to message)

    private fun canInstallUnknownApps(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            activity.packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermissionSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return openIntent(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${activity.packageName}")
            )
        ) || openIntent(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", activity.packageName, null)
            )
        )
    }

    private fun openReleasePage(url: String): Boolean {
        val uri = Uri.parse(url)
        require(uri.scheme == "https" || uri.scheme == "http") { "Release URL must use HTTP(S)." }
        return openIntent(Intent(Intent.ACTION_VIEW, uri))
    }

    private fun openIntent(intent: Intent): Boolean {
        return try {
            intent.flags = intent.flags or Intent.FLAG_ACTIVITY_NEW_TASK
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}
