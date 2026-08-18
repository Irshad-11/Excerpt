package com.example.excerpt

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.text.TextUtils
import android.view.inputmethod.InputMethodManager
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL =
        "com.excerpt/native"

    private var methodChannel:
        MethodChannel? = null

    override fun configureFlutterEngine(
        @NonNull flutterEngine: FlutterEngine
    ) {

        super.configureFlutterEngine(
            flutterEngine
        )

        methodChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                CHANNEL
            )

        methodChannel?.setMethodCallHandler {
                call,
                result ->

            val prefs =
                getSharedPreferences(
                    Prefs.NAME,
                    Context.MODE_PRIVATE
                )

            when (call.method) {

                "getAppFilesDir" -> {

                    result.success(
                        filesDir.absolutePath
                    )
                }

                "isClipboardEnabled" -> {

                    result.success(
                        prefs.getBoolean(
                            Prefs.KEY_ENABLED,
                            false
                        )
                    )
                }

                "setClipboardEnabled" -> {

                    val value =
                        call.arguments as Boolean

                    prefs.edit()
                        .putBoolean(
                            Prefs.KEY_ENABLED,
                            value
                        )
                        .apply()

                    result.success(
                        null
                    )
                }

                "canDrawOverlays" -> {

                    val can =
                        if (
                            Build.VERSION.SDK_INT >=
                            Build.VERSION_CODES.M
                        ) {

                            Settings.canDrawOverlays(
                                this
                            )

                        } else {

                            true
                        }

                    result.success(
                        can
                    )
                }

                "requestOverlayPermission" -> {

                    if (
                        Build.VERSION.SDK_INT >=
                        Build.VERSION_CODES.M
                    ) {

                        val intent =
                            Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse(
                                    "package:$packageName"
                                )
                            )

                        startActivity(
                            intent
                        )
                    }

                    result.success(
                        null
                    )
                }

                "isExcerptDefaultIme" -> {

                    result.success(
                        isExcerptDefaultIme()
                    )
                }

                "openImeSettings" -> {

                    openImeSettings()

                    result.success(
                        null
                    )
                }

                "openInputMethodPicker" -> {

                    val imm =
                        getSystemService(
                            Context.INPUT_METHOD_SERVICE
                        ) as InputMethodManager

                    imm.showInputMethodPicker()

                    result.success(
                        null
                    )
                }

                "getPendingClipText" -> {

                    result.success(
                        prefs.getString(
                            Prefs.KEY_PENDING_TEXT,
                            null
                        )
                    )
                }

                "clearPendingClipText" -> {

                    prefs.edit()
                        .remove(
                            Prefs.KEY_PENDING_TEXT
                        )
                        .apply()

                    result.success(
                        null
                    )
                }

                else -> {

                    result.notImplemented()
                }
            }
        }

        handleIntent(
            intent
        )
    }

    override fun onNewIntent(
        intent: Intent
    ) {

        super.onNewIntent(
            intent
        )

        setIntent(
            intent
        )

        handleIntent(
            intent
        )
    }

    private fun handleIntent(
        intent: Intent?
    ) {

        if (
            intent?.action ==
            Prefs.ACTION_SAVE_CLIP
        ) {

            val text =
                intent.getStringExtra(
                    Prefs.KEY_PENDING_TEXT
                )

            if (
                !text.isNullOrEmpty()
            ) {

                val prefs =
                    getSharedPreferences(
                        Prefs.NAME,
                        Context.MODE_PRIVATE
                    )

                prefs.edit()
                    .putString(
                        Prefs.KEY_PENDING_TEXT,
                        text
                    )
                    .apply()

                methodChannel?.invokeMethod(
                    "pendingClipText",
                    text
                )
            }
        }
    }

    private fun isExcerptDefaultIme():
        Boolean {

        val imm =
            getSystemService(
                Context.INPUT_METHOD_SERVICE
            ) as InputMethodManager

        val enabled =
            imm.enabledInputMethodList

        val ourPackage =
            packageName

        val isEnabled =
            enabled.any {
                it.packageName ==
                    ourPackage
            }

        if (!isEnabled) {
            return false
        }

        val defaultIme =
            Settings.Secure.getString(
                contentResolver,
                Settings.Secure.DEFAULT_INPUT_METHOD
            )

        return defaultIme?.startsWith(
            ourPackage
        ) == true
    }

    private fun openImeSettings() {

        try {

            startActivity(
                Intent(
                    Settings.ACTION_INPUT_METHOD_SETTINGS
                )
            )

        } catch (_: Exception) {

            startActivity(
                Intent(
                    Settings.ACTION_SETTINGS
                )
            )
        }
    }
}