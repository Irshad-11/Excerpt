package com.example.excerpt

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import android.text.InputType
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.io.File
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.UUID

/**
 * Handles Android's share sheet ("Excerpt" shows up as a share
 * target) for plain text AND one-or-more images, from any app.
 *
 * Deliberately does NOT launch MainActivity / spin up the Flutter
 * engine — this is a small standalone floating dialog that writes
 * straight into the same SQLite database the rest of the app uses
 * (see ExcerptDatabaseHelper), then finish()es, handing control
 * straight back to whichever app the user shared from. That keeps
 * the user's workflow intact instead of yanking them into the full
 * app just to save one thing.
 *
 * Everything it saves is written with source = "system", same as the
 * IME overlay — from the app's point of view this content also
 * arrived "from outside", not typed in the composer.
 */
class ShareReceiverActivity : Activity() {

    private lateinit var databaseHelper: ExcerptDatabaseHelper
    private lateinit var prefs: android.content.SharedPreferences

    private var sharedText: String? = null
    private var sharedImageUris: List<Uri> = emptyList()

    private var captionInput: EditText? = null
    private var selectedFolder: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        databaseHelper = ExcerptDatabaseHelper(this)
        prefs = getSharedPreferences(Prefs.NAME, Context.MODE_PRIVATE)

        if (!parseIntent()) {
            finish()
            return
        }

        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.setLayout(
            (resources.displayMetrics.widthPixels * 0.88).toInt(),
            ViewGroup.LayoutParams.WRAP_CONTENT
        )
        window.setGravity(Gravity.CENTER)

        setContentView(buildRootView(buildFolderStepCard()))
    }

    // ============================================================
    // Parse the incoming share intent
    // ============================================================

    private fun parseIntent(): Boolean {
        val action = intent?.action
        val type = intent?.type ?: ""

        return when (action) {
            Intent.ACTION_SEND -> {
                if (type.startsWith("image/")) {
                    val uri = intent.getParcelableExtraCompat<Uri>(Intent.EXTRA_STREAM)
                        ?: return false
                    sharedImageUris = listOf(uri)
                    true
                } else {
                    val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                    if (text.isNullOrBlank()) return false
                    sharedText = text.trim()
                    true
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                if (!type.startsWith("image/")) return false
                val uris = intent.getParcelableArrayListExtraCompat<Uri>(Intent.EXTRA_STREAM)
                if (uris.isNullOrEmpty()) return false
                sharedImageUris = uris
                true
            }
            else -> false
        }
    }

    // ============================================================
    // Root container — tapping outside the card dismisses; tapping
    // the card itself does not (so buttons inside work normally).
    // ============================================================

    private fun buildRootView(card: LinearLayout): View {
        val outer = FrameLayout(this)
        outer.setOnClickListener { finish() }

        card.isClickable = true
        card.setOnClickListener { /* swallow — don't dismiss */ }

        outer.addView(
            card,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        return outer
    }

    // ============================================================
    // Step 1 — pick a folder
    // ============================================================

    private fun buildFolderStepCard(): LinearLayout {
        val card = LinearLayout(this)
        card.orientation = LinearLayout.VERTICAL
        card.background = roundedBackground(Color.rgb(28, 28, 32), 22f)
        card.setPadding(dp(18), dp(18), dp(18), dp(16))

        val title = TextView(this)
        title.text = "Save to Excerpt"
        title.setTextColor(Color.WHITE)
        title.textSize = 16f
        title.typeface = Typeface.DEFAULT_BOLD
        card.addView(title)

        card.addView(spacer(dp(8)))

        val preview = TextView(this)
        preview.text = buildPreviewLabel()
        preview.setTextColor(Color.rgb(190, 190, 195))
        preview.textSize = 12.5f
        preview.maxLines = 3
        preview.ellipsize = TextUtils.TruncateAt.END
        card.addView(preview)

        card.addView(spacer(dp(16)))

        val folderLabel = TextView(this)
        folderLabel.text = "Choose a folder"
        folderLabel.setTextColor(Color.rgb(150, 150, 155))
        folderLabel.textSize = 11f
        card.addView(folderLabel)

        card.addView(spacer(dp(6)))

        val folders = listFolderNames()
        val lastUsed = prefs.getString(Prefs.KEY_LAST_FOLDER, null)

        val list = LinearLayout(this)
        list.orientation = LinearLayout.VERTICAL

        if (folders.isEmpty()) {
            val empty = TextView(this)
            empty.text = "No folders yet — create one below"
            empty.setTextColor(Color.rgb(150, 150, 155))
            empty.textSize = 12f
            empty.setPadding(dp(4), dp(8), dp(4), dp(8))
            list.addView(empty)
        } else {
            for (folder in folders) {
                list.addView(folderRow(folder, folder == lastUsed) {
                    selectedFolder = folder
                    setContentView(buildRootView(buildCaptionStepCard()))
                })
            }
        }

        val scroll = ScrollView(this)
        scroll.addView(list)
        scroll.layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            dp(if (folders.size > 4) 190 else ViewGroup.LayoutParams.WRAP_CONTENT)
        )
        card.addView(scroll)

        card.addView(spacer(dp(10)))
        card.addView(divider())
        card.addView(spacer(dp(10)))

        val newFolderRow = LinearLayout(this)
        newFolderRow.orientation = LinearLayout.HORIZONTAL
        newFolderRow.gravity = Gravity.CENTER_VERTICAL

        val newFolderInput = EditText(this)
        newFolderInput.hint = "New folder name"
        newFolderInput.setHintTextColor(Color.rgb(140, 140, 145))
        newFolderInput.setTextColor(Color.WHITE)
        newFolderInput.textSize = 13f
        newFolderInput.maxLines = 1
        newFolderInput.inputType = InputType.TYPE_CLASS_TEXT
        newFolderInput.background = roundedBackground(Color.rgb(42, 42, 48), 12f)
        newFolderInput.setPadding(dp(10), dp(8), dp(10), dp(8))

        newFolderRow.addView(
            newFolderInput,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        )

        val addBtn = pillButton("Add", Color.rgb(60, 190, 165), Color.BLACK)
        addBtn.setOnClickListener {
            val name = newFolderInput.text?.toString()?.trim().orEmpty()
                .replace(Regex("""[\\/:*?"<>|]"""), "_")
            if (name.isEmpty()) return@setOnClickListener
            ensureFolder(name)
            selectedFolder = name
            setContentView(buildRootView(buildCaptionStepCard()))
        }
        newFolderRow.addView(
            addBtn,
            LinearLayout.LayoutParams(dp(60), dp(36)).apply { marginStart = dp(8) }
        )

        card.addView(newFolderRow)

        card.addView(spacer(dp(10)))

        val cancel = TextView(this)
        cancel.text = "Cancel"
        cancel.setTextColor(Color.rgb(150, 150, 155))
        cancel.textSize = 12.5f
        cancel.gravity = Gravity.CENTER
        cancel.setOnClickListener { finish() }
        card.addView(cancel)

        return card
    }

    private fun buildPreviewLabel(): String {
        return if (sharedImageUris.isNotEmpty()) {
            if (sharedImageUris.size == 1) "1 image" else "${sharedImageUris.size} images"
        } else {
            val text = sharedText ?: ""
            val words = text.replace(Regex("""\s+"""), " ").trim().split(" ")
            if (words.size <= 14) text else words.take(14).joinToString(" ") + "\u2026"
        }
    }

    // ============================================================
    // Step 2 — optional caption, then Save
    // ============================================================

    private fun buildCaptionStepCard(): LinearLayout {
        val card = LinearLayout(this)
        card.orientation = LinearLayout.VERTICAL
        card.background = roundedBackground(Color.rgb(28, 28, 32), 22f)
        card.setPadding(dp(18), dp(18), dp(18), dp(16))

        val title = TextView(this)
        title.text = "Save to \"$selectedFolder\""
        title.setTextColor(Color.WHITE)
        title.textSize = 15f
        title.typeface = Typeface.DEFAULT_BOLD
        title.maxLines = 1
        title.ellipsize = TextUtils.TruncateAt.END
        card.addView(title)

        card.addView(spacer(dp(10)))

        val label = TextView(this)
        label.text = if (sharedImageUris.isNotEmpty())
            "Add a caption (optional)" else "Add extra text (optional)"
        label.setTextColor(Color.rgb(150, 150, 155))
        label.textSize = 11f
        card.addView(label)

        card.addView(spacer(dp(6)))

        val input = EditText(this)
        input.hint = if (sharedImageUris.isNotEmpty())
            "e.g. where this was taken\u2026" else "Add a note\u2026"
        input.setHintTextColor(Color.rgb(130, 130, 135))
        input.setTextColor(Color.WHITE)
        input.textSize = 13f
        input.minLines = 1
        input.maxLines = 3
        input.background = roundedBackground(Color.rgb(42, 42, 48), 12f)
        input.setPadding(dp(10), dp(8), dp(10), dp(8))
        captionInput = input
        card.addView(input)

        card.addView(spacer(dp(16)))

        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL

        val back = TextView(this)
        back.text = "Back"
        back.setTextColor(Color.rgb(150, 150, 155))
        back.textSize = 13f
        back.gravity = Gravity.CENTER
        back.setOnClickListener {
            selectedFolder = null
            setContentView(buildRootView(buildFolderStepCard()))
        }
        row.addView(back, LinearLayout.LayoutParams(0, dp(40), 1f))

        row.addView(spacer(dp(8)).apply {
            layoutParams = LinearLayout.LayoutParams(dp(8), dp(40))
        })

        val save = pillButton("Save", Color.rgb(60, 190, 165), Color.BLACK)
        save.setOnClickListener { commitSave() }
        row.addView(save, LinearLayout.LayoutParams(0, dp(40), 1f))

        card.addView(row)

        return card
    }

    // ============================================================
    // Commit
    // ============================================================

    private fun commitSave() {
        val folder = selectedFolder ?: return
        val caption = captionInput?.text?.toString()?.trim().orEmpty()

        try {
            if (sharedImageUris.isNotEmpty()) {
                var savedCount = 0
                for (uri in sharedImageUris) {
                    val savedPath = copyUriToAppStorage(uri) ?: continue
                    appendImageMessage(folder, savedPath, caption)
                    savedCount++
                }
                if (savedCount == 0) {
                    throw IllegalStateException("Could not read the shared image(s)")
                }
            } else {
                val text = sharedText.orEmpty()
                val finalText = if (caption.isNotEmpty()) "$text\n\n$caption" else text
                appendTextMessage(folder, finalText)
            }

            prefs.edit().putString(Prefs.KEY_LAST_FOLDER, folder).apply()

            Toast.makeText(this, "Saved to \"$folder\"", Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
            Toast.makeText(this, "Could not save: ${e.message}", Toast.LENGTH_LONG).show()
        }

        finish()
    }

    // ============================================================
    // File copy — content:// URIs from other apps aren't guaranteed
    // to stay readable later, so copy the bytes into our own storage
    // first, same as the Flutter composer does.
    // ============================================================

    private fun copyUriToAppStorage(uri: Uri): String? {
        return try {
            val imagesDir = File(filesDir, "images")
            if (!imagesDir.exists()) imagesDir.mkdirs()

            val mimeType = contentResolver.getType(uri)
            val ext = when {
                mimeType?.contains("png") == true -> ".png"
                mimeType?.contains("webp") == true -> ".webp"
                mimeType?.contains("gif") == true -> ".gif"
                else -> ".jpg"
            }

            val destFile = File(imagesDir, "${UUID.randomUUID()}$ext")

            contentResolver.openInputStream(uri)?.use { input ->
                destFile.outputStream().use { output -> input.copyTo(output) }
            } ?: return null

            destFile.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    // ============================================================
    // Data layer — same physical SQLite DB as Flutter and the IME
    // overlay (filesDir/excerpt.db via ExcerptDatabaseHelper).
    // ============================================================

    private fun listFolderNames(): List<String> {
        val db = try {
            databaseHelper.readableDatabase
        } catch (e: Exception) {
            return emptyList()
        }

        val names = mutableListOf<String>()
        db.query(
            "folders", arrayOf("name"), null, null, null, null,
            "name COLLATE NOCASE ASC"
        ).use { cursor ->
            val idx = cursor.getColumnIndexOrThrow("name")
            while (cursor.moveToNext()) names.add(cursor.getString(idx))
        }

        val lastUsed = prefs.getString(Prefs.KEY_LAST_FOLDER, null)
        if (lastUsed != null && names.remove(lastUsed)) names.add(0, lastUsed)

        return names
    }

    private fun ensureFolder(name: String): Long {
        val db = databaseHelper.writableDatabase

        db.query("folders", arrayOf("id"), "name = ?", arrayOf(name), null, null, null, "1")
            .use { cursor ->
                if (cursor.moveToFirst()) {
                    return cursor.getLong(cursor.getColumnIndexOrThrow("id"))
                }
            }

        val values = ContentValues().apply {
            put("name", name)
            put("created_at", isoTimestamp())
        }

        val id = db.insertWithOnConflict(
            "folders", null, values, android.database.sqlite.SQLiteDatabase.CONFLICT_IGNORE
        )
        if (id != -1L) return id

        db.query("folders", arrayOf("id"), "name = ?", arrayOf(name), null, null, null, "1")
            .use { cursor ->
                if (cursor.moveToFirst()) {
                    return cursor.getLong(cursor.getColumnIndexOrThrow("id"))
                }
            }

        throw IllegalStateException("Could not create or find folder: $name")
    }

    private fun appendTextMessage(folder: String, text: String) {
        val db = databaseHelper.writableDatabase
        val folderId = ensureFolder(folder)

        val values = ContentValues().apply {
            put("id", UUID.randomUUID().toString())
            put("folder_id", folderId)
            put("text", text)
            put("type", "text")
            put("source", "system")
            put("timestamp", isoTimestamp())
            put("important", 0)
            put("edited", 0)
            putNull("extra")
            putNull("image_path")
        }

        db.insert("messages", null, values)
    }

    private fun appendImageMessage(folder: String, imagePath: String, caption: String) {
        val db = databaseHelper.writableDatabase
        val folderId = ensureFolder(folder)

        val values = ContentValues().apply {
            put("id", UUID.randomUUID().toString())
            put("folder_id", folderId)
            put("text", caption)
            put("type", "image")
            put("source", "system")
            put("timestamp", isoTimestamp())
            put("important", 0)
            put("edited", 0)
            putNull("extra")
            put("image_path", imagePath)
        }

        db.insert("messages", null, values)
    }

    private fun isoTimestamp(): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US)
        return sdf.format(java.util.Date())
    }

    // ============================================================
    // Small UI helpers — intentionally the same hand-built look as
    // the IME overlay (ExcerptInputMethodService), so this feels like
    // part of the same app rather than a bolted-on extra.
    // ============================================================

    private fun roundedBackground(color: Int, radiusDp: Float): GradientDrawable {
        val drawable = GradientDrawable()
        drawable.setColor(color)
        drawable.cornerRadius = radiusDp * resources.displayMetrics.density
        return drawable
    }

    private fun pillButton(text: String, bg: Int, fg: Int): TextView {
        val button = TextView(this)
        button.text = text
        button.gravity = Gravity.CENTER
        button.setTextColor(fg)
        button.textSize = 13f
        button.typeface = Typeface.DEFAULT_BOLD
        button.background = roundedBackground(bg, 18f)
        button.isClickable = true
        button.isFocusable = true
        return button
    }

    private fun folderRow(name: String, isLastUsed: Boolean, onClick: () -> Unit): View {
        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL
        row.gravity = Gravity.CENTER_VERTICAL
        row.isClickable = true
        row.isFocusable = true
        row.setPadding(dp(6), dp(10), dp(6), dp(10))

        val icon = TextView(this)
        icon.text = "\uD83D\uDCC1"
        icon.textSize = 15f
        row.addView(icon, LinearLayout.LayoutParams(dp(24), ViewGroup.LayoutParams.WRAP_CONTENT))

        val label = TextView(this)
        label.text = name
        label.setTextColor(Color.WHITE)
        label.textSize = 13.5f
        label.maxLines = 1
        label.ellipsize = TextUtils.TruncateAt.END
        row.addView(label, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))

        if (isLastUsed) {
            val tag = TextView(this)
            tag.text = "recent"
            tag.setTextColor(Color.rgb(60, 190, 165))
            tag.textSize = 10f
            row.addView(tag)
        }

        row.setOnClickListener { onClick() }
        return row
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

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}

// ================================================================
// Parcelable-extra retrieval changed shape across Android versions —
// small compat helpers so this works from older devices through the
// latest without deprecation warnings driving the behaviour.
// ================================================================

@Suppress("DEPRECATION")
private inline fun <reified T : Parcelable> Intent.getParcelableExtraCompat(name: String): T? {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelableExtra(name, T::class.java)
    } else {
        getParcelableExtra(name)
    }
}

@Suppress("DEPRECATION")
private inline fun <reified T : Parcelable> Intent.getParcelableArrayListExtraCompat(name: String): ArrayList<T>? {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelableArrayListExtra(name, T::class.java)
    } else {
        getParcelableArrayListExtra(name)
    }
}