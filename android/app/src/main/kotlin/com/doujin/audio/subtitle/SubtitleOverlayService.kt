package com.doujin.audio.subtitle

import android.annotation.SuppressLint
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import kotlin.math.roundToInt

private const val INITIAL_WIDTH_DP = 160f

class SubtitleOverlayService : Service() {

    private lateinit var windowManager: WindowManager
    private var subtitleTextView: TextView? = null
    private lateinit var params: WindowManager.LayoutParams
    private val binder = LocalBinder()
    private var appliedStyle: OverlayStyle? = null

    private data class OverlayStyle(
        val fontSize: Float,
        val backgroundColor: String,
        val textColor: String,
        val fontFamily: String,
        val borderDepth: Float
    )

    private fun dp(value: Float): Float = value * resources.displayMetrics.density

    private fun dpInt(value: Float): Int = dp(value).roundToInt()

    inner class LocalBinder : Binder() {
        fun getService(): SubtitleOverlayService = this@SubtitleOverlayService
    }

    override fun onBind(intent: Intent?): IBinder {
        return binder
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureOverlayAttached()
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        removeOverlayView()
        stopSelf()
    }

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        createOverlay()
    }

    fun ensureOverlayAttached(): Boolean {
        if (subtitleTextView != null) return true
        return createOverlay()
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun createOverlay(): Boolean {
        if (subtitleTextView != null) return true
        if (!canDrawSubtitleOverlays(this)) {
            stopSelf()
            return false
        }

        val layoutType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        params = WindowManager.LayoutParams(
            dpInt(INITIAL_WIDTH_DP),
            WindowManager.LayoutParams.WRAP_CONTENT,
            layoutType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        )

        params.gravity = Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM
        params.y = 100 
        params.x = 0

        val textView = TextView(this).apply {
            minLines = 1
            fontFeatureSettings = "'tnum'"
            setTextColor(Color.WHITE)
            textSize = 16f
            setPadding(dpInt(20f), dpInt(10f), dpInt(20f), dpInt(10f))
            gravity = Gravity.CENTER
            includeFontPadding = false
            
            // Initial style
            val shape = GradientDrawable().apply {
                cornerRadius = dp(16f * 1.2f)
                setColor(Color.parseColor("#33000000"))
            }
            background = shape
        }

        textView.setOnTouchListener(object : View.OnTouchListener {
            private var initialX = 0
            private var initialY = 0
            private var initialTouchX = 0f
            private var initialTouchY = 0f

            override fun onTouch(v: View, event: MotionEvent): Boolean {
                when (event.action) {
                    MotionEvent.ACTION_DOWN -> {
                        initialX = params.x
                        initialY = params.y
                        initialTouchX = event.rawX
                        initialTouchY = event.rawY
                        return true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        val nextX = initialX + (event.rawX - initialTouchX).toInt()
                        val nextY = initialY - (event.rawY - initialTouchY).toInt()
                        if (nextX != params.x || nextY != params.y) {
                            params.x = nextX
                            params.y = nextY
                            if (subtitleTextView === textView) {
                                updateOverlayLayout(textView)
                            }
                        }
                        return true
                    }
                }
                return false
            }
        })

        return try {
            windowManager.addView(textView, params)
            subtitleTextView = textView
            appliedStyle = null
            true
        } catch (_: WindowManager.BadTokenException) {
            stopSelf()
            false
        } catch (_: SecurityException) {
            stopSelf()
            false
        } catch (_: IllegalStateException) {
            stopSelf()
            false
        }
    }

    fun updateSubtitle(text: String) {
        subtitleTextView?.post {
            val view = subtitleTextView ?: return@post
            if (view.text.toString() == text) return@post

            val wasEmpty = view.text.isEmpty()
            val isEmpty = text.isEmpty()
            view.text = text
            if (wasEmpty == isEmpty) return@post

            if (isEmpty) {
                // Keep the last rendered size while the window has no cue to measure.
                params.width = view.width.takeIf { it > 0 } ?: dpInt(INITIAL_WIDTH_DP)
                params.height = view.height.takeIf { it > 0 }
                    ?: WindowManager.LayoutParams.WRAP_CONTENT
            } else {
                params.width = WindowManager.LayoutParams.WRAP_CONTENT
                params.height = WindowManager.LayoutParams.WRAP_CONTENT
            }
            updateOverlayLayout(view)
        }
    }

    private fun updateOverlayLayout(view: View) {
        try {
            windowManager.updateViewLayout(view, params)
        } catch (_: IllegalArgumentException) {
            // Overlay view was already detached concurrently.
        }
    }

    fun setStyle(
        fontSize: Float,
        backgroundColor: String,
        textColor: String,
        fontFamily: String = "",
        borderDepth: Float = 0.5f
    ) {
        subtitleTextView?.post {
            val view = subtitleTextView ?: return@post
            val nextStyle = OverlayStyle(
                fontSize = fontSize,
                backgroundColor = backgroundColor,
                textColor = textColor,
                fontFamily = fontFamily,
                borderDepth = borderDepth
            )
            if (appliedStyle == nextStyle) return@post
            view.textSize = fontSize
            try {
                view.setTextColor(Color.parseColor(textColor))
                
                val shape = GradientDrawable().apply {
                    cornerRadius = dp(fontSize * 1.2f)
                    setColor(Color.parseColor(backgroundColor))
                    if (borderDepth > 0) {
                        setStroke(dpInt(borderDepth * 4).coerceAtLeast(1), Color.parseColor("#40FFFFFF"))
                    }
                }
                view.background = shape

                if (fontFamily.isNotEmpty()) {
                    val tf = android.graphics.Typeface.create(fontFamily, android.graphics.Typeface.NORMAL)
                    view.typeface = tf
                } else {
                    view.typeface = android.graphics.Typeface.DEFAULT
                }

                view.setShadowLayer(dp(4f), 0f, dp(2f), Color.parseColor("#80000000"))
                appliedStyle = nextStyle
            } catch (e: Exception) {
                // Ignore invalid colors
            }
        }
    }

    private fun removeOverlayView() {
        appliedStyle = null
        val view = subtitleTextView
        subtitleTextView = null
        if (view != null) {
            try {
                windowManager.removeView(view)
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        removeOverlayView()
    }
}
