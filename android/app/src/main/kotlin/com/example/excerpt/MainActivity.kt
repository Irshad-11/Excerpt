package com.example.excerpt

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.excerpt/native"

    private var methodChannel: MethodChannel? = null

    private val NOTIFICATION_PERMISSION_REQUEST_CODE = 5001
    private val PICK_IMPORT_FILE_REQUEST_CODE = 5002

    // Holds the Flutter `result` callback while the system file
    // picker (started for a result) is open, since "pickImportFile"
    // can't reply synchronously like the other channel methods.
    private var pendingImportResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        )

        methodChannel?.setMethodCallHandler { call, result ->

            val prefs = getSharedPreferences(Prefs.NAME, Context.MODE_PRIVATE)

            when (call.method) {

                // =================================================
                // App files
                // =================================================

                "getAppFilesDir" -> {
                    result.success(filesDir.absolutePath)
                }

                // =================================================
                // Clipboard monitoring
                // =================================================

                "isClipboardEnabled" -> {
                    result.success(prefs.getBoolean(Prefs.KEY_ENABLED, false))
                }

                "setClipboardEnabled" -> {
                    val value = call.arguments as Boolean

                    prefs.edit().putBoolean(Prefs.KEY_ENABLED, value).apply()

                    result.success(null)
                }

                // =================================================
                // Overlay permission
                // =================================================

                "canDrawOverlays" -> {
                    val can = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        Settings.canDrawOverlays(this)
                    } else {
                        true
                    }

                    result.success(can)
                }

                "requestOverlayPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName")
                                )
                            )
                        } catch (e: Exception) {
                            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION))
                        }
                    }

                    result.success(null)
                }

                // =================================================
                // Notification permission (Android 13+ / 16)
                // =================================================

                "hasNotificationPermission" -> {
                    val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                            android.content.pm.PackageManager.PERMISSION_GRANTED
                    } else {
                        NotificationManagerCompat.from(this).areNotificationsEnabled()
                    }

                    result.success(granted)
                }

                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                            NOTIFICATION_PERMISSION_REQUEST_CODE
                        )
                    }

                    result.success(null)
                }

                // =================================================
                // Input Method
                // =================================================

                "isExcerptDefaultIme" -> {
                    result.success(isExcerptDefaultIme())
                }

                "openImeSettings" -> {
                    openImeSettings()
                    result.success(null)
                }

                "openInputMethodPicker" -> {
                    try {
                        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                        imm.showInputMethodPicker()
                    } catch (e: Exception) {
                        result.error("IME_PICKER_ERROR", e.message, null)
                        return@setMethodCallHandler
                    }

                    result.success(null)
                }

                // =================================================
                // Pending clipboard text
                // =================================================

                "getPendingClipText" -> {
                    result.success(prefs.getString(Prefs.KEY_PENDING_TEXT, null))
                }

                "clearPendingClipText" -> {
                    prefs.edit().remove(Prefs.KEY_PENDING_TEXT).apply()
                    result.success(null)
                }

                // =================================================
                // Data export / import (Settings screen)
                // =================================================

                "shareFile" -> {
                    val path = call.arguments as String

                    try {
                        shareFile(path)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("SHARE_FILE_ERROR", e.message, null)
                    }
                }

                "pickImportFile" -> {
                    // Async: the actual result is delivered later from
                    // onActivityResult(), once the user picks a file.
                    pendingImportResult = result
                    pickImportFile()
                }

                else -> {
                    result.notImplemented()
                }
            }
        }

        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)

        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action == Prefs.ACTION_SAVE_CLIP) {
            val text = intent.getStringExtra(Prefs.KEY_PENDING_TEXT)

            if (!text.isNullOrEmpty()) {
                val prefs = getSharedPreferences(Prefs.NAME, Context.MODE_PRIVATE)

                prefs.edit().putString(Prefs.KEY_PENDING_TEXT, text).apply()

                methodChannel?.invokeMethod("pendingClipText", text)
            }
        }
    }

    private fun isExcerptDefaultIme(): Boolean {
        return try {
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            val enabled = imm.enabledInputMethodList
            val ourPackage = packageName

            val isEnabled = enabled.any { it.packageName == ourPackage }
            if (!isEnabled) return false

            val defaultIme = Settings.Secure.getString(
                contentResolver,
                Settings.Secure.DEFAULT_INPUT_METHOD
            )

            defaultIme?.startsWith(ourPackage) == true
        } catch (e: Exception) {
            false
        }
    }

    private fun openImeSettings() {
        try {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_SETTINGS))
        }
    }

    // =====================================================
    // Data export — hand the file to the OS share sheet
    // =====================================================

    private fun shareFile(path: String) {
        val file = File(path)

        val uri: Uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file
        )

        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "application/json"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        startActivity(Intent.createChooser(intent, "Export Excerpt data"))
    }

    // =====================================================
    // Data import — system document picker
    // =====================================================

    private fun pickImportFile() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
        }

        try {
            startActivityForResult(intent, PICK_IMPORT_FILE_REQUEST_CODE)
        } catch (e: Exception) {
            pendingImportResult?.error("IMPORT_PICKER_ERROR", e.message, null)
            pendingImportResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode != PICK_IMPORT_FILE_REQUEST_CODE) return

        val pendingResult = pendingImportResult
        pendingImportResult = null

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            // User cancelled — Dart side treats a null path as "cancelled".
            pendingResult?.success(null)
            return
        }

        try {
            val importsDir = File(filesDir, "imports")
            if (!importsDir.exists()) importsDir.mkdirs()

            val fileName = queryDisplayName(uri) ?: "import_${System.currentTimeMillis()}.json"
            val destFile = File(importsDir, fileName)

            contentResolver.openInputStream(uri)?.use { input ->
                destFile.outputStream().use { output -> input.copyTo(output) }
            } ?: throw IllegalStateException("Could not open the selected file")

            pendingResult?.success(destFile.absolutePath)
        } catch (e: Exception) {
            pendingResult?.error("IMPORT_READ_ERROR", e.message, null)
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        var name: String? = null

        val cursor: Cursor? = contentResolver.query(uri, null, null, null, null)
        cursor?.use {
            if (it.moveToFirst()) {
                val idx = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) name = it.getString(idx)
            }
        }

        return name
    }
}