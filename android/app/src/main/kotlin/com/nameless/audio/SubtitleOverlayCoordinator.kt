package com.nameless.audio

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.Uri
import android.os.Build
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
    private var isBound = false
    private var pendingText: String? = null
    private var pendingStyle: SubtitleOverlayStyle? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val localBinder = binder as SubtitleOverlayService.LocalBinder
            service = localBinder.getService()
            isBound = true
            applyPendingState()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            isBound = false
        }
    }

    fun canDrawOverlays(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(context)
        } else {
            true
        }
    }

    fun openOverlaySettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${context.packageName}")
        ).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        context.startActivity(intent)
        return true
    }

    fun start() {
        if (!isBound) {
            val intent = Intent(context, SubtitleOverlayService::class.java)
            context.startService(intent)
            context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        } else {
            applyPendingState()
        }
    }

    fun stop() {
        if (isBound) {
            context.unbindService(connection)
            isBound = false
            service = null
        }
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
        if (isBound) {
            context.unbindService(connection)
            isBound = false
            service = null
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
