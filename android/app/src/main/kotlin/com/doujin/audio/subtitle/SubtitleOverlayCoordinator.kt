package com.doujin.audio.subtitle

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.Settings

internal fun canDrawSubtitleOverlays(context: Context): Boolean =
    Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(context)

internal data class SubtitleOverlayStyle(
    val fontSize: Float,
    val backgroundColor: String,
    val textColor: String,
    val fontFamily: String = "",
    val borderDepth: Float = 0.5f
)

internal class SubtitleOverlayCoordinator(
    context: Context
) {
    private val appContext: Context = try {
        context.applicationContext ?: context
    } catch (_: NullPointerException) {
        context
    }
    private var service: SubtitleOverlayService? = null
    private var connection: ServiceConnection? = null
    private var pendingText: String? = null
    private var pendingStyle: SubtitleOverlayStyle? = null

    private fun newConnection() = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            if (connection !== this) return
            val boundService = (binder as? SubtitleOverlayService.LocalBinder)?.getService()
            if (boundService == null || !boundService.ensureOverlayAttached()) {
                dispose()
                stopOverlayService()
                return
            }
            service = boundService
            applyPendingState()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            if (connection !== this) return
            connection = null
            service = null
            try {
                appContext.unbindService(this)
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    fun canDrawOverlays(): Boolean = canDrawSubtitleOverlays(appContext)

    fun openOverlaySettings(): Boolean {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${appContext.packageName}")
        ).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        return try {
            appContext.startActivity(intent)
            true
        } catch (error: ActivityNotFoundException) {
            throw IllegalStateException("Unable to open overlay permission settings.", error)
        } catch (error: SecurityException) {
            throw IllegalStateException("Unable to open overlay permission settings.", error)
        }
    }

    fun start(): Boolean {
        if (!canDrawOverlays()) {
            stop()
            return false
        }
        val existingService = service
        if (existingService != null) {
            if (!existingService.ensureOverlayAttached()) {
                stop()
                return false
            }
            applyPendingState()
            return true
        }
        if (connection != null) {
            return true
        }
        val intent = Intent(appContext, SubtitleOverlayService::class.java)
        val nextConnection = newConnection()
        connection = nextConnection
        try {
            appContext.startService(intent)
            if (appContext.bindService(intent, nextConnection, Context.BIND_AUTO_CREATE)) return true
        } catch (error: IllegalStateException) {
            connection = null
            stopOverlayService()
            throw IllegalStateException("Unable to bind subtitle overlay service.", error)
        } catch (error: SecurityException) {
            connection = null
            stopOverlayService()
            throw IllegalStateException("Unable to bind subtitle overlay service.", error)
        }
        connection = null
        stopOverlayService()
        return false
    }

    fun stop() {
        val currentService = service
        dispose()
        pendingText = null
        currentService?.stopSelf()
        stopOverlayService()
    }

    fun updateSubtitle(text: String) {
        pendingText = text
        service?.updateSubtitle(text)
    }

    fun updateStyle(style: SubtitleOverlayStyle) {
        pendingStyle = style
        service?.setStyle(
            style.fontSize,
            style.backgroundColor,
            style.textColor,
            style.fontFamily,
            style.borderDepth
        )
    }

    fun dispose() {
        val previous = connection
        connection = null
        service = null
        if (previous != null) {
            try {
                appContext.unbindService(previous)
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    private fun stopOverlayService() {
        runCatching {
            appContext.stopService(Intent(appContext, SubtitleOverlayService::class.java))
        }
    }

    private fun applyPendingState() {
        val currentService = service ?: return
        pendingStyle?.let { style ->
            currentService.setStyle(
                style.fontSize, 
                style.backgroundColor, 
                style.textColor,
                style.fontFamily,
                style.borderDepth
            )
        }
        pendingText?.let(currentService::updateSubtitle)
    }
}
