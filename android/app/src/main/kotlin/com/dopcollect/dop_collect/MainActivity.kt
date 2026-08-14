package com.dopcollect.dop_collect

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "dop_collect/app"

    // FLAG_SECURE: the app shows customer names, account numbers, amounts and a
    // live banking login form (password field) inside the sync WebView. This
    // keeps all of it out of the Android recents thumbnail (persisted to disk),
    // screenshots, screen recorders and MediaProjection/casting captures.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "restart" -> {
                        result.success(true)
                        restartApp()
                    }
                    "deviceInfo" -> result.success(deviceInfo())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * What phone this is, and a hardware-backed handle for it.
     *
     * `androidId` (Settings.Secure.ANDROID_ID) is the one identifier that
     * survives an uninstall/reinstall or a "Clear data" — the app's own random
     * id lives in app storage and does not, which is why one phone could show up
     * as several devices. It is scoped to this app's signing key and this user,
     * and resets on factory reset, so it identifies the install-target rather
     * than the person. Dart hashes it before it is used or sent.
     *
     * No third-party Gradle dependency for this, matching the reasoning on
     * `restart` above — `device_info_plus` would pull in a whole plugin to read
     * three fields of `android.os.Build`.
     */
    private fun deviceInfo(): Map<String, Any?> = mapOf(
        "androidId" to android.provider.Settings.Secure.getString(
            contentResolver, android.provider.Settings.Secure.ANDROID_ID
        ),
        "model" to android.os.Build.MODEL,
        "manufacturer" to android.os.Build.MANUFACTURER,
        "sdkInt" to android.os.Build.VERSION.SDK_INT
    )

    // Full restart: launch a fresh task, then kill this process. The relaunch is
    // a genuine COLD start, which is what makes the app pick up a downloaded
    // Shorebird patch. (Same mechanism the restart_app plugin uses, but built in
    // so there's no third-party Gradle dependency.)
    private fun restartApp() {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        intent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        startActivity(intent)
        Runtime.getRuntime().exit(0)
    }
}
