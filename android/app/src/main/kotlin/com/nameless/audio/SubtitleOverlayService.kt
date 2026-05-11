package com.nameless.audio

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

class SubtitleOverlayService : Service() {

    private lateinit var windowManager: WindowManager
    private var subtitleTextView: TextView? = null
    private lateinit var params: WindowManager.LayoutParams
    private val binder = LocalBinder()

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
            textSize = 18f
            setPadding(40, 20, 40, 20)
            gravity = Gravity.CENTER
            
            // Initial style
            val shape = GradientDrawable().apply {
                cornerRadius = 24f
                setColor(Color.parseColor("#90000000"))
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

    fun setStyle(fontSize: Float, backgroundColor: String, textColor: String) {
        subtitleTextView?.post {
            subtitleTextView?.textSize = fontSize
            try {
                subtitleTextView?.setTextColor(Color.parseColor(textColor))
                
                val shape = GradientDrawable().apply {
                    cornerRadius = fontSize * 1.2f // Dynamic corner radius
                    setColor(Color.parseColor(backgroundColor))
                }
                subtitleTextView?.background = shape
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
