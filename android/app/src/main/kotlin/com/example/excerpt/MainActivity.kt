package com.example.excerpt

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.excerpt/native"

    private var methodChannel: MethodChannel? = null

    private val NOTIFICATION_PERMISSION_REQUEST_CODE = 5001

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
}