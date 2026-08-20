package com.example.excerpt


import android.widget.ImageView

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.hardware.display.DisplayManager
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.InputType
import android.text.TextUtils
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.app.NotificationCompat
import java.text.SimpleDateFormat
import java.util.Locale

class ExcerptInputMethodService : InputMethodService() {

    companion object {

        private const val TAG = "ExcerptIME"

        private const val PREVIEW_WORD_LIMIT = 6

        private const val CLIPBOARD_CHECK_INTERVAL = 500L
        private const val ACTIVE_MONITOR_INTERVAL = 1000L

        private const val NOTIFICATION_CHANNEL_ID = "excerpt_keyboard_status"
        private const val NOTIFICATION_ID = 1001

        // Auto-dismiss the compact bar if the user ignores it.
        private const val AUTO_DISMISS_DELAY = 8000L

        // How long the success state stays visible before closing.
        private const val SUCCESS_HOLD_DELAY = 1800L

        private const val ANIM_SHORT = 160L
        private const val ANIM_MED = 220L
    }

    // ============================================================
    // Core state (unchanged behaviour, still working as before)
    // ============================================================

    private lateinit var clipboardManager: ClipboardManager
    private lateinit var handler: Handler
    private lateinit var prefs: android.content.SharedPreferences
    private lateinit var databaseHelper: ExcerptDatabaseHelper

    // IMPORTANT: this WindowManager is obtained from a dedicated
    // TYPE_APPLICATION_OVERLAY window context (see
    // createOverlayWindowManager()), NOT from the IME service's own
    // context. On Android 13+, a Context's WindowManager must be used
    // only with the window type that Context was created for — the
    // IME service's own context is bound to TYPE_INPUT_METHOD, so
    // using it to add a TYPE_APPLICATION_OVERLAY window throws /
    // behaves unreliably (this was the cause of the overlay randomly
    // failing, then not showing at all).
    private var windowManager: WindowManager? = null
    private var overlayRoot: View? = null

    private var destroyed = false
    private var inputActive = false

    private var lastObservedText: String? = null
    private var lastShownText: String? = null

    private var capturedText: String = ""

    private val autoDismissRunnable = Runnable {
        animateDismiss()
    }

    private val clipboardListener =
        ClipboardManager.OnPrimaryClipChangedListener {
            handler.post {
                if (!destroyed) {
                    checkClipboard("listener")
                }
            }
        }

    private val clipboardMonitor = object : Runnable {
        override fun run() {
            if (destroyed) return
            if (!inputActive) return

            checkClipboard("periodic")

            handler.postDelayed(this, ACTIVE_MONITOR_INTERVAL)
        }
    }

    override fun onCreate() {
        super.onCreate()

        handler = Handler(Looper.getMainLooper())
        prefs = getSharedPreferences(Prefs.NAME, Context.MODE_PRIVATE)
        databaseHelper = ExcerptDatabaseHelper(this)
        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        windowManager = createOverlayWindowManager()

        clipboardManager.addPrimaryClipChangedListener(clipboardListener)

        createNotificationChannel()
        updateKeyboardNotification()
    }

    /**
     * Builds a WindowManager tied to a context created specifically
     * for TYPE_APPLICATION_OVERLAY windows (Android R+ API), so its
     * window type always matches the LayoutParams type used in
     * showOverlay(). Falls back to the plain service WindowManager on
     * older Android versions, where this strict matching isn't
     * enforced.
     */
    private fun createOverlayWindowManager(): WindowManager {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val displayManager = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
                val display = displayManager.getDisplay(Display.DEFAULT_DISPLAY)
                val displayContext = applicationContext.createDisplayContext(display)
                val overlayContext = displayContext.createWindowContext(
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    null
                )
                return overlayContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            } catch (e: Exception) {
                Log.e(TAG, "Could not create dedicated overlay window context, falling back", e)
            }
        }

        return getSystemService(Context.WINDOW_SERVICE) as WindowManager
    }

    // ============================================================
    // Input method lifecycle
    // ============================================================

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)

        inputActive = true
        updateKeyboardNotification()
        restartClipboardMonitoring("onStartInput")
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)

        inputActive = true
        updateKeyboardNotification()
        restartClipboardMonitoring("onStartInputView")
    }

    override fun onFinishInput() {
        inputActive = false
        stopClipboardMonitoring()
        super.onFinishInput()
    }

    override fun onDestroy() {
        destroyed = true
        inputActive = false

        stopClipboardMonitoring()
        removeKeyboardNotification()

        if (::databaseHelper.isInitialized) {
            try {
                databaseHelper.close()
            } catch (e: Exception) {
                Log.e(TAG, "Could not close Excerpt database", e)
            }
        }

        if (::clipboardManager.isInitialized) {
            try {
                clipboardManager.removePrimaryClipChangedListener(clipboardListener)
            } catch (e: Exception) {
                Log.e(TAG, "Could not remove clipboard listener", e)
            }
        }

        removeOverlayImmediate()

        super.onDestroy()
    }

    // ============================================================
    // Clipboard monitoring (unchanged logic)
    // ============================================================

    private fun restartClipboardMonitoring(source: String) {
        if (destroyed || !::handler.isInitialized) return

        stopClipboardMonitoring()

        handler.post {
            if (!destroyed && inputActive) {
                checkClipboard("immediate-$source")
            }
        }

        handler.postDelayed(clipboardMonitor, CLIPBOARD_CHECK_INTERVAL)
    }

    private fun stopClipboardMonitoring() {
        if (!::handler.isInitialized) return
        handler.removeCallbacks(clipboardMonitor)
    }

    private fun checkClipboard(source: String) {
        if (destroyed) return
        if (!::clipboardManager.isInitialized || !::prefs.isInitialized) return

        if (!isExcerptDefaultIme()) return

        val enabled = prefs.getBoolean(Prefs.KEY_ENABLED, false)
        if (!enabled) return

        if (!canDrawOverlay()) return

        try {
            val clip = clipboardManager.primaryClip ?: return
            if (clip.itemCount <= 0) return

            val description = clip.description

            if (description != null &&
                !description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN) &&
                !description.hasMimeType(ClipDescription.MIMETYPE_TEXT_HTML)
            ) {
                return
            }

            val text = clip.getItemAt(0).coerceToText(this)?.toString()?.trim()
            if (text.isNullOrEmpty()) return

            if (text == lastObservedText) return

            val storedLast = prefs.getString(Prefs.KEY_LAST_CLIPBOARD, null)
            if (text == storedLast) {
                lastObservedText = text
                return
            }

            if (text == lastShownText && overlayRoot != null) return

            lastObservedText = text

            prefs.edit().putString(Prefs.KEY_LAST_CLIPBOARD, text).apply()

            showOverlay(text)
        } catch (e: SecurityException) {
            Log.e(TAG, "Clipboard access denied", e)
        } catch (e: Exception) {
            Log.e(TAG, "Clipboard check failed", e)
        }
    }

    private fun isExcerptDefaultIme(): Boolean {
        return try {
            val defaultIme = Settings.Secure.getString(
                contentResolver,
                Settings.Secure.DEFAULT_INPUT_METHOD
            )
            defaultIme?.startsWith(packageName) == true
        } catch (e: Exception) {
            false
        }
    }

    private fun canDrawOverlay(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(this)
        } else {
            true
        }
    }

    // ============================================================
    // Notification (unchanged)
    // ============================================================

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Excerpt Keyboard",
            NotificationManager.IMPORTANCE_LOW
        )

        channel.description = "Shows when Excerpt is the active keyboard"
        channel.setSound(null, null)
        channel.enableVibration(false)

        manager.createNotificationChannel(channel)
    }

    private fun updateKeyboardNotification() {
        if (destroyed) return

        if (!isExcerptDefaultIme()) {
            removeKeyboardNotification()
            return
        }

        showKeyboardNotification()
    }

    private fun showKeyboardNotification() {
        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                return
            }
        }

        postKeyboardNotification(notificationManager)
    }

    private fun postKeyboardNotification(notificationManager: NotificationManager) {
        val changeKeyboardIntent = Intent(this, ExcerptInputMethodService::class.java).apply {
            action = Prefs.ACTION_CHANGE_KEYBOARD
        }

        val pendingIntent = PendingIntent.getService(
            this, 2001, changeKeyboardIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val contentIntent = PendingIntent.getService(
            this, 2002,
            Intent(this, ExcerptInputMethodService::class.java).apply {
                action = Prefs.ACTION_CHANGE_KEYBOARD
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_manage)
            .setContentTitle("Excerpt Keyboard")
            .setContentText("Excerpt is currently your default keyboard")
            .setSubText("Tap to change keyboard")
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(android.R.drawable.ic_menu_set_as, "Change keyboard", pendingIntent)
            .build()

        notificationManager.notify(NOTIFICATION_ID, notification)
    }

    private fun removeKeyboardNotification() {
        try {
            val notificationManager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.cancel(NOTIFICATION_ID)
        } catch (e: Exception) {
            Log.e(TAG, "Could not remove keyboard notification", e)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == Prefs.ACTION_CHANGE_KEYBOARD) {
            openInputMethodPicker()

            handler.postDelayed({
                if (!destroyed) updateKeyboardNotification()
            }, 1000L)
        }

        return super.onStartCommand(intent, flags, startId)
    }

    private fun openInputMethodPicker() {
        try {
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.showInputMethodPicker()
        } catch (e: Exception) {
            Log.e(TAG, "Could not open input method picker", e)
        }
    }

    // ============================================================
    // Data layer — uses the SAME SQLite database Flutter uses:
    // filesDir/excerpt.db
    //
    // The schema is mirrored by ExcerptDatabaseHelper. This means
    // folders/messages created here are immediately visible to the
    // Flutter app, and vice versa.
    // ============================================================

    private fun sanitizeFolderName(name: String): String {
        return name.trim().replace(Regex("""[\\/:*?"<>|]"""), "_")
    }

    private fun listFolderNames(): List<String> {
        val db = try {
            databaseHelper.readableDatabase
        } catch (e: Exception) {
            Log.e(TAG, "Could not open Excerpt database", e)
            return emptyList()
        }

        val names = mutableListOf<String>()

        try {
            db.query(
                "folders",
                arrayOf("name"),
                null,
                null,
                null,
                null,
                "name COLLATE NOCASE ASC"
            ).use { cursor ->
                val nameIndex = cursor.getColumnIndexOrThrow("name")
                while (cursor.moveToNext()) {
                    names.add(cursor.getString(nameIndex))
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Could not list folders from SQLite", e)
        } finally {
            // Do not close the database here. SQLiteOpenHelper manages the
            // connection lifecycle for this service instance.
        }

        val lastUsed = prefs.getString(Prefs.KEY_LAST_FOLDER, null)

        if (lastUsed != null && names.remove(lastUsed)) {
            names.add(0, lastUsed)
        }

        return names
    }

    private fun ensureFolder(name: String): Long {
        val db = databaseHelper.writableDatabase

        // Same semantics as Flutter FolderStore._folderId():
        // return an existing folder ID, otherwise create it.
        db.query(
            "folders",
            arrayOf("id"),
            "name = ?",
            arrayOf(name),
            null,
            null,
            null,
            "1"
        ).use { cursor ->
            if (cursor.moveToFirst()) {
                return cursor.getLong(cursor.getColumnIndexOrThrow("id"))
            }
        }

        val values = android.content.ContentValues().apply {
            put("name", name)
            put("created_at", isoTimestamp())
        }

        val insertedId = db.insertWithOnConflict(
            "folders",
            null,
            values,
            android.database.sqlite.SQLiteDatabase.CONFLICT_IGNORE
        )

        if (insertedId != -1L) {
            return insertedId
        }

        // Another writer (Flutter or another service instance) may have
        // created the same folder between our SELECT and INSERT.
        db.query(
            "folders",
            arrayOf("id"),
            "name = ?",
            arrayOf(name),
            null,
            null,
            null,
            "1"
        ).use { cursor ->
            if (cursor.moveToFirst()) {
                return cursor.getLong(cursor.getColumnIndexOrThrow("id"))
            }
        }

        throw IllegalStateException("Could not create or find folder: $name")
    }

    private fun isoTimestamp(): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US)
        return sdf.format(java.util.Date())
    }

    private fun appendMessage(folder: String, text: String, type: String) {
        val db = databaseHelper.writableDatabase
        val folderId = ensureFolder(folder)

        val values = android.content.ContentValues().apply {
            put("id", java.util.UUID.randomUUID().toString())
            put("folder_id", folderId)
            put("text", text)
            put("type", type)
            // The overlay only ever captures clipboard text on behalf
            // of the user — it always came from "outside", so it's
            // always source='system', never the SQLite column default
            // of 'user' (which is for composer-typed messages).
            put("source", "system")
            put("timestamp", isoTimestamp())
            put("important", 0)
            put("edited", 0)
            putNull("extra")
            putNull("image_path")
        }

        val inserted = db.insert("messages", null, values)

        if (inserted == -1L) {
            throw IllegalStateException("Could not save message to SQLite")
        }

        prefs.edit().putString(Prefs.KEY_LAST_FOLDER, folder).apply()
    }

    // ============================================================
    // Overlay — compact bar -> inline folder picker -> success
    // ============================================================

    private var cardContainer: LinearLayout? = null
    private var currentContent: View? = null
    private var windowParams: WindowManager.LayoutParams? = null
    private var folderEditText: EditText? = null

    private fun showOverlay(text: String) {
        removeOverlayImmediate()

        capturedText = text
        lastShownText = text

        val outer = FrameLayout(this)
        outer.clipChildren = false
        outer.clipToPadding = false

        val card = LinearLayout(this)
        card.orientation = LinearLayout.VERTICAL
        card.background = roundedBackground(Color.rgb(28, 28, 32), 22f)
        card.elevation = dp(10).toFloat()
        card.clipToOutline = false

        val cardParams = FrameLayout.LayoutParams(dp(320), ViewGroup.LayoutParams.WRAP_CONTENT)
        outer.addView(card, cardParams)

        cardContainer = card

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val params = WindowManager.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        )

        params.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        params.y = dp(54)

        windowParams = params

        try {
            windowManager?.addView(outer, params)
            overlayRoot = outer
        } catch (e: Exception) {
            Log.e(TAG, "Overlay addView failed", e)
            overlayRoot = null
            return
        }

        showCompactContent(text)

        // Entrance animation.
        outer.alpha = 0f
        outer.translationY = dp(-16).toFloat()
        outer.animate()
            .alpha(1f)
            .translationY(0f)
            .setDuration(ANIM_MED)
            .setInterpolator(DecelerateInterpolator())
            .start()

        scheduleAutoDismiss()
    }

    private fun scheduleAutoDismiss() {
        handler.removeCallbacks(autoDismissRunnable)
        handler.postDelayed(autoDismissRunnable, AUTO_DISMISS_DELAY)
    }

    private fun cancelAutoDismiss() {
        handler.removeCallbacks(autoDismissRunnable)
    }

    /** Crossfades the content inside the card without changing the window. */
    private fun swapContent(newContent: View) {
        val card = cardContainer ?: return
        val old = currentContent

        newContent.alpha = 0f
        card.addView(
            newContent,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        newContent.animate()
            .alpha(1f)
            .setDuration(ANIM_SHORT)
            .setStartDelay(if (old != null) ANIM_SHORT else 0)
            .start()

        if (old != null) {
            old.animate()
                .alpha(0f)
                .setDuration(ANIM_SHORT)
                .withEndAction {
                    card.removeView(old)
                    windowManager?.updateViewLayout(overlayRoot, windowParams)
                }
                .start()
        }

        currentContent = newContent

        // Let the window resize to the new content height smoothly.
        card.post {
            windowManager?.updateViewLayout(overlayRoot, windowParams)
        }
    }

    // ---- Compact bar (preview + Save + dismiss) ----

    private fun showCompactContent(text: String) {
        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL
        row.gravity = Gravity.CENTER_VERTICAL
        row.setPadding(dp(14), dp(10), dp(8), dp(10))

        val icon = TextView(this)
        icon.text = "\u2398" // clipboard-ish glyph, avoids needing an asset
        icon.setTextColor(Color.rgb(120, 220, 200))
        icon.textSize = 15f
        row.addView(
            icon,
            LinearLayout.LayoutParams(dp(20), ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                marginEnd = dp(8)
            }
        )

        val preview = TextView(this)
        preview.text = createPreview(text)
        preview.setTextColor(Color.WHITE)
        preview.textSize = 13f
        preview.typeface = Typeface.DEFAULT
        preview.maxLines = 1
        preview.ellipsize = TextUtils.TruncateAt.END
        preview.gravity = Gravity.CENTER_VERTICAL

        row.addView(
            preview,
            LinearLayout.LayoutParams(0, dp(40), 1f)
        )

        val save = pillButton("Save", Color.rgb(60, 190, 165), Color.BLACK)
        save.setOnClickListener {
            cancelAutoDismiss()
            showFolderListContent()
        }
        row.addView(
            save,
            LinearLayout.LayoutParams(dp(64), dp(36)).apply { marginStart = dp(6) }
        )

        val dismiss = createIconButton("\u00D7")
        dismiss.setOnClickListener { animateDismiss() }
        row.addView(
            dismiss,
            LinearLayout.LayoutParams(dp(36), dp(36)).apply { marginStart = dp(4) }
        )

        swapContent(row)
    }

    // ---- Folder list (pick or create, all inline) ----

    private fun showFolderListContent() {
        cancelAutoDismiss()

        val container = LinearLayout(this)
        container.orientation = LinearLayout.VERTICAL
        container.setPadding(dp(14), dp(12), dp(14), dp(12))

        val header = TextView(this)
        header.text = "Save to folder"
        header.setTextColor(Color.WHITE)
        header.textSize = 13f
        header.typeface = Typeface.DEFAULT_BOLD
        container.addView(header)

        container.addView(
            spacer(dp(8))
        )

        val folders = listFolderNames()

        val scroll = ScrollView(this)
        val maxHeight = dp(220)
        scroll.layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        )

        val list = LinearLayout(this)
        list.orientation = LinearLayout.VERTICAL

        if (folders.isEmpty()) {
            val empty = TextView(this)
            empty.text = "No folders yet — create one below"
            empty.setTextColor(Color.rgb(170, 170, 175))
            empty.textSize = 12f
            empty.setPadding(dp(4), dp(6), dp(4), dp(6))
            list.addView(empty)
        }

        val lastUsed = prefs.getString(Prefs.KEY_LAST_FOLDER, null)

        for (folder in folders) {
            list.addView(folderRow(folder, folder == lastUsed))
        }

        scroll.addView(list)
        scroll.setOnHierarchyChangeListener(null)

        // Cap the scroll area height once measured, so a long
        // folder list doesn't push the overlay off-screen.
        list.post {
            val lp = scroll.layoutParams
            if (list.height > maxHeight) {
                lp.height = maxHeight
                scroll.layoutParams = lp
            }
        }

        container.addView(scroll)

        container.addView(spacer(dp(10)))
        container.addView(divider())
        container.addView(spacer(dp(10)))

        // New folder row.
        val newFolderRow = LinearLayout(this)
        newFolderRow.orientation = LinearLayout.HORIZONTAL
        newFolderRow.gravity = Gravity.CENTER_VERTICAL

        val input = EditText(this)
        input.hint = "New folder name"
        input.setHintTextColor(Color.rgb(140, 140, 145))
        input.setTextColor(Color.WHITE)
        input.textSize = 13f
        input.maxLines = 1
        input.inputType = InputType.TYPE_CLASS_TEXT
        input.background = roundedBackground(Color.rgb(42, 42, 48), 12f)
        input.setPadding(dp(10), dp(8), dp(10), dp(8))
        input.setOnFocusChangeListener { _, hasFocus ->
            setOverlayFocusable(hasFocus)
        }

        folderEditText = input

        newFolderRow.addView(
            input,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        )

        val addBtn = createIconButton("+")
        addBtn.setOnClickListener {
            val name = sanitizeFolderName(input.text?.toString().orEmpty())
            if (name.isEmpty()) return@setOnClickListener

            ensureFolder(name)
            hideSoftKeyboardAndUnfocus(input)
            commitSave(name)
        }

        newFolderRow.addView(
            addBtn,
            LinearLayout.LayoutParams(dp(36), dp(36)).apply { marginStart = dp(6) }
        )

        container.addView(newFolderRow)

        container.addView(spacer(dp(8)))

        val cancel = TextView(this)
        cancel.text = "Cancel"
        cancel.setTextColor(Color.rgb(150, 150, 155))
        cancel.textSize = 12f
        cancel.gravity = Gravity.CENTER
        cancel.setPadding(0, dp(4), 0, dp(2))
        cancel.setOnClickListener { animateDismiss() }
        container.addView(cancel)

        swapContent(container)
    }

    private fun folderRow(name: String, isLastUsed: Boolean): View {
        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL
        row.gravity = Gravity.CENTER_VERTICAL
        row.background = rippleRowBackground()
        row.isClickable = true
        row.isFocusable = true
        row.setPadding(dp(8), dp(10), dp(8), dp(10))

        val icon = TextView(this)
        icon.text = "\uD83D\uDCC1"
        icon.textSize = 15f

        row.addView(
            icon,
            LinearLayout.LayoutParams(dp(24), ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                marginEnd = dp(8)
            }
        )

        val label = TextView(this)
        label.text = name
        label.setTextColor(Color.WHITE)
        label.textSize = 13.5f
        label.maxLines = 1
        label.ellipsize = TextUtils.TruncateAt.END

        row.addView(
            label,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        )

        if (isLastUsed) {
            val tag = TextView(this)
            tag.text = "recent"
            tag.setTextColor(Color.rgb(60, 190, 165))
            tag.textSize = 10f
            row.addView(tag)
        }

        row.setOnClickListener {
            commitSave(name)
        }

        return row
    }

    private fun commitSave(folder: String) {
        appendMessage(folder, capturedText, "text")
        showSuccessContent(folder)
    }

    // ---- Success state ----

    private fun showSuccessContent(folder: String) {
    val container = LinearLayout(this)
    container.orientation = LinearLayout.HORIZONTAL
    container.gravity = Gravity.CENTER
    container.setPadding(dp(16), dp(14), dp(16), dp(14))

    // Success icon
    val check = ImageView(this)
    check.setImageResource(com.example.excerpt.R.drawable.ic_check)
    check.scaleType = ImageView.ScaleType.CENTER
    check.scaleX = 0f
    check.scaleY = 0f

    container.addView(
        check,
        LinearLayout.LayoutParams(
            dp(18),
            dp(18)
        ).apply {
            marginEnd = dp(6)
        }
    )

    // Success text
    val label = TextView(this)
    label.text = "Saved to \"$folder\""
    label.setTextColor(Color.WHITE)
    label.textSize = 13f
    label.gravity = Gravity.CENTER_VERTICAL

    container.addView(
        label,
        LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        )
    )

    swapContent(container)

    // Small check animation
    check.animate()
        .scaleX(1f)
        .scaleY(1f)
        .setStartDelay(ANIM_SHORT)
        .setDuration(220L)
        .setInterpolator(OvershootInterpolator())
        .start()

    handler.postDelayed({
        animateDismiss()
    }, SUCCESS_HOLD_DELAY + ANIM_SHORT)
}

    // ---- Focus handling for the inline "new folder" input ----

    private fun setOverlayFocusable(focusable: Boolean) {
        val params = windowParams ?: return
        val root = overlayRoot ?: return

        params.flags = if (focusable) {
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM
        } else {
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        }

        params.softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_PAN

        try {
            windowManager?.updateViewLayout(root, params)
        } catch (e: Exception) {
            Log.e(TAG, "Could not update overlay focusability", e)
        }
    }

    private fun hideSoftKeyboardAndUnfocus(input: EditText) {
        try {
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.hideSoftInputFromWindow(input.windowToken, 0)
        } catch (e: Exception) {
            Log.e(TAG, "Could not hide soft keyboard", e)
        }

        input.clearFocus()
        setOverlayFocusable(false)
    }

    // ============================================================
    // Small UI helpers
    // ============================================================

    private fun roundedBackground(color: Int, radiusDp: Float): GradientDrawable {
        val drawable = GradientDrawable()
        drawable.setColor(color)
        drawable.cornerRadius = radiusDp * resources.displayMetrics.density
        return drawable
    }

    private fun rippleRowBackground(): RippleDrawable {
        val normal = GradientDrawable()
        normal.setColor(Color.TRANSPARENT)
        normal.cornerRadius = dp(12).toFloat()

        val mask = GradientDrawable()
        mask.setColor(Color.WHITE)
        mask.cornerRadius = dp(12).toFloat()

        return RippleDrawable(
            android.content.res.ColorStateList.valueOf(Color.argb(60, 255, 255, 255)),
            normal,
            mask
        )
    }

    private fun pillButton(text: String, bg: Int, fg: Int): TextView {
        val button = TextView(this)
        button.text = text
        button.gravity = Gravity.CENTER
        button.setTextColor(fg)
        button.textSize = 12.5f
        button.typeface = Typeface.DEFAULT_BOLD
        button.background = roundedBackground(bg, 18f)
        button.isClickable = true
        button.isFocusable = true
        return button
    }

    private fun createIconButton(text: String): TextView {
        val button = TextView(this)
        button.text = text
        button.gravity = Gravity.CENTER
        button.setTextColor(Color.rgb(210, 210, 215))
        button.textSize = 17f
        button.background = roundedBackground(Color.rgb(45, 45, 50), 18f)
        button.isClickable = true
        button.isFocusable = true
        return button
    }

    private fun spacer(height: Int): View {
        val view = View(this)
        view.layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, height)
        return view
    }

    private fun divider(): View {
        val view = View(this)
        view.setBackgroundColor(Color.rgb(50, 50, 55))
        view.layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(1))
        return view
    }

    private fun createPreview(text: String): String {
        val normalized = text.replace(Regex("""\s+"""), " ").trim()
        val words = normalized.split(" ").filter { it.isNotBlank() }

        if (words.size <= PREVIEW_WORD_LIMIT) return normalized

        return words.take(PREVIEW_WORD_LIMIT).joinToString(" ") + "\u2026"
    }

    // ============================================================
    // Dismiss / cleanup
    // ============================================================

    private fun animateDismiss() {
        cancelAutoDismiss()

        val root = overlayRoot ?: return

        root.animate()
            .alpha(0f)
            .translationY(dp(-16).toFloat())
            .setDuration(ANIM_SHORT)
            .withEndAction { removeOverlayImmediate() }
            .start()
    }

    private fun removeOverlayImmediate() {
        cancelAutoDismiss()

        val view = overlayRoot ?: return

        try {
            windowManager?.removeView(view)
        } catch (e: Exception) {
            Log.d(TAG, "Overlay already removed")
        }

        overlayRoot = null
        cardContainer = null
        currentContent = null
        windowParams = null
        folderEditText = null
        lastShownText = null
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }
}