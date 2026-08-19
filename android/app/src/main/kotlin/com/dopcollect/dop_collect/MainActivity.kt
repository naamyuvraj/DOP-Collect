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
    //
    // Set here, at onCreate, so the app is secure from its first frame — before
    // any Dart has run and before the setting below can be read. Dart may then
    // relax it (see the `setSecure` channel method); it can never be the case
    // that the app starts unprotected and gets locked down a moment later.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setSecure(true)
    }

    /**
     * Turn the screenshot/recording block on or off.
     *
     * Off is a deliberate, per-device choice made in Settings — the agent
     * needed to send a screenshot of a problem, and a protection with no way
     * round it just means photographing the screen with another phone, which
     * protects nothing and loses the report.
     */
    private fun setSecure(on: Boolean) {
        if (on) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
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
                    "setSecure" -> {
                        // Window flags are main-thread only; channel calls
                        // already arrive there, but be explicit — a stray
                        // background call would throw and take the app down.
                        val on = call.argument<Boolean>("on") ?: true
                        runOnUiThread { setSecure(on) }
                        result.success(true)
                    }
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
