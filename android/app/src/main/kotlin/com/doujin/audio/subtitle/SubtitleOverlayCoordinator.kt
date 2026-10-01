package com.doujin.audio.subtitle

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.Uri
import android.os.IBinder
import android.provider.Settings

internal data class SubtitleOverlayStyle(
    val fontSize: Float,
    val backgroundColor: String,
    val textColor: String,
    val fontFamily: String = "",
    val borderDepth: Float = 0.5f
)

internal class SubtitleOverlayCoordinator(
    private val context: Context
) {
    private var service: SubtitleOverlayService? = null
    private var connection: ServiceConnection? = null
    private var pendingText: String? = null
    private var pendingStyle: SubtitleOverlayStyle? = null

    private fun newConnection() = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            if (connection !== this) return
            val localBinder = binder as SubtitleOverlayService.LocalBinder
            service = localBinder.getService()
            applyPendingState()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            if (connection !== this) return
            service = null
        }
    }

    fun canDrawOverlays(): Boolean {
        return Settings.canDrawOverlays(context)
    }

    fun openOverlaySettings(): Boolean {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${context.packageName}")
        ).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        context.startActivity(intent)
        return true
    }

    fun start(): Boolean {
        if (connection != null) {
            applyPendingState()
            return true
        }
        val intent = Intent(context, SubtitleOverlayService::class.java)
        context.startService(intent)
        val nextConnection = newConnection()
        connection = nextConnection
        try {
            if (context.bindService(intent, nextConnection, Context.BIND_AUTO_CREATE)) return true
        } catch (error: Exception) {
            connection = null
            context.stopService(intent)
            throw error
        }
        connection = null
        context.stopService(intent)
        return false
    }

    fun stop() {
        dispose()
        pendingText = null
        context.stopService(Intent(context, SubtitleOverlayService::class.java))
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
        if (previous != null) context.unbindService(previous)
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
