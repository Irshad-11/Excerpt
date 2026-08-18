package com.example.excerpt

import android.inputmethodservice.InputMethodService
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.LinearLayout
import android.widget.TextView
import android.util.Log

class ExcerptInputMethodService : InputMethodService() {

    companion object {
        private const val TAG = "ExcerptIME"

        private const val PREVIEW_WORD_LIMIT = 6

        /*
         * After the IME becomes active, we do a short burst of
         * clipboard checks.
         *
         * This is deliberately NOT an infinite polling loop.
         */
        private const val BURST_INTERVAL = 100L
        private const val BURST_COUNT = 20
    }

    private lateinit var clipboardManager: ClipboardManager
    private lateinit var handler: Handler
    private lateinit var prefs: android.content.SharedPreferences

    private var windowManager: WindowManager? = null

    private var overlayView: View? = null

    private var destroyed = false

    private var lastObservedText: String? = null

    private var burstRemaining = 0

    private val clipboardListener =
        ClipboardManager.OnPrimaryClipChangedListener {

            Log.d(
                TAG,
                "Clipboard callback received"
            )

            /*
             * The callback itself is the fastest route.
             */
            checkClipboard(
                "listener"
            )
        }

    private val burstRunnable =
        object : Runnable {

            override fun run() {

                if (destroyed) {
                    return
                }

                if (burstRemaining <= 0) {
                    return
                }

                burstRemaining--

                checkClipboard(
                    "ime-burst"
                )

                if (burstRemaining > 0) {

                    handler.postDelayed(
                        this,
                        BURST_INTERVAL
                    )
                }
            }
        }

    override fun onCreate() {

        super.onCreate()

        Log.d(
            TAG,
            "Excerpt IME created"
        )

        handler =
            Handler(
                Looper.getMainLooper()
            )

        prefs =
            getSharedPreferences(
                Prefs.NAME,
                Context.MODE_PRIVATE
            )

        clipboardManager =
            getSystemService(
                Context.CLIPBOARD_SERVICE
            ) as ClipboardManager

        windowManager =
            getSystemService(
                Context.WINDOW_SERVICE
            ) as WindowManager

        clipboardManager
            .addPrimaryClipChangedListener(
                clipboardListener
            )

        /*
         * We do NOT automatically start polling forever.
         */
        Log.d(
            TAG,
            "Clipboard listener registered"
        )
    }

    override fun onStartInput(
        attribute: android.view.inputmethod.EditorInfo?,
        restarting: Boolean
    ) {

        super.onStartInput(
            attribute,
            restarting
        )

        Log.d(
            TAG,
            "onStartInput"
        )

        startShortClipboardBurst()
    }

    override fun onStartInputView(
        info: android.view.inputmethod.EditorInfo?,
        restarting: Boolean
    ) {

        super.onStartInputView(
            info,
            restarting
        )

        Log.d(
            TAG,
            "onStartInputView"
        )

        startShortClipboardBurst()
    }

    override fun onFinishInput() {

        Log.d(
            TAG,
            "onFinishInput"
        )

        stopClipboardBurst()

        super.onFinishInput()
    }

    private fun startShortClipboardBurst() {

        if (!::handler.isInitialized) {
            return
        }

        stopClipboardBurst()

        burstRemaining =
            BURST_COUNT

        handler.post(
            burstRunnable
        )

        Log.d(
            TAG,
            "Short clipboard detection burst started"
        )
    }

    private fun stopClipboardBurst() {

        if (!::handler.isInitialized) {
            return
        }

        burstRemaining = 0

        handler.removeCallbacks(
            burstRunnable
        )
    }

    private fun checkClipboard(
        source: String
    ) {

        if (destroyed) {
            return
        }

        if (!::clipboardManager.isInitialized) {
            return
        }

        if (!::prefs.isInitialized) {
            return
        }

        val enabled =
            prefs.getBoolean(
                Prefs.KEY_ENABLED,
                false
            )

        if (!enabled) {

            Log.d(
                TAG,
                "Clipboard monitoring disabled"
            )

            return
        }

        if (!canDrawOverlay()) {

            Log.d(
                TAG,
                "Overlay permission missing"
            )

            return
        }

        try {

            val clip =
                clipboardManager.primaryClip
                    ?: return

            if (clip.itemCount <= 0) {
                return
            }

            val description =
                clip.description

            if (
                description != null &&
                !description.hasMimeType(
                    ClipDescription.MIMETYPE_TEXT_PLAIN
                ) &&
                !description.hasMimeType(
                    ClipDescription.MIMETYPE_TEXT_HTML
                )
            ) {

                return
            }

            val text =
                clip
                    .getItemAt(0)
                    .coerceToText(this)
                    ?.toString()
                    ?.trim()

            if (text.isNullOrEmpty()) {
                return
            }

            if (
                text == lastObservedText
            ) {

                return
            }

            val storedLast =
                prefs.getString(
                    Prefs.KEY_LAST_CLIPBOARD,
                    null
                )

            if (text == storedLast) {

                lastObservedText =
                    text

                return
            }

            lastObservedText =
                text

            prefs.edit()
                .putString(
                    Prefs.KEY_LAST_CLIPBOARD,
                    text
                )
                .apply()

            Log.d(
                TAG,
                "NEW CLIPBOARD DETECTED [$source]"
            )

            showOverlay(
                text
            )

        } catch (e: SecurityException) {

            Log.e(
                TAG,
                "Clipboard access denied",
                e
            )

        } catch (e: Exception) {

            Log.e(
                TAG,
                "Clipboard check failed",
                e
            )
        }
    }

    private fun canDrawOverlay(): Boolean {

        return if (
            Build.VERSION.SDK_INT >=
            Build.VERSION_CODES.M
        ) {

            Settings.canDrawOverlays(
                this
            )

        } else {

            true
        }
    }

    private fun showOverlay(
        text: String
    ) {

        removeOverlay()

        val root =
            LinearLayout(this)

        root.orientation =
            LinearLayout.HORIZONTAL

        root.gravity =
            Gravity.CENTER_VERTICAL

        root.setPadding(
            dp(14),
            dp(8),
            dp(8),
            dp(8)
        )

        val background =
            GradientDrawable()

        background.setColor(
            Color.rgb(
                32,
                32,
                36
            )
        )

        background.cornerRadius =
            dp(24).toFloat()

        root.background =
            background

        val preview =
            TextView(this)

        preview.text =
            createPreview(text)

        preview.setTextColor(
            Color.WHITE
        )

        preview.textSize =
            13f

        preview.typeface =
            Typeface.DEFAULT

        preview.maxLines =
            1

        preview.ellipsize =
            TextUtils.TruncateAt.END

        preview.gravity =
            Gravity.CENTER_VERTICAL

        val previewParams =
            LinearLayout.LayoutParams(
                0,
                dp(40),
                1f
            )

        root.addView(
            preview,
            previewParams
        )

        val save =
            createButton(
                "Save"
            )

        save.setOnClickListener {

            Log.d(
                TAG,
                "Save clicked"
            )

            savePendingText(
                text
            )

            removeOverlay()

            openExcerpt()
        }

        root.addView(
            save,
            LinearLayout.LayoutParams(
                dp(56),
                dp(40)
            )
        )

        val dismiss =
            createButton(
                "×"
            )

        dismiss.textSize =
            22f

        dismiss.setOnClickListener {

            Log.d(
                TAG,
                "Overlay dismissed"
            )

            removeOverlay()
        }

        root.addView(
            dismiss,
            LinearLayout.LayoutParams(
                dp(40),
                dp(40)
            )
        )

        val type =
            if (
                Build.VERSION.SDK_INT >=
                Build.VERSION_CODES.O
            ) {

                WindowManager.LayoutParams
                    .TYPE_APPLICATION_OVERLAY

            } else {

                @Suppress("DEPRECATION")
                WindowManager.LayoutParams
                    .TYPE_PHONE
            }

        val params =
            WindowManager.LayoutParams(
                dp(320),
                dp(56),
                type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT
            )

        params.gravity =
            Gravity.TOP or
                Gravity.CENTER_HORIZONTAL

        params.y =
            dp(54)

        try {

            windowManager?.addView(
                root,
                params
            )

            overlayView =
                root

            Log.d(
                TAG,
                "Overlay successfully shown"
            )

        } catch (e: Exception) {

            Log.e(
                TAG,
                "Overlay addView failed",
                e
            )

            overlayView =
                null
        }
    }

    private fun createButton(
        text: String
    ): TextView {

        val button =
            TextView(this)

        button.text =
            text

        button.gravity =
            Gravity.CENTER

        button.setTextColor(
            Color.WHITE
        )

        button.textSize =
            13f

        button.isClickable =
            true

        button.isFocusable =
            true

        return button
    }

    private fun savePendingText(
        text: String
    ) {

        prefs.edit()
            .putString(
                Prefs.KEY_PENDING_TEXT,
                text
            )
            .apply()
    }

    private fun openExcerpt() {

        val intent =
            packageManager.getLaunchIntentForPackage(
                packageName
            )

        if (intent == null) {

            Log.e(
                TAG,
                "Could not find Excerpt launcher"
            )

            return
        }

        intent.action =
            Prefs.ACTION_SAVE_CLIP

        intent.putExtra(
            Prefs.KEY_PENDING_TEXT,
            prefs.getString(
                Prefs.KEY_PENDING_TEXT,
                ""
            )
        )

        intent.addFlags(
            android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP or
                android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP
        )

        try {

            startActivity(
                intent
            )

        } catch (e: Exception) {

            Log.e(
                TAG,
                "Could not open Excerpt",
                e
            )
        }
    }

    private fun createPreview(
        text: String
    ): String {

        val normalized =
            text
                .replace(
                    Regex("""\s+"""),
                    " "
                )
                .trim()

        val words =
            normalized
                .split(" ")
                .filter {
                    it.isNotBlank()
                }

        if (
            words.size <=
            PREVIEW_WORD_LIMIT
        ) {

            return normalized
        }

        return words
            .take(
                PREVIEW_WORD_LIMIT
            )
            .joinToString(" ") + "…"
    }

    private fun removeOverlay() {

        val view =
            overlayView
                ?: return

        try {

            windowManager?.removeView(
                view
            )

        } catch (e: Exception) {

            Log.d(
                TAG,
                "Overlay already removed"
            )
        }

        overlayView =
            null
    }

    private fun dp(
        value: Int
    ): Int {

        return (
            value *
                resources.displayMetrics.density
        ).toInt()
    }

    override fun onDestroy() {

        destroyed =
            true

        stopClipboardBurst()

        if (
            ::clipboardManager.isInitialized
        ) {

            clipboardManager
                .removePrimaryClipChangedListener(
                    clipboardListener
                )
        }

        removeOverlay()

        Log.d(
            TAG,
            "Excerpt IME destroyed"
        )

        super.onDestroy()
    }
}