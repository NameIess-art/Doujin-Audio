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

class SubtitleOverlayService : Service() {

    private lateinit var windowManager: WindowManager
    private var subtitleTextView: TextView? = null
    private lateinit var params: WindowManager.LayoutParams
    private val binder = LocalBinder()

    private fun dp(value: Float): Float = value * resources.displayMetrics.density

    private fun dpInt(value: Float): Int = dp(value).roundToInt()

    inner class LocalBinder : Binder() {
        fun getService(): SubtitleOverlayService = this@SubtitleOverlayService
    }

    override fun onBind(intent: Intent?): IBinder {
        return binder
    }

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        createOverlay()
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun createOverlay() {
        val layoutType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            layoutType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        )

        params.gravity = Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM
        params.y = 100 
        params.x = 0

        val textView = TextView(this).apply {
            text = ""
            visibility = View.GONE
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
        
        subtitleTextView = textView

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
                        params.x = initialX + (event.rawX - initialTouchX).toInt()
                        params.y = initialY - (event.rawY - initialTouchY).toInt()
                        windowManager.updateViewLayout(textView, params)
                        return true
                    }
                }
                return false
            }
        })

        windowManager.addView(textView, params)
    }

    fun updateSubtitle(text: String) {
        subtitleTextView?.post {
            val view = subtitleTextView ?: return@post
            view.text = text
            val nextVisibility = if (text.isEmpty()) View.GONE else View.VISIBLE
            if (view.visibility != nextVisibility) {
                view.visibility = nextVisibility
                try {
                    windowManager.updateViewLayout(view, params)
                } catch (_: Exception) {}
            }
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
            subtitleTextView?.textSize = fontSize
            try {
                subtitleTextView?.setTextColor(Color.parseColor(textColor))
                
                val shape = GradientDrawable().apply {
                    cornerRadius = dp(fontSize * 1.2f)
                    setColor(Color.parseColor(backgroundColor))
                    if (borderDepth > 0) {
                        setStroke(dpInt(borderDepth * 4).coerceAtLeast(1), Color.parseColor("#40FFFFFF"))
                    }
                }
                subtitleTextView?.background = shape

                if (fontFamily.isNotEmpty()) {
                    val tf = android.graphics.Typeface.create(fontFamily, android.graphics.Typeface.NORMAL)
                    subtitleTextView?.typeface = tf
                } else {
                    subtitleTextView?.typeface = android.graphics.Typeface.DEFAULT
                }

                subtitleTextView?.setShadowLayer(dp(4f), 0f, dp(2f), Color.parseColor("#80000000"))
            } catch (e: Exception) {
                // Ignore invalid colors
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        subtitleTextView?.let {
            windowManager.removeView(it)
        }
    }
}
